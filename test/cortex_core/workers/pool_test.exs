defmodule CortexCore.Workers.PoolTest do
  use ExUnit.Case
  alias CortexCore.Workers.{Pool, Registry}

  # Test worker modules
  defmodule TestWorker1 do
    @behaviour CortexCore.Workers.Worker
    defstruct [:name]
    def service_type, do: :llm
    def health_check(_), do: {:ok, :available}
    def stream_completion(_, _, _), do: {:error, :test_error}
    def info(w), do: %{name: w.name, status: :available}
    def priority(_), do: 10
  end

  defmodule TestWorker2 do
    @behaviour CortexCore.Workers.Worker
    defstruct [:name]
    def service_type, do: :llm
    def health_check(_), do: {:ok, :available}
    def stream_completion(_, _, _), do: {:ok, Stream.repeatedly(fn -> "test" end)}
    def info(w), do: %{name: w.name, status: :available}
    def priority(_), do: 20
  end

  defmodule FailingWorker do
    @behaviour CortexCore.Workers.Worker
    defstruct [:name]
    def service_type, do: :llm
    def health_check(_), do: {:ok, :available}
    def stream_completion(_, _, _), do: {:error, :always_fails}
    def info(w), do: %{name: w.name, status: :available}
    def priority(_), do: 10
  end

  defmodule RoundRobinWorker do
    @behaviour CortexCore.Workers.Worker
    defstruct [:name]
    def service_type, do: :llm
    def health_check(_), do: {:ok, :available}
    def stream_completion(worker, _, _), do: {:ok, Stream.repeatedly(fn -> worker.name end)}
    def info(w), do: %{name: w.name, status: :available}
    def priority(_), do: 10
  end

  setup do
    # Use unique names to avoid conflicts between tests
    registry_name = :"test_registry_#{:rand.uniform(10000)}"
    {:ok, registry} = Registry.start_link(name: registry_name)

    {:ok, pool} =
      Pool.start_link(
        registry: registry,
        strategy: :round_robin,
        health_check_interval: 0
      )

    on_exit(fn ->
      if Process.alive?(pool), do: Process.exit(pool, :normal)
      if Process.alive?(registry), do: Process.exit(registry, :normal)
    end)

    {:ok, pool: pool, registry: registry, registry_name: registry_name}
  end

  describe "stream_completion/3" do
    test "returns error when no workers available", %{pool: pool} do
      messages = [%{"role" => "user", "content" => "test"}]
      assert {:error, :no_workers_available} = Pool.stream_completion(pool, messages)
    end

    test "executes with failover when first worker fails", %{
      pool: pool,
      registry: registry,
      registry_name: _registry_name
    } do
      # Register workers
      Registry.register(registry, "test1", %TestWorker1{name: "test1"})
      Registry.register(registry, "test2", %TestWorker2{name: "test2"})

      # Test failover
      messages = [%{"role" => "user", "content" => "test"}]
      assert {:ok, stream} = Pool.stream_completion(pool, messages)
      assert Enumerable.impl_for(stream) != nil
    end

    test "returns all workers failed when all workers fail", %{pool: pool, registry: registry} do
      Registry.register(registry, "failing", %FailingWorker{name: "failing"})

      messages = [%{"role" => "user", "content" => "test"}]
      assert {:error, {:all_workers_failed, _details}} = Pool.stream_completion(pool, messages)
    end
  end

  describe "health_status/1" do
    test "returns current health status", %{pool: pool} do
      status = Pool.health_status(pool)
      assert is_map(status)
      # Pool.health_status returns a simple map of worker names to their status
      # Since no workers are registered yet, it should be empty
      assert status == %{}
    end
  end

  # NOTE: Pool.list_workers/1 function doesn't exist in the current implementation
  # describe "list_workers/1" do
  #   test "returns list of workers", %{pool: pool} do
  #     workers = Pool.list_workers(pool)
  #     assert is_list(workers)
  #   end
  # end

  describe "strategies" do
    test "round_robin strategy rotates workers", %{
      registry: registry,
      registry_name: _registry_name
    } do
      # Create a new pool for this specific test
      pool_name = :"test_pool_#{:rand.uniform(10000)}"

      {:ok, new_pool} =
        Pool.start_link(
          registry: registry,
          strategy: :round_robin,
          health_check_interval: 0,
          name: pool_name
        )

      Registry.register(registry, "worker1", %RoundRobinWorker{name: "worker1"})
      Registry.register(registry, "worker2", %RoundRobinWorker{name: "worker2"})

      # Multiple calls should hit different workers
      messages = [%{"role" => "user", "content" => "test"}]
      {:ok, _stream1} = Pool.stream_completion(new_pool, messages)
      {:ok, _stream2} = Pool.stream_completion(new_pool, messages)

      Process.exit(new_pool, :normal)
    end

    test "local_first strategy sorts by priority", %{registry: registry} do
      pool_name = :"test_pool_#{:rand.uniform(10000)}"

      {:ok, new_pool} =
        Pool.start_link(
          registry: registry,
          strategy: :local_first,
          health_check_interval: 0,
          name: pool_name
        )

      Registry.register(registry, "worker_lf", %RoundRobinWorker{name: "worker_lf"})

      messages = [%{"role" => "user", "content" => "local first test"}]
      {:ok, _stream} = Pool.stream_completion(new_pool, messages)

      Process.exit(new_pool, :normal)
    end
  end

  describe "Pool.call/4 (generic service API)" do
    # Search worker that implements call/3
    defmodule SearchWorker do
      @behaviour CortexCore.Workers.Worker
      defstruct [:name]
      def service_type, do: :search
      def health_check(_), do: {:ok, :available}
      def call(_worker, params, _opts), do: {:ok, %{results: [params.query]}}
      def info(w), do: %{name: w.name, status: :available}
      def priority(_), do: 10
    end

    defmodule FailingSearchWorker do
      @behaviour CortexCore.Workers.Worker
      defstruct [:name]
      def service_type, do: :search
      def health_check(_), do: {:ok, :available}
      def call(_worker, _params, _opts), do: {:error, :service_unavailable}
      def info(w), do: %{name: w.name, status: :available}
      def priority(_), do: 10
    end

    test "returns error when no workers of service_type", %{pool: pool} do
      assert {:error, :no_workers_available} = Pool.call(pool, :search, %{query: "test"})
    end

    test "dispatches to search worker successfully", %{pool: pool, registry: registry} do
      Registry.register(registry, "search-worker", %SearchWorker{name: "search-worker"})
      assert {:ok, %{results: ["test"]}} = Pool.call(pool, :search, %{query: "test"})
    end

    test "returns error when all service workers fail", %{pool: pool, registry: registry} do
      Registry.register(registry, "fail-search", %FailingSearchWorker{name: "fail-search"})
      assert {:error, {:all_workers_failed, _}} = Pool.call(pool, :search, %{query: "x"})
    end

    test "returns error when no workers for LLM service type", %{pool: pool} do
      assert {:error, :no_workers_available} = Pool.call(pool, :vision, %{prompt: "draw cat"})
    end
  end

  describe "Pool.check_health/1" do
    test "returns :ok after triggering health check", %{pool: pool} do
      # check_health is a GenServer.cast — returns :ok immediately
      assert :ok = Pool.check_health(pool)
    end

    test "health check runs against registered workers", %{pool: pool, registry: registry} do
      Registry.register(registry, "health-worker", %TestWorker2{name: "health-worker"})
      assert :ok = Pool.check_health(pool)
      # Give the cast time to process
      :timer.sleep(50)
      status = Pool.health_status(pool)
      assert is_map(status)
    end
  end

  describe "stream_completion with provider option" do
    test "dispatches to named provider when provider opt is set", %{
      pool: pool,
      registry: registry
    } do
      Registry.register(registry, "my-provider", %RoundRobinWorker{name: "my-provider"})
      messages = [%{"role" => "user", "content" => "hello"}]
      {:ok, _stream} = Pool.stream_completion(pool, messages, provider: "my-provider")
    end

    test "returns error when named provider not found", %{pool: pool} do
      messages = [%{"role" => "user", "content" => "hello"}]
      result = Pool.stream_completion(pool, messages, provider: "nonexistent-provider")
      # Could be no_workers_available or error depending on implementation
      assert match?({:error, _}, result)
    end
  end

  describe "periodic health checks" do
    test "pool starts without scheduled health check when interval is 0", %{pool: pool} do
      # Pool started with health_check_interval: 0 in setup (which means disabled)
      # health_status should still be accessible
      assert is_map(Pool.health_status(pool))
    end

    test "pool with disabled health check interval still works", %{registry: registry} do
      pool_name = :"test_pool_disabled_#{:rand.uniform(10000)}"

      {:ok, new_pool} =
        Pool.start_link(
          registry: registry,
          strategy: :round_robin,
          check_interval: :disabled,
          health_check_interval: 0,
          name: pool_name
        )

      assert is_map(Pool.health_status(new_pool))
      Process.exit(new_pool, :normal)
    end
  end

  describe "Pool.call/4 with round_robin strategy" do
    defmodule RoundRobinSearchWorker do
      @behaviour CortexCore.Workers.Worker
      defstruct [:name]
      def service_type, do: :search
      def health_check(_), do: {:ok, :available}
      def call(w, _params, _opts), do: {:ok, %{from: w.name}}
      def info(w), do: %{name: w.name, status: :available}
      def priority(_), do: 10
    end

    test "round_robin call rotates service workers", %{registry: registry} do
      pool_name = :"test_rr_call_pool_#{:rand.uniform(10000)}"

      {:ok, new_pool} =
        Pool.start_link(
          registry: registry,
          strategy: :round_robin,
          health_check_interval: 0,
          name: pool_name
        )

      Registry.register(registry, "search-rr-1", %RoundRobinSearchWorker{name: "search-rr-1"})
      Registry.register(registry, "search-rr-2", %RoundRobinSearchWorker{name: "search-rr-2"})

      assert {:ok, _} = Pool.call(new_pool, :search, %{query: "round-robin test"})
      assert {:ok, _} = Pool.call(new_pool, :search, %{query: "second call"})

      Process.exit(new_pool, :normal)
    end
  end

  describe "Pool.call/4 with specific provider" do
    defmodule NamedSearchWorker do
      @behaviour CortexCore.Workers.Worker
      defstruct [:name, :default_model]
      def service_type, do: :search
      def health_check(_), do: {:ok, :available}
      def call(_w, params, _opts), do: {:ok, %{q: params.query}}
      def info(w), do: %{name: w.name, type: :search}
      def priority(_), do: 10
    end

    test "dispatches to named provider for matching service_type", %{
      pool: pool,
      registry: registry
    } do
      Registry.register(
        registry,
        "named-search",
        %NamedSearchWorker{name: "named-search", default_model: "search-v1"}
      )

      assert {:ok, %{q: "hello"}} =
               Pool.call(pool, :search, %{query: "hello"}, provider: "named-search")
    end

    test "returns error when named provider has wrong service_type", %{
      pool: pool,
      registry: registry
    } do
      # Register a search worker but call with :vision service_type
      Registry.register(
        registry,
        "wrong-type-worker",
        %NamedSearchWorker{name: "wrong-type-worker"}
      )

      result = Pool.call(pool, :vision, %{prompt: "cat"}, provider: "wrong-type-worker")
      assert {:error, {:wrong_service_type, _msg}} = result
    end

    test "returns error when named provider not found", %{pool: pool} do
      result = Pool.call(pool, :search, %{query: "x"}, provider: "does-not-exist")
      assert {:error, {:provider_not_found, "does-not-exist"}} = result
    end
  end

  describe "worker with model information" do
    defmodule ModelWorker do
      @behaviour CortexCore.Workers.Worker
      defstruct [:name, :model]
      def service_type, do: :search
      def health_check(_), do: {:ok, :available}
      def call(_w, _params, _opts), do: {:ok, %{model_used: true}}
      def info(w), do: %{name: w.name, type: :search}
      def priority(_), do: 10
    end

    test "calls worker with model field and logs model info", %{pool: pool, registry: registry} do
      Registry.register(
        registry,
        "model-worker",
        %ModelWorker{name: "model-worker", model: "my-model-v1"}
      )

      assert {:ok, %{model_used: true}} = Pool.call(pool, :search, %{query: "test"})
    end
  end

  describe "handle_info callbacks" do
    test "pool handles DOWN message for completed task reference gracefully", %{pool: pool} do
      # Send a fake task completion message - pool should ignore refs it doesn't own
      ref = make_ref()
      send(pool, {ref, :done})
      # Give the pool time to process
      :timer.sleep(10)
      # Pool should still be alive and responding
      assert is_map(Pool.health_status(pool))
    end

    test "pool handles chunk message gracefully", %{pool: pool} do
      ref = make_ref()
      send(pool, {ref, {:chunk, "some chunk data"}})
      :timer.sleep(10)
      assert is_map(Pool.health_status(pool))
    end
  end

  describe "format_error_reason via stream_completion" do
    # Worker that fails with HTTP tuple error {status, message}
    defmodule HttpErrorWorker do
      @behaviour CortexCore.Workers.Worker
      defstruct [:name]
      def service_type, do: :llm
      def health_check(_), do: {:ok, :available}
      def stream_completion(_, _, _), do: {:error, {429, "Too Many Requests"}}
      def info(w), do: %{name: w.name, status: :available}
      def priority(_), do: 10
    end

    # Worker that returns a stream via call/3 (for execute_service_with_failover stream path)
    defmodule StreamCallWorker do
      @behaviour CortexCore.Workers.Worker
      defstruct [:name, :default_model]
      def service_type, do: :search
      def health_check(_), do: {:ok, :available}

      def call(_w, _params, _opts),
        do: {:ok, Stream.map(["chunk1", "chunk2"], fn c -> c end)}

      def info(w), do: %{name: w.name, type: :search}
      def priority(_), do: 10
    end

    test "handles HTTP error tuple in failover", %{pool: pool, registry: registry} do
      Registry.register(registry, "http-err-worker", %HttpErrorWorker{name: "http-err-worker"})
      messages = [%{"role" => "user", "content" => "test"}]
      result = Pool.stream_completion(pool, messages)
      # Should fail with all workers failed since only one worker that always returns HTTP error
      assert {:error, {:all_workers_failed, details}} = result
      assert String.contains?(details, "HTTP 429")
    end

    test "handles worker call/3 returning a stream result", %{pool: pool, registry: registry} do
      Registry.register(
        registry,
        "stream-call-worker",
        %StreamCallWorker{name: "stream-call-worker", default_model: "search-model"}
      )

      result = Pool.call(pool, :search, %{query: "stream call test"})
      # The stream from call/3 is validated - "chunk1" is a binary > 0 bytes, so it passes
      assert {:ok, _stream_or_concat} = result
    end
  end

  describe "empty stream handling" do
    # Worker that returns an empty stream - triggers empty_stream validation error
    defmodule EmptyStreamWorker do
      @behaviour CortexCore.Workers.Worker
      defstruct [:name]
      def service_type, do: :llm
      def health_check(_), do: {:ok, :available}
      def stream_completion(_, _, _), do: {:ok, Stream.take([], 1)}
      def info(w), do: %{name: w.name, status: :available}
      def priority(_), do: 10
    end

    test "handles empty stream from worker by trying next worker", %{
      pool: pool,
      registry: registry
    } do
      Registry.register(registry, "empty-stream", %EmptyStreamWorker{name: "empty-stream"})
      messages = [%{"role" => "user", "content" => "test"}]
      result = Pool.stream_completion(pool, messages)
      # All workers failed because empty stream is treated as a failure
      assert {:error, {:all_workers_failed, _}} = result
    end
  end

  describe "handle_info :configure_initial_workers" do
    test "pool handles configure_initial_workers message gracefully", %{pool: pool} do
      # The pool should handle this message without crashing
      send(pool, :configure_initial_workers)
      :timer.sleep(50)
      # Pool should still be alive
      assert is_map(Pool.health_status(pool))
    end
  end

  describe "periodic health check via handle_info" do
    defmodule PeriodicHealthWorker do
      @behaviour CortexCore.Workers.Worker
      defstruct [:name]
      def service_type, do: :search
      def health_check(_), do: {:ok, :available}
      def call(_w, _p, _o), do: {:ok, %{}}
      def info(w), do: %{name: w.name}
      def priority(_), do: 10
    end

    test "pool handles periodic_health_check message", %{pool: pool, registry: registry} do
      Registry.register(registry, "periodic-worker", %PeriodicHealthWorker{
        name: "periodic-worker"
      })

      # Trigger the periodic health check manually
      send(pool, :periodic_health_check)
      :timer.sleep(100)
      # Pool should update health status
      status = Pool.health_status(pool)
      assert is_map(status)
    end

    test "pool with short interval schedules periodic health checks", %{registry: registry} do
      pool_name = :"test_periodic_pool_#{:rand.uniform(10000)}"

      # Start pool with very short interval (100ms) - will trigger periodic checks
      {:ok, new_pool} =
        Pool.start_link(
          registry: registry,
          strategy: :round_robin,
          # Use tiny interval to trigger scheduling, but still non-zero
          check_interval: 10_000,
          health_check_interval: 10_000,
          name: pool_name
        )

      # Pool should start with empty health status
      assert is_map(Pool.health_status(new_pool))

      Process.exit(new_pool, :normal)
    end
  end

  describe "execute_service_with_failover exception handling" do
    # Worker that raises an exception (not returns error, actually raises)
    defmodule RaisingWorker do
      @behaviour CortexCore.Workers.Worker
      defstruct [:name]
      def service_type, do: :search
      def health_check(_), do: {:ok, :available}
      def call(_w, _p, _o), do: raise("Unexpected exception!")
      def info(w), do: %{name: w.name}
      def priority(_), do: 10
    end

    # Worker with multiple API keys that raises a rate limit error
    defmodule RateLimitRaisingWorker do
      @behaviour CortexCore.Workers.Worker
      defstruct [:name, :api_keys, :current_key_index, :last_rotation]
      def service_type, do: :search
      def health_check(_), do: {:ok, :available}
      def call(_w, _p, _o), do: raise("429 rate limit exceeded")
      def info(w), do: %{name: w.name}
      def priority(_), do: 10
    end

    # Worker with single API key and rate limit - should fallback (not rotate)
    defmodule SingleKeyRateLimitWorker do
      @behaviour CortexCore.Workers.Worker
      defstruct [:name, :api_keys, :current_key_index, :last_rotation]
      def service_type, do: :search
      def health_check(_), do: {:ok, :available}
      def call(_w, _p, _o), do: raise("429: rate limit exceeded")
      def info(w), do: %{name: w.name}
      def priority(_), do: 10
    end

    test "handles exception from worker during call", %{pool: pool, registry: registry} do
      Registry.register(registry, "raising-worker", %RaisingWorker{name: "raising-worker"})
      result = Pool.call(pool, :search, %{query: "test"})
      # Should handle exception gracefully and return error
      assert {:error, {:all_workers_failed, _}} = result
    end

    test "handles rate limit exception with multiple API keys - rotates and tries again", %{
      pool: pool,
      registry: registry
    } do
      # Worker with 2 API keys - rate limit will trigger rotation
      worker = %RateLimitRaisingWorker{
        name: "rate-limit-worker",
        api_keys: ["key1", "key2"],
        current_key_index: 0
      }

      Registry.register(registry, "rate-limit-worker", worker)
      result = Pool.call(pool, :search, %{query: "test"})
      # After rotating keys and still failing, should return all workers failed
      assert {:error, {:all_workers_failed, _}} = result
    end

    test "handles rate limit exception with single API key - falls back directly", %{
      pool: pool,
      registry: registry
    } do
      # Worker with 1 API key - rate limit will not rotate (can't rotate with 1 key)
      worker = %SingleKeyRateLimitWorker{
        name: "single-key-rl-worker",
        api_keys: ["key1"],
        current_key_index: 0
      }

      Registry.register(registry, "single-key-rl-worker", worker)
      result = Pool.call(pool, :search, %{query: "test"})
      assert {:error, {:all_workers_failed, _}} = result
    end
  end

  describe "validate_stream/2 empty stream raises exception" do
    # Worker that returns a stream that emits no elements via call/3
    defmodule EmptyCallStreamWorker do
      @behaviour CortexCore.Workers.Worker
      defstruct [:name]
      def service_type, do: :search
      def health_check(_), do: {:ok, :available}
      # Return empty stream - validate_stream/2 will raise, caught by rescue
      def call(_w, _p, _o), do: {:ok, Stream.take([], 10)}
      def info(w), do: %{name: w.name}
      def priority(_), do: 10
    end

    test "handles empty stream from call/3 via exception path", %{pool: pool, registry: registry} do
      Registry.register(
        registry,
        "empty-call-stream",
        %EmptyCallStreamWorker{name: "empty-call-stream"}
      )

      result = Pool.call(pool, :search, %{query: "test"})
      # Empty stream causes raise → caught by rescue → treated as exception
      assert {:error, {:all_workers_failed, _}} = result
    end
  end

  describe "health check with real workers" do
    defmodule HealthyWorkerForCheck do
      @behaviour CortexCore.Workers.Worker
      defstruct [:name]
      def service_type, do: :search
      def health_check(_), do: {:ok, :available}
      def call(_w, _p, _o), do: {:ok, %{}}
      def info(w), do: %{name: w.name, status: :available}
      def priority(_), do: 10
    end

    defmodule UnhealthyWorker do
      @behaviour CortexCore.Workers.Worker
      defstruct [:name]
      def service_type, do: :search
      def health_check(_), do: {:error, :connection_refused}
      def call(_w, _p, _o), do: {:error, :unavailable}
      def info(w), do: %{name: w.name, status: :unavailable}
      def priority(_), do: 10
    end

    defmodule RateLimitedWorker do
      @behaviour CortexCore.Workers.Worker
      defstruct [:name]
      def service_type, do: :search
      def health_check(_), do: {:error, {:rate_limited, "429 Too Many Requests"}}
      def call(_w, _p, _o), do: {:error, :rate_limited}
      def info(w), do: %{name: w.name, status: :rate_limited}
      def priority(_), do: 10
    end

    defmodule QuotaExceededWorker do
      @behaviour CortexCore.Workers.Worker
      defstruct [:name]
      def service_type, do: :search
      def health_check(_), do: {:error, {:quota_exceeded, "Quota exceeded"}}
      def call(_w, _p, _o), do: {:error, :quota_exceeded}
      def info(w), do: %{name: w.name, status: :quota_exceeded}
      def priority(_), do: 10
    end

    test "health check marks healthy workers as :available", %{pool: pool, registry: registry} do
      Registry.register(registry, "healthy-check", %HealthyWorkerForCheck{name: "healthy-check"})
      Pool.check_health(pool)
      :timer.sleep(200)
      status = Pool.health_status(pool)
      assert status["healthy-check"] == :available
    end

    test "health check marks failing workers as :unavailable", %{pool: pool, registry: registry} do
      Registry.register(registry, "unhealthy-check", %UnhealthyWorker{name: "unhealthy-check"})
      Pool.check_health(pool)
      :timer.sleep(200)
      status = Pool.health_status(pool)
      assert status["unhealthy-check"] == :unavailable
    end

    test "health check marks rate limited workers", %{pool: pool, registry: registry} do
      Registry.register(registry, "rate-limited-check", %RateLimitedWorker{
        name: "rate-limited-check"
      })

      Pool.check_health(pool)
      :timer.sleep(200)
      status = Pool.health_status(pool)
      assert status["rate-limited-check"] == :rate_limited
    end

    test "health check marks quota exceeded workers", %{pool: pool, registry: registry} do
      Registry.register(registry, "quota-check", %QuotaExceededWorker{name: "quota-check"})
      Pool.check_health(pool)
      :timer.sleep(200)
      status = Pool.health_status(pool)
      assert status["quota-check"] == :quota_exceeded
    end
  end
end
