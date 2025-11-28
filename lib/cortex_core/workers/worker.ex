defmodule CortexCore.Workers.Worker do
  @moduledoc """
  Behaviour que define el contrato para todos los workers.

  Soporta múltiples tipos de servicios:
  - `:llm` - Language Models (streaming chat)
  - `:embeddings` - Text embeddings for RAG and semantic search
  - `:search` - Web search APIs
  - `:audio` - Text-to-Speech / Speech-to-Text
  - `:vision` - Image generation / analysis
  - `:http` - Generic HTTP APIs

  Cada worker debe implementar:
  - Tipo de servicio (`service_type/0`)
  - Health check (`health_check/1`)
  - Información (`info/1`)
  - Prioridad (`priority/1`)
  - Operación principal (`call/3` o `stream_completion/3`)
  """

  @type service_type :: :llm | :embeddings | :search | :audio | :vision | :http | :custom
  @type health_status :: :available | :busy | :rate_limited | :quota_exceeded | :unavailable

  @doc """
  Retorna el tipo de servicio que provee este worker.

  Returns:
    - `:llm` para Language Models
    - `:embeddings` para Text embeddings
    - `:search` para Web search
    - `:audio` para TTS/STT
    - `:vision` para Image generation/analysis
    - `:http` para APIs genéricas
  """
  @callback service_type() :: service_type()

  @doc """
  Verifica si el worker está disponible y funcionando.

  El worker recibe su propia struct como argumento.

  Returns:
    - `{:ok, :available}` si el worker está listo
    - `{:ok, :busy}` si está ocupado pero funcional
    - `{:error, reason}` si hay algún problema
  """
  @callback health_check(worker :: struct()) :: {:ok, health_status()} | {:error, term()}

  @doc """
  Procesa una lista de mensajes y devuelve un stream de respuestas.

  **Específico para LLMs - Mantiene backward compatibility.**

  Args:
    - worker: La struct del worker
    - messages: Lista de mensajes con formato [%{role: String.t(), content: String.t()}]
    - opts: Opciones adicionales (modelo, temperatura, etc.)

  Returns:
    - `{:ok, stream}` donde stream es un Stream que emite chunks de texto
    - `{:error, reason}` si no puede procesar la petición
  """
  @callback stream_completion(worker :: struct(), messages :: list(map()), opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @doc """
  Ejecuta una operación genérica en el worker.

  **Nueva callback unificada para todos los tipos de servicios.**

  Args:
    - worker: La struct del worker
    - params: Mapa con parámetros específicos del servicio
    - opts: Opciones adicionales

  Returns:
    - `{:ok, result}` si la operación fue exitosa
    - `{:error, reason}` si hubo un error

  ## Examples

      # Search worker
      call(worker, %{query: "Elixir", max_results: 5}, [])

      # Audio worker
      call(worker, %{text: "Hello", voice: "adam"}, [])
  """
  @callback call(worker :: struct(), params :: map(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Devuelve información sobre el worker.

  Args:
    - worker: La struct del worker

  Returns:
    - Mapa con información del worker (nombre, tipo, modelos soportados, etc.)
  """
  @callback info(worker :: struct()) :: map()

  @doc """
  Devuelve la prioridad del worker (menor número = mayor prioridad).
  Usado para ordenar workers cuando hay múltiples disponibles.

  Args:
    - worker: La struct del worker
  """
  @callback priority(worker :: struct()) :: integer()

  # stream_completion y call son opcionales para backward compatibility
  @optional_callbacks [stream_completion: 3, call: 3]

  # ============================================
  # Helper Functions
  # ============================================

  @doc """
  Determina si un worker soporta streaming (LLMs).
  """
  def supports_streaming?(worker_module) when is_atom(worker_module) do
    function_exported?(worker_module, :stream_completion, 3)
  end

  @doc """
  Invoca al worker de forma genérica.

  Selecciona automáticamente entre `call/3` o `stream_completion/3`
  dependiendo de lo que el worker implemente.
  """
  def invoke(worker, params, opts) when is_struct(worker) and is_map(params) do
    worker_module = worker.__struct__

    cond do
      # Prioridad 1: Si tiene call/3 implementado, usarlo
      function_exported?(worker_module, :call, 3) ->
        apply(worker_module, :call, [worker, params, opts])

      # Prioridad 2: Backward compatibility para LLMs con stream_completion
      function_exported?(worker_module, :stream_completion, 3) and
      Map.has_key?(params, :messages) ->
        apply(worker_module, :stream_completion, [
          worker,
          params.messages,
          opts
        ])

      # No implementa ninguna operación
      true ->
        {:error, :unsupported_operation}
    end
  end
end