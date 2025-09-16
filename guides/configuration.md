# Configuration Guide

This guide covers all configuration options available in Cortex Core.

## Worker Configuration

Workers are the core components that connect to AI providers. Each worker needs specific configuration based on its type.

### OpenAI Configuration

```elixir
config :cortex_core,
  workers: [
    %{
      type: :openai,
      name: "openai-primary",
      api_keys: ["sk-..."],  # Required
      model: "gpt-5",        # Optional, default: "gpt-5"
      timeout: 30_000,       # Optional, default: 30 seconds
      base_url: "https://api.openai.com"  # Optional, for proxies
    }
  ]
```

### Anthropic Configuration

```elixir
%{
  type: :anthropic,
  name: "claude-worker",
  api_keys: ["sk-ant-..."],
  model: "claude-3-sonnet-20240229",  # Default: "claude-3-sonnet"
  timeout: 60_000  # Claude supports longer timeouts
}
```

### Google Gemini Configuration

```elixir
%{
  type: :gemini,
  name: "gemini-worker",
  api_keys: ["AIza..."],
  model: "gemini-pro",  # or "gemini-pro-vision"
  timeout: 30_000
}
```

### Groq Configuration

```elixir
%{
  type: :groq,
  name: "groq-fast",
  api_keys: ["gsk_..."],
  model: "llama-3.3-70b-versatile",
  timeout: 10_000  # Groq is very fast
}
```

### Ollama Configuration (Local Models)

```elixir
%{
  type: :ollama,
  name: "local-llama",
  base_url: "http://localhost:11434",
  models: ["llama3.1", "mistral", "codellama"],
  timeout: 120_000  # Local models can be slower
}
```

## Environment Variables

It's recommended to use environment variables for sensitive data:

```elixir
# config/runtime.exs
import Config

config :cortex_core,
  workers: [
    %{
      type: :openai,
      name: "openai-main",
      api_keys: [
        System.get_env("OPENAI_API_KEY_1"),
        System.get_env("OPENAI_API_KEY_2")
      ] |> Enum.filter(&(&1 != nil))
    }
  ]
```

## Pool Configuration

Configure the worker pool behavior:

```elixir
config :cortex_core,
  pool: %{
    strategy: :round_robin,  # or :random, :least_used
    health_check_interval: 60_000,  # milliseconds
    retry_attempts: 3,
    retry_delay: 1_000
  }
```

### Strategy Options

- `:round_robin` - Rotates through workers in order
- `:random` - Randomly selects workers
- `:least_used` - Prefers workers with fewer recent requests

## API Key Rotation

Configure how API keys are rotated:

```elixir
config :cortex_core,
  api_key_manager: %{
    rotation_strategy: :round_robin,  # or :random, :least_used
    rate_limit_window: 60_000,  # Track rate limits for 1 minute
    block_duration: 300_000     # Block rate-limited keys for 5 minutes
  }
```

## Timeouts and Retries

Global timeout configuration:

```elixir
config :cortex_core,
  default_timeout: 30_000,
  max_retries: 3,
  retry_base_delay: 1_000,
  retry_max_delay: 10_000
```

## Logging

Configure logging levels:

```elixir
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:worker_name, :provider]

config :cortex_core,
  log_level: :info,  # :debug for more verbose logging
  log_requests: false,  # Log all API requests
  log_responses: false  # Log all API responses
```

## Advanced Configuration

### Custom HTTP Client Options

```elixir
config :cortex_core,
  http_options: [
    pool_size: 10,
    pool_timeout: 5_000,
    receive_timeout: 30_000
  ]
```

### Proxy Configuration

For enterprise environments with HTTP proxies:

```elixir
config :cortex_core,
  proxy: %{
    host: "proxy.company.com",
    port: 8080,
    username: "user",
    password: System.get_env("PROXY_PASSWORD")
  }
```

### SSL/TLS Options

```elixir
config :cortex_core,
  ssl_options: [
    verify: :verify_peer,
    cacerts: :public_key.cacerts_get(),
    customize_hostname_check: [
      match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
    ]
  ]
```

## Complete Example

Here's a complete configuration example:

```elixir
# config/config.exs
import Config

config :cortex_core,
  workers: [
    %{
      type: :openai,
      name: "openai-primary",
      api_keys: ["${OPENAI_KEY_1}", "${OPENAI_KEY_2}"],
      model: "gpt-4",
      timeout: 30_000
    },
    %{
      type: :anthropic,
      name: "claude-backup",
      api_keys: ["${ANTHROPIC_KEY}"],
      model: "claude-3-sonnet",
      timeout: 60_000
    },
    %{
      type: :ollama,
      name: "local-fallback",
      base_url: "http://localhost:11434",
      models: ["llama3.1"],
      timeout: 120_000
    }
  ],
  pool: %{
    strategy: :round_robin,
    health_check_interval: 60_000
  },
  api_key_manager: %{
    rotation_strategy: :least_used,
    rate_limit_window: 60_000
  },
  log_level: :info
```

## Configuration Validation

Cortex Core validates configuration on startup. Common errors:

- Missing required fields (type, name, api_keys/base_url)
- Invalid worker types
- Empty API key lists
- Invalid timeout values

Check logs for configuration errors during application startup.