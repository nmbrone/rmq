defmodule RMQ.ConsumerTest do
  use RMQ.Case

  define_consumer(Consumer1, queue: "rmq_consumer_1")
  define_consumer(Consumer2, queue: "rmq_consumer_2", exchange: "rmq")

  define_consumer(Consumer3,
    queue: "rmq_consumer_3",
    exchange: {:topic, "rmq_topic"},
    routing_key: "*.*"
  )

  define_consumer(Consumer4, queue: "rmq_consumer_4", dead_letter: false, restart_delay: 100)

  setup do
    {:ok, conn} = RMQ.Connection.get_connection()
    {:ok, chan} = AMQP.Channel.open(conn)
    {:ok, conn: conn, chan: chan}
  end

  test "consumes from default exchange", %{chan: chan} do
    queue = "rmq_consumer_1"
    AMQP.Queue.delete(chan, queue)
    start_supervised!(Consumer1)
    Process.sleep(100)
    message = "Hello, World!"
    message_id = uuid()
    AMQP.Basic.publish(chan, "", queue, message, message_id: message_id)
    assert_receive {:consumed, ^message, %{message_id: ^message_id}}
  end

  test "declares the exchange and consumes from it", %{chan: chan} do
    exchange = "rmq"
    dl_exchange = "rmq.dead-letter"
    queue = "rmq_consumer_2"
    AMQP.Exchange.delete(chan, exchange)
    AMQP.Exchange.delete(chan, dl_exchange)
    AMQP.Queue.delete(chan, queue)
    start_supervised!(Consumer2)
    Process.sleep(100)
    message = "Hello, World!"
    message_id = uuid()
    AMQP.Basic.publish(chan, exchange, queue, message, message_id: message_id)
    assert exchange_exist?(chan, {:direct, dl_exchange})
    assert_receive {:consumed, ^message, %{message_id: ^message_id}}
  end

  test "declares the exchange of type other than :direct via tuple {type, name}", %{chan: chan} do
    exchange = "rmq_topic"
    AMQP.Exchange.delete(chan, exchange)
    start_supervised!(Consumer3)
    Process.sleep(100)
    message = "Hello, World!"
    message_id = uuid()
    AMQP.Basic.publish(chan, exchange, "rmq.topic", message, message_id: message_id)
    assert_receive {:consumed, ^message, %{message_id: ^message_id}}
  end

  test "dead letter can be opted out", %{chan: chan} do
    exchange = ".dead-letter"
    AMQP.Exchange.delete(chan, exchange)
    start_supervised!(Consumer4)
    Process.sleep(100)
    refute exchange_exist?(chan, {:direct, exchange})
  end

  test "automatically restarts", %{conn: conn, chan: chan} do
    AMQP.Queue.delete(chan, "rmq_consumer_4")
    start_supervised!(Consumer4)
    Process.sleep(100)
    message = "Hello, World!"
    message_id = uuid()
    AMQP.Basic.publish(chan, "", "rmq_consumer_4", message, message_id: message_id)
    AMQP.Connection.close(conn)
    assert_receive {:consumed, ^message, %{message_id: ^message_id}}, 300
  end

  def exchange_exist?(chan, {type, exchange}) do
    # with `passive: true` returns an error if the Exchange does not already exist
    # see https://hexdocs.pm/amqp/AMQP.Exchange.html#declare/4
    try do
      :ok = AMQP.Exchange.declare(chan, exchange, type, passive: true)
      true
    catch
      :exit, _ -> false
    end
  end
end
