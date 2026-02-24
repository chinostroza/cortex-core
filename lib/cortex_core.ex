defmodule CortexCore do
  @behaviour CortexCore.Behaviour

  @moduledoc """
  CortexCore - Universal Service Gateway

  A powerful and extensible library for managing multiple external services with
  intelligent failover, API key rotation, and unified interface.

  ## What is the Universal Service Gateway?

  CortexCore evolved from an AI-only gateway to support **any external service**:
  - **LLM Services**: OpenAI, Anthropic, Google Gemini, Groq, Cohere, xAI, Ollama
  - **Search Services**: Tavily, Serper, Brave Search
  - **Audio Services**: ElevenLabs (TTS), Whisper (STT)
  - **Vision Services**: Stability AI, Midjourney
  - **Generic HTTP**: Any REST API

  All services benefit from the same robust infrastructure: failover, health checks,
  API key rotation, and automatic retry logic.

  ## Features

  - **Multi-Service Support**: LLMs, Search, Audio, Vision, HTTP APIs
  - **Intelligent Failover**: Automatic fallback to next available worker
  - **API Key Rotation**: Built-in strategies (round-robin, local-first)
  - **Streaming Support**: SSE and JSON streaming for real-time responses (LLMs)
  - **Health Monitoring**: Automatic health checks and service availability
  - **Extensible**: Easy to add custom services via Worker behaviour

  ## Quick Start

      # Start the supervision tree
      {:ok, _} = CortexCore.start_link()

      # LLM chat completion (streaming)
      {:ok, stream} = CortexCore.chat([
        %{role: "user", content: "Hello, how are you?"}
      ])
      stream |> Enum.each(&IO.write/1)

      # Web search
      {:ok, results} = CortexCore.call(:search, %{
        query: "Elixir programming benefits",
        max_results: 5
      })

      # Text-to-speech
      {:ok, audio} = CortexCore.call(:audio, %{
        text: "Hello world",
        voice: "adam"
      })

  ## Configuration

  Configure services via environment variables:

      # LLM providers
      export OPENAI_API_KEYS=key1,key2,key3
      export ANTHROPIC_API_KEYS=key1,key2
      export GEMINI_API_KEYS=key1,key2

      # Search providers
      export TAVILY_API_KEY=tvly-...

      # Audio providers
      export ELEVENLABS_API_KEY=el-...

      # Pool settings
      export WORKER_POOL_STRATEGY=round_robin  # or: local_first
      export HEALTH_CHECK_INTERVAL=30          # seconds (0 to disable)

  ## Advanced Usage

      # Use specific LLM provider
      CortexCore.chat(messages, provider: :openai)

      # Custom LLM options
      CortexCore.chat(messages,
        model: "gpt-4",
        temperature: 0.7,
        max_tokens: 1000
      )

      # Get all services status
      CortexCore.health_status()

      # Add workers at runtime
      CortexCore.add_worker("tavily-backup",
        type: :tavily,
        api_keys: ["sk-..."]
      )
  """

  alias CortexCore.{Dispatcher, Workers}

  @typedoc "Message format for chat completions"
  @type message :: %{
          required(:role) => String.t(),
          required(:content) => String.t()
        }

  @typedoc "Options for chat completion"
  @type chat_opts :: [
          {:provider, atom()},
          {:model, String.t()},
          {:temperature, float()},
          {:max_tokens, integer()},
          {:stream, boolean()}
        ]

  @typedoc "Provider health status"
  @type health_status :: :available | :busy | :unavailable | :quota_exceeded | :rate_limited

  @doc """
  Starts the CortexCore supervision tree.

  ## Options

    * `:name` - Name for the supervisor (default: CortexCore.Supervisor)
    * `:registry_name` - Name for the worker registry (default: CortexCore.Workers.Registry)
    * `:pool_name` - Name for the worker pool (default: CortexCore.Workers.Pool)
    * `:strategy` - Pool strategy (:local_first, :round_robin, :least_used, :random)
    * `:health_check_interval` - Interval for health checks in ms (default: 30000)

  ## Examples

      # Default configuration
      CortexCore.start_link()

      # Custom configuration
      CortexCore.start_link(
        strategy: :round_robin,
        health_check_interval: 60_000
      )
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Workers.Supervisor.start_link(opts)
  end

  @doc """
  Executes a generic operation on a worker of the specified service type.

  This is the unified API for all service types in the Universal Service Gateway.

  ## Parameters

    * `service_type` - Type of service (:llm, :search, :audio, :vision, :http)
    * `params` - Map with service-specific parameters
    * `opts` - Optional keyword list of options

  ## Examples

      # Web search
      {:ok, results} = CortexCore.call(:search, %{
        query: "Elixir benefits",
        max_results: 5
      })

      # Text-to-speech
      {:ok, audio} = CortexCore.call(:audio, %{
        text: "Hello world",
        voice: "adam"
      })

      # Vision/image generation
      {:ok, image} = CortexCore.call(:vision, %{
        prompt: "A sunset over mountains",
        size: "1024x1024"
      })

  ## Returns

    * `{:ok, result}` - Success with service-specific result
    * `{:error, :no_workers_available}` - No workers available for this service type
    * `{:error, reason}` - Other errors
  """
  @spec call(atom(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def call(service_type, params, opts \\ []) when is_atom(service_type) and is_map(params) do
    Dispatcher.dispatch(service_type, params, opts)
  end

  @doc """
  Alias for `call/3` with more explicit naming.

  Useful when you want to make it clear you're calling a specific service.

  ## Examples

      CortexCore.call_service(:search, %{query: "Elixir"}, [])
  """
  @spec call_service(atom(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  defdelegate call_service(service_type, params, opts \\ []), to: __MODULE__, as: :call

  @doc """
  Sends a chat completion request to the best available provider.

  Returns a stream of response chunks that can be consumed with `Enum` or `Stream`.

  **Note**: This function is maintained for backward compatibility. For new code,
  consider using `call(:llm, %{messages: messages}, opts)` for non-streaming LLM calls.

  ## Parameters

    * `messages` - List of message maps with `:role` and `:content` keys
    * `opts` - Optional keyword list of options

  ## Options

    * `:provider` - Force specific provider (:openai, :anthropic, :gemini, etc.)
    * `:model` - Override default model for the provider
    * `:temperature` - Control randomness (0.0 to 2.0)
    * `:max_tokens` - Maximum tokens in response
    * `:stream` - Enable/disable streaming (default: true)

  ## Examples

      # Simple chat
      {:ok, stream} = CortexCore.chat([
        %{role: "user", content: "What is Elixir?"}
      ])

      # With options
      {:ok, stream} = CortexCore.chat(messages,
        provider: :openai,
        model: "gpt-4",
        temperature: 0.5
      )

      # Process response
      response = stream |> Enum.join("")

  ## Returns

    * `{:ok, stream}` - Success with response stream
    * `{:error, :no_workers_available}` - No providers available
    * `{:error, reason}` - Other errors
  """
  @spec chat(list(message()), chat_opts()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def chat(messages, opts \\ []) when is_list(messages) do
    Dispatcher.dispatch_stream(messages, opts)
  end

  @doc """
  Alias for `chat/2` for backward compatibility.
  """
  @spec stream_completion(list(message()), chat_opts()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  defdelegate stream_completion(messages, opts \\ []), to: __MODULE__, as: :chat

  @doc """
  Calls an AI provider with tool definitions and returns structured tool_calls.

  Requires explicit provider selection. Does not use auto-selection since tool
  use requires providers with explicit support (Gemini, Groq).

  ## Parameters

    * `messages` - List of message maps with `:role` and `:content` keys
    * `tools` - List of tool definitions in OpenAI function calling format
    * `opts` - Options including `:provider` (required), `:model`, `:tool_choice`

  ## Examples

      {:ok, tool_calls} = CortexCore.call_with_tools(
        [%{"role" => "user", "content" => "Extract data from this spec..."}],
        [%{"type" => "function", "function" => %{"name" => "extract", ...}}],
        provider: "gemini-primary"
      )

  ## Returns

    * `{:ok, [%{name: "fn_name", arguments: %{...}}]}` - Success with tool calls
    * `{:error, :no_provider_specified}` - Provider is required for tool use
    * `{:error, {:provider_not_found, name}}` - Provider not registered
    * `{:error, :rate_limited}` - Provider rate limited
    * `{:error, reason}` - Other errors
  """
  @spec call_with_tools(list(message()), list(map()), keyword()) ::
          {:ok, list(map())} | {:error, term()}
  def call_with_tools(messages, tools, opts \\ [])
      when is_list(messages) and is_list(tools) do
    Dispatcher.dispatch_tools(messages, tools, opts)
  end

  @doc """
  Embeds text into a vector representation for semantic search and RAG.

  This is a convenience function that wraps `call(:embeddings, ...)` and
  extracts the embedding vector(s) from the response.

  ## Parameters

    * `text` - String or list of strings to embed
    * `opts` - Optional keyword list of options

  ## Options

    * `:model` - Embedding model to use (default: "text-embedding-3-small")
    * `:provider` - Force specific provider (default: automatic selection)
    * `:dimensions` - Custom dimensions (only for text-embedding-3-small/large)

  ## Examples

      # Single text
      {:ok, vector} = CortexCore.embed("Paris is the capital of France")
      # => {:ok, [0.023, -0.891, ..., 0.445]}  # 1536 floats

      # Batch embedding
      {:ok, vectors} = CortexCore.embed([
        "First document",
        "Second document"
      ])
      # => {:ok, [[0.01, ...], [0.02, ...]]}

      # With custom model
      {:ok, vector} = CortexCore.embed("Hello world",
        model: "text-embedding-3-large"
      )

  ## Returns

    * `{:ok, vector}` - Success with single embedding (list of floats)
    * `{:ok, vectors}` - Success with multiple embeddings (list of lists)
    * `{:error, :no_workers_available}` - No embeddings providers available
    * `{:error, :batch_too_large}` - Batch exceeds 2048 inputs
    * `{:error, :input_too_long}` - Input exceeds 8191 tokens
    * `{:error, reason}` - Other errors

  ## Use Cases

      # 1. Document storage (RAG)
      {:ok, embedding} = CortexCore.embed(document_text)
      Repo.insert(%Embedding{text: document_text, embedding: embedding})

      # 2. Semantic search
      {:ok, query_embedding} = CortexCore.embed(user_query)
      results = Repo.all(from e in Embedding,
        order_by: fragment("embedding <=> ?", ^query_embedding),
        limit: 5
      )
  """
  @spec embed(String.t() | list(String.t()), keyword()) ::
          {:ok, list(float()) | list(list(float()))} | {:error, term()}
  def embed(text, opts \\ []) when is_binary(text) or is_list(text) do
    params = %{
      input: text,
      model: opts[:model] || "text-embedding-3-small"
    }

    # Add optional dimensions parameter
    params =
      if opts[:dimensions] do
        Map.put(params, :dimensions, opts[:dimensions])
      else
        params
      end

    case call(:embeddings, params, opts) do
      {:ok, %{embedding: embedding}} ->
        # Single embedding response
        {:ok, embedding}

      {:ok, %{embeddings: embeddings}} ->
        # Batch embedding response
        {:ok, embeddings}

      error ->
        error
    end
  end

  @doc """
  Gets the current health status of all registered providers.

  Returns a map with provider names as keys and their status as values.

  ## Examples

      CortexCore.health_status()
      # => %{
      #   "openai-primary" => :available,
      #   "anthropic-primary" => :rate_limited,
      #   "gemini-primary" => :available,
      #   "ollama-local" => :unavailable
      # }
  """
  @spec health_status() :: %{String.t() => health_status()}
  def health_status do
    Dispatcher.health_status()
  end

  @doc """
  Forces an immediate health check of all providers.

  This is useful when you want to refresh the status without waiting
  for the next scheduled check.

  ## Examples

      CortexCore.check_health()
      # => :ok
  """
  @spec check_health() :: :ok
  def check_health do
    Dispatcher.check_workers()
  end

  @doc """
  Lists all registered workers with their information.

  ## Examples

      CortexCore.list_workers()
      # => [
      #   %{name: "openai-primary", type: :openai, priority: 20, ...},
      #   %{name: "ollama-local", type: :ollama, priority: 10, ...}
      # ]
  """
  @spec list_workers() :: list(map())
  def list_workers do
    Workers.Supervisor.list_workers()
    |> Enum.map(fn worker ->
      worker.__struct__.info(worker)
    end)
  end

  @doc """
  Adds a new worker at runtime.

  ## Parameters

    * `name` - Unique name for the worker
    * `opts` - Worker configuration options

  ## Options

    * `:type` - Worker type (:openai, :anthropic, :gemini, etc.)
    * `:api_keys` - List of API keys
    * `:model` - Default model to use
    * `:timeout` - Request timeout in ms

  ## Examples

      CortexCore.add_worker("openai-backup",
        type: :openai,
        api_keys: ["sk-..."],
        model: "gpt-3.5-turbo"
      )
  """
  @spec add_worker(String.t(), keyword()) :: :ok | {:error, term()}
  def add_worker(name, opts) do
    Workers.Supervisor.add_worker(name, opts)
  end

  @doc """
  Removes a worker from the registry.

  ## Examples

      CortexCore.remove_worker("openai-backup")
  """
  @spec remove_worker(String.t()) :: :ok
  def remove_worker(name) do
    Workers.Supervisor.remove_worker(name)
  end

  @doc """
  Gets the version of CortexCore.

  ## Examples

      CortexCore.version()
      # => "1.0.0"
  """
  @spec version() :: String.t()
  def version do
    Application.spec(:cortex_core, :vsn) |> to_string()
  end
end
