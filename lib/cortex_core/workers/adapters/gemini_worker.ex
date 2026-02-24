defmodule CortexCore.Workers.Adapters.GeminiWorker do
  @moduledoc """
  Worker adapter para Google Gemini API.

  Características:
  - Soporte para múltiples API keys con rotación automática
  - Modelos: gemini-2.0-flash-001, gemini-1.5-pro, gemini-1.5-flash
  - Rate limits: 5 RPM / 25 RPD en free tier
  - Streaming via Server-Sent Events
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
    :last_rotation
  ]

  @default_timeout 60_000
  @default_model "gemini-3-flash-preview"
  @base_url "https://generativelanguage.googleapis.com"

  @doc """
  Crea una nueva instancia de GeminiWorker.

  Options:
    - :name - Nombre identificador del worker
    - :api_keys - Lista de API keys para rotación
    - :default_model - Modelo por defecto a usar
    - :timeout - Timeout para peticiones en ms
  """
  def new(opts) do
    api_keys =
      case Keyword.get(opts, :api_keys) do
        keys when is_list(keys) and keys != [] -> keys
        single_key when is_binary(single_key) -> [single_key]
        _ -> raise ArgumentError, "api_keys debe ser una lista no vacía o string"
      end

    # Aceptar tanto :model como :default_model para compatibilidad
    model = Keyword.get(opts, :model) || Keyword.get(opts, :default_model, @default_model)

    %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      api_keys: api_keys,
      current_key_index: 0,
      default_model: model,
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      last_rotation: nil
    }
  end

  @impl true
  def health_check(worker) do
    APIWorkerBase.health_check(worker)
  end

  @impl true
  def stream_completion(worker, messages, opts) do
    # Por ahora solo usar el worker tal cual, el logging se hace en build_headers
    APIWorkerBase.stream_completion(worker, messages, opts)
  end

  @impl true
  def info(worker) do
    base_info = APIWorkerBase.worker_info(worker, :gemini)

    Map.merge(base_info, %{
      base_url: @base_url,
      default_model: worker.default_model,
      available_models: [
        "gemini-3-flash-preview",
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite"
      ]
    })
  end

  @impl true
  # Prioridad media (después de local, antes de costosos)
  def priority(_worker), do: 30

  # Callbacks para APIWorkerBase

  def provider_config(worker) do
    model = worker.default_model || @default_model

    %{
      base_url: @base_url,
      stream_endpoint: "/v1beta/models/#{model}:generateContent",
      tools_endpoint: "/v1beta/models/#{model}:generateContent",
      health_endpoint: @base_url <> "/v1beta/models",
      model_param: "model",
      headers_fn: &build_headers/1,
      optional_params: %{
        "generationConfig" => %{
          "candidateCount" => 1,
          "maxOutputTokens" => 2048,
          "temperature" => 0.7
        }
      }
    }
  end

  def transform_messages(messages, _opts) do
    # Gemini usa un formato específico con "contents"
    %{
      "contents" =>
        Enum.map(messages, fn message ->
          # Soportar tanto maps con string keys como atom keys
          role = message[:role] || message["role"]
          content = message[:content] || message["content"]

          %{
            "role" => transform_role(role),
            "parts" => [%{"text" => content}]
          }
        end)
    }
  end

  def extract_content_from_chunk(json_data) do
    case Jason.decode(json_data) do
      {:ok, %{"candidates" => [%{"content" => %{"parts" => [%{"text" => text}]}} | _]}} ->
        text

      {:ok, %{"candidates" => [%{"content" => %{"parts" => parts}} | _]}} ->
        # Manejar múltiples partes
        Enum.map_join(parts, "", fn part -> Map.get(part, "text", "") end)

      _ ->
        ""
    end
  end

  def call_with_tools(worker, messages, tools, opts) do
    APIWorkerBase.call_with_tools(worker, messages, tools, opts)
  end

  def transform_tools(tools) do
    declarations =
      Enum.map(tools, fn %{"function" => f} ->
        %{
          "name" => f["name"],
          "description" => f["description"],
          "parameters" => f["parameters"]
        }
      end)

    %{"tools" => [%{"function_declarations" => declarations}]}
  end

  def extract_tool_calls(body) do
    case body do
      %{"candidates" => [%{"content" => %{"parts" => parts}} | _]} ->
        parts
        |> Enum.filter(&Map.has_key?(&1, "functionCall"))
        |> Enum.map(fn %{"functionCall" => %{"name" => name, "args" => args}} ->
          %{name: name, arguments: args}
        end)

      _ ->
        []
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

    # Log para identificar qué API key se está usando
    total_keys = length(worker.api_keys)

    if total_keys > 1 do
      require Logger
      masked_key = mask_api_key(api_key)

      Logger.info(
        "#{worker.name} usando API key ##{worker.current_key_index + 1}/#{total_keys} (#{masked_key})"
      )
    end

    [
      {"X-goog-api-key", api_key},
      {"accept", "application/json"}
    ]
  end

  # Helper para enmascarar API keys
  defp mask_api_key(nil), do: "no-key"

  defp mask_api_key(key) when is_binary(key) do
    case String.length(key) do
      len when len < 8 ->
        "***"

      _len ->
        prefix = String.slice(key, 0, 6)
        suffix = String.slice(key, -4, 4)
        "#{prefix}...#{suffix}"
    end
  end

  defp mask_api_key(_), do: "invalid-key"

  defp transform_role("user"), do: "user"
  defp transform_role(:user), do: "user"
  defp transform_role("assistant"), do: "model"
  defp transform_role(:assistant), do: "model"
  # Gemini no tiene role system específico
  defp transform_role("system"), do: "user"
  defp transform_role(:system), do: "user"
  defp transform_role(role) when is_atom(role), do: to_string(role)
  defp transform_role(role), do: role
end
