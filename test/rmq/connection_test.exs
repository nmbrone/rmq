defmodule RMQ.ConnectionTest do
  use ExUnit.Case
  import TestHelper

  test "will reconnect in case of losing connection" do
    {:ok, _pid} = RMQ.Connection.start_link(uri: rabbit_uri(), reconnect_interval: 100)
    {:ok, conn} = RMQ.Connection.get_connection()
    :ok = AMQP.Connection.close(conn)
    assert {:error, :not_connected} = RMQ.Connection.get_connection()
    Process.sleep(200)
    assert {:ok, %AMQP.Connection{}} = RMQ.Connection.get_connection()
  end
end
