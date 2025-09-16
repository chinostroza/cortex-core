# Creating Custom Workers

This guide shows how to create your own worker adapters for AI providers not yet supported by Cortex Core.

## Worker Behavior

All workers must implement the `CortexCore.Workers.Worker` behavior:

```elixir
defmodule CortexCore.Workers.Worker do
  @callback health_check(worker :: struct()) :: {:ok, :available | :busy} | {:error, term()}
  @callback stream_completion(worker :: struct(), messages :: list(map()), opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}
  @callback info(worker :: struct()) :: map()
  @callback priority(worker :: struct()) :: integer()
end
```

## Basic Worker Structure

Here's a template for creating a custom worker:

```elixir
defmodule CortexCore.Workers.Adapters.CustomWorker do
  @moduledoc """
  Worker adapter for Custom AI Provider.
  """
  
  @behaviour CortexCore.Workers.Worker
  
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
  @default_model "custom-model-v1"
  @base_url "https://api.customprovider.com"
  
  def new(opts) do
    %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      api_keys: normalize_api_keys(opts),
      current_key_index: 0,
      default_model: Keyword.get(opts, :default_model, @default_model),
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      base_url: Keyword.get(opts, :base_url, @base_url)
    }
  end
  
  @impl true
  def health_check(worker) do
    # Implement health check logic
    case check_api_endpoint(worker) do
      {:ok, _} -> {:ok, :available}
      {:error, reason} -> {:error, reason}
    end
  end
  
  @impl true
  def stream_completion(worker, messages, opts) do
    # Implement streaming logic
    {:ok, create_response_stream(worker, messages, opts)}
  end
  
  @impl true
  def info(worker) do
    %{
      name: worker.name,
      type: :custom,
      status: :available,
      api_keys_count: length(worker.api_keys),
      current_key_index: worker.current_key_index,
      default_model: worker.default_model
    }
  end
  
  @impl true
  def priority(_worker), do: 50  # Middle priority
  
  # Private helper functions...
end
```

## Using APIWorkerBase

For HTTP-based APIs, you can extend `APIWorkerBase` for common functionality:

```elixir
defmodule CortexCore.Workers.Adapters.MyAPIWorker do
  @behaviour CortexCore.Workers.Worker
  
  alias CortexCore.Workers.Adapters.APIWorkerBase
  
  # ... struct definition ...
  
  @impl true
  def health_check(worker) do
    APIWorkerBase.health_check(worker)
  end
  
  @impl true
  def stream_completion(worker, messages, opts) do
    APIWorkerBase.stream_completion(worker, messages, opts)
  end
  
  # Required callbacks for APIWorkerBase
  
  def provider_config(worker) do
    %{
      base_url: worker.base_url,
      stream_endpoint: "/v1/completions",
      health_endpoint: "/v1/health",
      model_param: "model",
      headers_fn: &build_headers/1,
      optional_params: %{
        "temperature" => 0.7,
        "stream" => true
      }
    }
  end
  
  def transform_messages(messages, _opts) do
    # Transform messages to provider's format
    %{"messages" => messages}
  end
  
  def extract_content_from_chunk(json_data) do
    # Extract text from streaming chunks
    case Jason.decode(json_data) do
      {:ok, %{"text" => text}} -> text
      _ -> ""
    end
  end
end
```

## Implementing Streaming

For streaming responses, create a Stream that emits text chunks:

```elixir
defp create_response_stream(worker, messages, opts) do
    Stream.resource(
      # Start function - initialize connection
      fn -> start_streaming(worker, messages, opts) end,
      
      # Next function - get next chunk
      fn
        {:ok, connection} -> 
          case get_next_chunk(connection) do
            {:ok, chunk} -> {[chunk], {:ok, connection}}
            :done -> {:halt, {:ok, connection}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
          
        {:error, reason} -> 
          {:halt, {:error, reason}}
      end,
      
      # After function - cleanup
      fn
        {:ok, connection} -> close_connection(connection)
        {:error, _reason} -> :ok
      end
    )
  end
```

## Handling API Keys

Implement key rotation for rate limiting:

```elixir
def rotate_api_key(worker) do
  new_index = rem(worker.current_key_index + 1, length(worker.api_keys))
  %{worker | current_key_index: new_index, last_rotation: DateTime.utc_now()}
end

def current_api_key(worker) do
  Enum.at(worker.api_keys, worker.current_key_index)
end
```

## Error Handling

Properly handle different error scenarios:

