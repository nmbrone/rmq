defmodule RMQ.Utils do
  @moduledoc """
  Utility functions.
  """

  @doc false
  def reconnect_interval(int, _attempt) when is_integer(int), do: int
  def reconnect_interval(func, attempt) when is_function(func), do: func.(attempt)

  @doc false
  def close_channel(%AMQP.Channel{pid: pid} = chan) do
    if Process.alive?(pid), do: AMQP.Channel.close(chan), else: :ok
  end

  def close_channel(_), do: :ok

  @doc false
  def normalize_queue({queue, opts}), do: {queue, opts}
  def normalize_queue(queue), do: {queue, []}

  @doc false
  def normalize_exchange({type, name, opts}), do: {type, name, opts}
  def normalize_exchange({type, name}), do: {type, name, []}
  def normalize_exchange(name), do: {:direct, name, []}

  @doc false
  def encode_message(message) when is_binary(message), do: message

  def encode_message(message) do
    case Jason.encode(message) do
      {:ok, encoded} -> encoded
      {:error, _} -> message
    end
  end

  @doc false
  def decode_message(message) do
    case Jason.decode(message) do
      {:ok, decoded} -> decoded
      {:error, _} -> message
    end
  end

  @doc """
  Acknowledges one or more messages.

  It's the same as `AMQP.Basic.ack/3` but with the ability to extract `delivery_tag` from
  the provided message meta.
  """
  @spec ack(
          chan :: AMQP.Channel.t(),
          delivery_tag_or_meta :: binary() | map(),
          options :: keyword()
        ) :: :ok | (error :: any())
  def ack(chan, delivery_tag_or_meta, options \\ [])

  def ack(chan, %{delivery_tag: delivery_tag}, options) do
    AMQP.Basic.ack(chan, delivery_tag, options)
  end

  def ack(chan, delivery_tag, options) do
    AMQP.Basic.ack(chan, delivery_tag, options)
  end

  @doc """
  Produces a reply to the message.

  It's basically just a wrapper around `AMQP.Basic.publish/5` which helps you properly publish
  a reply based on the message meta.

  When the given payload is not a string it will be encoded by using `Jason.encode/2`.
  """
  @spec reply(chan :: AMQP.Channel.t(), meta :: map(), payload :: any(), options :: keyword()) ::
          :ok | (error :: any())
  def reply(chan, meta, payload, options \\ [])
  def reply(_, %{reply_to: :undefined}, _, _), do: :missing_repty_to
  def reply(_, %{correlation_id: :undefined}, _, _), do: :missing_correlation_id

  def reply(chan, %{exchange: xch, reply_to: to, correlation_id: cid}, payload, options) do
    payload = encode_message(payload)
    options = Keyword.put(options, :correlation_id, cid)
    AMQP.Basic.publish(chan, xch, to, payload, options)
  end

  def reply(_, _, _, _), do: :error

  @doc false
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
