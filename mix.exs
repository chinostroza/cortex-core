defmodule CortexCore.MixProject do
  use Mix.Project

  @version "1.0.2"
  @source_url "https://github.com/chinostroza/cortex_core"

  def project do
    [
      app: :cortex_core,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      description: description(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        ignore_warnings: ".dialyzer_ignore.exs"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      # Core dependencies
      {:req, "~> 0.4"},
      {:finch, "~> 0.16"},
      {:jason, "~> 1.4"},

      # Development and testing
      {:ex_doc, "~> 0.30", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:mock, "~> 0.3", only: :test},
      {:bypass, "~> 2.1", only: :test}
    ]
  end

  defp description do
    """
    A powerful multi-provider AI gateway library for Elixir. Provides intelligent
    failover, API key rotation, streaming support, and unified interface for
    OpenAI, Anthropic, Google Gemini, Groq, Cohere, and local models via Ollama.
    """
  end

  defp package do
    [
      name: "cortex_core",
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG*),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Documentation" => "https://hexdocs.pm/cortex_core"
      },
      maintainers: ["Carlos Hinostroza"]
    ]
  end

  defp docs do
    [
      main: "readme",
      name: "Cortex Core",
      source_ref: "v#{@version}",
      canonical: "https://hexdocs.pm/cortex_core",
      source_url: @source_url,
      extras: [
        "README.md",
        "CHANGELOG.md",
        "LICENSE.md",
        "guides/getting_started.md",
        "guides/configuration.md",
        "guides/custom_workers.md",
        "guides/api_reference.md"
      ],
      groups_for_modules: [
        "Core": [
          CortexCore,
          CortexCore.Dispatcher
        ],
        "Workers": [
          CortexCore.Workers.Worker,
          CortexCore.Workers.Registry,
          CortexCore.Workers.Pool,
          CortexCore.Workers.Supervisor,
          CortexCore.Workers.APIKeyManager
        ],
        "Adapters": [
          CortexCore.Workers.Adapters.APIWorkerBase,
          CortexCore.Workers.Adapters.OllamaWorker,
          CortexCore.Workers.Adapters.OpenAIWorker,
          CortexCore.Workers.Adapters.AnthropicWorker,
          CortexCore.Workers.Adapters.GeminiWorker,
          CortexCore.Workers.Adapters.GroqWorker,
          CortexCore.Workers.Adapters.CohereWorker,
          CortexCore.Workers.Adapters.XAIWorker
        ]
      ]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "compile"],
      test: ["test --trace"],
      "test.coverage": ["coveralls.html"],
      quality: ["format", "credo --strict", "dialyzer"],
      "docs.generate": ["docs"]
    ]
  end
end
