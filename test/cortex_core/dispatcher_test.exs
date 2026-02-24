defmodule CortexCore.DispatcherTest do
  use ExUnit.Case
  import Mock

  alias CortexCore.Dispatcher
  alias CortexCore.Workers.{Pool, Registry}

  describe "dispatch/3" do
    test "returns ok on successful pool call" do
      with_mock Pool, call: fn _pool, _type, _params, _opts -> {:ok, %{"results" => []}} end do
        assert {:ok, _} = Dispatcher.dispatch(:search, %{query: "test"}, [])
      end
    end

    test "returns error when no workers available" do
      with_mock Pool,
        call: fn _pool, _type, _params, _opts -> {:error, :no_workers_available} end do
        assert {:error, :no_workers_available} = Dispatcher.dispatch(:search, %{}, [])
      end
    end

    test "returns error on generic failure" do
      with_mock Pool, call: fn _pool, _type, _params, _opts -> {:error, :timeout} end do
        assert {:error, :timeout} = Dispatcher.dispatch(:llm, %{}, [])
      end
    end

    test "dispatch_to_service/3 is alias for dispatch/3" do
      with_mock Pool, call: fn _pool, _type, _params, _opts -> {:ok, %{}} end do
        assert {:ok, _} = Dispatcher.dispatch_to_service(:search, %{query: "test"}, [])
      end
    end
  end

  describe "dispatch_stream/2" do
    test "returns ok stream on success" do
      stream = Stream.take(["chunk1", "chunk2"], 2)

      with_mock Pool,
        stream_completion: fn _pool, _messages, _opts -> {:ok, stream} end do
        assert {:ok, ^stream} = Dispatcher.dispatch_stream([%{role: "user", content: "hi"}])
      end
    end

    test "returns error when no workers available" do
      with_mock Pool,
        stream_completion: fn _pool, _messages, _opts -> {:error, :no_workers_available} end do
        assert {:error, :no_workers_available} = Dispatcher.dispatch_stream([])
      end
    end

    test "returns error on generic failure" do
      with_mock Pool,
        stream_completion: fn _pool, _messages, _opts -> {:error, :connection_refused} end do
        assert {:error, :connection_refused} = Dispatcher.dispatch_stream([])
      end
    end
  end

  describe "dispatch_tools/3" do
    test "returns error when no provider specified" do
      assert {:error, :no_provider_specified} = Dispatcher.dispatch_tools([], [], [])
    end

    test "returns error when provider not found" do
      with_mock Registry, get: fn _registry, _name -> {:error, :not_found} end do
        result = Dispatcher.dispatch_tools([], [], provider: "missing-worker")
        assert {:error, {:provider_not_found, "missing-worker"}} = result
      end
    end
  end

  describe "health_status/0" do
    test "returns health map from pool" do
      health = %{"openai-primary" => :available}

      # Pool.health_status/1 has default arg pool \\ __MODULE__.
      # When called as Pool.health_status(), Elixir compiles a 0-arity wrapper that calls
      # Pool.health_status(Pool). Mock intercepts at the 1-arity level.
      # We also mock the 0-arity in case Mock intercepts at that level.
      with_mocks([
        {Pool, [],
         [
           health_status: fn _pool -> health end,
           health_status: fn -> health end
         ]}
      ]) do
        result = Dispatcher.health_status()
        assert is_map(result)
      end
    end

    test "returns health map when pool returns empty" do
      with_mocks([
        {Pool, [],
         [
           health_status: fn _pool -> %{} end,
           health_status: fn -> %{} end
         ]}
      ]) do
        result = Dispatcher.health_status()
        assert is_map(result)
      end
    end
  end

  describe "check_workers/0" do
    test "delegates to pool check_health cast" do
      # Pool.check_health/1 has default arg pool \\ __MODULE__.
      # Dispatcher.check_workers/0 calls Pool.check_health() which issues a GenServer.cast.
      # Mock both arities to intercept at either level.
      with_mocks([
        {Pool, [],
         [
           check_health: fn _pool -> :ok end,
           check_health: fn -> :ok end
         ]}
      ]) do
        result = Dispatcher.check_workers()
        assert result == :ok
      end
    end
  end
end
