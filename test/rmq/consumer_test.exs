defmodule RMQ.ConsumerTest do
  use RMQ.Case

  define_consumer(Consumer, queue: "rmq_queue")
  define_consumer(Consumer2, queue: "rmq_queue_2", exchange: "rmq_exchange")

  setup do
    {:ok, conn} = RMQ.Connection.get_connection()
    {:ok, chan} = AMQP.Channel.open(conn)
    AMQP.Exchange.delete(chan, "rmq_exchange")
    AMQP.Queue.delete(chan, "rmq_queue")
    AMQP.Queue.delete(chan, "rmq_queue_2")
    {:ok, conn: conn, chan: chan}
  end

  test "creates consumer with default exchange", %{chan: chan} do
    start_supervised!(Consumer)
    Process.sleep(100)
    message = "Hello, World!"
    message_id = uuid()
    AMQP.Basic.publish(chan, "", "rmq_queue", message, message_id: message_id)
    assert_receive {:consumed, ^message, %{message_id: message_id}}
  end

  test "creates consumer with non default exchange", %{chan: chan} do
    start_supervised!(Consumer2)
    Process.sleep(100)
    message = "Hello, World!"
    message_id = uuid()
    AMQP.Basic.publish(chan, "rmq_exchange", "rmq_queue_2", message, message_id: message_id)
    assert_receive {:consumed, ^message, %{message_id: message_id}}
  end
end
