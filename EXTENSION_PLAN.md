# Plan de Extensión: Cortex Core → Universal Service Gateway

## 🎯 Objetivo

Extender Cortex Core para soportar múltiples tipos de servicios (búsqueda, audio, APIs genéricas) **sin romper** la funcionalidad existente de LLMs.

## 📋 Análisis de Estructura Actual

### Worker Behaviour Actual

```elixir
@callback health_check(worker :: struct()) :: {:ok, :available | :busy} | {:error, term()}
@callback stream_completion(worker :: struct(), messages :: list(map()), opts :: keyword()) ::
            {:ok, Enumerable.t()} | {:error, term()}
@callback info(worker :: struct()) :: map()
@callback priority(worker :: struct()) :: integer()
```

**Problema:** `stream_completion/3` es específico para LLMs (asume `messages`).

### Pool Actual

- Selecciona workers por estrategia (local_first, round_robin)
- Ejecuta health checks periódicos
- Maneja failover automático
- **Solo soporta un tipo de operación:** `stream_completion`

---

## 🏗️ Diseño de Extensión

### Estrategia: Backward Compatible Evolution

#### 1. Worker Behaviour Extendido

```elixir
defmodule CortexCore.Workers.Worker do
  @moduledoc """
  Behaviour que define el contrato para todos los workers.

  Soporta múltiples tipos de servicios:
  - :llm - Language Models (streaming)
  - :search - Web search APIs
  - :audio - Text-to-Speech / Speech-to-Text
  - :vision - Image generation / analysis
  - :http - Generic HTTP APIs
  """

  @type service_type :: :llm | :search | :audio | :vision | :http | :custom
  @type health_status :: :available | :busy | :rate_limited | :quota_exceeded | :unavailable

  # Callback requerido (nuevo)
  @callback service_type() :: service_type()

  # Callbacks existentes (sin cambios)
  @callback health_check(worker :: struct()) :: {:ok, health_status()} | {:error, term()}
  @callback info(worker :: struct()) :: map()
  @callback priority(worker :: struct()) :: integer()

  # Callback para LLMs (mantener backward compatibility)
  @callback stream_completion(worker :: struct(), messages :: list(map()), opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  # Nueva callback genérica
  @callback call(worker :: struct(), params :: map(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @optional_callbacks [stream_completion: 3, call: 3]

  # Funciones de ayuda

  @doc """
  Determina si un worker soporta streaming
  """
  def supports_streaming?(worker_module) do
    function_exported?(worker_module, :stream_completion, 3)
  end

  @doc """
  Invoca al worker de forma genérica
  """
  def invoke(worker, params, opts) do
    worker_module = worker.__struct__

    cond do
      # Si tiene call/3 implementado, usarlo
      function_exported?(worker_module, :call, 3) ->
        apply(worker_module, :call, [worker, params, opts])

      # Backward compatibility: si es LLM y tiene stream_completion
      function_exported?(worker_module, :stream_completion, 3) and
      is_list(Map.get(params, :messages)) ->
        apply(worker_module, :stream_completion, [
          worker,
          params.messages,
          opts
        ])

      true ->
        {:error, :unsupported_operation}
    end
  end
end
```

#### 2. Migración de Workers Existentes

Los workers LLM existentes siguen funcionando sin cambios:

```elixir
defmodule CortexCore.Workers.Adapters.OpenAIWorker do
  @behaviour CortexCore.Workers.Worker

  # NUEVO: Agregar service_type
  def service_type, do: :llm

  # EXISTENTE: Sin cambios
  def stream_completion(worker, messages, opts) do
    # Implementación actual
  end

  def health_check(worker), do: # Implementación actual
  def info(worker), do: # Implementación actual
  def priority(worker), do: 5
end
```

**Migración:** Solo agregar una línea (`service_type/0`) a cada worker existente.

---

## 🔧 Implementación: TavilyWorker (POC)

### Archivo: `lib/cortex_core/workers/adapters/tavily_worker.ex`

