defmodule RMQ.RPC do
  @moduledoc """
  RPC via RabbitMQ.

  In short, it's a `GenServer` which implements a publisher and a consumer at once.

  You can read more about how this works in the
  [tutorial](https://www.rabbitmq.com/tutorials/tutorial-six-python.html).

  ## Configuration

    * `:connection` - the connection module which implements `RMQ.Connection` behaviour;
    * `:queue` - the queue name to which the module will be subscribed for consuming responses.
      Also can be a tuple `{queue, options}`. See the options for `AMQP.Queue.declare/3`.
      Defaults to `""` which means the broker will assign a name to a newly created queue by itself;
    * `:exchange` - the exchange name to which `:queue` will be bound.
      Please make sure the exchange exist. Defaults to `""` - the default exchange;
    * `:consumer_tag` - a consumer tag for `:queue`. Defaults to the current module name;
    * `:publishing_options` - any valid options for `AMQP.Basic.publish/5` except
      `reply_to`, `correlation_id` - these will be set automatically and cannot be changed.
      Defaults to `[]`;
    * `:reconnect_interval` - a reconnect interval in milliseconds. It can be also a function that
      accepts the current connection attempt as a number and returns a new interval.
      Defaults to `5000`;
    * `:filter_parameters` - a list of parameters that may contain sensitive data and have
      to be filtered out when logging. Defaults to `["password"]`.


  ## Example

  Application 1:

      defmodule MyApp.RemoteResource do
        use RMQ.RPC, publishing_options: [app_id: "MyApp"]

        def find_by_id(id) do
          call("remote-resource-finder", %{id: id})
        end
      end

  Application 2:

      defmodule MyOtherApp.Consumer do
        use RMQ.Consumer, queue: "remote-resource-finder"

        @impl RMQ.Consumer
        def consume(chan, payload, meta) do
          response =
            payload
            |> Jason.decode!()
            |> Map.fetch!("id")
            |> MyOtherApp.Resource.get()
            |> Jason.encode!()

          AMQP.Basic.publish(chan, meta.exchange, meta.reply_to, response,
            correlation_id: meta.correlation_id
          )

          AMQP.Basic.ack(chan, meta.delivery_tag)
        end
      end

  """

  require Logger
  import RMQ.Utils

  @defaults [
    connection: RMQ.Connection,
    queue: "",
    exchange: "",
    publishing_options: [],
    reconnect_interval: 5000,
    filter_parameters: ["password"]
  ]

  @doc """
  A callback for dynamic configuration.

  Will be called before `c:setup_queue/2`.
  """
  @callback config() :: keyword()

  @doc """
  Does all the job on preparing the queue.

  Whenever you need full control over configuring the queue you can implement this callback and
  use `AMQP` library directly.

  See `setup_queue/2` for the default implementation.
  """
  @callback setup_queue(chan :: AMQP.Channel.t(), config :: keyword()) :: binary()

  @doc false
  def start_link(module, opts) do
    GenServer.start_link(module, module, Keyword.put_new(opts, :name, module))
  end

  @doc """
  Performs a call against the given module.

  Here `options` is a keyword list which will be merged into `:publishing_options` during the call
  and `timeout` is the timeout in milliseconds for the inner GenServer call.

  The payload will be encoded by using `Jason.encode!/1`.
  """
  @spec call(
          module :: module(),
          queue :: binary(),
          payload :: any(),
          options :: keyword(),
          timeout :: integer()
        ) :: {:ok, any()} | {:error, :not_connected} | {:error, :timeout} | {:error, any()}
  def call(module, queue, payload \\ %{}, options \\ [], timeout \\ 5000) do
    GenServer.call(module, {:publish, queue, payload, options}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  The default implementation for `c:setup_queue/2` callback.
  """
  @spec setup_queue(chan :: AMQP.Channel.t(), config :: keyword()) :: binary()
  def setup_queue(chan, conf) do
    {q, opts} = normalize_queue(conf[:queue])

    {:ok, %{queue: queue}} =
      AMQP.Queue.declare(chan, q, Keyword.merge([exclusive: true, auto_delete: true], opts))

    unless conf[:exchange] == "" do
      :ok = AMQP.Queue.bind(chan, queue, conf[:exchange], routing_key: queue)
    end

    {:ok, _} = AMQP.Basic.consume(chan, queue, nil, consumer_tag: conf[:consumer_tag])
    queue
  end

  @doc false
  def init(_module, _arg) do
    Process.flag(:trap_exit, true)
    send(self(), :init)
    {:ok, %{chan: nil, queue: nil, pids: %{}, config: %{}, attempt: 0}}
  end

  @doc false
  def handle_call(_module, {:publish, _queue, _payload, _options}, _from, %{chan: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(module, {:publish, queue, payload, options}, from, %{config: config} = state) do
    correlation_id = UUID.uuid1()

    options =
      config[:publishing_options]
      |> Keyword.merge(options)
      |> Keyword.put(:reply_to, state.queue)
      |> Keyword.put(:correlation_id, correlation_id)

    Logger.debug("""
    [#{module}] Publishing >>>
      Queue: #{inspect(queue)}
      ID: #{inspect(correlation_id)}
      Payload: #{inspect(filter_values(payload, config[:filter_parameters]))}
    """)

    payload = encode_message(payload)

    case AMQP.Basic.publish(state.chan, config[:exchange], queue, payload, options) do
      :ok -> {:noreply, put_in(state.pids[correlation_id], from)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @doc false
  def handle_info(module, :init, %{attempt: attempt} = state) do
    config = module_config(module)
    attempt = attempt + 1

    with {:ok, conn} <- config[:connection].get_connection(),
         {:ok, chan} <- AMQP.Channel.open(conn) do
      Process.monitor(chan.pid)
      queue = apply(module, :setup_queue, [chan, config])
      Logger.info("[#{module}] Ready")
      {:noreply, %{state | chan: chan, queue: queue, config: config, attempt: attempt}}
    else
      error ->
        time = RMQ.Utils.reconnect_interval(config[:reconnect_interval], attempt)
        Logger.error("[#{module}] No connection: #{inspect(error)}. Retrying in #{time}ms")
        Process.send_after(self(), :init, time)
        {:noreply, %{state | config: config, attempt: attempt}}
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

  def handle_info(module, {:basic_deliver, payload, meta}, %{config: config} = state) do
    {pid, state} = pop_in(state.pids[meta.correlation_id])

    unless is_nil(pid) do
      payload = decode_message(payload)

      Logger.debug("""
      [#{module}] Consuming <<<
        ID: #{inspect(meta.correlation_id)}
        Payload: #{inspect(filter_values(payload, config[:filter_parameters]))}
      """)

      GenServer.reply(pid, {:ok, payload})
      AMQP.Basic.ack(state.chan, meta.delivery_tag)
    end

    {:noreply, state}
  end

  def handle_info(module, {:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.error("[#{module}] Connection lost: #{inspect(reason)}. Reconnecting...")
    send(self(), :init)
    {:noreply, %{state | chan: nil}}
  end

  def handle_info(module, :shutdown = reason, state) do
    terminate(module, reason, state)
    {:noreply, state}
  end

  @doc false
  def terminate(_module, _reason, %{chan: chan}) do
    RMQ.Utils.close_channel(chan)
  end

  defp module_config(module) do
    @defaults
    |> Keyword.merge(apply(module, :config, []))
    |> Keyword.put_new(:consumer_tag, to_string(module))
  end

  defmacro __using__(opts \\ []) do
    quote location: :keep do
      use GenServer

      @behaviour RMQ.RPC
      @config unquote(opts)

      def start_link(opts), do: RMQ.RPC.start_link(__MODULE__, opts)

      def call(queue, payload \\ %{}, options \\ [], timeout \\ 5000) do
        RMQ.RPC.call(__MODULE__, queue, payload, options, timeout)
      end

      @impl RMQ.RPC
      def config, do: @config

      @impl RMQ.RPC
      def setup_queue(chan, config), do: RMQ.RPC.setup_queue(chan, config)

      @impl GenServer
      def init(arg), do: RMQ.RPC.init(__MODULE__, arg)

      @impl GenServer
      def handle_call(msg, from, state), do: RMQ.RPC.handle_call(__MODULE__, msg, from, state)

      @impl GenServer
      def handle_info(msg, state), do: RMQ.RPC.handle_info(__MODULE__, msg, state)

      @impl GenServer
      def terminate(reason, state), do: RMQ.RPC.terminate(__MODULE__, reason, state)

      defoverridable config: 0, setup_queue: 2
    end
  end
end
