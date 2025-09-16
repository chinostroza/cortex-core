defmodule CortexCore do
  @moduledoc """
  CortexCore - Multi-Provider AI Gateway Library

  A powerful and extensible library for managing multiple AI providers with
  intelligent failover, API key rotation, and streaming support.

  ## Features

  - **Multi-Provider Support**: OpenAI, Anthropic, Google Gemini, Groq, Cohere, xAI, Ollama
  - **Intelligent Failover**: Automatic fallback to next available provider
  - **API Key Rotation**: Built-in strategies (round-robin, least-used, random)
  - **Streaming Support**: SSE and JSON streaming for real-time responses
  - **Health Monitoring**: Automatic health checks and provider availability
  - **Extensible**: Easy to add custom providers via behaviour

  ## Quick Start

      # Start the supervision tree
      {:ok, _} = CortexCore.start_link()

      # Send a chat completion request
      {:ok, stream} = CortexCore.chat([
        %{role: "user", content: "Hello, how are you?"}
      ])

      # Process the stream
      stream |> Enum.each(&IO.write/1)

  ## Configuration

  Configure providers via environment variables:

      # Required for each provider
      export OPENAI_API_KEYS=key1,key2,key3
      export ANTHROPIC_API_KEYS=key1,key2
      export GEMINI_API_KEYS=key1,key2

      # Optional settings
      export WORKER_POOL_STRATEGY=round_robin  # or: local_first, least_used, random
      export HEALTH_CHECK_INTERVAL=30          # seconds (0 to disable)
      export API_KEY_ROTATION_STRATEGY=round_robin

  ## Advanced Usage

      # Use specific provider
      CortexCore.chat(messages, provider: :openai)

      # Custom options
      CortexCore.chat(messages,
        model: "gpt-4",
        temperature: 0.7,
        max_tokens: 1000
      )

      # Get provider status
      CortexCore.health_status()
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
  Sends a chat completion request to the best available provider.

  Returns a stream of response chunks that can be consumed with `Enum` or `Stream`.

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
      apply(worker.__struct__, :info, [worker])
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
