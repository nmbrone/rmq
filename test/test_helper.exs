defmodule TestHelper do
  def rabbit_uri do
    host = System.get_env("RABBITMQ_HOST", "localhost")
    port = System.get_env("RABBITMQ_PORT", "5672")
    user = System.get_env("RABBITMQ_USER", "guest")
    pass = System.get_env("RABBITMQ_PASSWORD", "guest")
    "amqp://#{user}:#{pass}@#{host}:#{port}"
  end
end

ExUnit.start()