```elixir
def stream_completion(worker, messages, opts) do
  try do
    validate_messages(messages)
    {:ok, do_stream_completion(worker, messages, opts)}
  rescue
    e in ArgumentError -> {:error, {:invalid_input, e.message}}
    e in RuntimeError -> {:error, {:runtime_error, e.message}}
  catch
    :exit, reason -> {:error, {:connection_failed, reason}}
  end
end
```

## Testing Your Worker

Create comprehensive tests:

```elixir
defmodule CortexCore.Workers.Adapters.CustomWorkerTest do
  use ExUnit.Case
  alias CortexCore.Workers.Adapters.CustomWorker
  
  describe "new/1" do
    test "creates worker with required fields" do
      worker = CustomWorker.new([
        name: "test-worker",
        api_keys: ["key1", "key2"]
      ])
      
      assert worker.name == "test-worker"
      assert length(worker.api_keys) == 2
    end
  end
  
  describe "health_check/1" do
    test "returns available when API is accessible" do
      worker = CustomWorker.new(name: "test", api_keys: ["key"])
      assert {:ok, :available} = CustomWorker.health_check(worker)
    end
  end
  
  # More tests...
end
```

## Registering Your Worker

Register your custom worker with the supervisor:

```elixir
# In your application startup or configuration
{:ok, worker} = CortexCore.Workers.Supervisor.add_worker(
  CortexCore.Workers.Supervisor,
  :custom,
  name: "my-custom-worker",
  api_keys: ["key1", "key2"]
)
```

## Best Practices

1. **Timeout Handling**: Always respect the worker's timeout setting
2. **Streaming**: Emit chunks as soon as they arrive, don't buffer
3. **Error Recovery**: Implement graceful degradation
4. **Logging**: Use appropriate log levels for debugging
5. **Testing**: Mock HTTP calls in tests for reliability

## Example: Complete Worker

Here's a complete example implementing a hypothetical "FastAI" provider:

```elixir
defmodule CortexCore.Workers.Adapters.FastAIWorker do
  @moduledoc """
  Worker adapter for FastAI streaming API.
  """
  
  @behaviour CortexCore.Workers.Worker
  alias CortexCore.Workers.Adapters.APIWorkerBase
  
  defstruct [
    :name,
    :api_keys,
    :current_key_index,
    :default_model,
    :timeout,
    :last_rotation,
    :base_url
  ]
  
  @default_timeout 15_000
  @default_model "fast-gpt-turbo"
  @base_url "https://api.fastai.com"
  
  def new(opts) do
    api_keys = case Keyword.get(opts, :api_keys) do
      keys when is_list(keys) and keys != [] -> keys
      key when is_binary(key) -> [key]
      _ -> raise ArgumentError, "api_keys required"
    end
    
    %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      api_keys: api_keys,
      current_key_index: 0,
      default_model: Keyword.get(opts, :default_model, @default_model),
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      base_url: Keyword.get(opts, :base_url, @base_url)
    }
  end
  
  @impl true
  def health_check(worker) do
    APIWorkerBase.health_check(worker)
  end
  
  @impl true
  def stream_completion(worker, messages, opts) do
    APIWorkerBase.stream_completion(worker, messages, opts)
  end
  
  @impl true
  def info(worker) do
    APIWorkerBase.worker_info(worker, :fastai)
    |> Map.merge(%{
      features: ["ultra_fast_streaming", "code_execution"],
      models: ["fast-gpt-turbo", "fast-gpt-mini"]
    })
  end
  
  @impl true
  def priority(_worker), do: 1  # Highest priority due to speed
  
  # APIWorkerBase callbacks
  
  def provider_config(worker) do
    %{
      base_url: worker.base_url,
      stream_endpoint: "/v1/stream",
      health_endpoint: "/v1/status",
      model_param: "model",
      headers_fn: &build_headers/1
    }
  end
  
  def transform_messages(messages, _opts) do
    %{"messages" => messages, "stream" => true}
  end
  
  def extract_content_from_chunk(json_data) do
    case Jason.decode(json_data) do
      {:ok, %{"text" => text}} -> text
      {:ok, %{"delta" => delta}} -> delta
      _ -> ""
    end
  end
  
  defp build_headers(worker) do
    [
      {"Authorization", "Bearer #{current_api_key(worker)}"},
      {"Content-Type", "application/json"},
      {"X-Fast-Mode", "enabled"}
    ]
  end
  
  defp current_api_key(worker) do
    Enum.at(worker.api_keys, worker.current_key_index)
  end
end
```

This worker can now be used like any built-in provider!