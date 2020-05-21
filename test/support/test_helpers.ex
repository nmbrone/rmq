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

  defmacro define_consumer(name, conf, dynamic \\ false) do
    quote do
      defmodule unquote(name) do
        use RMQ.Consumer, unless(unquote(dynamic), do: unquote(conf), else: [])

        # @impl RMQ.Consumer
        # def setup_queue(chan, queue) do
        #   super(chan, queue)
        # end

        @impl RMQ.Consumer
        def consume(chan, message, meta) do
          message =
            case meta.content_type do
              "application/json" -> Jason.decode!(message)
              _ -> message
            end

          Process.send_after(:current_test, {:consumed, message, meta}, 50)
          ack(chan, meta)
        end

        if unquote(dynamic) do
          def config, do: unquote(conf)
        end
      end
    end
  end
end
