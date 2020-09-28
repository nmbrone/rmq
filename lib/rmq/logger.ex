defmodule RMQ.Logger do
  defmacro __using__(_) do
    quote do
      require Logger

      @log_prefix "[#{inspect(__MODULE__)}]"

      defp log_debug(message), do: Logger.debug("#{@log_prefix} #{message}")
      defp log_info(message), do: Logger.info("#{@log_prefix} #{message}")
      defp log_warn(message), do: Logger.warn("#{@log_prefix} #{message}")
      defp log_error(message), do: Logger.error("#{@log_prefix} #{message}")

      defp log_debug(module, message), do: Logger.debug("[#{inspect(module)}] #{message}")
      defp log_info(module, message), do: Logger.info("[#{inspect(module)}] #{message}")
      defp log_warn(module, message), do: Logger.warn("[#{inspect(module)}] #{message}")
      defp log_error(module, message), do: Logger.error("[#{inspect(module)}] #{message}")
    end
  end
end
