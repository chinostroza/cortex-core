# API Reference

Complete API reference for Cortex Core functions.

## CortexCore

The main module providing the public API.

### Functions

#### chat/1

Sends messages to the AI and returns a streaming response.

```elixir
@spec chat(messages :: list(map())) :: {:ok, Enumerable.t()} | {:error, term()}
```

**Parameters:**
- `messages` - List of message maps with `role` and `content` keys

**Example:**
```elixir
{:ok, stream} = CortexCore.chat([
  %{"role" => "system", "content" => "You are a helpful assistant"},
  %{"role" => "user", "content" => "Hello!"}
])
```

#### chat/2

Sends messages with additional options.

```elixir
@spec chat(messages :: list(map()), opts :: keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
```

**Parameters:**
- `messages` - List of message maps
- `opts` - Keyword list of options:
  - `:model` - Override the default model
  - `:temperature` - Control randomness (0.0 to 2.0)
  - `:max_tokens` - Maximum response length
  - `:worker` - Specific worker to use

**Example:**
```elixir
{:ok, stream} = CortexCore.chat(
  [%{"role" => "user", "content" => "Write a poem"}],
  model: "gpt-4",
  temperature: 1.2,
  max_tokens: 100
)
```

#### health_status/0

Returns the health status of all workers.

```elixir
@spec health_status() :: map()
```

**Returns:**
```elixir
%{
  healthy: ["worker1", "worker2"],
  unhealthy: ["worker3"],
  total: 3
}
```

#### list_workers/0

Lists all registered workers with detailed information.

```elixir
@spec list_workers() :: list(map())
```

**Returns:**
```elixir
[
  %{
    name: "openai-main",
    type: :openai,
    status: :available,
    model: "gpt-4",
    api_keys_count: 3,
    priority: 5
  },
  # ...
]
```

#### version/0

Returns the current version of Cortex Core.

```elixir
@spec version() :: String.t()
```

## CortexCore.Workers.Pool

Manages worker pools and request routing.

### Functions

#### stream_completion/3

Routes a completion request to available workers.

```elixir
@spec stream_completion(pool :: pid(), messages :: list(map()), opts :: keyword()) ::
        {:ok, Enumerable.t()} | {:error, term()}
```

#### health_status/1

Returns health status for the pool.

```elixir
@spec health_status(pool :: pid()) :: map()
```

#### check_health/1

Triggers a health check for all workers.

```elixir
@spec check_health(pool :: pid()) :: :ok
```

## CortexCore.Workers.Registry

Manages worker registration.

### Functions

#### register/3

Registers a new worker.

```elixir
@spec register(registry :: pid(), name :: String.t(), worker :: struct()) ::
        :ok | {:error, :already_registered}
```

#### unregister/2

Unregisters a worker.

```elixir
@spec unregister(registry :: pid(), name :: String.t()) :: :ok
```

#### get/2

Retrieves a worker by name.

```elixir
@spec get(registry :: pid(), name :: String.t()) ::
        {:ok, struct()} | {:error, :not_found}
```

#### list_all/1

Lists all registered workers.

```elixir
@spec list_all(registry :: pid()) :: list(struct())
```

#### list_by_type/2

Lists workers of a specific type.

```elixir
@spec list_by_type(registry :: pid(), type :: atom()) :: list(struct())
```

## CortexCore.Workers.Supervisor

Supervises worker processes.

### Functions

#### add_worker/3

Dynamically adds a new worker.

```elixir
@spec add_worker(supervisor :: pid(), type :: atom(), opts :: keyword()) ::
        {:ok, struct()} | {:error, term()}
```

**Example:**
```elixir
{:ok, worker} = CortexCore.Workers.Supervisor.add_worker(
  CortexCore.Workers.Supervisor,
  :openai,
  name: "new-openai-worker",
  api_keys: ["sk-..."],
  model: "gpt-4"
)
```

#### remove_worker/2

Removes a worker from the supervisor.

```elixir
@spec remove_worker(supervisor :: pid(), name :: String.t()) :: :ok | {:error, term()}
```

#### list_workers/1

Lists all supervised workers.

```elixir
@spec list_workers(supervisor :: pid()) :: list(map())
```

## CortexCore.Workers.APIKeyManager

Manages API key rotation and rate limiting.

### Functions

#### get_next_key/2

Gets the next available API key for a worker.

```elixir
@spec get_next_key(manager :: pid(), worker :: struct()) ::
        {:ok, updated_worker :: struct()} | {:error, :no_available_keys}
```

#### report_rate_limit/2

Reports that a key hit a rate limit.

```elixir
@spec report_rate_limit(manager :: pid(), worker :: struct()) :: :ok
```

#### report_success/2

Reports successful API call.

```elixir
@spec report_success(manager :: pid(), worker :: struct()) :: :ok
```

#### get_stats/1

Returns usage statistics.

```elixir
@spec get_stats(manager :: pid()) :: map()
```

**Returns:**
```elixir
%{
  worker_name: "openai-main",
  rotation_strategy: :round_robin,
  blocked_keys: %{0 => true},
  usage_stats: %{
    0 => %{success_count: 42, error_count: 3},
    1 => %{success_count: 38, error_count: 1}
  }
}
```

## Worker Behavior

All workers implement these callbacks.

### Callbacks

#### health_check/1

```elixir
@callback health_check(worker :: struct()) ::
            {:ok, :available | :busy} | {:error, term()}
```

#### stream_completion/3

```elixir
@callback stream_completion(worker :: struct(), messages :: list(map()), opts :: keyword()) ::
            {:ok, Enumerable.t()} | {:error, term()}
```

#### info/1

```elixir
@callback info(worker :: struct()) :: map()
```

#### priority/1

```elixir
@callback priority(worker :: struct()) :: integer()
```

## Error Types

Common error returns:

- `{:error, :no_workers_available}` - No workers configured
- `{:error, {:all_workers_failed, details}}` - All workers failed with details
- `{:error, :timeout}` - Request timed out
- `{:error, {:rate_limited, message}}` - Rate limit exceeded
- `{:error, {:quota_exceeded, message}}` - API quota exceeded
- `{:error, {:invalid_api_key, message}}` - Invalid API key
- `{:error, {:server_error, status_code}}` - Server returned error

## Stream Processing

Response streams emit text chunks. Process them like this:

```elixir
{:ok, stream} = CortexCore.chat(messages)

# Collect all chunks
full_response = stream |> Enum.join("")

# Process chunks as they arrive
stream |> Enum.each(fn chunk ->
  IO.write(chunk)
  # Process each chunk...
end)

# Take only first N chunks
first_100_chars = stream |> Enum.take_while(fn chunk ->
  String.length(chunk) < 100
end) |> Enum.join("")
```

## Configuration Options

See the [Configuration Guide](configuration.md) for detailed configuration options.

## Custom Workers

See the [Custom Workers Guide](custom_workers.md) to implement your own providers.