defmodule RMQ.RPC do
  @moduledoc """
  RPC via RabbitMQ.

  ## Example

      defmodule MyApp.User do
        use RMQ.RPC, timeout: 5000

        def find_by_id(id) do
          remote_call("remote_user_finder", user_id: id)
        end
      end

  """

  defmacro __using__(opts \\ []) do
    quote location: :keep do
      require Logger
      use GenServer

      @default_timeout unquote(Keyword.get(opts, :timeout, 5000))

      def start_link() do
        GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
      end

      def remote_call(queue, payload \\ nil, timeout \\ @default_timeout) do
        GenServer.call(__MODULE__, {:publish, queue, payload}, timeout)
      end

      @impl GenServer
      def init(:ok) do
        send(self(), :init)
        {:ok, %{chan: nil, queue: nil, pids: %{}}}
      end

      @impl GenServer
      def handle_call({:publish, queue, payload}, from, state) do
        correlation_id = UUID.uuid1()

        Logger.debug("""
        #{__MODULE__} publish
          Queue: #{inspect(queue)}
          Payload: #{inspect(payload)}
        """)

        AMQP.Basic.publish(state.chan, "", queue, Jason.encode!(payload),
          reply_to: state.queue,
          correlation_id: correlation_id,
          content_type: "application/json"
        )

        {:noreply, put_in(state.pids[correlation_id], from)}
      end

      @impl GenServer
      def handle_info(:init, state) do
        case RMQ.Connection.get_connection() do
          {:ok, conn} ->
            {:ok, chan} = AMQP.Channel.open(conn)
            Process.monitor(chan.pid)

            {:ok, %{queue: queue}} =
              AMQP.Queue.declare(chan, "", exclusive: true, auto_delete: true)

            {:ok, _} = AMQP.Basic.consume(chan, queue)
            {:noreply, %{state | chan: chan, queue: queue}}

          {:error, :not_connected} ->
            Process.send_after(self(), :init, 5000)
            {:noreply, state}
        end
      end

      # Confirmation sent by the broker after registering this process as a consumer
      @impl GenServer
      def handle_info({:basic_consume_ok, _meta}, state) do
        {:noreply, state}
      end

      # Sent by the broker when the consumer is unexpectedly cancelled (such as after a queue deletion)
      @impl GenServer
      def handle_info({:basic_cancel, _meta}, state) do
        {:stop, :normal, state}
      end

      # Confirmation sent by the broker to the consumer process after a Basic.cancel
      @impl GenServer
      def handle_info({:basic_cancel_ok, _meta}, state) do
        {:noreply, state}
      end

      @impl GenServer
      def handle_info({:basic_deliver, payload, meta}, state) do
        {pid, state} = pop_in(state.pids[meta.correlation_id])

        unless is_nil(pid) do
          payload = Jason.decode!(payload)

          Logger.debug("""
          #{__MODULE__} consume
            Queue: #{inspect(meta.routing_key)}
            Payload: #{inspect(payload)}
          """)

          GenServer.reply(pid, payload)
          AMQP.Basic.ack(state.chan, meta.delivery_tag)
        end

        {:noreply, state}
      end

      @impl GenServer
      def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
        Logger.info(
          "#{__MODULE__} down. The monitored process #{inspect(pid)} " <>
          "died with reason #{inspect(reason)}. Restarting in 5s..."
        )

        Process.send_after(self(), :init, 5000)
        {:noreply, state}
      end
    end
  end
end
