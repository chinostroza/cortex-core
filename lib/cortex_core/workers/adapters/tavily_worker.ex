defmodule CortexCore.Workers.Adapters.TavilyWorker do
  @moduledoc """
  Worker para Tavily Search API.

  Tavily es un motor de búsqueda optimizado para AI agents, proporcionando
  resultados relevantes y estructurados.

  ## Capabilities
  - Web search con resultados relevantes
  - Rate limiting automático
  - API key rotation
  - Failover automático

  ## Configuration

      config :cortex_core,
        workers: [
          {:tavily, [
            type: :search,
            api_keys: ["sk-..."],
            timeout: 30_000
          ]}
        ]
  """

  @behaviour CortexCore.Workers.Worker

  require Logger

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
    include_answer = Map.get(params, :include_answer, true)

    execute_search(worker, query, max_results, search_depth, include_answer, opts)
  end

  @impl true
  def health_check(worker) do
    # Simple ping to check if API is accessible
    # Tavily no tiene endpoint de health, usamos search con timeout corto
    api_key = get_current_key(worker)

    # Test search mínimo
    test_payload = %{
      api_key: api_key,
      query: "test",
      max_results: 1
    }

    headers = [
      {"Content-Type", "application/json"},
      {"api-key", api_key}
    ]

    case Req.post(
           worker.base_url <> "/search",
           json: test_payload,
           headers: headers,
           receive_timeout: 5_000,
           retry: false
         ) do
      {:ok, %{status: 200}} ->
        {:ok, :available}

      {:ok, %{status: 429}} ->
        {:error, {:rate_limited, "Tavily API rate limited"}}

      {:ok, %{status: 403}} ->
        {:error, {:quota_exceeded, "Tavily API quota exceeded or invalid key"}}

      {:ok, %{status: 401}} ->
        {:error, {:unauthorized, "Invalid Tavily API key"}}

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
        "news_search",
        "answer_generation"
      ],
      search_depths: ["basic", "advanced"]
    }
  end

  @impl true
  # Prioridad media (después de local, antes de LLMs caros)
  def priority(_worker), do: 20

  # ============================================
  # Public API
  # ============================================

  @doc """
  Crea una nueva instancia de TavilyWorker.

  ## Options

    * `:name` - Nombre único del worker (requerido)
    * `:api_keys` - Lista de API keys o single key (requerido)
    * `:base_url` - URL base de la API (default: "https://api.tavily.com")
    * `:timeout` - Timeout en ms (default: 30_000)

  ## Examples

      TavilyWorker.new(
        name: "tavily-primary",
        api_keys: ["sk-..."],
        timeout: 45_000
      )
  """
  def new(opts) do
    api_keys =
      case Keyword.get(opts, :api_keys) do
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

  defp execute_search(worker, query, max_results, search_depth, include_answer, opts) do
    api_key = get_current_key(worker)

    # Construir payload según docs de Tavily
    payload = %{
      api_key: api_key,
      query: query,
      max_results: max_results,
      search_depth: search_depth,
      include_answer: include_answer,
      include_raw_content: Keyword.get(opts, :include_raw_content, false),
      include_images: Keyword.get(opts, :include_images, false)
    }

    headers = [
      {"Content-Type", "application/json"},
      {"api-key", api_key}
    ]

    Logger.debug("Tavily search: query=#{query}, max_results=#{max_results}")

    case Req.post(
           worker.base_url <> "/search",
           json: payload,
           headers: headers,
           receive_timeout: worker.timeout,
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} ->
        Logger.info("Tavily search successful: #{query}")
        {:ok, parse_response(body)}

      {:ok, %{status: 429, body: body}} ->
        # Rate limited - podría rotarse key aquí en el futuro
        error_msg = extract_error_message(body)
        Logger.warning("Tavily rate limited: #{inspect(error_msg)}")
        {:error, {:rate_limited, error_msg}}

      {:ok, %{status: 403, body: body}} ->
        error_msg = extract_error_message(body)
        Logger.error("Tavily quota exceeded: #{inspect(error_msg)}")
        {:error, {:quota_exceeded, error_msg}}

      {:ok, %{status: 401, body: body}} ->
        error_msg = extract_error_message(body)
        Logger.error("Tavily unauthorized: #{inspect(error_msg)}")
        {:error, {:unauthorized, error_msg}}

      {:ok, %{status: 400, body: body}} ->
        error_msg = extract_error_message(body)
        Logger.error("Tavily bad request: #{inspect(error_msg)}")
        {:error, {:bad_request, error_msg}}

      {:ok, %{status: status, body: body}} when status >= 400 ->
        error_msg = extract_error_message(body)
        Logger.error("Tavily HTTP error #{status}: #{inspect(error_msg)}")
        {:error, {:http_error, status, error_msg}}

      {:error, %{reason: :timeout}} ->
        Logger.error("Tavily request timeout")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("Tavily request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_current_key(worker) do
    Enum.at(worker.api_keys, worker.current_key_index)
  end

  defp parse_response(body) when is_map(body) do
    # Normalizar respuesta de Tavily según su formato
    %{
      results: Map.get(body, "results", []),
      answer: Map.get(body, "answer"),
      query: Map.get(body, "query"),
      response_time: Map.get(body, "response_time"),
      images: Map.get(body, "images", [])
    }
  end

  defp parse_response(body), do: body

  defp extract_error_message(body) when is_map(body) do
    # Tavily puede retornar error en diferentes formatos
    Map.get(body, "error") ||
      Map.get(body, "detail") ||
      Map.get(body, "message") ||
      "Unknown error"
  end

  defp extract_error_message(body) when is_binary(body), do: body
  defp extract_error_message(_), do: "Unknown error"
end
