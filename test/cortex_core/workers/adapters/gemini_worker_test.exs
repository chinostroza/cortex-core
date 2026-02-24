defmodule CortexCore.Workers.Adapters.GeminiWorkerTest do
  use ExUnit.Case

  alias CortexCore.Workers.Adapters.GeminiWorker

  setup do
    worker = GeminiWorker.new(name: "gemini-test", api_keys: ["test-key"])
    {:ok, worker: worker}
  end

  describe "transform_tools/1" do
    test "converts OpenAI function format to Gemini function_declarations" do
      tools = [
        %{
          "type" => "function",
          "function" => %{
            "name" => "extract",
            "description" => "Extract info",
            "parameters" => %{
              "type" => "object",
              "properties" => %{"name" => %{"type" => "string"}},
              "required" => ["name"]
            }
          }
        }
      ]

      result = GeminiWorker.transform_tools(tools)

      assert %{"tools" => [%{"function_declarations" => declarations}]} = result
      assert length(declarations) == 1
      assert hd(declarations)["name"] == "extract"
      assert hd(declarations)["description"] == "Extract info"
      assert hd(declarations)["parameters"]["type"] == "object"
    end

    test "converts multiple tools" do
      tools = [
        %{
          "type" => "function",
          "function" => %{"name" => "fn1", "description" => "d1", "parameters" => %{}}
        },
        %{
          "type" => "function",
          "function" => %{"name" => "fn2", "description" => "d2", "parameters" => %{}}
        }
      ]

      %{"tools" => [%{"function_declarations" => declarations}]} =
        GeminiWorker.transform_tools(tools)

      assert length(declarations) == 2
      assert Enum.map(declarations, & &1["name"]) == ["fn1", "fn2"]
    end

    test "wraps all declarations in a single tools entry" do
      tools = [
        %{
          "type" => "function",
          "function" => %{"name" => "f", "description" => "d", "parameters" => %{}}
        }
      ]

      %{"tools" => tools_list} = GeminiWorker.transform_tools(tools)
      assert length(tools_list) == 1
    end
  end

  describe "extract_tool_calls/1" do
    test "extracts functionCall parts from Gemini response" do
      body = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "functionCall" => %{
                    "name" => "extract",
                    "args" => %{"name" => "UserAuth", "priority" => "high"}
                  }
                }
              ]
            }
          }
        ]
      }

      result = GeminiWorker.extract_tool_calls(body)

      assert [%{name: "extract", arguments: %{"name" => "UserAuth", "priority" => "high"}}] =
               result
    end

    test "ignores non-functionCall parts" do
      body = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{"text" => "some text"},
                %{"functionCall" => %{"name" => "fn", "args" => %{"key" => "val"}}}
              ]
            }
          }
        ]
      }

      result = GeminiWorker.extract_tool_calls(body)
      assert length(result) == 1
      assert hd(result).name == "fn"
    end

    test "returns empty list when no candidates" do
      assert [] = GeminiWorker.extract_tool_calls(%{})
    end

    test "returns empty list when no functionCall parts" do
      body = %{
        "candidates" => [%{"content" => %{"parts" => [%{"text" => "hello"}]}}]
      }

      assert [] = GeminiWorker.extract_tool_calls(body)
    end

    test "handles multiple tool calls in one response" do
      body = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{"functionCall" => %{"name" => "fn1", "args" => %{"a" => 1}}},
                %{"functionCall" => %{"name" => "fn2", "args" => %{"b" => 2}}}
              ]
            }
          }
        ]
      }

      result = GeminiWorker.extract_tool_calls(body)
      assert length(result) == 2
    end
  end

  describe "transform_messages/2" do
    test "converts messages to Gemini contents format" do
      messages = [%{"role" => "user", "content" => "hello"}]
      result = GeminiWorker.transform_messages(messages, [])
      assert %{"contents" => [%{"role" => "user", "parts" => [%{"text" => "hello"}]}]} = result
    end

    test "maps assistant role to model" do
      messages = [%{"role" => "assistant", "content" => "hi"}]
      %{"contents" => [content]} = GeminiWorker.transform_messages(messages, [])
      assert content["role"] == "model"
    end
  end

  describe "provider_config/1" do
    test "includes tools_endpoint", %{worker: worker} do
      config = GeminiWorker.provider_config(worker)
      assert Map.has_key?(config, :tools_endpoint)
    end

    test "tools_endpoint matches stream_endpoint", %{worker: worker} do
      config = GeminiWorker.provider_config(worker)
      assert config.tools_endpoint == config.stream_endpoint
    end
  end
end
