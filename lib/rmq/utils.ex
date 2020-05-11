defmodule RMQ.Utils do
  @moduledoc false
  def reconnect_interval(int, _attempt) when is_integer(int), do: int
  def reconnect_interval(func, attempt) when is_function(func), do: func.(attempt)
end
