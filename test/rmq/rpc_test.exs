defmodule RMQ.RPCTest do
  use RMQ.Case
  import ExUnit.CaptureLog

  @moduletag :capture_log

  defmodule Worker do
    use RMQ.RPC

    def setup_queue(chan, config) do
      super(chan, config)
    end

    def config do
      [
        connection: RMQ.TestConnection,
        publishing_options: [app_id: "RMQ Test"],
        reconnect_interval: fn _ -> 200 end,
        filter_parameters: ~w[password secret]
      ]
    end
  end

  defmodule Worker2 do
    use RMQ.RPC,
      connection: RMQ.TestConnection,
      exchange: "rmq"
  end

  setup do
    {:ok, conn} = RMQ.TestConnection.get_connection()
    {:ok, chan} = AMQP.Channel.open(conn)

    {:ok, %{queue: queue}} = AMQP.Queue.declare(chan, "", exclusive: true, auto_delete: true)
    {:ok, %{queue: slow_queue}} = AMQP.Queue.declare(chan, "", exclusive: true, auto_delete: true)

    AMQP.Queue.subscribe(chan, queue, fn payload, meta ->
      params = Jason.decode!(payload)
      res = Jason.encode!(%{params: params, response: %{ok: true, password: "password"}})
      RMQ.Utils.reply(chan, meta, res)
      send(:current_test, {:consumed, params, meta})
    end)

    AMQP.Queue.subscribe(chan, slow_queue, fn payload, meta ->
      params = Jason.decode!(payload)
      res = Jason.encode!(%{params: params, response: %{ok: true, password: "password"}})
      Process.sleep(200)
      RMQ.Utils.reply(chan, meta, res)
      send(:current_test, {:consumed, params, meta})
    end)

    start_supervised!(Worker)

    %{conn: conn, chan: chan, queue: queue, slow_queue: slow_queue}
  end

  test "performs the call", ctx do
    res = {:ok, %{"response" => %{"ok" => true, "password" => "password"}, "params" => %{}}}
    assert res == Worker.call(ctx.queue)
    assert res == Worker.call(ctx.queue, %{})
    assert res == Worker.call(ctx.queue, %{}, app_id: "TestApp")
    assert res == Worker.call(ctx.queue, %{}, [app_id: "TestApp"], 1000)
  end

  test "handles multiple calls from different processes", %{queue: queue, slow_queue: slow_queue} do
    me = self()

    for q <- [slow_queue, queue] do
      spawn(fn ->
        res = Worker.call(q, %{user_id: "USR"})
        send(me, {q, res})
      end)
    end

    assert_receive {^queue, {:ok, %{"response" => %{}}}}, 300
    assert_receive {^slow_queue, {:ok, %{"response" => %{}}}}, 300
  end

  test "handles multiple calls from the same process", %{queue: queue, slow_queue: slow_queue} do
    assert {:ok, %{"params" => %{"req" => 1}}} = Worker.call(slow_queue, %{req: 1})
    assert {:ok, %{"params" => %{"req" => 2}}} = Worker.call(queue, %{req: 2})
  end

  test "works with non default exchange", %{chan: chan} do
    exchange = "rmq"
    queue = "rmq_rpc_1"
    :ok = AMQP.Exchange.delete(chan, exchange)
    :ok = AMQP.Exchange.declare(chan, exchange, :direct)
    {:ok, _} = AMQP.Queue.delete(chan, queue)
    {:ok, _} = AMQP.Queue.declare(chan, queue, exclusive: true, auto_delete: true)
    :ok = AMQP.Queue.bind(chan, queue, exchange, routing_key: queue)

    AMQP.Queue.subscribe(chan, queue, fn payload, meta ->
      params = Jason.decode!(payload)
      res = Jason.encode!(%{params: params, response: %{ok: true}})

      AMQP.Basic.publish(chan, meta.exchange, meta.reply_to, res,
        correlation_id: meta.correlation_id
      )
    end)

    start_supervised!(Worker2)
    assert {:ok, _} = Worker2.call(queue, %{})
  end

  test "correctly merges publishing options", %{queue: queue} do
    params = %{"id" => "123"}
    timestamp = DateTime.utc_now() |> DateTime.to_unix()

    Worker.call(queue, params)
    assert_receive {:consumed, ^params, %{app_id: "RMQ Test", timestamp: :undefined}}

    Worker.call(queue, params, app_id: "RMQ RPC Test", timestamp: timestamp)
    assert_receive {:consumed, ^params, %{app_id: "RMQ RPC Test", timestamp: ^timestamp}}
  end

  test "reconnects in case of losing connection", %{conn: conn, queue: queue} do
    Process.sleep(100)
    AMQP.Connection.close(conn)
    assert {:error, :not_connected} = Worker.call(queue)
    Process.sleep(100)
    assert {:error, :not_connected} = Worker.call(queue)
    Process.sleep(100)
    # we got timeout here since the consumer for the queue which is defined in :setup block
    # was canceled when the connection was lost
    assert {:error, :timeout} = Worker.call(queue, %{}, [], 100)
  end

  test "does filter outbound parameters in logs", ctx do
    log =
      capture_log(fn ->
        Worker.call(ctx.queue, %{secret: "secret"})
      end)

    assert log =~ ~s/"secret" => "[FILTERED]"/
  end

  test "does filter inbound parameters in logs", ctx do
    log =
      capture_log(fn ->
        Worker.call(ctx.queue)
      end)

    assert log =~ ~s/"password" => "[FILTERED]"/
  end
end
