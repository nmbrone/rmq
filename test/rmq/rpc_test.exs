defmodule RMQ.RPCTest do
  use RMQ.Case

  defmodule Worker do
    use RMQ.RPC,
      connection: RMQ.TestConnection,
      publishing_options: [app_id: "RMQ Test"],
      restart_delay: 100
  end

  defmodule Worker2 do
    use RMQ.RPC,
      connection: RMQ.TestConnection,
      exchange: "rmq"
  end

  setup_all do
    {:ok, conn} = RMQ.TestConnection.get_connection()
    {:ok, chan} = AMQP.Channel.open(conn)

    {:ok, %{queue: queue}} = AMQP.Queue.declare(chan, "", exclusive: true, auto_delete: true)
    {:ok, %{queue: slow_queue}} = AMQP.Queue.declare(chan, "", exclusive: true, auto_delete: true)

    AMQP.Queue.subscribe(chan, queue, fn payload, meta ->
      params = Jason.decode!(payload)
      res = Jason.encode!(%{params: params, response: %{ok: true}})
      AMQP.Basic.publish(chan, "", meta.reply_to, res, correlation_id: meta.correlation_id)
      send(:current_test, {:consumed, params, meta})
    end)

    AMQP.Queue.subscribe(chan, slow_queue, fn payload, meta ->
      params = Jason.decode!(payload)
      res = Jason.encode!(%{params: params, response: %{ok: true}})
      Process.sleep(200)
      AMQP.Basic.publish(chan, "", meta.reply_to, res, correlation_id: meta.correlation_id)
      send(:current_test, {:consumed, params, meta})
    end)

    start_supervised!(Worker)

    %{conn: conn, chan: chan, queue: queue, slow_queue: slow_queue}
  end

  test "performs call", ctx do
    res = Worker.remote_call(ctx.queue, %{user_id: "USR"})
    assert res == %{"params" => %{"user_id" => "USR"}, "response" => %{"ok" => true}}
  end

  test "handles multiple calls from different processes", %{queue: queue, slow_queue: slow_queue} do
    params = %{user_id: "USR"}
    response = %{"params" => %{"user_id" => "USR"}, "response" => %{"ok" => true}}
    me = self()

    for q <- [slow_queue, queue] do
      spawn(fn ->
        res = Worker.remote_call(q, params)
        send(me, {q, res})
      end)
    end

    assert_receive {^queue, ^response}, 300
    assert_receive {^slow_queue, ^response}, 300
  end

  test "handles multiple calls from same process", %{queue: queue, slow_queue: slow_queue} do
    assert %{"params" => %{"req" => 1}} = Worker.remote_call(slow_queue, %{req: 1})
    assert %{"params" => %{"req" => 2}} = Worker.remote_call(queue, %{req: 2})
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
    assert %{"response" => _} = Worker2.remote_call(queue, %{})
  end

  test "correctly merges publishing options", %{queue: queue} do
    params = %{"id" => "123"}
    timestamp = DateTime.utc_now() |> DateTime.to_unix()

    Worker.remote_call(queue, params)
    assert_receive {:consumed, ^params, %{app_id: "RMQ Test", timestamp: :undefined}}

    Worker.remote_call(queue, params, app_id: "RMQ RPC Test", timestamp: timestamp)
    assert_receive {:consumed, ^params, %{app_id: "RMQ RPC Test", timestamp: ^timestamp}}
  end
end
