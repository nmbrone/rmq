# RMQ - RabbitMQ tools.

[![Actions Status](https://github.com/nmbrone/rmq/workflows/build/badge.svg?branch=master)](https://github.com/nmbrone/rmq/actions)
[![Hex version badge](https://img.shields.io/hexpm/v/rmq.svg)](https://hex.pm/packages/rmq)

A set of handy tools for working with RabbitMQ in Elixir projects.
Based on [`amqp`](https://github.com/pma/amqp) elixir client.

## Installation

The package can be installed by adding `rmq` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:rmq, "~> 0.1.0-beta.0"}
  ]
end
```

## RMQ.Connection

A `GenServer` which opens and holds a connection to RabbitMQ broker.

#### Usage

```elixir
defmodule MyApp.RabbitConnection do
  use RMQ.Connection,
    otp_app: :my_app,
    uri: "amqp://localhost",
    connection_name: to_string(__MODULE__)
end
```

Meant to be started under the application's supervision tree as follows:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      MyApp.RabbitConnection
      # ...
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

```

#### Options

* `:uri` - AMQP URI (defaults to `"amqp://localhost"`);
* `:connection_name` - RabbitMQ connection name (defaults to `:undefined`);
* `:reconnect_interval` - Reconnect interval (defaults to `5000`);
* options for [`AMQP.Connection.open/3`](https://hexdocs.pm/amqp/1.4.0/AMQP.Connection.html#open/3).

Options passed to `start_link/1` will be merged into options from the config.

## RMQ.RPC

RPC via RabbitMQ.

#### Usage

```elixir
defmodule MyApp.RemoteResource do
  use RMQ.RPC,
    connection: MyApp.RabbitConnection,
    publishing_options: [app_id: "MyApp"]

  def find_by_id(id) do
    call("remote-resource-finder", %{id: id}, [message_id: "msg-123"])
  end

  def list_all() do
    call("remote-resource-list-all", %{})
  end
end
```

#### Options

* `:connection` - the connection module which implements `RMQ.Connection` behaviour;
* `:exchange` - the name of the exchange to which RPC consuming queue is bound.
  Please make sure the exchange exist. Defaults to `""`.
* `:timeout` - default timeout for `call/4` Defaults to `5000`.
* `:consumer_tag` - consumer tag for the callback queue. Defaults to a current module name;
* `:restart_delay` - restart delay. Defaults to `5000`;
* `:publishing_options` - options for [`AMQP.Basic.publish/5`](https://hexdocs.pm/amqp/1.4.0/AMQP.Basic.html#publish/5) 
  except `:reply_to`, `:correlation_id`, `:content_type` - these will be set automatically
  and cannot be overridden. Defaults to `[]`.


## RMQ.Consumer

RabbitMQ Consumer.

#### Usage

```elixir
defmodule MyApp.Consumer do
  use RMQ.Consumer,
    connection: MyApp.RabbitConnection,
    queue: "my-app-consumer-queue"

  @impl RMQ.Consumer
  def process(message, %{content_type: "application/json"}), do: Jason.decode!(message)
  def process(message, _meta), do: message
  
  @impl RMQ.Consumer
  def consume(chan, payload, meta) do
    # handle message here
    ack(chan, meta.delivery_tag)
  end
end
```

#### Options

* `:connection` - the connection module which implements `RMQ.Connection` behaviour;
* `:queue` - the name of the queue to consume. Will be created if does not exist;
* `:exchange` - the name of the exchange to which `queue` should be bound.
  Also accepts two-element tuple `{type, name}`. Defaults to `""`;
* `:routing_key` - queue binding key. Defaults to `queue`;
  Will be created if does not exist. Defaults to `""`;
* `:dead_letter` - defines if the consumer should setup deadletter exchange and queue.
  Defaults to `true`;
* `:dead_letter_queue` - the name of dead letter queue. Defaults to `"#{queue}_error"`;
* `:dead_letter_exchange` - the name of the exchange to which `dead_letter_queue` should be bound.
  Also accepts two-element tuple `{type, name}`. Defaults to `"#{exchange}.dead-letter"`;
* `:dead_letter_routing_key` - routing key for dead letter messages. Defaults to `queue`;
* `:concurrency` - defines if `consume/3` callback will be called in a separate process
  using `Task.start/1`. Defaults to `true`;
* `:prefetch_count` - sets the message prefetch count. Defaults to `10`;
* `:consumer_tag` - consumer tag. Defaults to a current module name;
* `:restart_delay` - restart delay. Defaults to `5000`.
