defmodule RMQ.Utils do
  @moduledoc false
  def reconnect_interval(int, _attempt) when is_integer(int), do: int
  def reconnect_interval(func, attempt) when is_function(func), do: func.(attempt)

  def close_channel(nil), do: :ok

  def close_channel(%AMQP.Channel{pid: pid} = chan) do
    if Process.alive?(pid), do: AMQP.Channel.close(chan), else: :ok
  end

  def normalize_queue({queue, opts}), do: {queue, opts}
  def normalize_queue(queue), do: {queue, []}

  def normalize_exchange({type, name, opts}), do: {type, name, opts}
  def normalize_exchange({type, name}), do: {type, name, []}
  def normalize_exchange(name), do: {:direct, name, []}
end
