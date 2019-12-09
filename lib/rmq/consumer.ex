defmodule RMQ.Consumer do
  @moduledoc ~S"""
  RabbitMQ Consumer.

  ## Options

    * `:queue` - the name of the queue to consume. Will be created if does not exist;
    * `:exchange` - the name of the exchange to which `queue` should be bound.
      Also accepts two-element tuple `{type, name}`. Defaults to `""`;
    * `:routing_key` - queue binding key. Defaults to `queue`;
      Will be created if does not exist. Defaults to `""`;
    * `:dead_letter` - defines if the consumer should setup deadletter exchange and queue.
      Defaults to `true`;
    * `:dead_letter_queue` - the name of dead letter queue. Defaults to `"#{queue}_error"`;
    * `:dead_letter_exchange` - the name of the exchange to which `dead_letter_queue` should be bound.
      Also accepts two-element tuple `{type, name}`. Defaults to `"#{exchange}.dead-letter"`;
    * `:dead_letter_routing_key` - routing key for dead letter messages. Defaults to `queue`;
    * `:concurrency` - defines if `consume/3` callback will be called in a separate process
      using `Task.start/1`. Defaults to `true`;
    * `:prefetch_count` - sets the message prefetch count. Defaults to `10`;
    * `:consumer_tag` - Defaults to current module name;
    * `:restart_delay` - Defaults to `5000`;

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
        {_, exchange} = Keyword.get(unquote(config), :exchange, "") |> normalize_exchange()

        config =
          unquote(config)
          |> Enum.into(%{})
          |> Map.put_new(:routing_key, queue)
          |> Map.put_new(:exchange, exchange)
          |> Map.put_new(:dead_letter, true)
          |> Map.put_new(:dead_letter_routing_key, queue)
          |> Map.put_new(:dead_letter_exchange, "#{exchange}.dead-letter")
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
            arguments = setup_dead_letter(chan, config)
            setup_queue(chan, config, arguments)
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

      defp setup_queue(chan, config, arguments) do
        {type, exchange} = normalize_exchange(config.exchange)

        {:ok, %{queue: queue}} =
          AMQP.Queue.declare(chan, config.queue, durable: true, arguments: arguments)

        # skip declaring default exchange
        unless exchange == "" do
          :ok = AMQP.Exchange.declare(chan, exchange, type, durable: true)
          :ok = AMQP.Queue.bind(chan, queue, exchange, routing_key: config.routing_key)
        end

        :ok = AMQP.Basic.qos(chan, prefetch_count: config.prefetch_count)
        {:ok, _} = AMQP.Basic.consume(chan, queue, nil, consumer_tag: config.consumer_tag)
      end

      defp setup_dead_letter(_chan, %{dead_letter: false}), do: []

      defp setup_dead_letter(chan, %{dead_letter: true} = config) do
        {type, exchange} = normalize_exchange(config.dead_letter_exchange)
        {:ok, %{queue: queue}} = AMQP.Queue.declare(chan, config.dead_letter_queue, durable: true)
        :ok = AMQP.Exchange.declare(chan, exchange, type, durable: true)
        :ok = AMQP.Queue.bind(chan, queue, exchange)

        [
          {"x-dead-letter-exchange", :longstr, exchange},
          {"x-dead-letter-routing-key", :longstr, config.dead_letter_routing_key}
        ]
      end

      defp normalize_exchange({type, name}), do: {type, name}
      defp normalize_exchange(name), do: {:direct, name}
    end
  end
end
