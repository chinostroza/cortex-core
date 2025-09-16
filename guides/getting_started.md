# Getting Started with Cortex Core

Cortex Core is a powerful multi-provider AI gateway for Elixir that provides a unified interface for multiple AI providers with intelligent failover and streaming support.

## Installation

Add `cortex_core` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:cortex_core, "~> 1.0"}
  ]
end
```

Then run:

```bash
mix deps.get
```

## Quick Start

### 1. Configure Your Workers

Set up your AI providers in your application configuration:

```elixir
# config/config.exs
config :cortex_core,
  workers: [
    %{
      type: :openai,
      name: "openai-main",
      api_keys: [System.get_env("OPENAI_API_KEY")],
      model: "gpt-4"
    },
    %{
      type: :anthropic,
      name: "claude-backup",
      api_keys: [System.get_env("ANTHROPIC_API_KEY")],
      model: "claude-3-sonnet"
    }
  ]
```

### 2. Start Using the API

```elixir
# Simple chat completion
{:ok, stream} = CortexCore.chat([
  %{"role" => "user", "content" => "Hello, how are you?"}
])

# Consume the streaming response
stream |> Enum.each(&IO.write/1)
```

### 3. Advanced Usage with Options

```elixir
# Specify model and other options
{:ok, stream} = CortexCore.chat(
  [%{"role" => "user", "content" => "Write a haiku about Elixir"}],
  model: "gpt-5",
  temperature: 0.7,
  max_tokens: 100
)
```

## Key Features

### Automatic Failover

If your primary worker fails, Cortex Core automatically switches to the next available worker:

```elixir
# This will try openai-main first, then claude-backup if it fails
{:ok, stream} = CortexCore.chat(messages)
```

### API Key Rotation

Workers automatically rotate API keys when rate limits are hit:

```elixir
# Configure multiple API keys per worker
%{
  type: :openai,
  name: "openai-pool",
  api_keys: [
    "sk-key1...",
    "sk-key2...",
    "sk-key3..."
  ]
}
```

### Health Monitoring

Check the health status of your workers:

```elixir
status = CortexCore.health_status()
# => %{
#   healthy: ["openai-main", "claude-backup"],
#   unhealthy: [],
#   total: 2
# }
```

### List Available Workers

```elixir
workers = CortexCore.list_workers()
# Returns detailed information about each worker
```

## Supported Providers

- **OpenAI**: GPT-5, GPT-4, GPT-3.5
- **Anthropic**: Claude Sonnet 4, Claude 3.7, Haiku 3.5
- **Google**: Gemini Pro 2.0, Pro 1.5, Flash 1.5
- **Groq**: Llama 3.3, Mixtral, Gemma
- **Cohere**: Command-R+, Command-R
- **xAI**: Grok models
- **Ollama**: Local models

## Error Handling

Cortex Core provides detailed error information:

```elixir
case CortexCore.chat(messages) do
  {:ok, stream} ->
    # Process the stream
    stream |> Enum.each(&IO.write/1)
    
  {:error, :no_workers_available} ->
    IO.puts("No workers are configured")
    
  {:error, {:all_workers_failed, details}} ->
    IO.puts("All workers failed: #{details}")
end
```

## Next Steps

- Read the [Configuration Guide](configuration.md) for detailed setup options
- Learn about [Custom Workers](custom_workers.md) to add your own providers
- Check the [API Reference](api_reference.md) for all available functions