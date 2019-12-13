defmodule RMQ.RPC do
  @moduledoc """
  RPC via RabbitMQ.

  ## Options

    * `:exchange` - the name of the exchange to which RPC consuming queue is bound.
      Please make sure the exchange exist. Defaults to `""`.
    * `:timeout` - default timeout for `remote_call/5` Defaults to `5000`.
    * `:consumer_tag` - consumer tag for the callback queue. Defaults to a current module name;
    * `:restart_delay` - Defaults to `5000`;
    * `:publishing_options` - any valid options for `AMQP.Basic.publish/5` except
      `:reply_to`, `:correlation_id`, `:content_type` - these will be set automatically
      and cannot be overridden. Defaults to `[]`;

  ## Example

      defmodule MyApp.User do
        use RMQ.RPC, exchange: "", timeout: 5000

        def find_by_id(id) do
          remote_call("remote_user_finder", user_id: id)
        end
      end

  """

  defmacro __using__(opts \\ []) do
    quote location: :keep do
      require Logger
      use GenServer

      @config %{
        exchange: Keyword.get(unquote(opts), :exchange, ""),
        consumer_tag: Keyword.get(unquote(opts), :consumer_tag, "#{__MODULE__}"),
        publishing_options: Keyword.get(unquote(opts), :publishing_options, []),
        restart_delay: Keyword.get(unquote(opts), :restart_delay, 5000),
        timeout: Keyword.get(unquote(opts), :timeout, 5000)
      }

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      def remote_call(queue, payload, options \\ [], timeout \\ @config.timeout) do
        GenServer.call(__MODULE__, {:publish, queue, payload, options}, timeout)
      end

      @impl GenServer
      def init(_opts) do
        send(self(), :init)
        {:ok, %{chan: nil, queue: nil, pids: %{}}}
      end

      @impl GenServer
      def handle_call({:publish, queue, payload, options}, from, state) do
        correlation_id = UUID.uuid1()

        options =
          @config.publishing_options
          |> Keyword.merge(options)
          |> Keyword.put(:reply_to, state.queue)
          |> Keyword.put(:correlation_id, correlation_id)
          |> Keyword.put(:content_type, "application/json")

        Logger.debug("""
        #{__MODULE__} is publishing
          Queue: #{inspect(queue)}
          Payload: #{inspect(payload)}
        """)

        AMQP.Basic.publish(state.chan, @config.exchange, queue, Jason.encode!(payload), options)
        {:noreply, put_in(state.pids[correlation_id], from)}
      end

      @impl GenServer
      def handle_info(:init, state) do
        case RMQ.Connection.get_connection() do
          {:ok, conn} ->
            {:ok, chan} = AMQP.Channel.open(conn)
            Process.monitor(chan.pid)
            queue = setup_callback_queue(chan)
            Logger.info("[#{__MODULE__}] RPC started")
            {:noreply, %{state | chan: chan, queue: queue}}

          {:error, :not_connected} ->
            Process.send_after(self(), :init, @config.restart_delay)
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
          #{__MODULE__} is consuming
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
        Logger.warn("[#{__MODULE__}] RPC down due to #{inspect(reason)}. Restarting...")
        Process.send_after(self(), :init, @config.restart_delay)
        {:noreply, state}
      end

      defp setup_callback_queue(chan) do
        {:ok, %{queue: queue}} =
          AMQP.Queue.declare(chan, "", exclusive: true, auto_delete: true)

        unless @config.exchange == "" do
          :ok = AMQP.Queue.bind(chan, queue, @config.exchange, routing_key: queue)
        end

        {:ok, _} = AMQP.Basic.consume(chan, queue, nil, consumer_tag: @config.consumer_tag)
        queue
      end
    end
  end
end
