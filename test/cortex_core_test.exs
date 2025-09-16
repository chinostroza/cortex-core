defmodule CortexCoreTest do
  use ExUnit.Case
  import CortexCore.TestHelpers
  
  doctest CortexCore

  describe "CortexCore main API" do
    setup do
      # No need to start the actual application, we'll mock everything
      :ok
    end

    test "version returns correct version" do
      assert CortexCore.version() =~ ~r/\d+\.\d+\.\d+/
    end

    test "chat/2 returns stream for valid messages" do
      messages = [%{role: "user", content: "Hello"}]

      with_mocked_dependencies(fn ->
        result = CortexCore.chat(messages)
        assert {:ok, stream} = result
        assert is_function(stream) or is_struct(stream, Stream)
      end)
    end

    test "health_status/0 returns map" do
      with_mocked_dependencies(fn ->
        status = CortexCore.health_status()
        assert is_map(status)
      end)
    end

    test "list_workers/0 returns list" do
      with_mocked_dependencies(fn ->
        workers = CortexCore.list_workers()
        assert is_list(workers)
      end)
    end
  end
end
