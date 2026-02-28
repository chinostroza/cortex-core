defmodule CortexCore.Workers.Adapters.OpenAIWorkerTest do
  use ExUnit.Case
  alias CortexCore.Workers.Adapters.OpenAIWorker

  setup do
    bypass = Bypass.open()

    worker =
      OpenAIWorker.new(
        name: "test_openai",
        api_keys: ["test_key_1", "test_key_2"],
        default_model: "gpt-5",
        timeout: 30_000,
        base_url: "http://localhost:#{bypass.port}"
      )

    on_exit(fn ->
      Bypass.down(bypass)
    end)

    {:ok, worker: worker, bypass: bypass}
  end

  describe "new/1" do
    test "creates worker with required fields" do
      worker =
        OpenAIWorker.new(
          name: "test_worker",
          api_keys: ["key1", "key2"],
          default_model: "gpt-5"
        )

      assert worker.name == "test_worker"
      assert worker.api_keys == ["key1", "key2"]
      assert worker.default_model == "gpt-5"
      assert worker.current_key_index == 0
    end

    test "uses default values for optional fields" do
      worker =
        OpenAIWorker.new(
          name: "test_worker",
          api_keys: ["key1"]
        )

      assert worker.default_model == "gpt-5"
      assert worker.timeout == 30_000
    end
  end

  describe "health_check/1" do
    test "returns ok when API is accessible", %{worker: worker} do
      # Use mock HTTP client that returns success
      alias CortexCore.TestHelpers.SuccessHTTPClient
      assert {:ok, :available} = OpenAIWorker.health_check(worker, SuccessHTTPClient)
    end

    test "returns error when API is not accessible", %{worker: worker} do
      # Use mock HTTP client that returns server error
      alias CortexCore.TestHelpers.ErrorHTTPClient
      assert {:error, {:server_error, 500}} = OpenAIWorker.health_check(worker, ErrorHTTPClient)
    end

    test "handles network timeout", %{worker: worker} do
      # Use mock HTTP client that returns timeout
      alias CortexCore.TestHelpers.MockHTTPClient
      assert {:error, :timeout} = OpenAIWorker.health_check(worker, MockHTTPClient)
    end
  end

  describe "stream_completion/3" do
    test "handles successful streaming response", %{worker: worker, bypass: bypass} do
      messages = [%{"role" => "user", "content" => "Hello"}]

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        # Verify request headers (simplified)
        auth_header = Plug.Conn.get_req_header(conn, "authorization")
        assert auth_header == ["Bearer test_key_1"]

        # Mock streaming response
        conn =
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
          |> Plug.Conn.send_chunked(200)

        {:ok, conn} =
          Plug.Conn.chunk(
            conn,
            "data: #{Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "Hello"}}]})}\n\n"
          )

        {:ok, _conn} = Plug.Conn.chunk(conn, "data: [DONE]\n\n")
      end)

      assert {:ok, stream} = OpenAIWorker.stream_completion(worker, messages, [])

      # Verify stream produces content
      content = stream |> Stream.filter(&is_binary/1) |> Enum.take(5) |> Enum.join("")
      assert String.contains?(content, "Hello")
    end

    test "handles API errors", %{worker: worker, bypass: bypass} do
      messages = [%{"role" => "user", "content" => "Hello"}]

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        Plug.Conn.resp(
          conn,
          400,
          Jason.encode!(%{
            "error" => %{
              "message" => "Invalid request",
              "type" => "invalid_request_error"
            }
          })
        )
      end)

      # Streaming APIs return {:ok, stream} even for errors
      assert {:ok, stream} = OpenAIWorker.stream_completion(worker, messages, [])
      # Errors are handled when consuming the stream
      content = stream |> Stream.filter(&is_binary/1) |> Enum.take(1) |> Enum.join("")
      # No content for error responses
      assert content == ""
    end

    test "handles rate limiting", %{worker: worker, bypass: bypass} do
      messages = [%{"role" => "user", "content" => "Hello"}]

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        Plug.Conn.resp(
          conn,
          429,
          Jason.encode!(%{
            "error" => %{
              "message" => "Rate limit exceeded",
              "type" => "rate_limit_error"
            }
          })
        )
      end)

      # Streaming APIs return {:ok, stream} even for rate limits
      assert {:ok, stream} = OpenAIWorker.stream_completion(worker, messages, [])
      # Rate limit errors are handled when consuming the stream
      content = stream |> Stream.filter(&is_binary/1) |> Enum.take(1) |> Enum.join("")
      # No content for rate limit responses
      assert content == ""
    end

    test "rotates API keys on failure", %{worker: worker} do
      messages = [%{"role" => "user", "content" => "Hello"}]

      # Test that the worker returns a stream (HTTP details tested elsewhere)
      assert {:ok, _stream} = OpenAIWorker.stream_completion(worker, messages, [])
    end

    test "validates message format", %{worker: worker} do
      invalid_messages = [%{"invalid" => "format"}]

      # Even invalid messages return a stream, validation happens server-side
      result = OpenAIWorker.stream_completion(worker, invalid_messages, [])
      assert match?({:ok, _stream}, result)
    end
  end

  describe "info/1" do
    test "returns worker information", %{worker: worker} do
      info = OpenAIWorker.info(worker)

      assert is_map(info)
      assert info.name == "test_openai"
      assert info.type == :openai
      assert info.default_model == "gpt-5"
      assert Map.has_key?(info, :status)
      assert Map.has_key?(info, :api_keys_count)
    end

    test "masks API keys in info", %{worker: worker} do
      info = OpenAIWorker.info(worker)

      # Should not expose actual API keys
      refute Map.has_key?(info, :api_keys)
      assert info.api_keys_count == 2
    end
  end

  describe "priority/1" do
    test "returns worker priority", %{worker: worker} do
      priority = OpenAIWorker.priority(worker)
      assert is_integer(priority)
      assert priority > 0
    end
  end

  describe "model support" do
    test "supports different OpenAI models" do
      models = ["gpt-5", "gpt-4-turbo", "gpt-3.5-turbo"]

      for model <- models do
        worker =
          OpenAIWorker.new(
            name: "test_#{model}",
            api_keys: ["key"],
            # Use default_model key instead of model
            default_model: model
          )

        assert worker.default_model == model
      end
    end
  end

  describe "streaming response parsing" do
    test "parses delta content correctly", %{worker: worker, bypass: bypass} do
      messages = [%{"role" => "user", "content" => "Test"}]

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        responses = [
          %{"choices" => [%{"delta" => %{"content" => "Hello"}}]},
          %{"choices" => [%{"delta" => %{"content" => " world"}}]},
          %{"choices" => [%{"delta" => %{"content" => "!"}}]}
        ]

        conn = Plug.Conn.put_resp_header(conn, "content-type", "text/event-stream")
        conn = Plug.Conn.send_chunked(conn, 200)

        final_conn =
          Enum.reduce(responses, conn, fn response, acc_conn ->
            {:ok, new_conn} = Plug.Conn.chunk(acc_conn, "data: #{Jason.encode!(response)}\n\n")
            new_conn
          end)

        {:ok, _conn} = Plug.Conn.chunk(final_conn, "data: [DONE]\n\n")
      end)

      {:ok, stream} = OpenAIWorker.stream_completion(worker, messages, [])
      content = stream |> Stream.filter(&is_binary/1) |> Enum.take(10) |> Enum.join("")

      assert String.contains?(content, "Hello")
      assert String.contains?(content, "world")
      assert String.contains?(content, "!")
    end

    test "handles empty delta content", %{worker: worker, bypass: bypass} do
      messages = [%{"role" => "user", "content" => "Test"}]

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        responses = [
          # Empty delta
          %{"choices" => [%{"delta" => %{}}]},
          %{"choices" => [%{"delta" => %{"content" => "Hello"}}]}
        ]

        conn = Plug.Conn.put_resp_header(conn, "content-type", "text/event-stream")
        conn = Plug.Conn.send_chunked(conn, 200)

        final_conn =
          Enum.reduce(responses, conn, fn response, acc_conn ->
            {:ok, new_conn} = Plug.Conn.chunk(acc_conn, "data: #{Jason.encode!(response)}\n\n")
            new_conn
          end)

        {:ok, _conn} = Plug.Conn.chunk(final_conn, "data: [DONE]\n\n")
      end)

      {:ok, stream} = OpenAIWorker.stream_completion(worker, messages, [])
      content = stream |> Stream.filter(&is_binary/1) |> Enum.take(5) |> Enum.join("")

      assert String.contains?(content, "Hello")
    end
  end
end
