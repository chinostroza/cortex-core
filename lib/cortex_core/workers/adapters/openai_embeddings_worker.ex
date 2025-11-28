defmodule CortexCore.Workers.Adapters.OpenAIEmbeddingsWorker do
  @moduledoc """
  Worker adapter para OpenAI Embeddings API.

  Características:
  - Modelos: text-embedding-3-small, text-embedding-3-large, text-embedding-ada-002
  - Dimensiones: 1536 (small/ada), 3072 (large)
  - Soporta batch embedding (hasta 2048 inputs)
  - Costo por token tracking
  - Rotación automática de API keys

  ## Pricing (as of 2025)
  - text-embedding-3-small: $0.020 per 1M tokens
  - text-embedding-3-large: $0.130 per 1M tokens
  - text-embedding-ada-002: $0.100 per 1M tokens

  ## Usage

      # Single text
      {:ok, result} = CortexCore.call(:embeddings, %{
        input: "Paris is the capital of France"
      })
      # => {:ok, %{embedding: [0.023, -0.891, ...], dimensions: 1536, ...}}

      # Batch
      {:ok, result} = CortexCore.call(:embeddings, %{
        input: ["First text", "Second text", "Third text"]
      })
      # => {:ok, %{embeddings: [[...], [...], [...]], ...}}
  """

  @behaviour CortexCore.Workers.Worker

  # ============================================
  # Worker Behaviour Implementation
  # ============================================

  @impl true
  def service_type, do: :embeddings

  defstruct [
    :name,
    :api_keys,
    :current_key_index,
    :default_model,
    :timeout,
    :last_rotation,
    :base_url
  ]

  @default_timeout 30_000
  @default_model "text-embedding-3-small"
  @base_url "https://api.openai.com"
  @embeddings_endpoint "/v1/embeddings"
  @max_batch_size 2048

  # Model pricing per 1M tokens in USD
  @pricing %{
    "text-embedding-3-small" => 0.020,
    "text-embedding-3-large" => 0.130,
    "text-embedding-ada-002" => 0.100
  }

  # Model dimensions
  @dimensions %{
    "text-embedding-3-small" => 1536,
    "text-embedding-3-large" => 3072,
    "text-embedding-ada-002" => 1536
  }

  @doc """
  Crea una nueva instancia de OpenAIEmbeddingsWorker.

  ## Options

    - `:name` - Nombre único del worker (required)
    - `:api_keys` - Lista de API keys o string único (required)
    - `:default_model` - Modelo por defecto (default: "text-embedding-3-small")
    - `:timeout` - Timeout en milisegundos (default: 30_000)
    - `:base_url` - URL base de la API (default: "https://api.openai.com")

  ## Examples

      OpenAIEmbeddingsWorker.new(
        name: "openai-embeddings-1",
        api_keys: ["sk-..."],
        default_model: "text-embedding-3-small"
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
      default_model: Keyword.get(opts, :default_model, @default_model),
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      last_rotation: nil,
      base_url: Keyword.get(opts, :base_url, @base_url)
    }
  end

  @impl true
  def health_check(worker, http_client \\ Req) do
    # Realizar un embedding de prueba con texto mínimo
    test_params = %{
      input: "test",
      model: worker.default_model
    }

    case call(worker, test_params, [], http_client) do
      {:ok, _} -> {:ok, :available}
      {:error, :quota_exceeded} -> {:ok, :quota_exceeded}
      {:error, :rate_limited} -> {:ok, :rate_limited}
      {:error, :unauthorized} -> {:ok, :unavailable}
      {:error, _} -> {:ok, :unavailable}
    end
  end

  @impl true
  def call(worker, params, opts \\ [], http_client \\ Req) do
    input = Map.get(params, :input) || Map.get(params, "input")

    if is_nil(input) do
      {:error, :missing_input}
    else
      # Validar batch size si es lista
      if is_list(input) and length(input) > @max_batch_size do
        {:error, :batch_too_large}
      else
        execute_embedding(worker, input, params, opts, http_client)
      end
    end
  end

  @impl true
  def info(worker) do
    %{
      name: worker.name,
      type: :openai_embeddings,
      service_type: :embeddings,
      api_keys_count: length(worker.api_keys),
      current_key_index: worker.current_key_index,
      timeout: worker.timeout,
      last_rotation: worker.last_rotation,
      base_url: worker.base_url,
      default_model: worker.default_model,
      available_models: [
        "text-embedding-3-small",
        "text-embedding-3-large",
        "text-embedding-ada-002"
      ],
      max_batch_size: @max_batch_size,
      pricing: @pricing
    }
  end

  @impl true
  def priority(_worker), do: 10

  # ============================================
  # Public API
  # ============================================

  @doc """
  Rota al siguiente API key disponible.
  """
  def rotate_api_key(worker) do
    new_index = rem(worker.current_key_index + 1, length(worker.api_keys))

    %{worker |
      current_key_index: new_index,
      last_rotation: DateTime.utc_now()
    }
  end

  @doc """
  Obtiene el API key actual.
  """
  def current_api_key(worker) do
    Enum.at(worker.api_keys, worker.current_key_index)
  end

  # ============================================
  # Private Functions
  # ============================================

  defp execute_embedding(worker, input, params, opts, http_client) do
    model = Keyword.get(opts, :model) || Map.get(params, :model) || worker.default_model

    # Build request payload
    payload = %{
      input: input,
      model: model,
      encoding_format: "float"
    }

    # Add optional dimensions parameter (only for 3-small and 3-large)
    payload = if Map.has_key?(params, :dimensions) and model in ["text-embedding-3-small", "text-embedding-3-large"] do
      Map.put(payload, :dimensions, params.dimensions)
    else
      payload
    end

    url = worker.base_url <> @embeddings_endpoint
    headers = build_headers(worker)

    case http_client.post(url,
      json: payload,
      headers: headers,
      receive_timeout: worker.timeout
    ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        parse_success_response(body, model, input)

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: 429, body: body}} ->
        if quota_exceeded?(body) do
          {:error, :quota_exceeded}
        else
          {:error, :rate_limited}
        end

      {:ok, %{status: 400, body: body}} ->
        error_msg = extract_error_message(body)
        if String.contains?(String.downcase(error_msg), "too long") do
          {:error, :input_too_long}
        else
          {:error, {:bad_request, error_msg}}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, extract_error_message(body)}}

      {:error, %{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_success_response(body, model, input) do
    case body do
      %{"data" => data, "usage" => usage} when is_list(data) ->
        embeddings = Enum.map(data, fn item -> item["embedding"] end)

        result = if is_list(input) do
          # Batch response
          %{
            embeddings: embeddings,
            model: model,
            dimensions: get_dimensions(model, List.first(embeddings)),
            usage: %{
              prompt_tokens: usage["prompt_tokens"],
              total_tokens: usage["total_tokens"]
            },
            cost_usd: calculate_cost(model, usage["total_tokens"])
          }
        else
          # Single response
          %{
            embedding: List.first(embeddings),
            model: model,
            dimensions: get_dimensions(model, List.first(embeddings)),
            usage: %{
              prompt_tokens: usage["prompt_tokens"],
              total_tokens: usage["total_tokens"]
            },
            cost_usd: calculate_cost(model, usage["total_tokens"])
          }
        end

        {:ok, result}

      %{"error" => error} ->
        {:error, {:api_error, error["message"] || "Unknown error"}}

      _ ->
        {:error, :invalid_response}
    end
  end

  defp build_headers(worker) do
    api_key = current_api_key(worker)
    [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]
  end

  defp quota_exceeded?(body) when is_binary(body) do
    quota_patterns = [
      "quota",
      "exceeded",
      "billing",
      "current quota"
    ]

    body_lower = String.downcase(body)
    Enum.any?(quota_patterns, fn pattern ->
      String.contains?(body_lower, pattern)
    end)
  end

  defp quota_exceeded?(body) when is_map(body) do
    error_msg = get_in(body, ["error", "message"]) || ""
    quota_exceeded?(error_msg)
  end

  defp quota_exceeded?(_), do: false

  defp extract_error_message(body) when is_binary(body), do: body

  defp extract_error_message(body) when is_map(body) do
    get_in(body, ["error", "message"]) || "Unknown error"
  end

  defp extract_error_message(_), do: "Unknown error"

  defp get_dimensions(model, embedding) do
    # Try to get from known dimensions, otherwise count from actual embedding
    Map.get(@dimensions, model) || length(embedding || [])
  end

  defp calculate_cost(model, tokens) do
    price_per_million = Map.get(@pricing, model, 0.020)
    tokens * price_per_million / 1_000_000
  end
end