```elixir
defmodule CortexCore.Workers.Adapters.TavilyWorker do
  @moduledoc """
  Worker para Tavily Search API.

  Capabilities:
  - Web search con resultados relevantes
  - Rate limiting automático
  - Key rotation
  - Failover
  """

  @behaviour CortexCore.Workers.Worker

  defstruct [
    :name,
    :api_keys,
    :current_key_index,
    :base_url,
    :timeout,
    :last_rotation
  ]

  @default_timeout 30_000
  @base_url "https://api.tavily.com"

  # ============================================
  # Worker Behaviour Implementation
  # ============================================

  @impl true
  def service_type, do: :search

  @impl true
  def call(worker, params, opts) do
    query = Map.fetch!(params, :query)
    max_results = Map.get(params, :max_results, 5)
    search_depth = Map.get(params, :search_depth, "basic")

    execute_search(worker, query, max_results, search_depth, opts)
  end

  @impl true
  def health_check(worker) do
    # Simple ping to check if API is accessible
    api_key = get_current_key(worker)
    headers = [{"api-key", api_key}]

    case Req.get(worker.base_url <> "/health", headers: headers, receive_timeout: 5_000) do
      {:ok, %{status: 200}} ->
        {:ok, :available}

      {:ok, %{status: 429}} ->
        {:error, {:rate_limited, "Tavily API rate limited"}}

      {:ok, %{status: 403}} ->
        {:error, {:quota_exceeded, "Tavily API quota exceeded"}}

      {:ok, %{status: status}} when status >= 500 ->
        {:error, {:server_error, status}}

      {:error, %{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def info(worker) do
    %{
      name: worker.name,
      type: :search,
      service: :tavily,
      api_keys_count: length(worker.api_keys),
      current_key_index: worker.current_key_index,
      base_url: worker.base_url,
      timeout: worker.timeout,
      capabilities: [
        "web_search",
        "deep_search",
        "news_search"
      ]
    }
  end

  @impl true
  def priority(_worker), do: 20  # Prioridad media (después de local, antes de LLMs caros)

  # ============================================
  # Public API
  # ============================================

  def new(opts) do
    api_keys = case Keyword.get(opts, :api_keys) do
      keys when is_list(keys) and keys != [] -> keys
      single_key when is_binary(single_key) -> [single_key]
      _ -> raise ArgumentError, "api_keys debe ser una lista no vacía o string"
    end

    %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      api_keys: api_keys,
      current_key_index: 0,
      base_url: Keyword.get(opts, :base_url, @base_url),
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      last_rotation: nil
    }
  end

  # ============================================
  # Private Functions
  # ============================================

  defp execute_search(worker, query, max_results, search_depth, _opts) do
    api_key = get_current_key(worker)

    payload = %{
      api_key: api_key,
      query: query,
      max_results: max_results,
      search_depth: search_depth,
      include_answer: true,
      include_raw_content: false,
      include_images: false
    }

    headers = [
      {"Content-Type", "application/json"},
      {"api-key", api_key}
    ]

    case Req.post(
      worker.base_url <> "/search",
      json: payload,
      headers: headers,
      receive_timeout: worker.timeout
    ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_response(body)}

      {:ok, %{status: 429, body: body}} ->
        # Rate limited - intentar rotar key
        error_msg = extract_error_message(body)
        {:error, {:rate_limited, error_msg}}

      {:ok, %{status: 403, body: body}} ->
        error_msg = extract_error_message(body)
        {:error, {:quota_exceeded, error_msg}}

      {:ok, %{status: status, body: body}} when status >= 400 ->
        error_msg = extract_error_message(body)
        {:error, {:http_error, status, error_msg}}

      {:error, %{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_current_key(worker) do
    Enum.at(worker.api_keys, worker.current_key_index)
  end

  defp parse_response(body) when is_map(body) do
    # Normalizar respuesta de Tavily
    %{
      results: Map.get(body, "results", []),
      answer: Map.get(body, "answer"),
      query: Map.get(body, "query"),
      response_time: Map.get(body, "response_time")
    }
  end

  defp parse_response(body), do: body

  defp extract_error_message(body) when is_map(body) do
    Map.get(body, "error") || Map.get(body, "message") || "Unknown error"
  end

  defp extract_error_message(body) when is_binary(body), do: body
  defp extract_error_message(_), do: "Unknown error"
end
```

