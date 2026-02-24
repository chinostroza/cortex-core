defmodule CortexCore.Workers.Adapters.DuckDuckGoWorker do
  @moduledoc """
  Worker para DuckDuckGo Instant Answer API.

  DuckDuckGo ofrece una API gratuita sin necesidad de API key,
  ideal como fallback cuando otros servicios de búsqueda fallan.

  ## Capabilities
  - Web search gratuito (sin API key)
  - Instant Answers
  - Related topics
  - Privacidad mejorada (no tracking)
  - Failover automático

  ## Configuration

      config :cortex_core,
        workers: [
          {:duckduckgo, [
            type: :search,
            timeout: 30_000
          ]}
        ]

  ## Limitations
  - Resultados limitados comparados con servicios de pago
  - Sin soporte para paginación avanzada
  - Rate limiting no documentado (se recomienda usar con moderación)

  ## Pricing
  - Completamente gratuito
  - Sin API key requerida
  """

  @behaviour CortexCore.Workers.Worker

  require Logger

  defstruct [
    :name,
    :base_url,
    :timeout
  ]

  @default_timeout 30_000
  @base_url "https://api.duckduckgo.com"

  # ============================================
  # Worker Behaviour Implementation
  # ============================================

  @impl true
  def service_type, do: :search

  @impl true
  def call(worker, params, _opts) do
    query = Map.fetch!(params, :query)
    max_results = Map.get(params, :max_results, 10)
    no_html = Map.get(params, :no_html, true)
    skip_disambig = Map.get(params, :skip_disambig, true)

    execute_search(worker, query, max_results, no_html, skip_disambig)
  end

  @impl true
  def health_check(worker) do
    # DuckDuckGo no requiere autenticación, solo verificamos conectividad
    url = "#{worker.base_url}/?q=test&format=json&no_html=1&skip_disambig=1"

    case Req.get(url, receive_timeout: 5_000, retry: false) do
      {:ok, %{status: 200}} ->
        {:ok, :available}

      {:ok, %{status: 429}} ->
        {:error, {:rate_limited, "DuckDuckGo rate limited"}}

      {:ok, %{status: 503}} ->
        {:error, {:unavailable, "DuckDuckGo service unavailable"}}

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
      service: :duckduckgo,
      api_keys_count: 0,  # No requiere API key
      base_url: worker.base_url,
      timeout: worker.timeout,
      capabilities: [
        "web_search",
        "instant_answers",
        "related_topics",
        "privacy_focused",
        "free_tier"
      ],
      pricing: "Free (no API key required)",
      limitations: [
        "Limited results compared to paid services",
        "No pagination support",
        "Undocumented rate limits"
      ]
    }
  end

  @impl true
  def priority(_worker), do: 30  # Prioridad baja (fallback gratuito)

  # ============================================
  # Public API
  # ============================================

  @doc """
  Crea una nueva instancia de DuckDuckGoWorker.

  ## Options

    * `:name` - Nombre único del worker (requerido)
    * `:base_url` - URL base de la API (default: "https://api.duckduckgo.com")
    * `:timeout` - Timeout en ms (default: 30_000)

  ## Examples

      DuckDuckGoWorker.new(
        name: "duckduckgo-fallback",
        timeout: 45_000
      )
  """
  def new(opts) do
    %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      base_url: Keyword.get(opts, :base_url, @base_url),
      timeout: Keyword.get(opts, :timeout, @default_timeout)
    }
  end

  # ============================================
  # Private Functions
  # ============================================

  defp execute_search(worker, query, max_results, no_html, skip_disambig) do
    url = build_url(query, no_html, skip_disambig)

    Logger.debug("DuckDuckGo search: query=#{query}")

    case Req.get(url, receive_timeout: worker.timeout, retry: false) do
      {:ok, %{status: 200, body: body}} ->
        Logger.info("DuckDuckGo search successful: #{query}")
        {:ok, parse_response(body, max_results)}

      {:ok, %{status: 429}} ->
        Logger.warning("DuckDuckGo rate limited")
        {:error, {:rate_limited, "Rate limit exceeded - please retry later"}}

      {:ok, %{status: 503, body: body}} ->
        error_msg = extract_error_message(body)
        Logger.error("DuckDuckGo service unavailable: #{inspect(error_msg)}")
        {:error, {:unavailable, error_msg}}

      {:ok, %{status: status, body: body}} when status >= 400 ->
        error_msg = extract_error_message(body)
        Logger.error("DuckDuckGo HTTP error #{status}: #{inspect(error_msg)}")
        {:error, {:http_error, status, error_msg}}

      {:error, %{reason: :timeout}} ->
        Logger.error("DuckDuckGo request timeout")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("DuckDuckGo request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_url(query, no_html, skip_disambig) do
    params = [
      {"q", query},
      {"format", "json"},
      {"no_html", if(no_html, do: "1", else: "0")},
      {"skip_disambig", if(skip_disambig, do: "1", else: "0")}
    ]

    query_string = URI.encode_query(params)
    "#{@base_url}/?#{query_string}"
  end

  defp parse_response(body, max_results) when is_map(body) do
    # Extraer Instant Answer si existe
    abstract_text = Map.get(body, "AbstractText", "")
    abstract_source = Map.get(body, "AbstractSource")
    abstract_url = Map.get(body, "AbstractURL")

    # Extraer Related Topics
    related_topics = Map.get(body, "RelatedTopics", [])

    results = extract_results(related_topics, max_results)

    # Agregar abstract como primer resultado si existe
    results = if abstract_text != "" do
      [%{
        "title" => abstract_source || "Instant Answer",
        "url" => abstract_url,
        "snippet" => abstract_text,
        "type" => "instant_answer"
      } | results]
    else
      results
    end

    %{
      results: Enum.take(results, max_results),
      query: Map.get(body, "Query"),
      answer_type: Map.get(body, "AnswerType"),
      instant_answer: if(abstract_text != "", do: abstract_text, else: nil),
      heading: Map.get(body, "Heading"),
      image: Map.get(body, "Image"),
      definition: Map.get(body, "Definition")
    }
  end

  defp parse_response(body, max_results) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> parse_response(parsed, max_results)
      {:error, _} -> %{results: [], error: "Failed to parse response"}
    end
  end

  defp parse_response(_, _), do: %{results: []}

  defp extract_results(topics, _max_results) when is_list(topics) do
    topics
    |> Enum.flat_map(fn topic ->
      case topic do
        # Topic con subtopics anidados
        %{"Topics" => subtopics} when is_list(subtopics) ->
          Enum.map(subtopics, &parse_topic/1)

        # Topic simple
        topic when is_map(topic) ->
          [parse_topic(topic)]

        _ ->
          []
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_results(_, _), do: []

  defp parse_topic(%{"Text" => text, "FirstURL" => url} = topic) do
    # Extraer título del texto (antes del primer " - ")
    title = case String.split(text, " - ", parts: 2) do
      [t, _] -> t
      _ -> String.slice(text, 0, 100)
    end

    %{
      "title" => title,
      "url" => url,
      "snippet" => text,
      "icon_url" => Map.get(topic, "Icon", %{}) |> Map.get("URL"),
      "type" => "related_topic"
    }
  end

  defp parse_topic(_), do: nil

  defp extract_error_message(body) when is_map(body) do
    Map.get(body, "message") ||
    Map.get(body, "error") ||
    "Unknown error"
  end

  defp extract_error_message(body) when is_binary(body) do
    if String.contains?(body, "<!DOCTYPE") or String.contains?(body, "<html") do
      "Service unavailable (HTML response)"
    else
      body
    end
  end

  defp extract_error_message(_), do: "Unknown error"
end
