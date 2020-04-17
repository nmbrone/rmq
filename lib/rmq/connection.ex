defmodule RMQ.Connection do
  @moduledoc ~S"""
  A `GenServer` which provides a robust connection to RabbitMQ broker.

  Can be used as following:

      defmodule MyApp.RabbitConnection do
        use RMQ.Connection,
          otp_app: :my_app,
          uri: "amqp://localhost",
          connection_name: to_string(__MODULE__)
      end

  Can be configured via the application environment:

      config :my_app, MyApp.RabbitConnection,
        uri: "amqp://localhost",
        connection_name: "MyApp.RabbitConnection"

  Supports dynamic configuration via `c:config/0` callback:

      defmodule MyApp.RabbitConnection do
        use RMQ.Connection, otp_app: :my_app

        def config do
          [
            uri: System.get_env("RABBIT_URL", "amqp://localhost"),
            connection_name: to_string(__MODULE__)
          ]
        end
      end

  ## Configuration

    * `:otp_app` - the only required value. It should point to an OTP application
      that has the connection configuration.
    * `:uri` - AMQP URI. Defaults to `"amqp://localhost"`;
    * `:connection_name` - RabbitMQ connection name. Defaults to `:undefined`;
    * `:reconnect_interval` - reconnect interval. Defaults to `5000`;
    * options for `AMQP.Connection.open/3`.

  """

  @doc "Starts a `GenServer` process linked to the current process."
  @callback start_link(options :: [GenServer.option()]) :: GenServer.on_start()

  @doc "Gets the connection."
  @callback get_connection() :: {:ok, AMQP.Connection.t()} | {:error, :not_connected}

  @doc """
  Callback for dynamic configuration.

  Can be used in case the connection configuration needs to be set dynamically,
  for example by reading a system environment variable.
  """
  @callback config() :: Keyword.t()

  @optional_callbacks config: 0

  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      require Logger
      use GenServer

      @behaviour RMQ.Connection

      {otp_app, conf} = Keyword.pop(opts, :otp_app)

      @otp_app otp_app
      @config conf

      @impl RMQ.Connection
      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
      end

      @impl RMQ.Connection
      def get_connection do
        case GenServer.call(__MODULE__, :get_connection) do
          nil -> {:error, :not_connected}
          conn -> {:ok, conn}
        end
      end

      @impl RMQ.Connection
      def config, do: []

      @impl GenServer
      def init(_) do
        send(self(), :connect)
        {:ok, nil}
      end

      @impl GenServer
      def handle_call(:get_connection, _from, state) do
        {:reply, state.conn, state}
      end

      @impl GenServer
      def handle_info(:connect, _) do
        {uri, rest} = Keyword.pop(get_config(), :uri, "amqp://localhost")
        {connection_name, rest} = Keyword.pop(rest, :connection_name, :undefined)
        {reconnect_interval, rest} = Keyword.pop(rest, :reconnect_interval, 5000)

        state = %{
          conn: nil,
          uri: uri,
          name: connection_name,
          options: rest,
          reconnect_interval: reconnect_interval
        }

        case AMQP.Connection.open(state.uri, state.name, state.options) do
          {:ok, conn} ->
            Logger.info("[RMQ] Successfully connected to the server")
            Process.monitor(conn.pid)
            {:noreply, %{state | conn: conn}}

          {:error, error} ->
            Logger.error(
              "[RMQ] Failed to connect to the server: #{inspect(error)}. Reconnecting..."
            )

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

      defp get_config do
        Application.get_env(@otp_app, __MODULE__, [])
        |> Keyword.merge(@config)
        |> Keyword.merge(config())
      end

      defoverridable config: 0
    end
  end
end
