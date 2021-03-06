defmodule RMQ.Connection do
  @moduledoc ~S"""
  A `GenServer` which provides a robust connection to the RabbitMQ server.

  ## Usage

      iex> RMQ.Connection.start_link([])
      {:ok, #PID<0.310.0>}
      iex> RMQ.Connection.get_connection()
      {:ok, %AMQP.Connection{pid: #PID<0.314.0>}}

  ## Configuration

      config :rmq, :connection,
        uri: "amqp://localhost",
        name: "MyAppConnection",
        reconnect_interval: 5000,
        username: "user",
        password: "password"
        # ... other options for AMQP.Connection.open/3

    All configuration is optional.

    * `:uri` - an AMQP URI. Defaults to `"amqp://localhost"`;
    * `:reconnect_interval` - a reconnect interval in milliseconds. It can be also a function that
      accepts the current connection attempt as a number and returns a new interval.
      Defaults to `5000`;
    * other options for `AMQP.Connection.open/2`.

  ## Dynamic configuration

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

  ## Multiple connections

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
  use RMQ.Logger

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
  @callback config() :: keyword()

  @doc "Starts a `GenServer` process linked to the current process."
  def start_link(opts), do: start_link(__MODULE__, opts)

  @doc "Starts a `GenServer` process linked to the current process."
  def start_link(module, opts) do
    GenServer.start_link(__MODULE__, module, Keyword.put(opts, :name, module))
  end

  @doc "Gets the connection."
  @spec get_connection(module :: module()) ::
          {:ok, AMQP.Connection.t()} | {:error, :not_connected}
  def get_connection(module \\ __MODULE__) do
    case GenServer.call(module, :get) do
      nil -> {:error, :not_connected}
      conn -> {:ok, conn}
    end
  end

  @doc "Returns the configuration."
  def config(), do: Application.get_env(:rmq, :connection, [])

  @impl GenServer
  def init(module) do
    Process.flag(:trap_exit, true)
    send(self(), {:connect, 1})
    {:ok, %{module: module, conn: nil}}
  end

  @impl GenServer
  def handle_call(:get, _from, state) do
    {:reply, state.conn, state}
  end

  @impl GenServer
  def handle_info({:connect, attempt}, %{module: module} = state) do
    {uri, options} = Keyword.pop(module.config(), :uri, "amqp://localhost")
    {reconnect_interval, options} = Keyword.pop(options, :reconnect_interval, 5000)

    case AMQP.Connection.open(uri, options) do
      {:ok, conn} ->
        log_info("Connected")
        Process.monitor(conn.pid)
        {:noreply, %{state | conn: conn}}

      {:error, reason} ->
        ms = RMQ.Utils.reconnect_interval(reconnect_interval, attempt)
        log_error("Connection failed: #{inspect(reason)}. Reconnecting in #{ms}ms")
        Process.send_after(self(), {:connect, attempt + 1}, ms)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, %{module: module} = state) do
    log_error(module, "Connection lost: #{inspect(reason)}. Reconnecting...")
    send(self(), {:connect, 1})
    {:noreply, %{state | conn: nil}}
  end

  @impl GenServer
  def terminate(_reason, %{conn: conn}) do
    unless is_nil(conn), do: AMQP.Connection.close(conn)
    :ok
  end

  @doc false
  defmacro __using__(opts \\ []) do
    quote location: :keep, bind_quoted: [opts: opts] do
      @behaviour RMQ.Connection
      @otp_app Keyword.get(opts, :otp_app, :rmq)

      def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

      def start_link(opts), do: RMQ.Connection.start_link(__MODULE__, opts)

      def get_connection(), do: RMQ.Connection.get_connection(__MODULE__)

      @impl RMQ.Connection
      def config(), do: Application.get_env(@otp_app, __MODULE__, [])

      defoverridable config: 0
    end
  end
end
