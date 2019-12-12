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
* any other option for [`AMQP.Connection.open/2`](https://hexdocs.pm/amqp/1.4.0/AMQP.Connection.html#open/2-options).


## RMQ.RPC

RPC via RabbitMQ.

#### Usage

```elixir
defmodule MyApp.RemoteResource do
  use RMQ.RPC, timeout: 5000
    
  def find_by_id(id) do
    remote_call("remote_resource_finder", id: id)
  end
end
```
