defmodule CortexCore.TestHelpers do
  @moduledoc """
  Helper functions and mocks for tests
  """
  
  import Mock
  
  def mock_registry do
    [
      {CortexCore.Workers.Registry, [:passthrough], [
        start_link: fn _opts -> {:ok, self()} end,
        register: fn _registry, _name, worker -> {:ok, worker} end,
        register: fn _name, worker -> {:ok, worker} end,
        unregister: fn _registry, _name -> :ok end,
        unregister: fn _name -> :ok end,
        get: fn _registry, name -> 
          {:ok, %{
            name: name,
            type: :mock,
            api_keys: ["test_key"],
            current_key_index: 0,
            default_model: "mock-model",
            timeout: 30_000
          }}
        end,
        get: fn name -> 
          {:ok, %{
            name: name,
            type: :mock,
            api_keys: ["test_key"],
            current_key_index: 0,
            default_model: "mock-model",
            timeout: 30_000
          }}
        end,
        list_all: fn _registry -> [] end,
        list_all: fn -> [] end,
        list_by_type: fn _registry, _type -> [] end,
        list_by_type: fn _type -> [] end,
        count: fn _registry -> 0 end,
        count: fn -> 0 end
      ]}
    ]
  end
  
  def mock_pool do
    [
      {CortexCore.Workers.Pool, [:passthrough], [
        start_link: fn _opts -> 
          # Return a mock PID but don't send async messages
          {:ok, self()} 
        end,
        stream_completion: fn _pool, _messages, _opts -> 
          {:ok, Stream.cycle(["Mocked response"])}
        end,
        stream_completion: fn _messages, _opts -> 
          {:ok, Stream.cycle(["Mocked response"])}
        end,
        stream_completion: fn _messages -> 
          {:ok, Stream.cycle(["Mocked response"])}
        end,
        health_status: fn _pool -> 
          %{workers: [], strategy: :round_robin, healthy: [], unhealthy: [], total: 0}
        end,
        health_status: fn -> 
          %{workers: [], strategy: :round_robin, healthy: [], unhealthy: [], total: 0}
        end,
        check_health: fn _pool -> :ok end,
        check_health: fn -> :ok end
      ]},
      # Also mock the Supervisor to avoid async worker configuration
      {CortexCore.Workers.Supervisor, [:passthrough], [
        configure_initial_workers: fn _registry -> :ok end
      ]}
    ]
  end
  
  def mock_api_key_manager do
    [
      {CortexCore.Workers.APIKeyManager, [:passthrough], [
        start_link: fn _opts -> {:ok, self()} end,
        get_next_key: fn _manager, worker -> 
          # Use random for workers with 5+ keys (random strategy test), deterministic otherwise
          new_index = if length(worker.api_keys) >= 5 do
            :rand.uniform(length(worker.api_keys)) - 1
          else
            rem(worker.current_key_index + 1, length(worker.api_keys))
          end
          {:ok, %{worker | current_key_index: new_index}}
        end,
        report_rate_limit: fn _manager, _worker -> :ok end,
        report_success: fn _manager, _worker -> :ok end,
        get_stats: fn _manager -> 
          %{
            worker_name: "test_worker",
            rotation_strategy: :round_robin,
            blocked_keys: %{0 => true},  # Simulate blocked key
            usage_stats: %{0 => %{success_count: 1}}  # Simulate usage
          }
        end
      ]}
    ]
  end
  
  def mock_basic_dependencies do
    mock_registry() ++ mock_pool() ++ mock_api_key_manager()
  end
  
  def with_mocked_dependencies(fun) do
    with_mocks mock_basic_dependencies() do
      fun.()
    end
  end
  
  def with_mocked_api_key_manager(fun) do
    with_mocks mock_api_key_manager() do
      fun.()
    end
  end
  
  # Mock HTTP client para tests de health check
  defmodule MockHTTPClient do
    def get(_url, _opts) do
      {:error, :timeout}
    end
    
    def post(_url, _opts) do
      {:error, :timeout} 
    end
  end
  
  defmodule ErrorHTTPClient do
    def get(_url, _opts) do
      {:ok, %{status: 500, body: "Internal Server Error"}}
    end
    
    def post(_url, _opts) do
      {:ok, %{status: 500, body: "Internal Server Error"}}
    end
  end
  
  defmodule SuccessHTTPClient do
    def get(_url, _opts) do
      {:ok, %{status: 200, body: ~s({"data": [{"id": "gpt-4"}]})}}
    end
    
    def post(_url, _opts) do
      {:ok, %{status: 200, body: ~s({"id": "msg_test"})}}
    end
  end
end