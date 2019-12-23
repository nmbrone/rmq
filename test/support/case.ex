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
    start_supervised!(RMQ.TestConnection)
    :ok
  end

  setup do
    Process.register(self(), :current_test)
    :ok
  end
end
