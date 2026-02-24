defmodule CortexCore.Workers.RegistryTest do
  use ExUnit.Case
  alias CortexCore.Workers.Registry

  setup do
    registry_name = :"test_registry_#{:rand.uniform(10000)}"
    {:ok, registry} = Registry.start_link(name: registry_name)

    on_exit(fn ->
      if Process.alive?(registry), do: Process.exit(registry, :normal)
    end)

    {:ok, registry: registry}
  end

  describe "register/3" do
    test "registers a worker successfully", %{registry: registry} do
      worker = %{name: "test_worker", type: :openai}

      assert :ok = Registry.register(registry, "test_worker", worker)

      # Verify registration - Registry.list_all returns only workers, not {name, worker} tuples
      workers = Registry.list_all(registry)
      assert length(workers) == 1
      assert worker in workers
    end

    test "allows multiple workers with different names", %{registry: registry} do
      worker1 = %{name: "worker1", type: :openai}
      worker2 = %{name: "worker2", type: :anthropic}

      assert :ok = Registry.register(registry, "worker1", worker1)
      assert :ok = Registry.register(registry, "worker2", worker2)

      workers = Registry.list_all(registry)
      assert length(workers) == 2
      assert worker1 in workers
      assert worker2 in workers
    end

    test "does not allow duplicate worker names", %{registry: registry} do
      worker1 = %{name: "test_worker", type: :openai}
      worker2 = %{name: "test_worker", type: :anthropic}

      assert :ok = Registry.register(registry, "test_worker", worker1)
      assert {:error, :already_registered} = Registry.register(registry, "test_worker", worker2)

      workers = Registry.list_all(registry)
      assert length(workers) == 1
      assert worker1 in workers
    end
  end

  describe "unregister/2" do
    test "unregisters a worker successfully", %{registry: registry} do
      worker = %{name: "test_worker", type: :openai}
      Registry.register(registry, "test_worker", worker)

      assert :ok = Registry.unregister(registry, "test_worker")

      workers = Registry.list_all(registry)
      assert workers == []
    end

    test "returns ok even if worker doesn't exist", %{registry: registry} do
      assert :ok = Registry.unregister(registry, "nonexistent_worker")
    end
  end

  describe "list_all/1" do
    test "returns empty list when no workers registered", %{registry: registry} do
      assert [] = Registry.list_all(registry)
    end

    test "returns all registered workers", %{registry: registry} do
      worker1 = %{name: "worker1", type: :openai}
      worker2 = %{name: "worker2", type: :anthropic}

      Registry.register(registry, "worker1", worker1)
      Registry.register(registry, "worker2", worker2)

      workers = Registry.list_all(registry)
      assert length(workers) == 2
      assert worker1 in workers
      assert worker2 in workers
    end
  end

  describe "get/2" do
    test "returns worker when it exists", %{registry: registry} do
      worker = %{name: "test_worker", type: :openai}
      Registry.register(registry, "test_worker", worker)

      assert {:ok, ^worker} = Registry.get(registry, "test_worker")
    end

    test "returns error when worker doesn't exist", %{registry: registry} do
      assert {:error, :not_found} = Registry.get(registry, "nonexistent")
    end
  end

  describe "count/1" do
    test "returns 0 when no workers registered", %{registry: registry} do
      assert 0 = Registry.count(registry)
    end

    test "returns correct count after registrations", %{registry: registry} do
      worker1 = %{name: "worker1", type: :openai}
      worker2 = %{name: "worker2", type: :anthropic}

      Registry.register(registry, "worker1", worker1)
      assert 1 = Registry.count(registry)

      Registry.register(registry, "worker2", worker2)
      assert 2 = Registry.count(registry)
    end

    test "decreases count after unregister", %{registry: registry} do
      worker = %{name: "worker1", type: :openai}
      Registry.register(registry, "worker1", worker)
      assert 1 = Registry.count(registry)

      Registry.unregister(registry, "worker1")
      assert 0 = Registry.count(registry)
    end
  end

  describe "list_by_type/2" do
    # list_by_type calls worker.__struct__.info(worker) to get the type,
    # so we need workers that are real structs with a proper info/1 function.
    # We use the real pool_test-style test workers defined locally.
    defmodule TypedWorker do
      @moduledoc false
      @behaviour CortexCore.Workers.Worker
      defstruct [:name, :type]
      def service_type, do: :search
      def health_check(_), do: {:ok, :available}
      def info(w), do: %{name: w.name, type: w.type}
      def priority(_), do: 10
    end

    test "returns empty list when no workers of type", %{registry: registry} do
      assert [] = Registry.list_by_type(registry, :openai)
    end

    test "returns only workers of the given type", %{registry: registry} do
      w1 = %TypedWorker{name: "w1", type: :search}
      w2 = %TypedWorker{name: "w2", type: :llm}

      Registry.register(registry, "w1", w1)
      Registry.register(registry, "w2", w2)

      search_workers = Registry.list_by_type(registry, :search)
      assert length(search_workers) == 1
      assert w1 in search_workers

      llm_workers = Registry.list_by_type(registry, :llm)
      assert length(llm_workers) == 1
      assert w2 in llm_workers
    end

    test "returns empty list for type with no registered workers", %{registry: registry} do
      w1 = %TypedWorker{name: "w1", type: :search}
      Registry.register(registry, "w1", w1)

      assert [] = Registry.list_by_type(registry, :audio)
    end
  end
end
