# RMQ

A set of handy tools for working with RabbitMQ in Elixir projects.
Based on [`amqp`](https://github.com/pma/amqp) elixir client.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `rmq` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:rmq, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/rmq](https://hexdocs.pm/rmq).


## RMQ.Connection

A GenServer which is responsible for opening and keeping a robust connection to the RabbitMQ broker.

#### Usage

```elixir
RMQ.Connection.start_link(options)
```

In most applications it should be started under the application's supervision tree as follows:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      {RMQ.Connection, [uri: "amqp://localhost", connection_name: "MyApp"]},
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


## RMQ.RPC

RPC via RabbitMQ.

#### Usage

```elixir
defmodule MyApp.RemoteResource do
  use RMQ.RPC, publishing_options: [app_id: "MyApp"]
    
  def find_by_id(id) do
    remote_call("remote-resource-finder", %{id: id}, [message_id: "msg-123"])
  end

  def list_all() do
    remote_call("remote-resource-list-all", %{})
  end
end
```

#### Options

* `:exchange` - the name of the exchange to which RPC consuming queue is bound.
  Please make sure the exchange exist. Defaults to `""`.
* `:timeout` - default timeout for `remote_call/4` Defaults to `5000`.
* `:consumer_tag` - consumer tag for the callback queue. Defaults to a current module name;
* `:restart_delay` - restart delay. Defaults to `5000`;
* `:publishing_options` - options for [`AMQP.Basic.publish/5`](https://hexdocs.pm/amqp/1.4.0/AMQP.Basic.html#publish/5) 
  except `:reply_to`, `:correlation_id`, `:content_type` - these will be set automatically
  and cannot be overridden. Defaults to `[]`;


## RMQ.Consumer

RabbitMQ Consumer.

#### Usage

```elixir
defmodule MyApp.Consumer do
  use RMQ.Consumer, queue: "my-app-consumer-queue"

  @impl RMQ.Consumer
  def consume(chan, message, meta) do
    # handle message here
    ack(chan, meta.delivery_tag)
  end
end
```

#### Options

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
* `:restart_delay` - restart delay. Defaults to `5000`;
