defmodule CortexCore.Workers.Adapters.SerperWorker do
  @moduledoc """
  Worker para Serper API (Google Search).

  Serper proporciona acceso a Google Search con una API simple y económica.
  Ideal para obtener resultados de alta calidad de Google sin usar Custom Search API.

  ## Capabilities
  - Web search (Google results)
  - News search
  - Image search
  - Shopping results
  - Places search
  - API key rotation
  - Failover automático

  ## Configuration

      config :cortex_core,
        workers: [
          {:serper, [
            type: :search,
            api_keys: ["..."],
            timeout: 30_000
          ]}
        ]

  ## Pricing
  - Free tier: 2,500 queries
  - Pay-as-you-go: $1.50/1000 queries after free tier
  - Enterprise plans available

  ## Limitations
  - Rate limiting: 100 requests/minute
  - No pagination beyond 100 results
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
  @base_url "https://google.serper.dev"

  # ============================================
  # Worker Behaviour Implementation
  # ============================================

  @impl true
  def service_type, do: :search

  @impl true
  def call(worker, params, _opts) do
    query = Map.fetch!(params, :query)
    num = Map.get(params, :max_results, 10)
    # search, news, images, shopping, places
    search_type = Map.get(params, :search_type, "search")
    location = Map.get(params, :location)
    # Geographic location
    gl = Map.get(params, :gl, "us")
    # Language
    hl = Map.get(params, :hl, "en")

    execute_search(worker, query, num, search_type, location, gl, hl)
  end

  @impl true
  def health_check(worker) do
    api_key = get_current_key(worker)

    headers = [
      {"X-API-KEY", api_key},
      {"Content-Type", "application/json"}
    ]

    # Simple test query
    payload = %{
      "q" => "test",
      "num" => 1
    }

    url = "#{worker.base_url}/search"

    case Req.post(url, headers: headers, json: payload, receive_timeout: 5_000, retry: false) do
      {:ok, %{status: 200}} ->
        {:ok, :available}

      {:ok, %{status: 429}} ->
        {:error, {:rate_limited, "Serper API rate limited"}}

      {:ok, %{status: 403}} ->
        {:error, {:quota_exceeded, "Serper API quota exceeded or invalid key"}}

      {:ok, %{status: 401}} ->
        {:error, {:unauthorized, "Invalid Serper API key"}}

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
      service: :serper,
      api_keys_count: length(worker.api_keys),
      current_key_index: worker.current_key_index,
      base_url: worker.base_url,
      timeout: worker.timeout,
      capabilities: [
        "web_search",
        "news_search",
        "image_search",
        "shopping_search",
        "places_search",
        "google_results"
      ],
      search_types: ["search", "news", "images", "shopping", "places"],
      supported_countries: ["us", "uk", "ca", "au", "de", "fr", "es", "it", "jp", "br"],
      supported_languages: ["en", "es", "fr", "de", "it", "pt", "ja", "zh"],
      pricing: "$1.50/1000 queries (2,500 free queries)"
    }
  end

  @impl true
  # Highest priority (Google results quality)
  def priority(_worker), do: 10

  # ============================================
  # Public API
  # ============================================

  @doc """
  Crea una nueva instancia de SerperWorker.

  ## Options

    * `:name` - Nombre único del worker (requerido)
    * `:api_keys` - Lista de API keys o single key (requerido)
    * `:base_url` - URL base de la API (default: "https://google.serper.dev")
    * `:timeout` - Timeout en ms (default: 30_000)

  ## Examples

      SerperWorker.new(
        name: "serper-primary",
        api_keys: ["..."],
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

  defp execute_search(worker, query, num, search_type, location, gl, hl) do
    api_key = get_current_key(worker)
    headers = [{"X-API-KEY", api_key}, {"Content-Type", "application/json"}]

    payload =
      %{"q" => query, "num" => num, "gl" => gl, "hl" => hl}
      |> maybe_add_location(location)

    url = "#{worker.base_url}/#{search_type}"
    Logger.debug("Serper search: query=#{query}, type=#{search_type}, num=#{num}")

    Req.post(url, headers: headers, json: payload, receive_timeout: worker.timeout, retry: false)
    |> handle_serper_response(query, search_type)
  end

  defp maybe_add_location(payload, nil), do: payload
  defp maybe_add_location(payload, location), do: Map.put(payload, "location", location)

  defp handle_serper_response({:ok, %{status: 200, body: body}}, query, search_type) do
    Logger.info("Serper search successful: #{query}")
    {:ok, parse_response(body, search_type)}
  end

  defp handle_serper_response({:ok, %{status: 429, body: body}}, _query, _search_type) do
    error_msg = extract_error_message(body)
    Logger.warning("Serper rate limited: #{inspect(error_msg)}")
    {:error, {:rate_limited, error_msg}}
  end

  defp handle_serper_response({:ok, %{status: 403, body: body}}, _query, _search_type) do
    error_msg = extract_error_message(body)
    Logger.error("Serper quota exceeded: #{inspect(error_msg)}")
    {:error, {:quota_exceeded, error_msg}}
  end

  defp handle_serper_response({:ok, %{status: 401, body: body}}, _query, _search_type) do
    error_msg = extract_error_message(body)
    Logger.error("Serper unauthorized: #{inspect(error_msg)}")
    {:error, {:unauthorized, error_msg}}
  end

  defp handle_serper_response({:ok, %{status: 400, body: body}}, _query, _search_type) do
    error_msg = extract_error_message(body)
    Logger.error("Serper bad request: #{inspect(error_msg)}")
    {:error, {:bad_request, error_msg}}
  end

  defp handle_serper_response({:ok, %{status: status, body: body}}, _query, _search_type)
       when status >= 400 do
    error_msg = extract_error_message(body)
    Logger.error("Serper HTTP error #{status}: #{inspect(error_msg)}")
    {:error, {:http_error, status, error_msg}}
  end

  defp handle_serper_response({:error, %{reason: :timeout}}, _query, _search_type) do
    Logger.error("Serper request timeout")
    {:error, :timeout}
  end

  defp handle_serper_response({:error, reason}, _query, _search_type) do
    Logger.error("Serper request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp get_current_key(worker) do
    Enum.at(worker.api_keys, worker.current_key_index)
  end

  defp parse_response(body, search_type) when is_map(body) do
    case search_type do
      "search" ->
        parse_web_search(body)

      "news" ->
        parse_news_search(body)

      "images" ->
        parse_image_search(body)

      "shopping" ->
        parse_shopping_search(body)

      "places" ->
        parse_places_search(body)

      _ ->
        parse_web_search(body)
    end
  end

  defp parse_response(body, _), do: body

  defp parse_web_search(body) do
    organic = Map.get(body, "organic", [])

    results =
      Enum.map(organic, fn result ->
        %{
          "title" => Map.get(result, "title"),
          "url" => Map.get(result, "link"),
          "snippet" => Map.get(result, "snippet"),
          "position" => Map.get(result, "position"),
          "date" => Map.get(result, "date")
        }
      end)

    %{
      results: results,
      query: Map.get(body, "searchParameters", %{}) |> Map.get("q"),
      answer_box: Map.get(body, "answerBox"),
      knowledge_graph: Map.get(body, "knowledgeGraph"),
      related_searches: Map.get(body, "relatedSearches", []),
      people_also_ask: Map.get(body, "peopleAlsoAsk", [])
    }
  end

  defp parse_news_search(body) do
    news = Map.get(body, "news", [])

    results =
      Enum.map(news, fn article ->
        %{
          "title" => Map.get(article, "title"),
          "url" => Map.get(article, "link"),
          "snippet" => Map.get(article, "snippet"),
          "source" => Map.get(article, "source"),
          "date" => Map.get(article, "date"),
          "image_url" => Map.get(article, "imageUrl")
        }
      end)

    %{
      results: results,
      query: Map.get(body, "searchParameters", %{}) |> Map.get("q")
    }
  end

  defp parse_image_search(body) do
    images = Map.get(body, "images", [])

    results =
      Enum.map(images, fn image ->
        %{
          "title" => Map.get(image, "title"),
          "url" => Map.get(image, "link"),
          "image_url" => Map.get(image, "imageUrl"),
          "source" => Map.get(image, "source"),
          "position" => Map.get(image, "position")
        }
      end)

    %{
      results: results,
      query: Map.get(body, "searchParameters", %{}) |> Map.get("q")
    }
  end

  defp parse_shopping_search(body) do
    shopping = Map.get(body, "shopping", [])

    results =
      Enum.map(shopping, fn product ->
        %{
          "title" => Map.get(product, "title"),
          "url" => Map.get(product, "link"),
          "price" => Map.get(product, "price"),
          "source" => Map.get(product, "source"),
          "rating" => Map.get(product, "rating"),
          "image_url" => Map.get(product, "imageUrl")
        }
      end)

    %{
      results: results,
      query: Map.get(body, "searchParameters", %{}) |> Map.get("q")
    }
  end

  defp parse_places_search(body) do
    places = Map.get(body, "places", [])

    results =
      Enum.map(places, fn place ->
        %{
          "title" => Map.get(place, "title"),
          "address" => Map.get(place, "address"),
          "rating" => Map.get(place, "rating"),
          "reviews" => Map.get(place, "reviews"),
          "phone" => Map.get(place, "phoneNumber"),
          "website" => Map.get(place, "website"),
          "position" => Map.get(place, "position")
        }
      end)

    %{
      results: results,
      query: Map.get(body, "searchParameters", %{}) |> Map.get("q")
    }
  end

  defp extract_error_message(body) when is_map(body) do
    Map.get(body, "message") ||
      Map.get(body, "error") ||
      Map.get(body, "detail") ||
      "Unknown error"
  end

  defp extract_error_message(body) when is_binary(body), do: body
  defp extract_error_message(_), do: "Unknown error"
end
