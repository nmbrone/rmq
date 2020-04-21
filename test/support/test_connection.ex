defmodule RMQ.TestConnection do
  use RMQ.Connection, otp_app: :rmq

  def config do
    Keyword.merge(super(),
      uri: RMQ.TestHelpers.rabbit_uri(),
      connection_name: to_string(__MODULE__),
      reconnect_interval: 100
    )
  end
end
