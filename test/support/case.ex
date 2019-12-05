defmodule RMQ.Case do
  use ExUnit.CaseTemplate
  alias RMQ.TestHelpers

  using do
    quote do
      use ExUnit.Case
      require RMQ.TestHelpers
      import RMQ.TestHelpers
    end
  end

  setup_all do
    start_supervised!(
      {RMQ.Connection,
       [uri: TestHelpers.rabbit_uri(), connection_name: "RMQ", reconnect_interval: 100]}
    )

    :ok
  end

  setup do
    Process.register(self(), :current_test)
    :ok
  end
end
