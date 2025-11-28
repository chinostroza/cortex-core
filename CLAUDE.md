# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Cortex Core is an Elixir library that provides a unified interface for multiple AI providers (OpenAI, Anthropic, Google Gemini, Groq, Cohere, xAI, and Ollama) with intelligent failover, load balancing, and API key management.

## Essential Commands

### Development
```bash
# Install dependencies
mix deps.get

# Compile the project
mix compile

# Run interactive shell with the project loaded
iex -S mix

# Format code
mix format

# Run static analysis
mix credo

# Run type checking
mix dialyzer

# Generate documentation
mix docs
```

### Testing
```bash
# Run all tests
mix test

# Run a specific test file
mix test test/path/to/test_file.exs

# Run a specific test by line number
mix test test/path/to/test_file.exs:42

# Run tests with coverage
mix coveralls

# Run tests with HTML coverage report
mix coveralls.html

# Run tests in watch mode (requires installing mix_test_watch)
mix test.watch

# Run tests with verbose output
mix test --trace
```

### Publishing
```bash
# Publish to Hex.pm
mix hex.publish
```

## Architecture

### Core Components

1. **CortexCore** (`lib/cortex_core/cortex_core.ex`): Main public API module that provides high-level functions for chat completions.

2. **Dispatcher** (`lib/cortex_core/dispatcher.ex`): Handles request routing, provider selection based on priority, and automatic failover when providers fail.

3. **Worker System**:
   - **Worker Behaviour** (`lib/cortex_core/workers/worker.ex`): Defines the contract all provider adapters must implement
   - **Worker Pool** (`lib/cortex_core/workers/pool.ex`): Manages worker instances and health monitoring
   - **API Key Manager** (`lib/cortex_core/workers/api_key_manager.ex`): Implements key rotation strategies (round-robin, least-used, random)

4. **Provider Adapters** (`lib/cortex_core/workers/adapters/`):
   - `api_worker_base.ex`: Base module with common HTTP client functionality
   - Individual adapters inherit from base and implement provider-specific logic

### Key Design Patterns

1. **OTP Supervision Tree**: Uses Elixir's OTP principles with supervised GenServers for reliability
2. **Behaviour-based Extensibility**: New providers can be added by implementing the Worker behaviour
3. **Priority-based Failover**: Providers are tried in order of priority with automatic failover
4. **Health Monitoring**: Automatic health checks with configurable intervals and failure thresholds

### Configuration

The library is configured via environment variables:
- `CORTEX_PROVIDERS`: JSON configuration for all providers
- Provider-specific configs can also use individual env vars (e.g., `OPENAI_API_KEY`)

### Testing Approach

- Unit tests for individual modules
- Integration tests using Bypass for HTTP mocking
- Mock library for testing GenServer interactions
- Comprehensive test coverage expected (check with `mix coveralls`)

## Important Considerations

1. **Provider Response Normalization**: All provider responses are normalized to a common format in the adapter modules
2. **Streaming Support**: Both SSE and JSON streaming are supported - handle these cases carefully
3. **Error Handling**: The library uses tagged tuples (`{:ok, result}` / `{:error, reason}`) - maintain this pattern
4. **API Compatibility**: Maintain compatibility with the public API in `CortexCore` module
5. **Health Monitoring**: Provider health is tracked automatically - ensure new adapters properly report success/failure
6. **Configuration**: Provider configuration is handled via environment variables in JSON format (see `CORTEX_PROVIDERS`)
7. **Dependencies**: Uses `req` for HTTP, `finch` for connection pooling, and `jason` for JSON parsing

## Common Development Tasks

When adding a new provider:
1. Create adapter in `lib/cortex_core/workers/adapters/`
2. Implement the Worker behaviour
3. Add provider configuration handling
4. Write comprehensive tests including streaming scenarios
5. Update README.md with provider-specific documentation