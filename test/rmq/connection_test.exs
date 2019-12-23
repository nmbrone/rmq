defmodule RMQ.ConnectionTest do
  use ExUnit.Case
  import RMQ.TestHelpers

  defmodule Conn1 do
    use RMQ.Connection, otp_app: :rmq
  end

  defmodule Conn2 do
    use RMQ.Connection, otp_app: :rmq

    def config do
      [
        uri: System.get_env("TEST_RABBIT_URI")
      ]
    end
  end

  defmodule Conn3 do
    use RMQ.Connection,
      otp_app: :rmq,
      uri: rabbit_uri(),
      reconnect_interval: 100
  end

  test "supports configuration via the application environment" do
    uri = rabbit_uri()

    Application.put_env(:rmq, Conn1,
      uri: uri,
      reconnect_interval: 100,
      connection_name: "TEST",
      virtual_host: "/"
    )

    {:ok, pid} = Conn1.start_link()

    assert %{
             uri: ^uri,
             reconnect_interval: 100,
             name: "TEST",
             options: [virtual_host: "/"]
           } = :sys.get_state(pid)

    GenServer.stop(pid)
    Application.delete_env(:rmq, Conn1)
  end

  test "supports runtime configuration via `config` callback" do
    uri = rabbit_uri()
    System.put_env("TEST_RABBIT_URI", uri)
    {:ok, pid} = Conn2.start_link()
    assert %{uri: ^uri} = :sys.get_state(pid)
    System.delete_env("TEST_RABBIT_URI")
    GenServer.stop(pid)
  end

  test "reconnects in case of losing connection" do
    {:ok, pid} = Conn3.start_link()
    {:ok, conn} = Conn3.get_connection()
    # Process.exit(conn.pid, "Good night!")
    AMQP.Connection.close(conn)
    Process.sleep(50)
    assert {:error, :not_connected} = Conn3.get_connection()
    Process.sleep(200)
    assert {:ok, %AMQP.Connection{}} = Conn3.get_connection()
    GenServer.stop(pid)
  end
end
