defmodule CortexCore.Workers.Adapters.AnthropicWorkerTest do
  use ExUnit.Case
  alias CortexCore.Workers.Adapters.AnthropicWorker

  setup do
    bypass = Bypass.open()

    worker =
      AnthropicWorker.new(
        name: "test_anthropic",
        api_keys: ["test_key_1", "test_key_2"],
        default_model: "claude-sonnet-4-20250514",
        timeout: 60_000,
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
        AnthropicWorker.new(
          name: "test_worker",
          api_keys: ["key1", "key2"],
          default_model: "claude-sonnet-4-20250514"
        )

      assert worker.name == "test_worker"
      assert worker.api_keys == ["key1", "key2"]
      assert worker.default_model == "claude-sonnet-4-20250514"
      assert worker.current_key_index == 0
    end

    test "uses default values for optional fields" do
      worker =
        AnthropicWorker.new(
          name: "test_worker",
          api_keys: ["key1"]
        )

      assert worker.default_model == "claude-sonnet-4-20250514"
      assert worker.timeout == 60_000
    end
  end

  describe "health_check/1" do
    test "returns ok when API is accessible", %{worker: worker, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        Plug.Conn.resp(
          conn,
          200,
          Jason.encode!(%{
            "id" => "msg_test",
            "type" => "message",
            "content" => [%{"type" => "text", "text" => "Health check OK"}]
          })
        )
      end)

      assert {:ok, :available} = AnthropicWorker.health_check(worker)
    end

    test "returns error when API is not accessible", %{worker: worker, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        Plug.Conn.resp(
          conn,
          500,
          Jason.encode!(%{
            "error" => %{
              "type" => "internal_server_error",
              "message" => "Internal server error"
            }
          })
        )
      end)

      assert {:error, _reason} = AnthropicWorker.health_check(worker)
    end
  end

  describe "stream_completion/3" do
    test "handles successful streaming response", %{worker: worker, bypass: bypass} do
      messages = [%{"role" => "user", "content" => "Hello"}]

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        # Verify request headers (simplified)
        assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test_key_1"]
        assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]

        # Mock streaming response
        conn =
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
          |> Plug.Conn.send_chunked(200)

        {:ok, conn} =
          Plug.Conn.chunk(
            conn,
            "event: message_start\ndata: #{Jason.encode!(%{"type" => "message_start", "message" => %{"id" => "msg_test"}})}\n\n"
          )

        {:ok, conn} =
          Plug.Conn.chunk(
            conn,
            "event: content_block_delta\ndata: #{Jason.encode!(%{"type" => "content_block_delta", "delta" => %{"text" => "Hello"}})}\n\n"
          )

        {:ok, _conn} =
          Plug.Conn.chunk(
            conn,
            "event: message_stop\ndata: #{Jason.encode!(%{"type" => "message_stop"})}\n\n"
          )
      end)

      assert {:ok, stream} = AnthropicWorker.stream_completion(worker, messages, [])

      # Verify stream produces content
      content = stream |> Stream.filter(&is_binary/1) |> Enum.take(5) |> Enum.join("")
      assert String.contains?(content, "Hello")
    end

    test "handles API errors", %{worker: worker, bypass: bypass} do
      messages = [%{"role" => "user", "content" => "Hello"}]

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        Plug.Conn.resp(
          conn,
          400,
          Jason.encode!(%{
            "error" => %{
              "type" => "invalid_request_error",
              "message" => "Invalid request"
            }
          })
        )
      end)

      # Streaming APIs return {:ok, stream} even for errors
      assert {:ok, stream} = AnthropicWorker.stream_completion(worker, messages, [])
      # Errors are handled when consuming the stream
      content = stream |> Stream.filter(&is_binary/1) |> Enum.take(1) |> Enum.join("")
      # No content for error responses
      assert content == ""
    end

    test "handles rate limiting", %{worker: worker, bypass: bypass} do
      messages = [%{"role" => "user", "content" => "Hello"}]

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        Plug.Conn.resp(
          conn,
          429,
          Jason.encode!(%{
            "error" => %{
              "type" => "rate_limit_error",
              "message" => "Rate limit exceeded"
            }
          })
        )
      end)

      # Streaming APIs return {:ok, stream} even for rate limits
      assert {:ok, stream} = AnthropicWorker.stream_completion(worker, messages, [])
      # Rate limit errors are handled when consuming the stream
      content = stream |> Stream.filter(&is_binary/1) |> Enum.take(1) |> Enum.join("")
      # No content for rate limit responses
      assert content == ""
    end

    test "converts messages to Anthropic format" do
      messages = [
        %{"role" => "system", "content" => "You are helpful"},
        %{"role" => "user", "content" => "Hello"}
      ]

      # Test that message conversion works by calling the transform_messages function directly
      transformed = AnthropicWorker.transform_messages(messages, [])

      # System message should be extracted to system field
      assert transformed["system"] == "You are helpful"

      # Only user messages should remain in messages array
      assert length(transformed["messages"]) == 1
      assert List.first(transformed["messages"])["role"] == "user"
    end
  end

  describe "info/1" do
    test "returns worker information", %{worker: worker} do
      info = AnthropicWorker.info(worker)

      assert is_map(info)
      assert info.name == "test_anthropic"
      assert info.type == :anthropic
      assert info.default_model == "claude-sonnet-4-20250514"
      assert Map.has_key?(info, :status)
      assert Map.has_key?(info, :api_keys_count)
    end

    test "includes Claude-specific features", %{worker: worker} do
      info = AnthropicWorker.info(worker)

      assert Map.has_key?(info, :features)
      assert "extended_thinking" in info.features
      assert "tool_use" in info.features
    end
  end

  describe "priority/1" do
    test "returns appropriate priority for different models", %{} do
      claude_4_worker =
        AnthropicWorker.new(
          name: "claude_4",
          api_keys: ["key"],
          default_model: "claude-sonnet-4-20250514"
        )

      claude_3_worker =
        AnthropicWorker.new(
          name: "claude_3",
          api_keys: ["key"],
          default_model: "claude-3.5-haiku"
        )

      # All Anthropic workers have the same priority currently
      assert AnthropicWorker.priority(claude_4_worker) ==
               AnthropicWorker.priority(claude_3_worker)

      assert AnthropicWorker.priority(claude_4_worker) == 10
    end
  end

  describe "streaming response parsing" do
    test "extracts text from content blocks", %{worker: worker, bypass: bypass} do
      messages = [%{"role" => "user", "content" => "Test"}]

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        events = [
          %{"type" => "message_start", "message" => %{"id" => "msg_1"}},
          %{"type" => "content_block_start", "index" => 0},
          %{"type" => "content_block_delta", "delta" => %{"text" => "Hello"}},
          %{"type" => "content_block_delta", "delta" => %{"text" => " world"}},
          %{"type" => "content_block_stop"},
          %{"type" => "message_stop"}
        ]

        conn = Plug.Conn.put_resp_header(conn, "content-type", "text/event-stream")
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(events, conn, fn event, acc_conn ->
          {:ok, new_conn} =
            Plug.Conn.chunk(
              acc_conn,
              "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
            )

          new_conn
        end)
      end)

      {:ok, stream} = AnthropicWorker.stream_completion(worker, messages, [])
      content = stream |> Stream.filter(&is_binary/1) |> Enum.take(10) |> Enum.join("")

      assert String.contains?(content, "Hello")
      assert String.contains?(content, "world")
    end

    test "handles non-streaming responses", %{worker: worker} do
      messages = [%{"role" => "user", "content" => "Test"}]

      # Test that the worker returns a stream (content tested elsewhere)
      {:ok, stream} = AnthropicWorker.stream_completion(worker, messages, [])
      assert is_struct(stream, Stream)
    end

    test "ignores control events", %{worker: worker, bypass: bypass} do
      messages = [%{"role" => "user", "content" => "Test"}]

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        events = [
          %{"type" => "message_start"},
          %{"type" => "content_block_start"},
          %{"type" => "content_block_delta", "delta" => %{"text" => "Content"}},
          %{"type" => "content_block_stop"},
          %{"type" => "message_stop"}
        ]

        conn = Plug.Conn.put_resp_header(conn, "content-type", "text/event-stream")
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(events, conn, fn event, acc_conn ->
          {:ok, new_conn} =
            Plug.Conn.chunk(
              acc_conn,
              "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
            )

          new_conn
        end)
      end)

      {:ok, stream} = AnthropicWorker.stream_completion(worker, messages, [])
      content_pieces = stream |> Stream.filter(&is_binary/1) |> Enum.take(10) |> Enum.reject(&(&1 == ""))

      # Should only contain actual content, not control events
      assert content_pieces == ["Content"]
    end
  end

  describe "model support" do
    test "supports different Claude models" do
      models = [
        "claude-sonnet-4-20250514",
        "claude-3.7-sonnet",
        "claude-3.5-haiku",
        "claude-3-sonnet"
      ]

      for model <- models do
        worker =
          AnthropicWorker.new(
            name: "test_#{model}",
            api_keys: ["key"],
            default_model: model
          )

        assert worker.default_model == model
      end
    end
  end
end
