defmodule RMQ.ConnectionTest do
  use ExUnit.Case
  import RMQ.TestHelpers

  test "accepts options via configuration" do
    Application.put_env(:rmq, :connection, uri: rabbit_uri(), virtual_host: "not_exist")
    assert {:ok, _pid} = RMQ.Connection.start_link()
    assert {:error, :not_connected} = RMQ.Connection.get_connection()
    Application.delete_env(:rmq, :connection)
  end

  test "accepts options via `start_link/1`" do
    Application.put_env(:rmq, :connection, virtual_host: "not_exist")
    assert {:ok, _pid} = RMQ.Connection.start_link(uri: rabbit_uri(), virtual_host: "/")
    assert {:ok, _conn} = RMQ.Connection.get_connection()
    Application.delete_env(:rmq, :connection)
  end

  test "reconnects in case of losing connection" do
    {:ok, _pid} = RMQ.Connection.start_link(uri: rabbit_uri(), reconnect_interval: 100)
    {:ok, conn} = RMQ.Connection.get_connection()
    # Process.exit(conn.pid, "Good night!")
    AMQP.Connection.close(conn)
    Process.sleep(50)
    assert {:error, :not_connected} = RMQ.Connection.get_connection()
    Process.sleep(200)
    assert {:ok, %AMQP.Connection{}} = RMQ.Connection.get_connection()
  end
end
