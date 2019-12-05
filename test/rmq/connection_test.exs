defmodule RMQ.ConnectionTest do
  use ExUnit.Case
  import RMQ.TestHelpers

  test "connects" do
    assert {:ok, _pid} = RMQ.Connection.start_link(uri: rabbit_uri())
    assert {:ok, conn} = RMQ.Connection.get_connection()
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
