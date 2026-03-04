defmodule CortexCore.ModelDiscovery do
  @moduledoc """
  Pure HTTP module for discovering available models from AI providers.

  No state, no Ecto — just HTTP calls that return model lists.
  Used by CortexCommunity.ModelSelector for orchestration and persistence.
  """

  require Logger

  # Curated model lists for providers without discovery endpoints
  @anthropic_models [
    "claude-sonnet-4-20250514",
    "claude-3-5-haiku-20241022",
    "claude-3-opus-20240229"
  ]
  @cohere_models ["command-r-plus", "command-r", "command-light"]
  @xai_models ["grok-code-fast-1", "grok-3-mini-beta", "grok-beta"]

  @doc """
  Discover available models for a given worker.

  Returns `{:ok, [model_id]}` or `{:error, reason}`.

  ## Parameters
  - `provider_type` - atom: :gemini, :groq, :openai, :anthropic, :cohere, :xai
  - `api_key` - binary API key for the provider
  """
  @spec list_models(atom(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_models(:gemini, api_key) do
    url = "https://generativelanguage.googleapis.com/v1beta/models?key=#{api_key}"

    case Req.get(url, receive_timeout: 10_000, retry: false) do
      {:ok, %{status: 200, body: body}} ->
        models =
          body
          |> Map.get("models", [])
          |> Enum.filter(&supports_generate_content?/1)
          |> Enum.map(&Map.get(&1, "name", ""))
          |> Enum.map(&strip_model_prefix/1)
          |> Enum.reject(&skip_gemini_model?/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, models}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def list_models(:groq, api_key) do
    url = "https://api.groq.com/openai/v1/models"

    case Req.get(url,
           headers: [{"authorization", "Bearer #{api_key}"}],
           receive_timeout: 10_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} ->
        models =
          body
          |> Map.get("data", [])
          |> Enum.map(&Map.get(&1, "id", ""))
          |> Enum.filter(&relevant_groq_model?/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, models}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def list_models(:openai, api_key) do
    url = "https://api.openai.com/v1/models"

    case Req.get(url,
           headers: [{"authorization", "Bearer #{api_key}"}],
           receive_timeout: 10_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} ->
        models =
          body
          |> Map.get("data", [])
          |> Enum.map(&Map.get(&1, "id", ""))
          |> Enum.filter(&String.starts_with?(&1, "gpt-"))
          |> Enum.reject(&(&1 == ""))

        {:ok, models}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def list_models(:anthropic, _api_key), do: {:ok, @anthropic_models}
  def list_models(:cohere, _api_key), do: {:ok, @cohere_models}
  def list_models(:xai, _api_key), do: {:ok, @xai_models}

  def list_models(provider, _api_key) do
    Logger.warning("ModelDiscovery: unknown provider #{inspect(provider)}, skipping")
    {:error, :unknown_provider}
  end

  # Private helpers

  defp supports_generate_content?(model) do
    methods = Map.get(model, "supportedGenerationMethods", [])
    "generateContent" in methods
  end

  defp strip_model_prefix("models/" <> rest), do: rest
  defp strip_model_prefix(name), do: name

  defp skip_gemini_model?(name) do
    skip_patterns = ["tts", "image", "robotics", "embedding", "nano-banana", "aqa", "vision"]
    Enum.any?(skip_patterns, &String.contains?(name, &1))
  end

  defp relevant_groq_model?(id) do
    relevant = ["llama", "mixtral", "gemma", "deepseek", "qwen"]
    # Exclude moderation/guard models — not suitable for chat/ranking
    exclude = ["guard", "prompt-guard", "whisper", "distil-whisper"]

    Enum.any?(relevant, &String.contains?(id, &1)) and
      not Enum.any?(exclude, &String.contains?(id, &1))
  end
end
