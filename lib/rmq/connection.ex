defmodule RMQ.Connection do
  @moduledoc """
  GenServer which is responsible for opening and managing a connection to RabbitMQ broker.

  Will use `AMQP.Connection.open/3` internally.

  ## Options

    * `:uri` - AMQP URI (defaults to `"amqp://localhost"`);
    * `:connection_name` - RabbitMQ connection name (defaults to `:undefined`);
    * `:reconnect_interval` - Reconnect interval (defaults to `5000`).

  See `AMQP.Connection.open/2` for other options.

  ## Examples

      iex>RMQ.Connection.start_link()
      {:ok, #PID<0.249.0>}

      iex>RMQ.Connection.start_link(uri: "amqp://quest:quest@localhost:5672")
      {:ok, #PID<0.249.0>}

      iex>RMQ.Connection.start_link(port: 5672, user: "quest", password: "guest")
      {:ok, #PID<0.249.0>}

      iex>RMQ.Connection.get_connection()
      {:ok, %AMQP.Connection{pid: #PID<0.253.0>}}

  """

  use GenServer
  require Logger

  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  def get_connection do
    case GenServer.call(__MODULE__, :get_connection) do
      nil -> {:error, :not_connected}
      conn -> {:ok, conn}
    end
  end

  @impl GenServer
  def init(options) do
    {uri, options} = Keyword.pop(options, :uri, "amqp://localhost")
    {connection_name, options} = Keyword.pop(options, :connection_name, :undefined)
    {reconnect_interval, options} = Keyword.pop(options, :reconnect_interval, 5000)

    state = %{
      conn: nil,
      uri: uri,
      name: connection_name,
      options: options,
      reconnect_interval: reconnect_interval
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:get_connection, _from, state) do
    {:reply, state.conn, state}
  end

  def handle_info(:connect, state) do
    case AMQP.Connection.open(state.uri, state.name, state.options) do
      {:ok, conn} ->
        Logger.info("[RMQ]: Successfully connected to the server")
        Process.monitor(conn.pid)
        {:noreply, %{state | conn: conn}}

      {:error, error} ->
        Logger.error("[RMQ]: Failed to connect to the server: #{inspect(error)}. Reconnecting...")
        Process.send_after(self(), :connect, state.reconnect_interval)
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.info("[RMQ]: Connection lost due to #{inspect(reason)}. Reconnecting...")
    Process.send_after(self(), :connect, state.reconnect_interval)
    {:noreply, %{state | conn: nil}}
  end

  @impl GenServer
  def terminate(_reason, %{conn: conn}) when not is_nil(conn) do
    AMQP.Connection.close(conn)
  end
end