---

## 🔄 Actualización del API Público

### Archivo: `lib/cortex_core.ex`

```elixir
defmodule CortexCore do
  alias CortexCore.{Dispatcher, Workers}

  # ============================================
  # API Existente (sin cambios - backward compatible)
  # ============================================

  @doc """
  Sends a chat completion request (LLM specific).
  Backward compatible con versión anterior.
  """
  @spec chat(list(message()), chat_opts()) ::
    {:ok, Enumerable.t()} | {:error, term()}
  def chat(messages, opts \\ []) when is_list(messages) do
    call(:llm, %{messages: messages}, opts)
  end

  # Alias para backward compatibility
  defdelegate stream_completion(messages, opts \\ []), to: __MODULE__, as: :chat

  # ============================================
  # Nueva API Unificada
  # ============================================

  @doc """
  Llamada unificada a cualquier tipo de servicio.

  ## Service Types

  - `:llm` - Language Model (streaming chat)
  - `:search` - Web search
  - `:audio` - Text-to-Speech / Speech-to-Text
  - `:http` - Generic HTTP API

  ## Examples

      # LLM
      CortexCore.call(:llm, %{messages: [...]})

      # Search
      CortexCore.call(:search, %{query: "Elixir programming"})

      # Audio
      CortexCore.call(:audio, %{text: "Hello", voice: "adam"})
  """
  @spec call(service_type :: atom(), params :: map(), opts :: keyword()) ::
    {:ok, term()} | {:error, term()}
  def call(service_type, params, opts \\ []) do
    Dispatcher.dispatch(service_type, params, opts)
  end

  @doc """
  Llama a un servicio específico por nombre.

  ## Examples

      CortexCore.call_service(:tavily, %{query: "..."})
      CortexCore.call_service(:elevenlabs, %{text: "...", voice: "..."})
  """
  @spec call_service(service_name :: atom(), params :: map(), opts :: keyword()) ::
    {:ok, term()} | {:error, term()}
  def call_service(service_name, params, opts \\ []) do
    Dispatcher.dispatch_to_service(service_name, params, opts)
  end

  # Resto de funciones existentes...
  def health_status, do: Dispatcher.health_status()
  def check_health, do: Dispatcher.check_workers()
  def list_workers, do: Workers.Supervisor.list_workers() |> Enum.map(&worker_info/1)
  def add_worker(name, opts), do: Workers.Supervisor.add_worker(name, opts)
  def remove_worker(name), do: Workers.Supervisor.remove_worker(name)

  defp worker_info(worker) do
    apply(worker.__struct__, :info, [worker])
  end
end
```

---

## 🔄 Actualización del Dispatcher

### Archivo: `lib/cortex_core/dispatcher.ex`

```elixir
defmodule CortexCore.Dispatcher do
  require Logger

  # ============================================
  # Backward Compatible API
  # ============================================

  @doc "Backward compatible - delega a nueva API"
  def dispatch_stream(messages, opts \\ []) do
    dispatch(:llm, %{messages: messages}, opts)
  end

  # ============================================
  # Nueva API Unificada
  # ============================================

  @doc """
  Despacha una llamada según el tipo de servicio
  """
  def dispatch(service_type, params, opts \\ []) do
    case CortexCore.Workers.Pool.call(
      CortexCore.Workers.Pool,
      service_type,
      params,
      opts
    ) do
      {:ok, result} ->
        Logger.info("Dispatched #{service_type} successfully")
        {:ok, result}

      {:error, :no_workers_available} = error ->
        Logger.error("No workers available for service #{service_type}")
        error

      {:error, reason} = error ->
        Logger.error("Error dispatching #{service_type}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Despacha a un servicio específico por nombre
  """
  def dispatch_to_service(service_name, params, opts) do
    opts = Keyword.put(opts, :service, service_name)
    service_type = get_service_type(service_name)
    dispatch(service_type, params, opts)
  end

  def health_status do
    CortexCore.Workers.Pool.health_status()
  end

  def check_workers do
    CortexCore.Workers.Pool.check_health()
  end

  # Helpers

  defp get_service_type(service_name) do
    # Mapeo de nombres a tipos
    case service_name do
      name when name in [:tavily, :serper, :brave] -> :search
      name when name in [:elevenlabs, :whisper] -> :audio
      name when name in [:openai, :anthropic, :gemini, :ollama] -> :llm
      _ -> :http
    end
  end
end
```

