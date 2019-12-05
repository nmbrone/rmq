defmodule RMQ.Consumer do
  @moduledoc ~S"""
  RabbitMQ Consumer.

  ## Options

    * `:queue` - The name of the queue to consume. Will be created if does not exist;
    * `:exchange` - The name of the exchange to which `queue` should be bound.
      Will be created if does not exist. Defaults to `""`;
    * `:dead_letter_queue` - Defaults to `"#{queue}_error"`;
    * `:dead_letter_exchange` - Defaults to `"#{exchange}.deadletter"`;
    * `:concurrency` - Defaults to `true`;
    * `:prefetch_count` - Defaults to `10`;
    * `:consumer_tag` - Defaults to current module name;
    * `:restart_delay` - Defaults to `5000`;
    * `:routing_key` - Defaults to `queue`;

  ## Example

      defmodule MyApp.Consumer do
        use RMQ.Consumer, queue: "my_app_consumer_queue"

        @impl RMQ.Consumer
        def consume(conn, message, meta) do
          # handle message here
        end
      end

  """

  @type chan :: AMQP.Channel.t()
  @type payload :: any()
  @type meta :: Map.t()

  @callback consume(chan, payload, meta) :: any()

  defmacro __using__(config) when is_list(config) do
    quote location: :keep do
      use GenServer
      require Logger
      import AMQP.Basic, only: [ack: 3, ack: 2, reject: 3, reject: 2]

      @behaviour RMQ.Consumer

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      @impl GenServer
      def init(_opts) do
        queue = Keyword.fetch!(unquote(config), :queue)
        exchange = Keyword.get(unquote(config), :exchange, "")

        config =
          unquote(config)
          |> Enum.into(%{})
          |> Map.put_new(:routing_key, queue)
          |> Map.put_new(:exchange, exchange)
          |> Map.put_new(:dead_letter_exchange, "#{exchange}.deadletter")
          |> Map.put_new(:dead_letter_queue, "#{queue}_error")
          |> Map.put_new(:prefetch_count, 10)
          |> Map.put_new(:concurrency, true)
          |> Map.put_new(:consumer_tag, Atom.to_string(__MODULE__))
          |> Map.put_new(:restart_delay, 5000)

        Process.flag(:trap_exit, true)
        send(self(), :init)
        {:ok, %{chan: nil, config: config}}
      end

      # Confirmation sent by the broker after registering this process as a consumer
      @impl GenServer
      def handle_info({:basic_consume_ok, meta}, state) do
        {:noreply, state}
      end

      # Sent by the broker when the consumer is unexpectedly cancelled (such as after a queue deletion)
      @impl GenServer
      def handle_info({:basic_cancel, meta}, state) do
        {:stop, :normal, state}
      end

      # Confirmation sent by the broker to the consumer process after a Basic.cancel
      @impl GenServer
      def handle_info({:basic_cancel_ok, meta}, state) do
        {:noreply, state}
      end

      @impl GenServer
      def handle_info({:basic_deliver, payload, meta}, %{chan: chan, config: config} = state) do
        if config.concurrency do
          Task.start(fn -> consume(chan, payload, meta) end)
        else
          consume(chan, payload, meta)
        end

        {:noreply, state}
      end

      @impl GenServer
      def handle_info(:init, %{config: config} = state) do
        case RMQ.Connection.get_connection() do
          {:ok, conn} ->
            {:ok, chan} = AMQP.Channel.open(conn)
            Process.monitor(chan.pid)

            {:ok, _} = AMQP.Queue.declare(chan, config.dead_letter_queue, durable: true)

            {:ok, _} =
              AMQP.Queue.declare(chan, config.queue,
                durable: true,
                arguments: [
                  {"x-dead-letter-exchange", :longstr, config.dead_letter_exchange},
                  {"x-dead-letter-routing-key", :longstr, config.dead_letter_queue}
                ]
              )

            :ok = AMQP.Exchange.declare(chan, config.dead_letter_exchange, :direct, durable: true)
            :ok = AMQP.Queue.bind(chan, config.dead_letter_queue, config.dead_letter_exchange)

            # skip declaring default exchange
            unless config.exchange == "" do
              :ok = AMQP.Exchange.declare(chan, config.exchange, :direct, durable: true)

              :ok =
                AMQP.Queue.bind(chan, config.queue, config.exchange,
                  routing_key: config.routing_key
                )
            end

            :ok = AMQP.Basic.qos(chan, prefetch_count: config.prefetch_count)

            {:ok, _} =
              AMQP.Basic.consume(chan, config.queue, nil, consumer_tag: config.consumer_tag)

            Logger.info("[#{__MODULE__}]: Consumer started")
            {:noreply, %{state | chan: chan}}

          {:error, :not_connected} ->
            Process.send_after(self(), :init, config.restart_delay)
            {:noreply, state}
        end
      end

      @impl GenServer
      def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
        Logger.error("[#{__MODULE__}]: Consumer down due to #{inspect(reason)}. Restarting...")
        Process.send_after(self(), :init, state.config.restart_delay)
        {:noreply, %{state | chan: nil}}
      end

      @impl GenServer
      def terminate(_reason, %{chan: chan}) do
        unless is_nil(chan), do: AMQP.Channel.close(chan)
      end
    end
  end
end
