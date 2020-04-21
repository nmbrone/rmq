defmodule RMQ.Consumer do
  @moduledoc ~S"""
  RabbitMQ Consumer.

  Keep in mind that the consumed message needs to be explicitly acknowledged via `AMQP.Basic.ack/3`
  or rejected via `AMQP.Basic.reject/3`. For convenience, these functions
  are imported and are available directly.

  `AMQP.Basic.publish/3` is imported as well which is convenient for the case
  when the consumer implements RPC.

  ## Configuration

    * `:connection` - the connection module which implements `RMQ.Connection` behaviour;
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
    * `:concurrency` - defines if `c:consume/3` callback will be called in a separate process.
      Defaults to `true`;
    * `:prefetch_count` - sets the message prefetch count. Defaults to `10`;
    * `:consumer_tag` - consumer tag. Defaults to a current module name;
    * `:restart_delay` - restart delay. Defaults to `5000`.

  ## Example

      defmodule MyApp.Consumer do
        use RMQ.Consumer,
          connection: MyApp.RabbitConnection,
          queue: "my-app-consumer-queue"

        @impl RMQ.Consumer
        def process(message, %{content_type: "application/json"}), do: Jason.decode!(message)
        def process(message, _meta), do: message

        @impl RMQ.Consumer
        def consume(chan, payload, meta) do
          # handle message here
          ack(chan, meta.delivery_tag)
        end
      end

  """

  @doc "Starts a `GenServer` process linked to the current process."
  @callback start_link(options :: [GenServer.option()]) :: GenServer.on_start()

  @doc """
  Optional callback for processing the message before consuming it.

  Accepts payload and metadata. Must return (modified) payload.
  """
  @callback process(payload :: any(), meta :: Map.t()) :: payload :: any()

  @doc """
  Consumes the message.
  """
  @callback consume(chan :: AMQP.Channel.t(), payload :: any(), meta :: Map.t()) :: any()

  @optional_callbacks process: 2

  defmacro __using__(opts) when is_list(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      use GenServer
      require Logger
      import AMQP.Basic, only: [ack: 3, ack: 2, reject: 3, reject: 2, publish: 5, publish: 4]

      @behaviour RMQ.Consumer
      @connection Keyword.get(opts, :connection, RMQ.Connection)

      @impl RMQ.Consumer
      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
      end

      @impl RMQ.Consumer
      def process(payload, _meta), do: payload

      @impl GenServer
      def init(:ok) do
        queue = Keyword.fetch!(unquote(opts), :queue)
        {_, exchange} = Keyword.get(unquote(opts), :exchange, "") |> normalize_exchange()

        config =
          unquote(opts)
          |> Enum.into(%{})
          |> Map.drop([:connection])
          |> Map.put_new(:routing_key, queue)
          |> Map.put_new(:exchange, exchange)
          |> Map.put_new(:dead_letter, true)
          |> Map.put_new(:dead_letter_routing_key, queue)
          |> Map.put_new(:dead_letter_exchange, "#{exchange}.dead-letter")
          |> Map.put_new(:dead_letter_queue, "#{queue}_error")
          |> Map.put_new(:prefetch_count, 10)
          |> Map.put_new(:concurrency, true)
          |> Map.put_new(:consumer_tag, to_string(__MODULE__))
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
          spawn(fn -> consume(chan, process(payload, meta), meta) end)
        else
          consume(chan, process(payload, meta), meta)
        end

        {:noreply, state}
      end

      @impl GenServer
      def handle_info(:init, %{config: config} = state) do
        case @connection.get_connection() do
          {:ok, conn} ->
            {:ok, chan} = AMQP.Channel.open(conn)
            Process.monitor(chan.pid)
            arguments = setup_dead_letter(chan, config)
            setup_queue(chan, config, arguments)
            Logger.info("[#{__MODULE__}] Consumer started")
            {:noreply, %{state | chan: chan}}

          {:error, :not_connected} ->
            Process.send_after(self(), :init, config.restart_delay)
            {:noreply, state}
        end
      end

      @impl GenServer
      def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
        Logger.warn("[#{__MODULE__}] Consumer down due to #{inspect(reason)}. Restarting...")
        Process.send_after(self(), :init, state.config.restart_delay)
        {:noreply, %{state | chan: nil}}
      end

      @impl GenServer
      def terminate(_reason, %{chan: chan}) do
        unless is_nil(chan), do: AMQP.Channel.close(chan)
        :ok
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

      defoverridable process: 2
    end
  end
end
