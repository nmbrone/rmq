defmodule RMQ.RPCTest do
  use ExUnit.Case
  import TestHelper

  defmodule Worker do
    use RMQ.RPC
    def call(route, payload), do: remote_call(route, payload)
  end

  setup_all do
    {:ok, _pid} = RMQ.Connection.start_link(uri: rabbit_uri())
    {:ok, _pid} = Worker.start_link()
    {:ok, conn} = RMQ.Connection.get_connection()
    {:ok, chan} = AMQP.Channel.open(conn)
    {:ok, %{queue: queue}} = AMQP.Queue.declare(chan, "", exclusive: true, auto_delete: true)
    {:ok, %{queue: slow_queue}} = AMQP.Queue.declare(chan, "", exclusive: true, auto_delete: true)

    AMQP.Queue.subscribe(chan, queue, fn payload, meta ->
      params = Jason.decode!(payload)
      res = Jason.encode!(%{params: params, response: %{ok: true}})
      AMQP.Basic.publish(chan, "", meta.reply_to, res, correlation_id: meta.correlation_id)
    end)

    AMQP.Queue.subscribe(chan, slow_queue, fn payload, meta ->
      params = Jason.decode!(payload)
      res = Jason.encode!(%{params: params, response: %{ok: true}})
      Process.sleep(200)
      AMQP.Basic.publish(chan, "", meta.reply_to, res, correlation_id: meta.correlation_id)
    end)

    %{chan: chan, queue: queue, slow_queue: slow_queue}
  end

  describe "remote_call/3" do
    test "performs call", ctx do
      res = Worker.call(ctx.queue, %{user_id: "USR"})
      assert res == %{"params" => %{"user_id" => "USR"}, "response" => %{"ok" => true}}
    end

    test "handles multiple calls", %{queue: queue, slow_queue: slow_queue} do
      params = %{user_id: "USR"}
      response = %{"params" => %{"user_id" => "USR"}, "response" => %{"ok" => true}}
      me = self()

      for queue <- [slow_queue, queue] do
        spawn(fn ->
          res = Worker.call(queue, params)
          send(me, {queue, res})
        end)
      end

      assert_receive {^queue, ^response}, 300
      assert_receive {^slow_queue, ^response}, 300
    end
  end
end
