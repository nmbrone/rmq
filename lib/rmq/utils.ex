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

  def filter_values(%{__struct__: mod} = struct, _params) when is_atom(mod) do
    struct
  end

  def filter_values(map, params) when is_map(map) do
    Enum.into(map, %{}, &do_filter(&1, params))
  end

  def filter_values(list, params) when is_list(list) do
    if Keyword.keyword?(list) do
      Enum.into(list, [], &do_filter(&1, params))
    else
      Enum.map(list, &filter_values(&1, params))
    end
  end

  def filter_values(other, _params), do: other

  defp do_filter({k, v}, params) do
    if k in params do
      {k, "[FILTERED]"}
    else
      {k, filter_values(v, params)}
    end
  end
end
