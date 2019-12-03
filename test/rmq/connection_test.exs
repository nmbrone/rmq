defmodule RMQ.ConnectionTest do
  use ExUnit.Case

  setup_all do
    RMQ.Connection.start_link(reconnect_interval: 100)
    :ok
  end

  test "will reconnect in case of losing connection" do
    {:ok, conn} = RMQ.Connection.get_connection()
    :ok = AMQP.Connection.close(conn)
    assert {:error, :not_connected} = RMQ.Connection.get_connection()
    Process.sleep(200)
    assert {:ok, %AMQP.Connection{}} = RMQ.Connection.get_connection()
  end
end
