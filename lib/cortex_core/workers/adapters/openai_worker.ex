defmodule CortexCore.Workers.Adapters.OpenAIWorker do
  @moduledoc """
  Worker adapter para OpenAI GPT models.

  Características:
  - Modelos: gpt-5, gpt-5-mini, gpt-5-nano, gpt-4, gpt-3.5-turbo
  - Context: 400K tokens (GPT-5), 128K tokens (GPT-4)
  - Especializado en coding y agentic tasks
  - API estándar de referencia
  """

  @behaviour CortexCore.Workers.Worker

  alias CortexCore.Workers.Adapters.APIWorkerBase

  # ============================================
  # Worker Behaviour Implementation
  # ============================================

  @impl true
  def service_type, do: :llm

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
  @default_model "gpt-5"
  @base_url "https://api.openai.com"
  @stream_endpoint "/v1/chat/completions"

  @doc """
  Crea una nueva instancia de OpenAIWorker.
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
      default_model: Keyword.get(opts, :default_model, @default_model),
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      last_rotation: nil,
      base_url: Keyword.get(opts, :base_url, @base_url)
    }
  end

  @impl true
  def health_check(worker, http_client \\ Req) do
    APIWorkerBase.health_check(worker, http_client)
  end

  @impl true
  def stream_completion(worker, messages, opts) do
    APIWorkerBase.stream_completion(worker, messages, opts)
  end

  @impl true
  def info(worker) do
    base_info = APIWorkerBase.worker_info(worker, :openai)

    Map.merge(base_info, %{
      base_url: worker.base_url,
      default_model: worker.default_model,
      available_models: [
        "gpt-5",
        "gpt-5-mini",
        "gpt-5-nano",
        "gpt-4",
        "gpt-4-turbo",
        "gpt-3.5-turbo"
      ]
    })
  end

  @impl true
  # Máxima prioridad (después de local)
  def priority(_worker), do: 5

  # Callbacks para APIWorkerBase

  def provider_config(worker) do
    %{
      base_url: worker.base_url,
      stream_endpoint: @stream_endpoint,
      health_endpoint: worker.base_url <> "/v1/models",
      model_param: "model",
      headers_fn: &build_headers/1,
      optional_params: %{
        "stream" => true,
        "temperature" => 0.7
      }
    }
  end

  def transform_messages(messages, _opts) do
    # OpenAI usa su propio formato estándar
    %{
      "messages" => messages
    }
  end

  def extract_content_from_chunk(json_data) do
    case Jason.decode(json_data) do
      {:ok, %{"choices" => [%{"delta" => %{"content" => content}} | _]}} ->
        content

      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}} ->
        content

      # Manejar respuestas de reasoning
      {:ok,
       %{"choices" => [%{"delta" => %{"reasoning" => _reasoning, "content" => content}} | _]}} ->
        content

      _ ->
        ""
    end
  end

  @doc """
  Rota al siguiente API key disponible.
  """
  def rotate_api_key(worker) do
    new_index = rem(worker.current_key_index + 1, length(worker.api_keys))

    %{worker | current_key_index: new_index, last_rotation: DateTime.utc_now()}
  end

  @doc """
  Obtiene el API key actual.
  """
  def current_api_key(worker) do
    Enum.at(worker.api_keys, worker.current_key_index)
  end

  # Funciones privadas

  defp build_headers(worker) do
    api_key = current_api_key(worker)

    [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]
  end
end
