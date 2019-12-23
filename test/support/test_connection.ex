defmodule RMQ.TestConnection do
  use RMQ.Connection,
    otp_app: :rmq,
    connection_name: to_string(__MODULE__),
    reconnect_interval: 100

  def config do
    [
      uri: RMQ.TestHelpers.rabbit_uri()
    ]
  end
end
