# Cortex Core

[![Hex.pm](https://img.shields.io/hexpm/v/cortex_core.svg)](https://hex.pm/packages/cortex_core)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/cortex_core)
[![License](https://img.shields.io/hexpm/l/cortex_core.svg)](https://github.com/chinostroza/cortex_core/blob/main/LICENSE.md)
[![CI](https://github.com/chinostroza/cortex_core/workflows/CI/badge.svg)](https://github.com/chinostroza/cortex_core/actions)

A powerful multi-provider AI gateway library for Elixir. Build cost-effective AI applications with intelligent failover, API key rotation, and streaming support across multiple providers.

## Features

- 🌐 **Multi-Provider Support**: OpenAI, Anthropic, Google Gemini, Groq, Cohere, xAI, and Ollama (local)
- 🔄 **Intelligent Failover**: Automatic fallback to next available provider
- 🔑 **API Key Rotation**: Built-in strategies (round-robin, least-used, random)  
- 🌊 **Streaming Support**: SSE and JSON streaming for real-time responses
- 🏥 **Health Monitoring**: Automatic health checks and provider availability tracking
- 📊 **Priority-based Selection**: Configure provider priorities for cost optimization
- 🛡️ **Rate Limit Handling**: Automatic detection and key rotation on rate limits
- 🔌 **Extensible**: Easy to add custom providers via behaviour

## Installation

Add `cortex_core` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:cortex_core, "~> 1.0.0"}
  ]
end
```

## Quick Start

### Basic Usage

```elixir
# Start the supervision tree (usually in your Application)
{:ok, _} = CortexCore.start_link()

# Send a chat completion request
{:ok, stream} = CortexCore.chat([
  %{role: "user", content: "What is Elixir programming language?"}
])

# Process the stream
response = stream |> Enum.join("")
IO.puts(response)
```

### Configuration

Configure providers via environment variables:

```bash
# OpenAI
export OPENAI_API_KEYS=sk-key1,sk-key2,sk-key3
export OPENAI_MODEL=gpt-4

# Anthropic  
export ANTHROPIC_API_KEYS=sk-ant-key1,sk-ant-key2
export ANTHROPIC_MODEL=claude-3-opus-20240229

# Google Gemini
export GEMINI_API_KEYS=AIza-key1,AIza-key2
export GEMINI_MODEL=gemini-pro

# Groq (Fast inference)
export GROQ_API_KEYS=gsk-key1,gsk-key2
export GROQ_MODEL=llama3-8b-8192

# Local Ollama
export OLLAMA_BASE_URL=http://localhost:11434
export OLLAMA_MODEL=llama2

# Pool Configuration
export WORKER_POOL_STRATEGY=local_first  # or: round_robin, least_used, random
export HEALTH_CHECK_INTERVAL=30          # seconds (0 to disable)
export API_KEY_ROTATION_STRATEGY=round_robin
```

### Advanced Usage

```elixir
# Use specific provider
{:ok, stream} = CortexCore.chat(messages, provider: :openai)

# Custom parameters
{:ok, stream} = CortexCore.chat(messages,
  model: "gpt-4",
  temperature: 0.7,
  max_tokens: 2000
)

# Check provider health
health = CortexCore.health_status()
# => %{
#   "openai-primary" => :available,
#   "anthropic-primary" => :rate_limited,
#   "ollama-local" => :available
# }

# Add custom worker at runtime
CortexCore.add_worker("openai-europe",
  type: :openai,
  api_keys: ["sk-eu-key1", "sk-eu-key2"],
  model: "gpt-3.5-turbo"
)
```

## Provider Priorities

Providers are selected based on priority (lower number = higher priority):

| Provider | Priority | Use Case |
|----------|----------|----------|
| Ollama | 10 | Local, free, unlimited |
| Groq | 20 | Fast, generous free tier |
| Gemini | 30 | Balanced cost/performance |
| Cohere | 40 | Good for specific tasks |
| OpenAI | 50 | High quality, higher cost |
| Anthropic | 60 | Best quality, highest cost |

## Architecture

```
┌─────────────────┐
│   Your App      │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  CortexCore     │
└────────┬────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│           Worker Pool                    │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐   │
│  │ Ollama  │ │  Groq   │ │ OpenAI  │   │
│  │ Worker  │ │ Worker  │ │ Worker  │   │
│  └─────────┘ └─────────┘ └─────────┘   │
└─────────────────────────────────────────┘
         │           │           │
         ▼           ▼           ▼
    [Local AI]  [Groq API]  [OpenAI API]
```

## Creating Custom Workers

Implement the `CortexCore.Workers.Worker` behaviour:

```elixir
defmodule MyCustomWorker do
  @behaviour CortexCore.Workers.Worker
  
  defstruct [:name, :api_key, :endpoint]
  
  def new(opts) do
    %__MODULE__{
      name: opts[:name],
      api_key: opts[:api_key],
      endpoint: opts[:endpoint]
    }
  end
  
  @impl true
  def health_check(worker) do
    # Check if service is available
    {:ok, :available}
  end
  
  @impl true
  def stream_completion(worker, messages, opts) do
    # Return a stream of response chunks
    stream = Stream.repeatedly(fn -> "response chunk" end)
    {:ok, stream}
  end
  
  @impl true
  def info(worker) do
    %{
      name: worker.name,
      type: :custom,
      endpoint: worker.endpoint
    }
  end
  
  @impl true
  def priority(_worker), do: 100
end
```

## Error Handling

CortexCore provides comprehensive error handling:

```elixir
case CortexCore.chat(messages) do
  {:ok, stream} ->
    # Process successful response
    Enum.each(stream, &IO.write/1)
    
  {:error, :no_workers_available} ->
    # All workers are down or rate limited
    IO.puts("No AI providers available")
    
  {:error, {:all_workers_failed, details}} ->
    # All workers tried but failed
    IO.puts("All providers failed: #{details}")
    
  {:error, reason} ->
    # Other errors
    IO.puts("Error: #{inspect(reason)}")
end
```

## Testing

For testing, you can use mock workers:

```elixir
# In test_helper.exs
CortexCore.start_link(
  health_check_interval: 0  # Disable health checks in tests
)

# In your tests
CortexCore.add_worker("test-worker",
  type: :ollama,
  base_url: "http://localhost:11434"
)
```

## Performance Considerations

- **Streaming**: Responses are streamed to minimize memory usage
- **Connection Pooling**: HTTP connections are pooled via Finch
- **Async Health Checks**: Health checks run in parallel
- **Minimal Overhead**: Direct streaming from provider to client

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE.md](LICENSE.md) file for details.

## Support

- 📖 [Documentation](https://hexdocs.pm/cortex_core)
- 🐛 [Issue Tracker](https://github.com/chinostroza/cortex_core/issues)
- 💬 [Discussions](https://github.com/chinostroza/cortex_core/discussions)

## Acknowledgments

Built with ❤️ using Elixir and OTP for the Elixir community.