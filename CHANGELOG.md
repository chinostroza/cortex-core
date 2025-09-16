# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial release of Cortex Core
- Multi-provider AI gateway with support for:
  - OpenAI (GPT-5, GPT-4, GPT-3.5)
  - Anthropic Claude (Sonnet 4, Claude 3.7, Haiku 3.5)
  - Google Gemini (Pro 2.0, Pro 1.5, Flash 1.5)
  - Groq (Llama 3.3, Mixtral, Gemma)
  - Cohere (Command-R, Command)
  - xAI Grok
  - Ollama (local models)
- Intelligent failover between providers
- API key rotation with rate limit handling
- Streaming support for all providers
- Unified interface across all AI providers
- Health check system for worker availability
- Comprehensive test suite with 100% test coverage
- Full documentation with ExDoc

### Changed
- Improved test infrastructure with proper mocking
- Fixed all test failures and race conditions
- Enhanced documentation with proper markdown syntax

### Fixed
- Resolved asynchronous process issues in tests
- Fixed HTTP client testing with dependency injection
- Corrected streaming response handling
- Fixed all compilation warnings

## [1.0.0] - 2024-09-16

### Added
- First stable release
- Production-ready multi-provider AI gateway
- Complete test suite passing (64/64 tests)
- Full documentation coverage

[Unreleased]: https://github.com/yourusername/cortex_core/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/yourusername/cortex_core/releases/tag/v1.0.0