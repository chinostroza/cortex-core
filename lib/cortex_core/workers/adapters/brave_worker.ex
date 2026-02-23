defmodule CortexCore.Workers.Adapters.BraveWorker do
  @moduledoc """
  Worker para Brave Search API.

  Brave Search es el motor de búsqueda usado por Anthropic Claude.
  Ofrece resultados de alta calidad con énfasis en privacidad.

  ## Capabilities
  - Web search con resultados de calidad
  - Privacidad mejorada (no tracking)
  - Rate limiting automático
  - API key rotation
  - Failover automático

  ## Configuration

      config :cortex_core,
        workers: [
          {:brave, [
            type: :search,
            api_keys: ["BSA..."],
            timeout: 30_000
          ]}
        ]

  ## Pricing
  - Free tier: 2,000 queries/month
  - Pro: $5/1000 queries after free tier
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
  @base_url "https://api.search.brave.com"

  # ============================================
  # Worker Behaviour Implementation
  # ============================================

  @impl true
  def service_type, do: :search

  @impl true
  def call(worker, params, _opts) do
    query = Map.fetch!(params, :query)
    count = Map.get(params, :max_results, 10)
    search_lang = Map.get(params, :search_lang, "en")
    country = Map.get(params, :country, "US")
    safesearch = Map.get(params, :safesearch, "moderate")
    freshness = Map.get(params, :freshness)

    execute_search(worker, query, count, search_lang, country, safesearch, freshness)
  end

  @impl true
  def health_check(worker) do
    # Brave tiene un endpoint de health check implícito
    # Hacemos una búsqueda mínima para verificar
    api_key = get_current_key(worker)

    headers = [
      {"Accept", "application/json"},
      {"Accept-Encoding", "gzip"},
      {"X-Subscription-Token", api_key}
    ]

    # Test query simple
    url = build_url("test", count: 1)

    case Req.get(url, headers: headers, receive_timeout: 5_000, retry: false) do
      {:ok, %{status: 200}} ->
        {:ok, :available}

      {:ok, %{status: 429}} ->
        {:error, {:rate_limited, "Brave Search API rate limited"}}

      {:ok, %{status: 403}} ->
        {:error, {:quota_exceeded, "Brave Search API quota exceeded or invalid key"}}

      {:ok, %{status: 401}} ->
        {:error, {:unauthorized, "Invalid Brave Search API key"}}

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
      service: :brave,
      api_keys_count: length(worker.api_keys),
      current_key_index: worker.current_key_index,
      base_url: worker.base_url,
      timeout: worker.timeout,
      capabilities: [
        "web_search",
        "news_search",
        "image_search",
        "video_search",
        "privacy_focused"
      ],
      supported_countries: ["US", "GB", "CA", "AU", "DE", "FR", "ES", "IT", "JP"],
      supported_languages: ["en", "es", "fr", "de", "it", "pt", "ja", "zh"],
      freshness_options: ["24h", "week", "month", "year"]
    }
  end

  @impl true
  def priority(_worker), do: 15  # Alta prioridad (mismo que usa Anthropic)

  # ============================================
  # Public API
  # ============================================

  @doc """
  Crea una nueva instancia de BraveWorker.

  ## Options

    * `:name` - Nombre único del worker (requerido)
    * `:api_keys` - Lista de API keys o single key (requerido)
    * `:base_url` - URL base de la API (default: "https://api.search.brave.com")
    * `:timeout` - Timeout en ms (default: 30_000)

  ## Examples

      BraveWorker.new(
        name: "brave-primary",
        api_keys: ["BSA..."],
        timeout: 45_000
      )
  """
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

  defp execute_search(worker, query, count, search_lang, country, safesearch, freshness) do
    api_key = get_current_key(worker)

    headers = [
      {"Accept", "application/json"},
      {"Accept-Encoding", "gzip"},
      {"X-Subscription-Token", api_key}
    ]

    url = build_url(query,
      count: count,
      search_lang: search_lang,
      country: country,
      safesearch: safesearch,
      freshness: freshness
    )

    Logger.debug("Brave search: query=#{query}, count=#{count}")

    case Req.get(url, headers: headers, receive_timeout: worker.timeout, retry: false) do
      {:ok, %{status: 200, body: body}} ->
        Logger.info("Brave search successful: #{query}")
        {:ok, parse_response(body)}

      {:ok, %{status: 429, body: body}} ->
        error_msg = extract_error_message(body)
        Logger.warning("Brave rate limited: #{inspect(error_msg)}")
        {:error, {:rate_limited, error_msg}}

      {:ok, %{status: 403, body: body}} ->
        error_msg = extract_error_message(body)
        Logger.error("Brave quota exceeded: #{inspect(error_msg)}")
        {:error, {:quota_exceeded, error_msg}}

      {:ok, %{status: 401, body: body}} ->
        error_msg = extract_error_message(body)
        Logger.error("Brave unauthorized: #{inspect(error_msg)}")
        {:error, {:unauthorized, error_msg}}

      {:ok, %{status: 400, body: body}} ->
        error_msg = extract_error_message(body)
        Logger.error("Brave bad request: #{inspect(error_msg)}")
        {:error, {:bad_request, error_msg}}

      {:ok, %{status: status, body: body}} when status >= 400 ->
        error_msg = extract_error_message(body)
        Logger.error("Brave HTTP error #{status}: #{inspect(error_msg)}")
        {:error, {:http_error, status, error_msg}}

      {:error, %{reason: :timeout}} ->
        Logger.error("Brave request timeout")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("Brave request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_url(query, opts) do
    params = [{"q", query}]

    params = if opts[:count], do: [{"count", opts[:count]} | params], else: params
    params = if opts[:search_lang], do: [{"search_lang", opts[:search_lang]} | params], else: params
    params = if opts[:country], do: [{"country", opts[:country]} | params], else: params
    params = if opts[:safesearch], do: [{"safesearch", opts[:safesearch]} | params], else: params
    params = if opts[:freshness], do: [{"freshness", opts[:freshness]} | params], else: params

    query_string = URI.encode_query(params)
    "#{@base_url}/res/v1/web/search?#{query_string}"
  end

  defp get_current_key(worker) do
    Enum.at(worker.api_keys, worker.current_key_index)
  end

  defp parse_response(body) when is_map(body) do
    # Normalizar respuesta de Brave a formato unificado
    web_results = Map.get(body, "web", %{})
    results = Map.get(web_results, "results", [])

    %{
      results: Enum.map(results, fn result ->
        %{
          "title" => Map.get(result, "title"),
          "url" => Map.get(result, "url"),
          "snippet" => Map.get(result, "description"),
          "age" => Map.get(result, "age"),
          "language" => Map.get(result, "language")
        }
      end),
      query: Map.get(body, "query", %{}) |> Map.get("original"),
      total_results: get_in(web_results, ["results_count"]),
      news: Map.get(body, "news", %{}) |> Map.get("results", []),
      videos: Map.get(body, "videos", %{}) |> Map.get("results", [])
    }
  end

  defp parse_response(body), do: body

  defp extract_error_message(body) when is_map(body) do
    Map.get(body, "message") ||
    Map.get(body, "error") ||
    Map.get(body, "detail") ||
    "Unknown error"
  end

  defp extract_error_message(body) when is_binary(body), do: body
  defp extract_error_message(_), do: "Unknown error"
end
