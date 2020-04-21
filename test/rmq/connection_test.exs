defmodule RMQ.ConnectionTest do
  use ExUnit.Case, async: true

  import RMQ.TestHelpers

  defmodule MyConn do
    use RMQ.Connection, otp_app: :my_app
  end

  @moduletag :capture_log

  setup tags do
    unless tags[:skip_config] do
      Application.put_env(:rmq, :connection,
        uri: rabbit_uri(),
        connection_name: "TestConnection",
        reconnect_interval: 1000,
        virtual_host: "/"
      )

      Application.put_env(:my_app, MyConn,
        uri: rabbit_uri(),
        connection_name: "TestConnection_2",
        reconnect_interval: 1000,
        virtual_host: "/"
      )
    end

    :ok
  end

  test "can be used directly" do
    {:ok, pid} = start_supervised(RMQ.Connection)
    assert %{conn: %AMQP.Connection{}, attempt: 1} = :sys.get_state(pid)
  end

  test "can be used via `use` macro" do
    {:ok, pid} = start_supervised(MyConn)
    assert %{conn: %AMQP.Connection{}, attempt: 1} = :sys.get_state(pid)
  end

  test "can be used simultaneously" do
    start_supervised!(RMQ.Connection)
    start_supervised!(MyConn)

    {:ok, %{pid: pid1}} = RMQ.Connection.get()
    {:ok, %{pid: pid2}} = MyConn.get()

    assert pid1 !== pid2
  end

  @tag :skip_config
  test "reconnects with the given interval" do
    Application.put_env(:rmq, :connection,
      uri: rabbit_uri(),
      reconnect_interval: fn _attempt -> 100 end,
      username: "unknown"
    )

    Application.put_env(:my_app, MyConn,
      uri: rabbit_uri(),
      reconnect_interval: 100,
      username: "unknown"
    )

    start_supervised!(RMQ.Connection)
    start_supervised!(MyConn)

    assert {:error, :not_connected} = RMQ.Connection.get()
    assert {:error, :not_connected} = MyConn.get()

    Application.put_env(:rmq, :connection, uri: rabbit_uri())
    Application.put_env(:my_app, MyConn, uri: rabbit_uri())

    Process.sleep(100)

    assert {:ok, _} = RMQ.Connection.get()
    assert {:ok, _} = MyConn.get()
  end

  test "reconnects in case of losing the connection" do
    start_supervised!(RMQ.Connection)
    start_supervised!(MyConn)

    {:ok, %{pid: pid11} = conn1} = RMQ.Connection.get()
    {:ok, %{pid: pid12} = conn2} = MyConn.get()

    AMQP.Connection.close(conn1)
    AMQP.Connection.close(conn2)

    Process.sleep(10)

    {:ok, %{pid: pid21}} = RMQ.Connection.get()
    {:ok, %{pid: pid22}} = MyConn.get()

    assert pid11 != pid21
    assert pid12 != pid22
  end
end