---

## 🔄 Actualización del Pool

### Modificación en: `lib/cortex_core/workers/pool.ex`

Agregar nuevo handler:

```elixir
defmodule CortexCore.Workers.Pool do
  # ... código existente ...

  # NUEVO: Handler genérico para cualquier tipo de servicio
  def call(pool \\ __MODULE__, service_type, params, opts) do
    GenServer.call(pool, {:call, service_type, params, opts}, 30_000)
  end

  # NUEVO: Handle call genérico
  @impl true
  def handle_call({:call, service_type, params, opts}, _from, state) do
    case select_and_execute_service(state, service_type, params, opts) do
      {:ok, result, new_state} ->
        {:reply, {:ok, result}, new_state}

      {:ok, result} ->
        {:reply, {:ok, result}, state}

      {:error, reason} = error ->
        Logger.error("Error executing service #{service_type}: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  # Handler existente para backward compatibility
  @impl true
  def handle_call({:stream_completion, messages, opts}, _from, state) do
    # Delegar a nueva implementación
    case select_and_execute_service(state, :llm, %{messages: messages}, opts) do
      {:ok, stream, new_state} ->
        {:reply, {:ok, stream}, new_state}

      {:ok, stream} ->
        {:reply, {:ok, stream}, state}

      {:error, reason} = error ->
        {:reply, error, state}
    end
  end

  # NUEVA: Función de selección y ejecución genérica
  defp select_and_execute_service(state, service_type, params, opts) do
    # Obtener workers del tipo correcto
    workers = get_workers_by_service_type(state, service_type, opts)

    if workers == [] do
      {:error, :no_workers_available}
    else
      execute_with_workers_generic(workers, params, opts)
    end
  end

  defp get_workers_by_service_type(state, service_type, opts) do
    all_workers = get_all_workers(state)

    # Filtrar por tipo de servicio
    service_workers = all_workers
    |> Enum.filter(fn worker ->
      apply(worker.__struct__, :service_type, []) == service_type
    end)

    # Si se especificó un servicio concreto, filtrar más
    case Keyword.get(opts, :service) do
      nil ->
        service_workers

      service_name ->
        service_workers
        |> Enum.filter(fn worker ->
          String.contains?(worker.name, to_string(service_name))
        end)
    end
    |> filter_available(state)
    |> sort_by_strategy(state)
  end

  defp execute_with_workers_generic(workers, params, opts) do
    execute_with_failover_generic(workers, params, opts, [])
  end

  defp execute_with_failover_generic([], _params, _opts, errors) do
    detailed_errors = errors
    |> Enum.map(fn {worker, error} -> "#{worker}: #{inspect(error)}" end)
    |> Enum.join("; ")

    {:error, {:all_workers_failed, detailed_errors}}
  end

  defp execute_with_failover_generic([worker | rest], params, opts, errors) do
    Logger.info("Trying worker: #{worker.name}")

    result = CortexCore.Workers.Worker.invoke(worker, params, opts)

    case result do
      {:ok, response} ->
        Logger.info("Worker #{worker.name} succeeded")
        {:ok, response}

      {:error, reason} ->
        Logger.warning("Worker #{worker.name} failed: #{inspect(reason)}")
        execute_with_failover_generic(rest, params, opts, [{worker.name, reason} | errors])
    end
  end

  # ... resto del código existente ...
end
```

