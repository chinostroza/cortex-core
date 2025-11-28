defmodule CortexCore.Workers.Adapters.OpenAIEmbeddingsWorkerTest do
  use ExUnit.Case, async: true

  alias CortexCore.Workers.Adapters.OpenAIEmbeddingsWorker

  # Mock HTTP client for testing
  defmodule MockHTTPClient do
    def post(_url, opts) do
      # Simulate successful embedding response
      case opts[:json][:input] do
        "test" ->
          {:ok, %{
            status: 200,
            body: %{
              "data" => [
                %{
                  "embedding" => Enum.map(1..1536, fn _ -> :rand.uniform() end),
                  "index" => 0
                }
              ],
              "model" => "text-embedding-3-small",
              "usage" => %{
                "prompt_tokens" => 1,
                "total_tokens" => 1
              }
            }
          }}

        ["text1", "text2", "text3"] ->
          {:ok, %{
            status: 200,
            body: %{
              "data" => [
                %{"embedding" => Enum.map(1..1536, fn _ -> :rand.uniform() end), "index" => 0},
                %{"embedding" => Enum.map(1..1536, fn _ -> :rand.uniform() end), "index" => 1},
                %{"embedding" => Enum.map(1..1536, fn _ -> :rand.uniform() end), "index" => 2}
              ],
              "model" => "text-embedding-3-small",
              "usage" => %{
                "prompt_tokens" => 6,
                "total_tokens" => 6
              }
            }
          }}

        "rate_limit_test" ->
          {:ok, %{
            status: 429,
            body: %{
              "error" => %{
                "message" => "Rate limit reached for requests",
                "type" => "tokens"
              }
            }
          }}

        "quota_test" ->
          {:ok, %{
            status: 429,
            body: %{
              "error" => %{
                "message" => "You exceeded your current quota, please check your plan and billing details",
                "type" => "insufficient_quota"
              }
            }
          }}

        "long_text" ->
          {:ok, %{
            status: 400,
            body: %{
              "error" => %{
                "message" => "This input is too long",
                "type" => "invalid_request_error"
              }
            }
          }}

        _ ->
          {:ok, %{status: 500, body: "Internal server error"}}
      end
    end

    def get(_url, _opts) do
      # Mock health check
      {:ok, %{status: 200}}
    end
  end

  describe "new/1" do
    test "creates worker with valid options" do
      worker = OpenAIEmbeddingsWorker.new(
        name: "test-worker",
        api_keys: ["sk-test-key"]
      )

      assert worker.name == "test-worker"
      assert worker.api_keys == ["sk-test-key"]
      assert worker.default_model == "text-embedding-3-small"
      assert worker.timeout == 30_000
    end

    test "creates worker with multiple API keys" do
      worker = OpenAIEmbeddingsWorker.new(
        name: "test-worker",
        api_keys: ["key1", "key2", "key3"]
      )

      assert length(worker.api_keys) == 3
    end

    test "accepts custom model" do
      worker = OpenAIEmbeddingsWorker.new(
        name: "test-worker",
        api_keys: ["sk-test"],
        default_model: "text-embedding-3-large"
      )

      assert worker.default_model == "text-embedding-3-large"
    end

    test "raises when api_keys is missing" do
      assert_raise ArgumentError, fn ->
        OpenAIEmbeddingsWorker.new(name: "test")
      end
    end
  end

  describe "service_type/0" do
    test "returns :embeddings" do
      assert OpenAIEmbeddingsWorker.service_type() == :embeddings
    end
  end

  describe "info/1" do
    test "returns worker information" do
      worker = OpenAIEmbeddingsWorker.new(
        name: "test-worker",
        api_keys: ["sk-test1", "sk-test2"]
      )

      info = OpenAIEmbeddingsWorker.info(worker)

      assert info.name == "test-worker"
      assert info.type == :openai_embeddings
      assert info.service_type == :embeddings
      assert info.api_keys_count == 2
      assert info.default_model == "text-embedding-3-small"
      assert info.max_batch_size == 2048
      assert is_map(info.pricing)
    end
  end

  describe "priority/1" do
    test "returns priority 10" do
      worker = OpenAIEmbeddingsWorker.new(
        name: "test",
        api_keys: ["sk-test"]
      )

      assert OpenAIEmbeddingsWorker.priority(worker) == 10
    end
  end

  describe "call/3 - single embedding" do
    test "embeds single text successfully" do
      worker = OpenAIEmbeddingsWorker.new(
        name: "test",
        api_keys: ["sk-test"]
      )

      {:ok, result} = OpenAIEmbeddingsWorker.call(
        worker,
        %{input: "test"},
        [],
        MockHTTPClient
      )

      assert is_list(result.embedding)
      assert length(result.embedding) == 1536
      assert result.model == "text-embedding-3-small"
      assert result.dimensions == 1536
      assert is_map(result.usage)
      assert result.usage.prompt_tokens == 1
      assert is_float(result.cost_usd)
    end

    test "returns error when input is missing" do
      worker = OpenAIEmbeddingsWorker.new(
        name: "test",
        api_keys: ["sk-test"]
      )

      assert {:error, :missing_input} = OpenAIEmbeddingsWorker.call(
        worker,
        %{},
        [],
        MockHTTPClient
      )
    end
  end

  describe "call/3 - batch embedding" do
    test "embeds multiple texts successfully" do
      worker = OpenAIEmbeddingsWorker.new(
        name: "test",
        api_keys: ["sk-test"]
      )

      {:ok, result} = OpenAIEmbeddingsWorker.call(
        worker,
        %{input: ["text1", "text2", "text3"]},
        [],
        MockHTTPClient
      )

      assert is_list(result.embeddings)
      assert length(result.embeddings) == 3
      assert Enum.all?(result.embeddings, &(is_list(&1) and length(&1) == 1536))
      assert result.model == "text-embedding-3-small"
      assert result.dimensions == 1536
      assert result.usage.prompt_tokens == 6
    end

    test "returns error when batch is too large" do
      worker = OpenAIEmbeddingsWorker.new(
        name: "test",
        api_keys: ["sk-test"]
      )

      large_batch = Enum.map(1..2049, fn i -> "text#{i}" end)

      assert {:error, :batch_too_large} = OpenAIEmbeddingsWorker.call(
        worker,
        %{input: large_batch},
        [],
        MockHTTPClient
      )
    end
  end

  describe "call/3 - error handling" do
    test "handles rate limit error" do
      worker = OpenAIEmbeddingsWorker.new(
        name: "test",
        api_keys: ["sk-test"]
      )

      {:error, :rate_limited} = OpenAIEmbeddingsWorker.call(
        worker,
        %{input: "rate_limit_test"},
        [],
        MockHTTPClient
      )
    end

    test "handles quota exceeded error" do
      worker = OpenAIEmbeddingsWorker.new(
        name: "test",
        api_keys: ["sk-test"]
      )

      {:error, :quota_exceeded} = OpenAIEmbeddingsWorker.call(
        worker,
        %{input: "quota_test"},
        [],
        MockHTTPClient
      )
    end

    test "handles input too long error" do
      worker = OpenAIEmbeddingsWorker.new(
        name: "test",
        api_keys: ["sk-test"]
      )

      {:error, :input_too_long} = OpenAIEmbeddingsWorker.call(
        worker,
        %{input: "long_text"},
        [],
        MockHTTPClient
      )
    end
  end

  describe "health_check/2" do
    test "returns :available when API is healthy" do
      worker = OpenAIEmbeddingsWorker.new(
        name: "test",
        api_keys: ["sk-test"]
      )

      assert {:ok, :available} = OpenAIEmbeddingsWorker.health_check(
        worker,
        MockHTTPClient
      )
    end
  end

  describe "rotate_api_key/1" do
    test "rotates to next API key" do
      worker = OpenAIEmbeddingsWorker.new(
        name: "test",
        api_keys: ["key1", "key2", "key3"]
      )

      assert worker.current_key_index == 0
      assert OpenAIEmbeddingsWorker.current_api_key(worker) == "key1"

      worker = OpenAIEmbeddingsWorker.rotate_api_key(worker)
      assert worker.current_key_index == 1
      assert OpenAIEmbeddingsWorker.current_api_key(worker) == "key2"

      worker = OpenAIEmbeddingsWorker.rotate_api_key(worker)
      assert worker.current_key_index == 2
      assert OpenAIEmbeddingsWorker.current_api_key(worker) == "key3"

      # Should wrap around
      worker = OpenAIEmbeddingsWorker.rotate_api_key(worker)
      assert worker.current_key_index == 0
      assert OpenAIEmbeddingsWorker.current_api_key(worker) == "key1"
    end

    test "sets last_rotation timestamp" do
      worker = OpenAIEmbeddingsWorker.new(
        name: "test",
        api_keys: ["key1", "key2"]
      )

      assert is_nil(worker.last_rotation)

      worker = OpenAIEmbeddingsWorker.rotate_api_key(worker)
      refute is_nil(worker.last_rotation)
      assert %DateTime{} = worker.last_rotation
    end
  end

  describe "cost calculation" do
    test "calculates cost for text-embedding-3-small" do
      worker = OpenAIEmbeddingsWorker.new(
        name: "test",
        api_keys: ["sk-test"]
      )

      {:ok, result} = OpenAIEmbeddingsWorker.call(
        worker,
        %{input: "test", model: "text-embedding-3-small"},
        [],
        MockHTTPClient
      )

      # 1 token * $0.020 / 1M = 0.00000002
      assert result.cost_usd < 0.0001
      assert result.cost_usd > 0
    end
  end
end
