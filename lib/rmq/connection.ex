defmodule RMQ.Connection do
  @moduledoc ~S"""
  A GenServer which provides a robust connection to the RabbitMQ broker.

  ### Usage

      iex> RMQ.Connection.start_link([])
      {:ok, #PID<0.310.0>}
      iex> RMQ.Connection.get_connection()
      {:ok, %AMQP.Connection{pid: #PID<0.314.0>}}

  ### Configuration

      config :rmq, :connection,
        uri: "amqp://localhost",
        name: "MyAppConnection",
        reconnect_interval: 5000,
        username: "user",
        password: "password"
        # ... other options for AMQP.Connection.open/3

    All configuration is optional.

    * `:uri` - an AMQP URI. Defaults to `"amqp://localhost"`;
    * `:connection_name` - a RabbitMQ connection name. Defaults to `:undefined`;
    * `:reconnect_interval` - reconnect interval in milliseconds. It can be also a function that
      accepts the current connection attempt as a number and returns a new interval.
      Defaults to `5000`;
    * other options for `AMQP.Connection.open/3`.

  ### Dynamic configuration

  In case you need to read the configuration dynamically you can use `c:config/0` callback:

      defmodule MyApp.RabbitConnection do
        use RMQ.Connection

        def config do
          [
            uri: System.get_env("RABBITMQ_URI"),
            name: "MyAppConnection",
            reconnect_interval: fn attempt -> attempt * 1000 end
            # ...
          ]
        end
      end

  ### Multiple connections

  If for some reason, you need to hold multiple connections you can use the following approach:

      defmodule MyApp.RabbitConnection1 do
        use RMQ.Connection, otp_app: :my_app
      end

      defmodule MyApp.RabbitConnection2 do
        use RMQ.Connection, otp_app: :my_app
      end

      # config.exs
      config :my_app, MyApp.RabbitConnection1,
        uri: "amqp://localhost",
        name: "MyAppConnection1"

      config :my_app, MyApp.RabbitConnection2,
        uri: "amqp://localhost",
        name: "MyAppConnection2"

  `otp_app: :my_app` here can be omitted and in that case `otp_app: :rmq` will be used.
  """

  use GenServer
  require Logger

  defstruct conn: nil, attempt: 0

  @doc "Starts a `GenServer` process linked to the current process."
  @callback start_link(options :: [GenServer.option()]) :: GenServer.on_start()

  @doc "Gets the connection."
  @callback get_connection() :: {:ok, AMQP.Connection.t()} | {:error, :not_connected}

  @doc """
  A callback invoked right before connection.

  `use RMQ.Connection` will inject the default implementation of it:

      def config do
        Application.get_env(@otp_app, __MODULE__, [])
      end

  What can be eventually overridden into something like:

      def config do
        Keyword.merge(super(), uri: System.get_env("RABBITMQ_URI"))
      end
  """
  @callback config() :: Keyword.t()

  def start_link(opts) when is_list(opts), do: start_link(__MODULE__, opts)

  @doc false
  def start_link(module, opts \\ []) do
    GenServer.start_link(module, :ok, Keyword.put_new(opts, :name, module))
  end

  @doc "Gets the connection."
  @spec get_connection(server :: GenServer.server()) ::
          {:ok, AMQP.Connection.t()} | {:error, :not_connected}
  def get_connection(server \\ __MODULE__) do
    case GenServer.call(server, :get) do
      nil -> {:error, :not_connected}
      conn -> {:ok, conn}
    end
  end

  @doc "An alias for `get_connection/1`."
  @spec get() :: {:ok, AMQP.Connection.t()} | {:error, :not_connected}
  def get(), do: get_connection(__MODULE__)

  @doc "Returns the configuration."
  def config(), do: Application.get_env(:rmq, :connection, [])

  @impl GenServer
  def init(_) do
    send(self(), :connect)
    {:ok, %__MODULE__{}}
  end

  @impl GenServer
  def handle_call(:get, _from, state) do
    {:reply, state.conn, state}
  end

  @impl GenServer
  def handle_info(msg, state) do
    handle_info(__MODULE__, msg, state)
  end

  @doc false
  def handle_info(module, :connect, state) do
    {uri, options} = Keyword.pop(module.config(), :uri, "amqp://localhost")
    {name, options} = Keyword.pop(options, :name, :undefined)
    {reconnect_interval, options} = Keyword.pop(options, :reconnect_interval, 5000)

    attempt = state.attempt + 1

    reconnect_after =
      if is_function(reconnect_interval),
        do: reconnect_interval.(attempt),
        else: reconnect_interval

    case AMQP.Connection.open(uri, name, options) do
      {:ok, conn} ->
        Logger.info("[#{module}] Successfully connected to the server")
        Process.monitor(conn.pid)
        {:noreply, %{state | attempt: attempt, conn: conn}}

      {:error, reason} ->
        Logger.error(
          "[#{module}] Failed to connect to the server. Reason: #{inspect(reason)}. " <>
            "Reconnecting in #{reconnect_after}ms"
        )

        Process.send_after(self(), :connect, reconnect_after)
        {:noreply, %{state | attempt: attempt}}
    end
  end

  def handle_info(module, {:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.error("[#{module}] Connection lost. Reason: #{inspect(reason)}. Reconnecting...")
    send(self(), :connect)
    {:noreply, %{state | conn: nil}}
  end

  @doc false
  defmacro __using__(opts \\ []) do
    quote location: :keep, bind_quoted: [opts: opts] do
      @behaviour RMQ.Connection

      use GenServer

      @otp_app Keyword.get(opts, :otp_app, :rmq)

      @impl RMQ.Connection
      def start_link(opts), do: RMQ.Connection.start_link(__MODULE__, opts)

      @impl RMQ.Connection
      def get_connection(), do: RMQ.Connection.get_connection(__MODULE__)

      def get(), do: RMQ.Connection.get_connection(__MODULE__)

      @impl RMQ.Connection
      def config(), do: Application.get_env(@otp_app, __MODULE__, [])

      @impl GenServer
      def init(_), do: RMQ.Connection.init(:ok)

      @impl GenServer
      def handle_call(msg, from, state), do: RMQ.Connection.handle_call(msg, from, state)

      @impl GenServer
      def handle_info(msg, state), do: RMQ.Connection.handle_info(__MODULE__, msg, state)

      defoverridable config: 0
    end
  end
end