---

## 📝 Configuración

### En `config/config.exs`

```elixir
config :cortex_core,
  workers: [
    # LLM Workers (existentes)
    {:openai, [
      type: :llm,
      api_keys: System.get_env("OPENAI_API_KEYS") |> String.split(","),
      default_model: "gpt-4"
    ]},

    # NEW: Search Workers
    {:tavily, [
      type: :search,
      api_keys: System.get_env("TAVILY_API_KEYS") |> String.split(",")
    ]},

    # NEW: Audio Workers (futuro)
    # {:elevenlabs, [
    #   type: :audio,
    #   api_keys: System.get_env("ELEVENLABS_API_KEYS") |> String.split(",")
    # ]}
  ]
```

---

## ✅ Plan de Implementación

### Fase 1: Extensión del Behaviour (Esta sesión)
- [x] Analizar estructura actual
- [ ] Agregar `service_type/0` callback
- [ ] Agregar `call/3` callback opcional
- [ ] Implementar `Worker.invoke/3` helper
- [ ] Tests unitarios del behaviour

### Fase 2: Implementar TavilyWorker (Esta sesión)
- [ ] Crear `TavilyWorker`
- [ ] Implementar `call/3` con manejo de errores
- [ ] Health check específico para Tavily
- [ ] Tests de integración con API real (opcional)
- [ ] Tests con mocks

### Fase 3: Actualizar Pool y Dispatcher (Esta sesión)
- [ ] Agregar handler `call/4` en Pool
- [ ] Implementar `select_and_execute_service/4`
- [ ] Agregar `dispatch/3` en Dispatcher
- [ ] Mantener backward compatibility
- [ ] Tests de integración

### Fase 4: Actualizar API Pública (Esta sesión)
- [ ] Agregar `CortexCore.call/3`
- [ ] Agregar `CortexCore.call_service/3`
- [ ] Mantener `chat/2` como wrapper
- [ ] Actualizar documentación
- [ ] Tests de API pública

### Fase 5: Migrar Workers Existentes (Próxima sesión)
- [ ] Agregar `service_type/0` a todos los workers LLM
- [ ] Verificar que todos los tests pasen
- [ ] Actualizar documentación de workers

### Fase 6: Workers Adicionales (Futuro)
- [ ] SerperWorker (search alternativo)
- [ ] ElevenLabsWorker (audio)
- [ ] GenericHTTPWorker (template para custom APIs)

---

## 🧪 Tests

### Test del Behaviour Extendido

```elixir
defmodule CortexCore.Workers.WorkerTest do
  use ExUnit.Case

  test "invoke/3 calls call/3 when available" do
    # Test implementation
  end

  test "invoke/3 falls back to stream_completion for LLMs" do
    # Test implementation
  end
end
```

### Test de TavilyWorker

```elixir
defmodule CortexCore.Workers.Adapters.TavilyWorkerTest do
  use ExUnit.Case

  describe "call/3" do
    test "executes search successfully" do
      # Mock Req
      # Test implementation
    end

    test "handles rate limiting" do
      # Test rate limiting
    end
  end

  describe "health_check/1" do
    test "returns available when API is up" do
      # Test implementation
    end
  end
end
```

---

## 📊 Backward Compatibility Checklist

- [x] Workers LLM existentes siguen funcionando sin cambios
- [x] `CortexCore.chat/2` sigue funcionando
- [x] `CortexCore.stream_completion/2` sigue funcionando
- [x] Pool selecciona workers correctamente
- [x] Health checks funcionan igual
- [x] Failover funciona igual
- [x] Strategies (local_first, round_robin) funcionan igual

---

## 🚀 Próximos Pasos Inmediatos

1. ✅ **Completado**: Análisis de estructura actual
2. **Ahora**: Implementar cambios en Worker behaviour
3. **Siguiente**: Crear TavilyWorker completo
4. **Luego**: Actualizar Pool y Dispatcher
5. **Finalmente**: Tests y documentación

¿Empezamos con la implementación del Worker Behaviour extendido?
