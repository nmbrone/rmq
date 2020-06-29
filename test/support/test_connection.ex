defmodule RMQ.TestConnection do
  use RMQ.Connection

  def config do
    Keyword.merge(super(),
      uri: RMQ.TestHelpers.rabbit_uri(),
      name: to_string(__MODULE__),
      reconnect_interval: 100
    )
  end
end
