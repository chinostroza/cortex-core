# lib/cortex/dispatcher.ex

defmodule CortexCore.Dispatcher do
  @moduledoc """
  Dispatcher principal que delega el trabajo al pool de workers.

  Este módulo mantiene compatibilidad hacia atrás mientras usa
  el nuevo sistema de workers internamente.
  """

  require Logger

  @doc """
  Despacha una operación genérica a un worker del tipo especificado.

  Esta es la nueva API unificada para todos los tipos de servicios.

  ## Parameters
    - service_type: Tipo de servicio (:llm, :search, :audio, :vision, :http)
    - params: Mapa con parámetros específicos del servicio
    - opts: Opciones adicionales (timeout, etc.)

  ## Returns
    - `{:ok, result}` si la operación fue exitosa
    - `{:error, reason}` si hubo un error

  ## Examples
      # Web search
      dispatch(:search, %{query: "Elixir benefits", max_results: 5}, [])

      # Text-to-speech
      dispatch(:audio, %{text: "Hello world", voice: "adam"}, [])

      # LLM chat (aunque se recomienda usar dispatch_stream para streaming)
      dispatch(:llm, %{messages: messages}, [model: "gpt-4"])
  """
  def dispatch(service_type, params, opts \\ []) do
    case CortexCore.Workers.Pool.call(CortexCore.Workers.Pool, service_type, params, opts) do
      {:ok, result} ->
        Logger.info("Operación #{service_type} despachada exitosamente")
        {:ok, result}

      {:error, :no_workers_available} = error ->
        Logger.error("No hay workers disponibles para service_type: #{service_type}")
        error

      {:error, reason} = error ->
        Logger.error("Error en dispatch #{service_type}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Alias explícito para dispatch/3.

  Útil para hacer el código más legible cuando se llama a servicios específicos.

  ## Examples
      dispatch_to_service(:search, %{query: "..."}, [])
  """
  defdelegate dispatch_to_service(service_type, params, opts \\ []), to: __MODULE__, as: :dispatch

  @doc """
  Despacha un stream de completion usando el pool de workers.

  Esta función mantiene compatibilidad hacia atrás con la API original.
  Para nuevos servicios LLM, considerar usar dispatch(:llm, %{messages: ...}, []).

  ## Args
    - messages: Lista de mensajes en formato OpenAI
    - opts: Opciones adicionales (modelo, etc.)

  ## Returns
    - `{:ok, stream}` si puede procesar la petición
    - `{:error, reason}` si no hay workers disponibles
  """
  def dispatch_stream(messages, opts \\ []) do
    case CortexCore.Workers.Pool.stream_completion(CortexCore.Workers.Pool, messages, opts) do
      {:ok, stream} ->
        Logger.info("Stream despachado exitosamente")
        {:ok, stream}

      {:error, :no_workers_available} = error ->
        Logger.error("No hay workers disponibles")
        error

      {:error, reason} = error ->
        Logger.error("Error en dispatch_stream: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Obtiene el estado de salud de todos los workers.
  """
  def health_status do
    CortexCore.Workers.Pool.health_status()
  end

  @doc """
  Fuerza un health check de todos los workers.
  """
  def check_workers do
    CortexCore.Workers.Pool.check_health()
  end
end
