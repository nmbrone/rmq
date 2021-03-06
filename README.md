# RMQ - RabbitMQ tools.

[![Actions Status](https://github.com/nmbrone/rmq/workflows/CI/badge.svg)](https://github.com/nmbrone/rmq/actions)
[![Hex version badge](https://img.shields.io/hexpm/v/rmq.svg)](https://hex.pm/packages/rmq)

A set of handy tools for working with RabbitMQ in Elixir projects.
Based on [`AMQP`](https://github.com/pma/amqp) library.

It includes:

1. [RMQ.Connection](#rmqconnection)
2. [RMQ.Consumer](#rmqconsumer)
3. [RMQ.RPQ](#rmqrpc)

## Installation

The package can be installed by adding `rmq` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:rmq, "~> 0.3.0"}
  ]
end
```

## RMQ.Connection

A `GenServer` which provides a robust connection to the RabbitMQ server.

#### Usage

```elixir
defmodule MyApp.RabbitConnection do
  use RMQ.Connection,
    otp_app: :my_app,
    uri: "amqp://localhost",
    name: to_string(__MODULE__)
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

* `:uri` - an AMQP URI. Defaults to `"amqp://localhost"`;
* `:reconnect_interval` - a reconnect interval in milliseconds. It can be also a function that
  accepts the current connection attempt as a number and returns a new interval.
  Defaults to `5000`;
* other options for [`AMQP.Connection.open/2`](https://hexdocs.pm/amqp/1.5.0/AMQP.Connection.html#open/2).


## RMQ.Consumer

RabbitMQ Consumer.

#### Usage

```elixir
defmodule MyApp.Consumer do
  use RMQ.Consumer,
    queue: "my-app-consumer-queue",
    exchange: {"my-exchange", :direct, durable: true}

  @impl RMQ.Consumer
  def consume(chan, payload, meta) do
    # do something with the payload
    ack(chan, meta.delivery_tag)
  end
end

# or with dynamic configuration
defmodule MyApp.Consumer2 do
  use RMQ.Consumer

  @impl RMQ.Consumer
  def config do
    [
      queue: System.fetch_env!("QUEUE_NAME"),
      reconnect_interval: fn attempt -> attempt * 1000 end,
    ]
  end

  @impl RMQ.Consumer
  def consume(chan, payload, meta) do
    # do something with the payload
    ack(chan, meta.delivery_tag)
  end
end
```

#### Options

* `:connection` - the connection module which implements `RMQ.Connection` behaviour.
  Defaults to `RMQ.Connection`;
* `:queue` - the name of the queue to consume. Will be created if does not exist.
  Also can be a tuple `{queue, options}`. See the options for `AMQP.Queue.declare/3`;
* `:exchange` - the name of the exchange to which `queue` should be bound.
  Also can be a tuple `{type, exchange, options}`. See the options for
  `AMQP.Exchange.declare/4`. Defaults to `""`;
* `:routing_key` - queue binding key. Defaults to `queue`;
  Will be created if does not exist. Defaults to `""`;
* `:dead_letter` - defines if the consumer should setup deadletter exchange and queue.
  Defaults to `true`;
* `:dead_letter_queue` - the name of dead letter queue. Also can be a tuple `{queue, options}`.
  See the options for `AMQP.Queue.declare/3`. Defaults to `"#{queue}_error"`.;
* `:dead_letter_exchange` - the name of the exchange to which `dead_letter_queue` should be bound.
  Also can be a tuple `{type, exchange}` or `{type, exchange, options}`. See the options for
  `AMQP.Exchange.declare/4`. Defaults to `"#{exchange}.dead-letter"`;
* `:dead_letter_routing_key` - routing key for dead letter messages. Defaults to `queue`;
* `:prefetch_count` - sets the message prefetch count. Defaults to `10`;
* `:consumer_tag` - consumer tag. Defaults to a current module name;
* `:reconnect_interval` - a reconnect interval in milliseconds. It can be also a function that
  accepts the current connection attempt as a number and returns a new interval.
  Defaults to `5000`;

## RMQ.RPC

RPC via RabbitMQ.

#### Usage

```elixir
# Application 1:

defmodule MyApp.RemoteResource do
  use RMQ.RPC, publishing_options: [app_id: "MyApp"]

  def find_by_id(id) do
    call("remote-resource-finder", %{id: id})
  end
end

#  Application 2:

defmodule MyOtherApp.Consumer do
  use RMQ.Consumer, queue: "remote-resource-finder"

  @impl RMQ.Consumer
  def consume(chan, payload, meta) do
    response =
      payload
      |> Jason.decode!()
      |> Map.fetch!("id")
      |> MyOtherApp.Resource.get()
      |> Jason.encode!()

    reply(chan, meta, response)
    ack(chan, meta)
  end
end
```

#### Options

* `:connection` - the connection module which implements `RMQ.Connection` behaviour;
* `:queue` - the queue name to which the module will be subscribed for consuming responses.
  Also can be a tuple `{queue, options}`. See the options for `AMQP.Queue.declare/3`.
  Defaults to `""` which means the broker will assign a name to a newly created queue by itself;
* `:exchange` - the exchange name to which `:queue` will be bound.
  Please make sure the exchange exist. Defaults to `""` - the default exchange;
* `:consumer_tag` - a consumer tag for `:queue`. Defaults to the current module name;
* `:publishing_options` - any valid options for `AMQP.Basic.publish/5` except
  `reply_to`, `correlation_id` - these will be set automatically and cannot be changed.
  Defaults to `[]`;
* `:reconnect_interval` - a reconnect interval in milliseconds. It can be also a function that
  accepts the current connection attempt as a number and returns a new interval.
  Defaults to `5000`;
* `:filter_parameters` - a list of parameters that may contain sensitive data and have
  to be filtered out when logging. Defaults to `["password"]`.
