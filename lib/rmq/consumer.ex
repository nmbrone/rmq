defmodule RMQ.Consumer do
  @moduledoc ~S"""
  RabbitMQ Consumer.

  ## Configuration

    * `:connection` - the connection module which implements `RMQ.Connection` behaviour.
      Defaults to `RMQ.Connection`;
    * `:queue` - the name of the queue to consume. Will be created if does not exist.
      Also can be a tuple `{queue, options}`. See the options for `AMQP.Queue.declare/3`;
    * `:exchange` - the name of the exchange to which `queue` should be bound.
      Also can be a tuple `{exchange, type, options}`. See the options for
      `AMQP.Exchange.declare/4`. Defaults to `""`;
    * `:routing_key` - queue binding key. Defaults to `queue`;
      Will be created if does not exist. Defaults to `""`;
    * `:dead_letter` - defines if the consumer should setup deadletter exchange and queue.
      Defaults to `true`;
    * `:dead_letter_queue` - the name of dead letter queue. Also can be a tuple `{queue, options}`.
      See the options for `AMQP.Queue.declare/3`. Defaults to `"#{queue}_error"`.;
    * `:dead_letter_exchange` - the name of the exchange to which `dead_letter_queue` should be bound.
      Also can be a tuple `{type, exchange}` or `{type, exchange, options}`. See the options for
      `AMQP.Exchange.declare/4`. Defaults to `"#{exchange}.dead-letter"`;
    * `:dead_letter_routing_key` - routing key for dead letter messages. Defaults to `queue`;
    * `:concurrency` - defines if `c:consume/3` callback should be called in a separate process.
      Defaults to `true`;
    * `:prefetch_count` - sets the message prefetch count. Defaults to `10`;
    * `:consumer_tag` - consumer tag. Defaults to a current module name;
    * `:reconnect_interval` - a reconnect interval in milliseconds. It can be also a function that
      accepts the current connection attempt as a number and returns a new interval.
      Defaults to `5000`;

  ## Examples

      defmodule MyApp.Consumer do
        use RMQ.Consumer,
          queue: {"my-app-consumer-queue", durable: true},
          exchange: {"my-exchange", :direct, durable: true}

        @impl RMQ.Consumer
        def consume(chan, payload, meta) do
          # do something with the payload
          ack(chan, meta.delivery_tag)
        end
      end

      defmodule MyApp.Consumer2 do
        use RMQ.Consumer

        @impl RMQ.Consumer
        def config do
          [
            queue: System.fetch_env!("QUEUE_NAME"),
            reconnect_interval: fn attempt -> attempt * 1000 end,
          ]
        end

        @impl RMQ.Consumer
        def consume(chan, payload, meta) do
          # do something with the payload
          ack(chan, meta.delivery_tag)
        end
      end

  """

  require Logger
  import RMQ.Utils

  @defaults [
    connection: RMQ.Connection,
    exchange: "",
    dead_letter: true,
    prefetch_count: 10,
    reconnect_interval: 5000,
    concurrency: true
  ]

  @doc """
  A callback for consuming a message.

  Keep in mind that the consumed message needs to be explicitly acknowledged via `AMQP.Basic.ack/3`
  or rejected via `AMQP.Basic.reject/3`. For convenience, these functions
  are imported and are available for use directly.

  `RMQ.Utils.reply/4` is imported as well which is convenient for the case when the consumer
  implements RPC.

  When `:concurrency` is `true` this function will be executed in the spawned process
  using `Kernel.spawn/1`.
  """
  @callback consume(chan :: AMQP.Channel.t(), payload :: any(), meta :: map()) :: any()

  @doc """
  A callback for dynamic configuration.
  """
  @callback config() :: keyword()

  @doc """
  Does all the job on preparing the queue.

  Whenever you need full control over configuring the queue you can implement this callback and
  use `AMQP` library directly.

  See `setup_queue/2` for the default implementation.
  """
  @callback setup_queue(chan :: AMQP.Channel.t(), config :: keyword()) :: :ok

  @doc false
  def start_link(module, opts) do
    GenServer.start_link(module, module, Keyword.put_new(opts, :name, module))
  end

  @doc false
  def init(_module, _arg) do
    Process.flag(:trap_exit, true)
    send(self(), {:init, 1})
    {:ok, %{chan: nil, config: %{}}}
  end

  @doc false
  def handle_info(module, {:init, attempt}, state) do
    config = module_config(module)

    with {:ok, conn} <- config[:connection].get_connection(),
         {:ok, chan} <- AMQP.Channel.open(conn) do
      Process.monitor(chan.pid)
      module.setup_queue(chan, config)
      Logger.info("[#{module}] Ready")
      {:noreply, %{state | config: config, chan: chan}}
    else
      error ->
        time = reconnect_interval(config[:reconnect_interval], attempt)
        Logger.error("[#{module}] No connection: #{inspect(error)}. Retrying in #{time}ms")
        Process.send_after(self(), {:init, attempt + 1}, time)
        {:noreply, %{state | config: config}}
    end
  end

  # Confirmation sent by the broker after registering this process as a consumer
  def handle_info(_module, {:basic_consume_ok, _meta}, state) do
    {:noreply, state}
  end

  # Sent by the broker when the consumer is unexpectedly cancelled (such as after a queue deletion)
  def handle_info(_module, {:basic_cancel, _meta}, state) do
    {:stop, :normal, state}
  end

  # Confirmation sent by the broker to the consumer process after a Basic.cancel
  def handle_info(_module, {:basic_cancel_ok, _meta}, state) do
    {:noreply, state}
  end

  def handle_info(module, {:basic_deliver, payload, meta}, %{chan: chan, config: config} = state) do
    if config[:concurrency] do
      spawn(fn -> module.consume(chan, payload, meta) end)
    else
      module.consume(chan, payload, meta)
    end

    {:noreply, state}
  end

  def handle_info(module, {:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.error("[#{module}] Connection lost: #{inspect(reason)}. Reconnecting...")
    send(self(), {:init, 1})
    {:noreply, %{state | chan: nil}}
  end

  @doc false
  def terminate(_module, _reason, %{chan: chan}) do
    close_channel(chan)
  end

  @doc """
  The default implementation for `c:setup_queue/2` callback.
  """
  @spec setup_queue(chan :: AMQP.Channel.t(), config :: keyword()) :: :ok
  def setup_queue(chan, config) do
    {xch, xch_type, xch_opts} = normalize_exchange(config[:exchange])
    {q, q_opts} = normalize_queue(config[:queue])

    dl_args = setup_dead_letter(chan, config)
    q_opts = Keyword.update(q_opts, :arguments, dl_args, &(dl_args ++ &1))

    {:ok, %{queue: q}} = AMQP.Queue.declare(chan, q, q_opts)

    # the exchange "" is the default exchange and cannot be declared this way
    unless xch == "" do
      :ok = AMQP.Exchange.declare(chan, xch, xch_type, xch_opts)
      :ok = AMQP.Queue.bind(chan, q, xch, routing_key: config[:routing_key])
    end

    :ok = AMQP.Basic.qos(chan, prefetch_count: config[:prefetch_count])
    {:ok, _} = AMQP.Basic.consume(chan, q, nil, consumer_tag: config[:consumer_tag])
    :ok
  end

  defp setup_dead_letter(chan, config) do
    if config[:dead_letter] do
      {xch, xch_type, xch_opts} = normalize_exchange(config[:dead_letter_exchange])
      {q, q_opts} = normalize_queue(config[:dead_letter_queue])

      {:ok, %{queue: q}} = AMQP.Queue.declare(chan, q, q_opts)

      :ok = AMQP.Exchange.declare(chan, xch, xch_type, xch_opts)
      :ok = AMQP.Queue.bind(chan, q, xch)

      [
        {"x-dead-letter-exchange", :longstr, xch},
        {"x-dead-letter-routing-key", :longstr, config[:dead_letter_routing_key]}
      ]
    else
      []
    end
  end

  defp module_config(module) do
    config = Keyword.merge(@defaults, module.config())
    {q, q_opts} = Keyword.fetch!(config, :queue) |> normalize_queue()
    {xch, xch_type, xch_opts} = Keyword.fetch!(config, :exchange) |> normalize_exchange()
    dl_xch_name = String.replace_prefix("#{xch}.dead-letter", ".", "")
    # by default for the dead-letter exchange use the same type and the same `:durable` option
    # as for the main exchange. When the `:durable` option isn't set explicitly, we determine it
    # based on the main exchange. The default exchange `""` is always durable.
    dl_xch = {dl_xch_name, xch_type, durable: Keyword.get(xch_opts, :durable, xch == "")}
    # by default for the dead-letter queue use the same `:durable` option as for the main queue
    dl_q = {"#{q}_error", durable: Keyword.get(q_opts, :durable, false)}

    config
    |> Keyword.put_new(:routing_key, q)
    |> Keyword.put_new(:dead_letter_routing_key, q)
    |> Keyword.put_new(:dead_letter_exchange, dl_xch)
    |> Keyword.put_new(:dead_letter_queue, dl_q)
    |> Keyword.put_new(:consumer_tag, to_string(module))
  end

  defmacro __using__(opts \\ []) do
    quote location: :keep do
      use GenServer

      import RMQ.Utils, only: [ack: 3, ack: 2, reply: 4, reply: 3]
      import AMQP.Basic, only: [reject: 3, reject: 2, publish: 5, publish: 4]

      @behaviour RMQ.Consumer
      @config unquote(opts)

      def start_link(opts), do: RMQ.Consumer.start_link(__MODULE__, opts)

      @impl RMQ.Consumer
      def setup_queue(chan, config), do: RMQ.Consumer.setup_queue(chan, config)

      @impl RMQ.Consumer
      def config, do: @config

      @impl GenServer
      def init(arg), do: RMQ.Consumer.init(__MODULE__, arg)

      @impl GenServer
      def handle_info(msg, state), do: RMQ.Consumer.handle_info(__MODULE__, msg, state)

      @impl GenServer
      def terminate(reason, state), do: RMQ.Consumer.terminate(__MODULE__, reason, state)

      defoverridable config: 0, setup_queue: 2
    end
  end
end
