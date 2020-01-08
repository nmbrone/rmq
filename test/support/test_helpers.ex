defmodule RMQ.TestHelpers do
  def rabbit_uri do
    host = System.get_env("RABBITMQ_HOST", "localhost")
    port = System.get_env("RABBITMQ_PORT", "5672")
    user = System.get_env("RABBITMQ_USER", "guest")
    pass = System.get_env("RABBITMQ_PASSWORD", "guest")
    "amqp://#{user}:#{pass}@#{host}:#{port}"
  end

  def uuid do
    :crypto.strong_rand_bytes(10)
    |> Base.url_encode64()
    |> binary_part(0, 10)
  end

  defmacro define_consumer(name, config) do
    quote do
      defmodule unquote(name) do
        use RMQ.Consumer, unquote(config)

        @impl RMQ.Consumer
        def process(message, %{content_type: "application/json"}), do: Jason.decode!(message)
        def process(message, _meta), do: message

        @impl RMQ.Consumer
        def consume(chan, message, meta) do
          send(:current_test, {:consumed, message, meta})
          ack(chan, meta.delivery_tag)
        end

        def queue(pid), do: pid |> config() |> Map.get(:queue)
        def exchange(pid), do: pid |> config() |> Map.get(:exchange)
        def config(pid), do: pid |> state() |> Map.get(:config)
        def state(pid) when is_pid(pid), do: :sys.get_state(pid)
      end
    end
  end
end
