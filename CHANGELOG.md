# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2025-11-28

### Added
- **Embeddings Support**: Full implementation of text embeddings for RAG and semantic search
  - New `OpenAIEmbeddingsWorker` adapter for OpenAI embeddings API
  - Support for 3 embedding models:
    - `text-embedding-3-small` (1536 dims, $0.020/1M tokens) - default
    - `text-embedding-3-large` (3072 dims, $0.130/1M tokens)
    - `text-embedding-ada-002` (1536 dims, $0.100/1M tokens) - legacy
  - Batch embedding support (up to 2048 texts per request)
  - Automatic cost calculation per request
  - Token usage tracking
- New convenience API: `CortexCore.embed/2` for easy embeddings
- Generic API support: `CortexCore.call(:embeddings, params)`
- New service type: `:embeddings` in Worker behaviour
- Configuration via environment variables:
  - `OPENAI_EMBEDDINGS_API_KEYS` - comma-separated API keys
  - `OPENAI_EMBEDDINGS_DEFAULT_MODEL` - default embedding model
  - `OPENAI_EMBEDDINGS_TIMEOUT` - request timeout
- Full integration with existing infrastructure:
  - Health monitoring for embeddings workers
  - Automatic failover between API keys
  - Rate limit detection and handling
  - Quota exceeded detection
- Comprehensive test suite for embeddings (29 tests)
  - 18 unit tests for OpenAIEmbeddingsWorker
  - 11 integration tests for end-to-end workflows
- Documentation updates in README with examples and use cases

### Changed
- Updated Worker behaviour to include `:embeddings` service type
- Enhanced documentation with embeddings examples for RAG pipelines

### Fixed
- Fixed test workers in pool_test.exs to implement `service_type/0` callback

## [1.0.0] - 2024-09-16

### Added
- First stable release
- Production-ready multi-provider AI gateway
- Complete test suite passing (64/64 tests)
- Full documentation coverage

[Unreleased]: https://github.com/chinostroza/cortex_core/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/chinostroza/cortex_core/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/chinostroza/cortex_core/releases/tag/v1.0.0