defmodule CortexCore.Workers.Adapters.PubMedWorker do
  @moduledoc """
  Worker para PubMed API (NCBI E-utilities).

  PubMed proporciona acceso gratuito a MEDLINE, la base de datos de literatura
  biomédica y ciencias de la vida. Ideal para investigación científica y médica.

  ## Capabilities
  - Búsqueda en 35+ millones de artículos científicos
  - Acceso a abstracts y metadata
  - Filtros por tipo de estudio (RCT, systematic review, meta-analysis)
  - Filtros por año de publicación
  - Datos de citación y DOI
  - 100% GRATUITO (sin API key requerida)

  ## Configuration

      config :cortex_core,
        workers: [
          {:pubmed, [
            type: :search,
            timeout: 30_000,
            email: "your-email@example.com"  # Opcional pero recomendado
          ]}
        ]

  ## API Guidelines
  - Sin API key: máximo 3 requests/segundo
  - Con API key: máximo 10 requests/segundo (requiere registro NCBI)
  - Se recomienda incluir email en parámetros
  - No hay límite de queries mensuales

  ## Filtros Disponibles
  - publication_type: "review", "systematic review", "meta-analysis", "rct", "clinical trial"
  - year_start/year_end: filtrar por año de publicación
  - max_results: número de resultados (default: 10)
  """

  @behaviour CortexCore.Workers.Worker

  require Logger

  defstruct [
    :name,
    :base_url,
    :timeout,
    :email,
    :tool_name
  ]

  @default_timeout 30_000
  @base_url "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"

  # ============================================
  # Worker Behaviour Implementation
  # ============================================

  @impl true
  def service_type, do: :search

  @impl true
  def call(worker, params, _opts) do
    query = Map.fetch!(params, :query)
    max_results = Map.get(params, :max_results, 10)
    publication_type = Map.get(params, :publication_type)
    year_start = Map.get(params, :year_start)
    year_end = Map.get(params, :year_end)

    execute_search(worker, query, max_results, publication_type, year_start, year_end)
  end

  @impl true
  def health_check(worker) do
    # Simple query to check API availability
    url = "#{worker.base_url}/esearch.fcgi"

    params = [
      db: "pubmed",
      term: "covid",
      retmax: 1,
      retmode: "json"
    ]

    params = if worker.email, do: [{:email, worker.email} | params], else: params

    case Req.get(url, params: params, receive_timeout: 5_000, retry: false) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        # Check if esearchresult exists in response
        if Map.has_key?(body, "esearchresult") do
          {:ok, :available}
        else
          {:error, {:invalid_response, "Unexpected PubMed response format"}}
        end

      {:ok, %{status: 429}} ->
        {:error, {:rate_limited, "PubMed API rate limited"}}

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
      service: :pubmed,
      base_url: worker.base_url,
      timeout: worker.timeout,
      email: worker.email,
      capabilities: [
        "scientific_literature_search",
        "medical_research",
        "peer_reviewed_articles",
        "abstract_retrieval",
        "doi_lookup",
        "citation_data",
        "publication_type_filtering",
        "date_filtering"
      ],
      supported_filters: [
        "publication_type: review, systematic review, meta-analysis, rct, clinical trial",
        "year_start: integer (e.g., 2020)",
        "year_end: integer (e.g., 2024)",
        "max_results: 1-200"
      ],
      database_size: "35+ million citations",
      pricing: "FREE (no API key required)",
      rate_limit: "3 requests/second without API key, 10 with API key"
    }
  end

  @impl true
  # Higher priority than Serper for scientific queries
  def priority(_worker), do: 5

  # ============================================
  # Public API
  # ============================================

  @doc """
  Crea una nueva instancia de PubMedWorker.

  ## Options

    * `:name` - Nombre único del worker (requerido)
    * `:base_url` - URL base de la API (default: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils")
    * `:timeout` - Timeout en ms (default: 30_000)
    * `:email` - Email de contacto (opcional pero recomendado por NCBI)
    * `:tool_name` - Nombre de la aplicación (default: "CortexCore")

  ## Examples

      PubMedWorker.new(
        name: "pubmed-primary",
        email: "research@example.com",
        timeout: 45_000
      )
  """
  def new(opts) do
    %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      base_url: Keyword.get(opts, :base_url, @base_url),
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      email: Keyword.get(opts, :email),
      tool_name: Keyword.get(opts, :tool_name, "CortexCore")
    }
  end

  # ============================================
  # Private Functions
  # ============================================

  defp execute_search(worker, query, max_results, publication_type, year_start, year_end) do
    # Build PubMed query with filters
    pubmed_query = build_pubmed_query(query, publication_type, year_start, year_end)

    Logger.debug("PubMed search: query=#{pubmed_query}, max_results=#{max_results}")

    # Step 1: Search for PMIDs
    case search_pmids(worker, pubmed_query, max_results) do
      {:ok, [_ | _] = pmids} ->
        # Step 2: Fetch article summaries
        case fetch_summaries(worker, pmids) do
          {:ok, articles} ->
            Logger.info("PubMed search successful: #{query} (#{length(articles)} results)")
            {:ok, format_response(articles, query)}

          {:error, reason} ->
            Logger.error("PubMed fetch summaries failed: #{inspect(reason)}")
            {:error, reason}
        end

      {:ok, []} ->
        Logger.info("PubMed search returned no results: #{query}")
        {:ok, format_response([], query)}

      {:error, reason} ->
        Logger.error("PubMed search failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_pubmed_query(query, publication_type, year_start, year_end) do
    filters =
      []
      |> maybe_add_publication_type_filter(publication_type)
      |> maybe_add_date_filter(year_start, year_end)

    if Enum.empty?(filters) do
      query
    else
      query <> " AND " <> Enum.join(filters, " AND ")
    end
  end

  defp maybe_add_publication_type_filter(filters, nil), do: filters

  defp maybe_add_publication_type_filter(filters, publication_type) do
    type_filter = get_publication_type_filter(String.downcase(publication_type))

    if type_filter do
      [publication_type <> " " <> type_filter | filters]
    else
      filters
    end
  end

  defp get_publication_type_filter("review"), do: "[Publication Type]"
  defp get_publication_type_filter("systematic review"), do: "systematic[sb]"
  defp get_publication_type_filter("meta-analysis"), do: "meta-analysis[Publication Type]"
  defp get_publication_type_filter("rct"), do: "randomized controlled trial[Publication Type]"
  defp get_publication_type_filter("clinical trial"), do: "clinical trial[Publication Type]"
  defp get_publication_type_filter(_), do: nil

  defp maybe_add_date_filter(filters, nil, nil), do: filters

  defp maybe_add_date_filter(filters, year_start, year_end) do
    start_year = year_start || 1900
    end_year = year_end || DateTime.utc_now().year
    ["#{start_year}:#{end_year}[pdat]" | filters]
  end

  defp search_pmids(worker, query, max_results) do
    url = "#{worker.base_url}/esearch.fcgi"

    params = [
      db: "pubmed",
      term: query,
      # PubMed max is 200
      retmax: min(max_results, 200),
      retmode: "json",
      sort: "relevance"
    ]

    params = if worker.email, do: [{:email, worker.email} | params], else: params
    params = if worker.tool_name, do: [{:tool, worker.tool_name} | params], else: params

    case Req.get(url, params: params, receive_timeout: worker.timeout, retry: false) do
      {:ok, %{status: 200, body: body}} ->
        parse_search_response(body)

      {:ok, %{status: 429}} ->
        {:error, {:rate_limited, "PubMed API rate limited (max 3 req/sec)"}}

      {:ok, %{status: status}} when status >= 400 ->
        {:error, {:http_error, status}}

      {:error, %{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_search_response(body) when is_map(body) do
    case get_in(body, ["esearchresult", "idlist"]) do
      pmids when is_list(pmids) ->
        {:ok, pmids}

      _ ->
        {:error, {:invalid_response, "Could not extract PMIDs from response"}}
    end
  end

  defp parse_search_response(_), do: {:error, {:invalid_response, "Invalid response format"}}

  defp fetch_summaries(worker, pmids) do
    url = "#{worker.base_url}/esummary.fcgi"

    params = [
      db: "pubmed",
      id: Enum.join(pmids, ","),
      retmode: "json"
    ]

    params = if worker.email, do: [{:email, worker.email} | params], else: params
    params = if worker.tool_name, do: [{:tool, worker.tool_name} | params], else: params

    case Req.get(url, params: params, receive_timeout: worker.timeout, retry: false) do
      {:ok, %{status: 200, body: body}} ->
        parse_summary_response(body)

      {:ok, %{status: 429}} ->
        {:error, {:rate_limited, "PubMed API rate limited"}}

      {:ok, %{status: status}} when status >= 400 ->
        {:error, {:http_error, status}}

      {:error, %{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_summary_response(body) when is_map(body) do
    case get_in(body, ["result"]) do
      result when is_map(result) ->
        uids = Map.get(result, "uids", [])

        articles =
          Enum.map(uids, fn uid ->
            article = Map.get(result, uid, %{})
            parse_article(article)
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, articles}

      _ ->
        {:error, {:invalid_response, "Could not extract articles from response"}}
    end
  end

  defp parse_summary_response(_), do: {:error, {:invalid_response, "Invalid response format"}}

  defp parse_article(article) when is_map(article) do
    # Extract authors
    authors =
      case Map.get(article, "authors") do
        authors_list when is_list(authors_list) ->
          Enum.map_join(authors_list, ", ", fn author ->
            Map.get(author, "name", "")
          end)

        _ ->
          ""
      end

    # Extract publication date
    pub_date = Map.get(article, "pubdate", "")

    # Extract journal
    journal = Map.get(article, "fulljournalname", Map.get(article, "source", ""))

    # Extract DOI from articleids
    doi =
      case Map.get(article, "articleids") do
        ids when is_list(ids) ->
          doi_entry = Enum.find(ids, fn id -> Map.get(id, "idtype") == "doi" end)
          if doi_entry, do: Map.get(doi_entry, "value"), else: nil

        _ ->
          nil
      end

    # Build PubMed URL
    pmid = Map.get(article, "uid")
    pubmed_url = if pmid, do: "https://pubmed.ncbi.nlm.nih.gov/#{pmid}/", else: nil

    %{
      "title" => Map.get(article, "title", ""),
      "url" => pubmed_url,
      "snippet" => extract_snippet(article),
      "authors" => authors,
      "journal" => journal,
      "publication_date" => pub_date,
      "pmid" => pmid,
      "doi" => doi,
      "source" => "PubMed"
    }
  end

  defp parse_article(_), do: nil

  defp extract_snippet(article) do
    # PubMed summaries don't include full abstracts, but we can build a snippet
    title = Map.get(article, "title", "")
    journal = Map.get(article, "fulljournalname", Map.get(article, "source", ""))
    pub_date = Map.get(article, "pubdate", "")

    "#{journal}. #{pub_date}. #{String.slice(title, 0, 150)}"
  end

  defp format_response(articles, query) do
    %{
      results: articles,
      query: query,
      source: "PubMed",
      database_size: "35+ million citations",
      result_type: "peer_reviewed_literature"
    }
  end
end
