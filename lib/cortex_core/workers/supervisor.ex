defmodule CortexCore.Workers.Supervisor do
  @moduledoc """
  Supervisor principal para el sistema de workers.

  Responsabilidades:
  - Supervisar Registry y Pool
  - Configurar workers desde configuración
  - Manejar el ciclo de vida del sistema de workers
  """

  use Supervisor
  require Logger

  alias CortexCore.Workers.{Pool, Registry}

  alias CortexCore.Workers.Adapters.{
    AnthropicWorker,
    BraveWorker,
    CohereWorker,
    DuckDuckGoWorker,
    GeminiWorker,
    GroqWorker,
    OllamaWorker,
    OpenAIEmbeddingsWorker,
    OpenAIWorker,
    PubMedWorker,
    SerperWorker,
    TavilyWorker,
    XAIWorker
  }

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    registry_name = Keyword.get(opts, :registry_name, CortexCore.Workers.Registry)
    pool_name = Keyword.get(opts, :pool_name, CortexCore.Workers.Pool)
    strategy = get_pool_strategy()
    health_check_interval = get_health_check_interval()

    children = [
      {Registry, [name: registry_name]},
      {Pool,
       [
         name: pool_name,
         registry: registry_name,
         strategy: strategy,
         check_interval: health_check_interval
       ]},
      {Task.Supervisor, name: CortexCore.Workers.TaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: __MODULE__]
    Supervisor.init(children, opts)
  end

  defp get_pool_strategy do
    env_strategy = System.get_env("WORKER_POOL_STRATEGY", "local_first")

    strategy =
      case env_strategy do
        "round_robin" -> :round_robin
        "least_used" -> :least_used
        "random" -> :random
        _ -> :local_first
      end

    Logger.info("Pool strategy configurada: #{inspect(strategy)} (desde env: #{env_strategy})")
    strategy
  end

  defp get_health_check_interval do
    case System.get_env("HEALTH_CHECK_INTERVAL") do
      nil -> 30_000
      "0" -> :disabled
      interval_str -> parse_interval(interval_str)
    end
  end

  defp parse_interval(interval_str) do
    case Integer.parse(interval_str) do
      {seconds, ""} -> seconds * 1000
      _ -> 30_000
    end
  end

  @doc """
  Agrega un worker al registry en tiempo de ejecución.
  """
  def add_worker(supervisor \\ __MODULE__, name, worker_opts) do
    registry_name = get_registry_name(supervisor)

    case create_worker(worker_opts[:type], name, worker_opts) do
      {:error, _} = error -> error
      worker -> Registry.register(registry_name, name, worker)
    end
  end

  defp create_worker(:openai, name, opts),
    do: OpenAIWorker.new(Keyword.put(opts, :name, name))

  defp create_worker(:openai_embeddings, name, opts),
    do: OpenAIEmbeddingsWorker.new(Keyword.put(opts, :name, name))

  defp create_worker(:anthropic, name, opts),
    do: AnthropicWorker.new(Keyword.put(opts, :name, name))

  defp create_worker(:xai, name, opts),
    do: XAIWorker.new(Keyword.put(opts, :name, name))

  defp create_worker(:gemini_pro_25, name, opts),
    do: GeminiWorker.new(Keyword.put(opts, :name, name))

  defp create_worker(:ollama, name, opts),
    do: OllamaWorker.new(Keyword.put(opts, :name, name))

  defp create_worker(:groq, name, opts),
    do: GroqWorker.new(Keyword.put(opts, :name, name))

  defp create_worker(:gemini, name, opts),
    do: GeminiWorker.new(Keyword.put(opts, :name, name))

  defp create_worker(:cohere, name, opts),
    do: CohereWorker.new(Keyword.put(opts, :name, name))

  defp create_worker(:tavily, name, opts),
    do: TavilyWorker.new(Keyword.put(opts, :name, name))

  defp create_worker(:serper, name, opts),
    do: SerperWorker.new(Keyword.put(opts, :name, name))

  defp create_worker(:brave, name, opts),
    do: BraveWorker.new(Keyword.put(opts, :name, name))

  defp create_worker(:pubmed, name, opts),
    do: PubMedWorker.new(Keyword.put(opts, :name, name))

  defp create_worker(:duckduckgo, name, opts),
    do: DuckDuckGoWorker.new(Keyword.put(opts, :name, name))

  defp create_worker(_, _name, _opts), do: {:error, :unsupported_worker_type}

  @doc """
  Remueve un worker del registry.
  """
  def remove_worker(supervisor \\ __MODULE__, name) do
    registry_name = get_registry_name(supervisor)
    Registry.unregister(registry_name, name)
  end

  @doc """
  Obtiene información de todos los workers.
  """
  def list_workers(supervisor \\ __MODULE__) do
    registry_name = get_registry_name(supervisor)
    Registry.list_all(registry_name)
  end

  @doc """
  Configura workers iniciales. Llamado de forma asíncrona por el Pool.
  """
  def configure_initial_workers(registry_name) do
    configure_workers(registry_name)
  end

  # Private Functions

  defp configure_workers(registry_name) do
    # Configurar workers desde variables de entorno
    workers_to_register =
      []
      # LLM Workers
      |> maybe_add_openai_worker()
      |> maybe_add_anthropic_worker()
      |> maybe_add_xai_worker()
      |> maybe_add_groq_worker()
      |> maybe_add_gemini_pro_25_worker()
      |> maybe_add_gemini_worker()
      |> maybe_add_cohere_worker()
      |> maybe_add_ollama_worker()
      # Embeddings Workers
      |> maybe_add_openai_embeddings_worker()
      # Search Workers
      |> maybe_add_serper_worker()
      |> maybe_add_brave_worker()
      |> maybe_add_pubmed_worker()
      |> maybe_add_tavily_worker()
      |> maybe_add_duckduckgo_worker()

    # Registrar todos los workers configurados
    Enum.each(workers_to_register, fn {name, worker} ->
      case Registry.register(registry_name, name, worker) do
        :ok ->
          Logger.info("Worker registrado: #{name}")

        {:error, :already_registered} ->
          Logger.warning("Worker ya existe: #{name}")

        error ->
          Logger.error("Error registrando worker #{name}: #{inspect(error)}")
      end
    end)

    # Mostrar resumen de workers configurados
    if Enum.empty?(workers_to_register) do
      Logger.warning("No se encontraron API keys válidos. Revisa tu archivo .env")
    else
      Logger.info(
        "Configurados #{length(workers_to_register)} workers: #{Enum.map_join(workers_to_register, ", ", &elem(&1, 0))}"
      )
    end
  end

  # Función auxiliar para parsear listas de API keys desde environment
  defp get_env_list(env_var) do
    case System.get_env(env_var) do
      nil ->
        []

      "" ->
        []

      keys_string ->
        keys_string
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp maybe_add_openai_worker(workers) do
    openai_keys = get_env_list("OPENAI_API_KEYS")

    if Enum.empty?(openai_keys) do
      workers
    else
      openai_model = System.get_env("OPENAI_MODEL", "gpt-5")

      worker =
        OpenAIWorker.new(
          name: "openai-primary",
          api_keys: openai_keys,
          model: openai_model,
          timeout: 30_000
        )

      [{"openai-primary", worker} | workers]
    end
  end

  defp maybe_add_anthropic_worker(workers) do
    anthropic_keys = get_env_list("ANTHROPIC_API_KEYS")

    if Enum.empty?(anthropic_keys) do
      workers
    else
      anthropic_model = System.get_env("ANTHROPIC_MODEL", "claude-sonnet-4-20250514")

      worker =
        AnthropicWorker.new(
          name: "anthropic-primary",
          api_keys: anthropic_keys,
          model: anthropic_model,
          timeout: 60_000
        )

      [{"anthropic-primary", worker} | workers]
    end
  end

  defp maybe_add_xai_worker(workers) do
    xai_keys = get_env_list("XAI_API_KEYS")

    if Enum.empty?(xai_keys) do
      workers
    else
      xai_model = System.get_env("XAI_MODEL", "grok-code-fast-1")

      worker =
        XAIWorker.new(
          name: "xai-primary",
          api_keys: xai_keys,
          model: xai_model,
          timeout: 30_000
        )

      [{"xai-primary", worker} | workers]
    end
  end

  defp maybe_add_gemini_pro_25_worker(workers) do
    gemini_pro_25_keys = get_env_list("GEMINI_PRO_25_API_KEYS")

    if Enum.empty?(gemini_pro_25_keys) do
      workers
    else
      gemini_pro_25_model = System.get_env("GEMINI_PRO_25_MODEL", "gemini-3-flash-preview")

      worker =
        GeminiWorker.new(
          name: "gemini-pro-25-primary",
          api_keys: gemini_pro_25_keys,
          model: gemini_pro_25_model,
          timeout: 60_000
        )

      [{"gemini-pro-25-primary", worker} | workers]
    end
  end

  defp maybe_add_groq_worker(workers) do
    groq_keys = get_env_list("GROQ_API_KEYS")

    if Enum.empty?(groq_keys) do
      workers
    else
      groq_model = System.get_env("GROQ_MODEL", "llama-3.1-8b-instant")
      Logger.info("Configurando Groq worker con modelo: #{groq_model}")

      worker =
        GroqWorker.new(
          name: "groq-primary",
          api_keys: groq_keys,
          default_model: groq_model,
          timeout: 30_000
        )

      [{"groq-primary", worker} | workers]
    end
  end

  defp maybe_add_gemini_worker(workers) do
    gemini_keys = get_env_list("GEMINI_API_KEYS")

    if Enum.empty?(gemini_keys) do
      workers
    else
      gemini_model = System.get_env("GEMINI_MODEL", "gemini-3-flash-preview")

      worker =
        GeminiWorker.new(
          name: "gemini-primary",
          api_keys: gemini_keys,
          model: gemini_model,
          timeout: 30_000
        )

      [{"gemini-primary", worker} | workers]
    end
  end

  defp maybe_add_cohere_worker(workers) do
    cohere_keys = get_env_list("COHERE_API_KEYS")

    if Enum.empty?(cohere_keys) do
      workers
    else
      cohere_model = System.get_env("COHERE_MODEL", "command-light")

      worker =
        CohereWorker.new(
          name: "cohere-primary",
          api_keys: cohere_keys,
          model: cohere_model,
          timeout: 30_000
        )

      [{"cohere-primary", worker} | workers]
    end
  end

  defp maybe_add_ollama_worker(workers) do
    # Ollama siempre está disponible como local fallback
    ollama_url = System.get_env("OLLAMA_BASE_URL", "http://localhost:11434")
    ollama_model = System.get_env("OLLAMA_MODEL", "gemma3:4b")

    # Verificar si Ollama está corriendo
    case check_ollama_availability(ollama_url) do
      true ->
        worker =
          OllamaWorker.new(
            name: "ollama-local",
            base_url: ollama_url,
            models: [ollama_model],
            # Ollama puede ser más lento
            timeout: 60_000
          )

        [{"ollama-local", worker} | workers]

      false ->
        Logger.warning("Ollama no disponible en #{ollama_url}")
        workers
    end
  end

  defp check_ollama_availability(base_url) do
    case Req.get(base_url <> "/api/tags", receive_timeout: 2000, retry: false) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp maybe_add_openai_embeddings_worker(workers) do
    embeddings_keys = get_env_list("OPENAI_EMBEDDINGS_API_KEYS")

    if Enum.empty?(embeddings_keys) do
      workers
    else
      embeddings_model =
        System.get_env("OPENAI_EMBEDDINGS_DEFAULT_MODEL", "text-embedding-3-small")

      embeddings_timeout =
        System.get_env("OPENAI_EMBEDDINGS_TIMEOUT", "30000") |> String.to_integer()

      worker =
        OpenAIEmbeddingsWorker.new(
          name: "openai-embeddings-primary",
          api_keys: embeddings_keys,
          default_model: embeddings_model,
          timeout: embeddings_timeout
        )

      [{"openai-embeddings-primary", worker} | workers]
    end
  end

  defp maybe_add_tavily_worker(workers) do
    tavily_keys = get_env_list("TAVILY_API_KEY")

    if Enum.empty?(tavily_keys) do
      workers
    else
      worker =
        TavilyWorker.new(
          name: "tavily-primary",
          api_keys: tavily_keys,
          timeout: 30_000
        )

      [{"tavily-primary", worker} | workers]
    end
  end

  defp maybe_add_serper_worker(workers) do
    serper_keys = get_env_list("SERPER_API_KEY")

    if Enum.empty?(serper_keys) do
      workers
    else
      worker =
        SerperWorker.new(
          name: "serper-primary",
          api_keys: serper_keys,
          timeout: 30_000
        )

      [{"serper-primary", worker} | workers]
    end
  end

  defp maybe_add_brave_worker(workers) do
    brave_keys = get_env_list("BRAVE_API_KEY")

    if Enum.empty?(brave_keys) do
      workers
    else
      worker =
        BraveWorker.new(
          name: "brave-primary",
          api_keys: brave_keys,
          timeout: 30_000
        )

      [{"brave-primary", worker} | workers]
    end
  end

  defp maybe_add_pubmed_worker(workers) do
    # PubMed no requiere API key (NCBI E-utilities es gratuito)
    # Opcional: agregar email para mejor rate limiting
    pubmed_email = System.get_env("PUBMED_EMAIL")

    worker =
      PubMedWorker.new(
        name: "pubmed-primary",
        email: pubmed_email,
        timeout: 30_000
      )

    [{"pubmed-primary", worker} | workers]
  end

  defp maybe_add_duckduckgo_worker(workers) do
    # DuckDuckGo no requiere API key
    worker =
      DuckDuckGoWorker.new(
        name: "duckduckgo-primary",
        timeout: 30_000
      )

    [{"duckduckgo-primary", worker} | workers]
  end

  defp get_registry_name(_supervisor) do
    # Por ahora retornamos el nombre por defecto
    # En el futuro podríamos inspeccionar el supervisor para obtener el registry real
    CortexCore.Workers.Registry
  end
end
