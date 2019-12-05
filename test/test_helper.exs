# Suppress RabbitMQ progress logs
:logger.add_primary_filter(
  :ignore_rabbitmq_progress_reports,
  {&:logger_filters.domain/2, {:stop, :equal, [:progress]}}
)

ExUnit.start()
