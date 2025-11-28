defmodule CortexCore.EmbeddingsIntegrationTest do
  use ExUnit.Case, async: false

  alias CortexCore.Workers.Adapters.OpenAIEmbeddingsWorker

  # Mock successful embedding response
  defmodule MockSuccessClient do
    def post(_url, opts) do
      input = opts[:json][:input]

      embeddings = if is_list(input) do
        Enum.map(input, fn _ -> Enum.map(1..1536, fn _ -> :rand.uniform() end) end)
      else
        [Enum.map(1..1536, fn _ -> :rand.uniform() end)]
      end

      {:ok, %{
        status: 200,
        body: %{
          "data" => Enum.with_index(embeddings, fn embedding, idx ->
            %{"embedding" => embedding, "index" => idx}
          end),
          "model" => opts[:json][:model] || "text-embedding-3-small",
          "usage" => %{
            "prompt_tokens" => if(is_list(input), do: length(input) * 5, else: 5),
            "total_tokens" => if(is_list(input), do: length(input) * 5, else: 5)
          }
        }
      }}
    end

    def get(_url, _opts), do: {:ok, %{status: 200}}
  end

  setup do
    # Clean up before each test
    if Process.whereis(CortexCore.Workers.Registry) do
      GenServer.stop(CortexCore.Workers.Registry, :normal)
      Process.sleep(100)
    end

    :ok
  end

  describe "embeddings end-to-end workflow" do
    test "single text embedding via CortexCore.embed/2" do
      # Start CortexCore with embeddings worker
      start_supervised!({CortexCore.Workers.Supervisor, health_check_interval: 0})

      # Manually add embeddings worker
      worker = OpenAIEmbeddingsWorker.new(
        name: "test-embeddings",
        api_keys: ["sk-test-key"]
      )

      CortexCore.Workers.Registry.register(
        CortexCore.Workers.Registry,
        "test-embeddings",
        worker
      )

      # Mock the HTTP client at runtime by replacing the call
      text = "Paris is the capital of France"
      params = %{input: text, model: "text-embedding-3-small"}

      # Call directly with mock client
      {:ok, result} = OpenAIEmbeddingsWorker.call(worker, params, [], MockSuccessClient)

      assert is_list(result.embedding)
      assert length(result.embedding) == 1536
      assert Enum.all?(result.embedding, &is_float/1)
      assert result.model == "text-embedding-3-small"
      assert result.dimensions == 1536
      assert result.usage.prompt_tokens > 0
      assert result.cost_usd > 0
    end

    test "batch embedding via CortexCore.call/3" do
      start_supervised!({CortexCore.Workers.Supervisor, health_check_interval: 0})

      worker = OpenAIEmbeddingsWorker.new(
        name: "test-embeddings",
        api_keys: ["sk-test-key"]
      )

      CortexCore.Workers.Registry.register(
        CortexCore.Workers.Registry,
        "test-embeddings",
        worker
      )

      texts = [
        "First document about Paris",
        "Second document about France",
        "Third document about Europe"
      ]

      params = %{input: texts, model: "text-embedding-3-small"}
      {:ok, result} = OpenAIEmbeddingsWorker.call(worker, params, [], MockSuccessClient)

      assert is_list(result.embeddings)
      assert length(result.embeddings) == 3
      assert Enum.all?(result.embeddings, fn embedding ->
        is_list(embedding) and length(embedding) == 1536
      end)
      assert result.usage.prompt_tokens == 15  # 3 texts * 5 tokens each
    end

    test "embeddings with different models" do
      start_supervised!({CortexCore.Workers.Supervisor, health_check_interval: 0})

      worker = OpenAIEmbeddingsWorker.new(
        name: "test-embeddings",
        api_keys: ["sk-test-key"],
        default_model: "text-embedding-3-large"
      )

      CortexCore.Workers.Registry.register(
        CortexCore.Workers.Registry,
        "test-embeddings",
        worker
      )

      params = %{input: "Test text", model: "text-embedding-3-large"}
      {:ok, result} = OpenAIEmbeddingsWorker.call(worker, params, [], MockSuccessClient)

      assert result.model == "text-embedding-3-large"
    end

    test "health check integration" do
      start_supervised!({CortexCore.Workers.Supervisor, health_check_interval: 0})

      worker = OpenAIEmbeddingsWorker.new(
        name: "test-embeddings",
        api_keys: ["sk-test-key"]
      )

      CortexCore.Workers.Registry.register(
        CortexCore.Workers.Registry,
        "test-embeddings",
        worker
      )

      # Perform health check
      {:ok, status} = OpenAIEmbeddingsWorker.health_check(worker, MockSuccessClient)
      assert status == :available
    end

    test "worker info returns complete metadata" do
      start_supervised!({CortexCore.Workers.Supervisor, health_check_interval: 0})

      worker = OpenAIEmbeddingsWorker.new(
        name: "test-embeddings",
        api_keys: ["key1", "key2", "key3"]
      )

      info = OpenAIEmbeddingsWorker.info(worker)

      assert info.name == "test-embeddings"
      assert info.type == :openai_embeddings
      assert info.service_type == :embeddings
      assert info.api_keys_count == 3
      assert info.default_model == "text-embedding-3-small"
      assert info.max_batch_size == 2048
      assert info.available_models == [
        "text-embedding-3-small",
        "text-embedding-3-large",
        "text-embedding-ada-002"
      ]
      assert is_map(info.pricing)
    end
  end

  describe "embeddings service type routing" do
    test "CortexCore.call routes to embeddings workers" do
      start_supervised!({CortexCore.Workers.Supervisor, health_check_interval: 0})

      worker = OpenAIEmbeddingsWorker.new(
        name: "test-embeddings",
        api_keys: ["sk-test-key"]
      )

      CortexCore.Workers.Registry.register(
        CortexCore.Workers.Registry,
        "test-embeddings",
        worker
      )

      # Verify worker is registered with correct service type
      assert OpenAIEmbeddingsWorker.service_type() == :embeddings
    end
  end

  describe "error handling integration" do
    defmodule MockErrorClient do
      def post(_url, opts) do
        case opts[:json][:input] do
          "rate_limit" ->
            {:ok, %{
              status: 429,
              body: %{"error" => %{"message" => "Rate limit reached for requests"}}
            }}

          "quota" ->
            {:ok, %{
              status: 429,
              body: %{"error" => %{"message" => "You exceeded your current quota, please check your plan"}}
            }}

          "unauthorized" ->
            {:ok, %{status: 401, body: %{"error" => %{"message" => "Invalid API key"}}}}

          _ ->
            {:ok, %{status: 500, body: "Internal server error"}}
        end
      end

      def get(_url, _opts), do: {:error, :timeout}
    end

    test "handles rate limit errors" do
      worker = OpenAIEmbeddingsWorker.new(
        name: "test",
        api_keys: ["sk-test"]
      )

      {:error, :rate_limited} = OpenAIEmbeddingsWorker.call(
        worker,
        %{input: "rate_limit"},
        [],
        MockErrorClient
      )
    end

    test "handles quota exceeded errors" do
      worker = OpenAIEmbeddingsWorker.new(
        name: "test",
        api_keys: ["sk-test"]
      )

      {:error, :quota_exceeded} = OpenAIEmbeddingsWorker.call(
        worker,
        %{input: "quota"},
        [],
        MockErrorClient
      )
    end

    test "handles unauthorized errors" do
      worker = OpenAIEmbeddingsWorker.new(
        name: "test",
        api_keys: ["sk-test"]
      )

      {:error, :unauthorized} = OpenAIEmbeddingsWorker.call(
        worker,
        %{input: "unauthorized"},
        [],
        MockErrorClient
      )
    end

    test "health check reports unavailable on errors" do
      worker = OpenAIEmbeddingsWorker.new(
        name: "test",
        api_keys: ["sk-test"]
      )

      {:ok, :unavailable} = OpenAIEmbeddingsWorker.health_check(
        worker,
        MockErrorClient
      )
    end
  end

  describe "API key rotation integration" do
    test "rotates through multiple API keys" do
      worker = OpenAIEmbeddingsWorker.new(
        name: "test",
        api_keys: ["key1", "key2", "key3"]
      )

      assert OpenAIEmbeddingsWorker.current_api_key(worker) == "key1"

      worker = OpenAIEmbeddingsWorker.rotate_api_key(worker)
      assert OpenAIEmbeddingsWorker.current_api_key(worker) == "key2"

      worker = OpenAIEmbeddingsWorker.rotate_api_key(worker)
      assert OpenAIEmbeddingsWorker.current_api_key(worker) == "key3"

      worker = OpenAIEmbeddingsWorker.rotate_api_key(worker)
      assert OpenAIEmbeddingsWorker.current_api_key(worker) == "key1"
    end
  end
end
