defmodule RMQ.Connection do
  @moduledoc """
  `GenServer` which is responsible for opening and managing a connection to the RabbitMQ broker.

  ## Options

    * `:uri` - AMQP URI. Defaults to `"amqp://localhost"`;
    * `:connection_name` - RabbitMQ connection name. Defaults to `:undefined`;
    * `:reconnect_interval` - reconnect interval. Defaults to `5000`;
    * options for `AMQP.Connection.open/3`.

  Could be configured with:

      config :rmq, :connection,
        uri: "amqp://quest:quest@localhost:5672",
        connection_name: "RMQ.Connection",
        reconnect_interval: 5000
        # ...

  In this case, options passed to `start_link/1` will be merged into options from the config.

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

  @doc """
  Starts a `GenServer` process linked to the current process.
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @doc """
  Gets the connection.
  """
  @spec get_connection :: {:ok, AMQP.Connection.t()} | {:error, :not_connected}
  def get_connection do
    case GenServer.call(__MODULE__, :get_connection) do
      nil -> {:error, :not_connected}
      conn -> {:ok, conn}
    end
  end

  @impl GenServer
  def init(options) do
    options = merge_options(options)
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

  @impl GenServer
  def handle_info(:connect, state) do
    case AMQP.Connection.open(state.uri, state.name, state.options) do
      {:ok, conn} ->
        Logger.info("[RMQ] Successfully connected to the server")
        Process.monitor(conn.pid)
        {:noreply, %{state | conn: conn}}

      {:error, error} ->
        Logger.error("[RMQ] Failed to connect to the server: #{inspect(error)}. Reconnecting...")
        Process.send_after(self(), :connect, state.reconnect_interval)
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warn("[RMQ] Connection lost due to #{inspect(reason)}. Reconnecting...")
    Process.send_after(self(), :connect, state.reconnect_interval)
    {:noreply, %{state | conn: nil}}
  end

  @impl GenServer
  def terminate(_reason, %{conn: conn}) do
    unless is_nil(conn), do: AMQP.Connection.close(conn)
    :ok
  end

  defp merge_options(options) do
    Application.get_env(:rmq, :connection, [])
    |> Keyword.merge(options)
  end
end
