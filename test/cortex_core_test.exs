defmodule CortexCoreTest do
  use ExUnit.Case
  import Mock
  import CortexCore.TestHelpers

  alias CortexCore.Workers.Pool

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

    test "call/3 dispatches to pool" do
      with_mocked_dependencies(fn ->
        result = CortexCore.call(:search, %{query: "test"})
        assert {:ok, _} = result
      end)
    end

    test "call/2 dispatches to pool with no opts" do
      with_mocked_dependencies(fn ->
        result = CortexCore.call(:search, %{query: "test"})
        assert {:ok, _} = result
      end)
    end

    test "call_with_tools/3 returns error when no provider specified" do
      with_mocked_dependencies(fn ->
        result =
          CortexCore.call_with_tools(
            [%{role: "user", content: "test"}],
            [%{"function" => %{"name" => "test"}}]
          )

        assert {:error, :no_provider_specified} = result
      end)
    end

    test "check_health/0 triggers health check" do
      with_mocked_dependencies(fn ->
        # check_health delegates to Dispatcher.check_workers -> Pool.check_health (cast)
        # cast returns :ok immediately
        assert :ok = CortexCore.check_health()
      end)
    end

    test "add_worker/2 delegates to Supervisor" do
      with_mocked_dependencies(fn ->
        result = CortexCore.add_worker("test-worker", type: :unknown_type, api_keys: ["key1"])
        # unsupported type returns {:error, :unsupported_worker_type}
        assert {:error, :unsupported_worker_type} = result
      end)
    end

    test "remove_worker/1 delegates to Supervisor" do
      with_mocked_dependencies(fn ->
        # remove_worker calls Registry.unregister which always returns :ok
        result = CortexCore.remove_worker("test-worker")
        assert :ok = result
      end)
    end

    test "embed/1 passthrough when pool returns non-embedding result" do
      with_mocked_dependencies(fn ->
        # Pool.call returns {:ok, %{"results" => []}} from mock, which doesn't match
        # {:ok, %{embedding: _}} or {:ok, %{embeddings: _}}, so it passes through
        result = CortexCore.embed("hello world")
        # Passes through as-is since mock returns {:ok, %{"results" => []}}
        assert {:ok, %{"results" => []}} = result
      end)
    end

    test "embed/1 returns single embedding vector when worker returns {:ok, %{embedding: _}}" do
      with_mocks([
        {Pool, [],
         [
           call: fn _pool, _type, _params, _opts -> {:ok, %{embedding: [0.1, 0.2, 0.3]}} end,
           call: fn _type, _params, _opts -> {:ok, %{embedding: [0.1, 0.2, 0.3]}} end
         ]},
        {CortexCore.Workers.Registry, [:passthrough],
         [
           list_all: fn _registry -> [] end,
           list_all: fn -> [] end
         ]},
        {CortexCore.Workers.Supervisor, [:passthrough],
         [configure_initial_workers: fn _registry -> :ok end]}
      ]) do
        assert {:ok, [0.1, 0.2, 0.3]} = CortexCore.embed("hello")
      end
    end

    test "embed/1 returns batch embeddings when worker returns {:ok, %{embeddings: _}}" do
      with_mocks([
        {Pool, [],
         [
           call: fn _pool, _type, _params, _opts ->
             {:ok, %{embeddings: [[0.1, 0.2], [0.3, 0.4]]}}
           end,
           call: fn _type, _params, _opts -> {:ok, %{embeddings: [[0.1, 0.2], [0.3, 0.4]]}} end
         ]},
        {CortexCore.Workers.Registry, [:passthrough],
         [
           list_all: fn _registry -> [] end,
           list_all: fn -> [] end
         ]},
        {CortexCore.Workers.Supervisor, [:passthrough],
         [configure_initial_workers: fn _registry -> :ok end]}
      ]) do
        assert {:ok, [[0.1, 0.2], [0.3, 0.4]]} = CortexCore.embed(["hello", "world"])
      end
    end

    test "embed/2 with dimensions option passes dimensions to call" do
      with_mocks([
        {Pool, [],
         [
           call: fn _pool, :embeddings, params, _opts ->
             assert Map.has_key?(params, :dimensions)
             {:ok, %{embedding: [0.1, 0.2, 0.3]}}
           end,
           call: fn :embeddings, params, _opts ->
             assert Map.has_key?(params, :dimensions)
             {:ok, %{embedding: [0.1, 0.2, 0.3]}}
           end
         ]},
        {CortexCore.Workers.Registry, [:passthrough],
         [
           list_all: fn _registry -> [] end,
           list_all: fn -> [] end
         ]},
        {CortexCore.Workers.Supervisor, [:passthrough],
         [configure_initial_workers: fn _registry -> :ok end]}
      ]) do
        assert {:ok, [0.1, 0.2, 0.3]} = CortexCore.embed("hello", dimensions: 512)
      end
    end

    test "stream_completion/1 is alias for chat/1" do
      with_mocked_dependencies(fn ->
        messages = [%{role: "user", content: "Hello"}]
        result = CortexCore.stream_completion(messages)
        assert {:ok, _} = result
      end)
    end

    test "call_service/3 is alias for call/3" do
      with_mocked_dependencies(fn ->
        result = CortexCore.call_service(:search, %{query: "test"})
        assert {:ok, _} = result
      end)
    end
  end
end
