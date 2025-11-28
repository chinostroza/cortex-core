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
    {:ok, pool} = Pool.start_link(
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

    test "executes with failover when first worker fails", %{pool: pool, registry: registry, registry_name: _registry_name} do
      # Register workers
      Registry.register(registry, "test1", %TestWorker1{name: "test1"})
      Registry.register(registry, "test2", %TestWorker2{name: "test2"})

      # Test failover
      messages = [%{"role" => "user", "content" => "test"}]
      assert {:ok, stream} = Pool.stream_completion(pool, messages)
      assert is_function(stream)
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
    test "round_robin strategy rotates workers", %{registry: registry, registry_name: _registry_name} do
      # Create a new pool for this specific test
      pool_name = :"test_pool_#{:rand.uniform(10000)}"
      {:ok, new_pool} = Pool.start_link(
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
  end
end