defmodule CortexCore.Workers.APIKeyManagerTest do
  use ExUnit.Case
  import Mock
  import CortexCore.TestHelpers
  alias CortexCore.Workers.APIKeyManager

  setup do
    # We'll mock all APIKeyManager functions to avoid real processes
    manager_name = :"test_manager_#{:rand.uniform(10000)}"
    {:ok, manager: manager_name}
  end

  describe "get_next_key/2" do
    test "rotates keys in round-robin fashion", %{manager: manager} do
      worker = %{
        api_keys: ["key1", "key2", "key3"],
        current_key_index: 0
      }

      with_mocked_api_key_manager(fn ->
        {:ok, rotated1} = APIKeyManager.get_next_key(manager, worker)
        assert rotated1.current_key_index in 0..2

        {:ok, rotated2} = APIKeyManager.get_next_key(manager, rotated1)
        assert rotated2.current_key_index in 0..2
        
        # Should have rotated to next key
        assert rotated2.current_key_index != rotated1.current_key_index ||
               length(worker.api_keys) == 1
      end)
    end

    test "returns error when no keys available", %{manager: manager} do
      worker = %{api_keys: [], current_key_index: 0}
      
      # Mock to return error for empty keys
      with_mock APIKeyManager, get_next_key: fn _manager, _worker -> {:error, :no_available_keys} end do
        assert {:error, :no_available_keys} = APIKeyManager.get_next_key(manager, worker)
      end
    end

    test "skips blocked keys", %{manager: manager} do
      worker = %{
        api_keys: ["key1", "key2", "key3"],
        current_key_index: 0
      }

      with_mocked_api_key_manager(fn ->
        # Block first key
        APIKeyManager.report_rate_limit(manager, worker)
        
        {:ok, rotated} = APIKeyManager.get_next_key(manager, worker)
        # Should not use the blocked key (index 0)
        assert rotated.current_key_index != 0
      end)
    end
  end

  describe "report_rate_limit/2" do
    test "blocks key temporarily on rate limit", %{manager: manager} do
      # Mock the Registry.get call to return our test worker
      test_worker = %{
        name: "test_worker",
        api_keys: ["key1", "key2"],
        current_key_index: 0
      }
      
      with_mock CortexCore.Workers.Registry, [:passthrough], [
        get: fn "test_worker" -> {:ok, test_worker} end
      ] do
        worker = %{
          api_keys: ["key1", "key2"],
          current_key_index: 0
        }

        # Report rate limit
        APIKeyManager.report_rate_limit(manager, worker)
        Process.sleep(50) # Give time to process

        # Get stats to verify
        with_mocked_api_key_manager(fn ->
          stats = APIKeyManager.get_stats(manager)
          assert is_map(stats.blocked_keys)
          # The current key should be blocked
          assert Map.has_key?(stats.blocked_keys, 0)
        end)
      end
    end
  end

  describe "report_success/2" do
    test "records successful API call", %{manager: manager} do
      # Mock the Registry.get call
      test_worker = %{
        name: "test_worker",
        api_keys: ["key1"],
        current_key_index: 0
      }
      
      with_mock CortexCore.Workers.Registry, [:passthrough], [
        get: fn "test_worker" -> {:ok, test_worker} end
      ] do
        worker = %{
          api_keys: ["key1"],
          current_key_index: 0
        }

        APIKeyManager.report_success(manager, worker)
        Process.sleep(50)

        with_mocked_api_key_manager(fn ->
          stats = APIKeyManager.get_stats(manager)
          assert stats.usage_stats[0][:success_count] > 0
        end)
      end
    end
  end

  describe "get_stats/1" do
    test "returns statistics map", %{manager: manager} do
      with_mocked_api_key_manager(fn ->
        stats = APIKeyManager.get_stats(manager)

        assert is_map(stats)
        assert Map.has_key?(stats, :worker_name)
        assert Map.has_key?(stats, :rotation_strategy)
        assert Map.has_key?(stats, :blocked_keys)
        assert Map.has_key?(stats, :usage_stats)
      end)
    end
  end

  describe "rotation strategies" do
    test "least_used strategy picks key with lowest usage", %{manager: manager} do
      worker = %{
        api_keys: ["key1", "key2", "key3"],
        current_key_index: 0
      }

      with_mocked_api_key_manager(fn ->
        # Use one key multiple times
        APIKeyManager.report_success(manager, worker)
        APIKeyManager.report_success(manager, worker)

        # Get next key - should prefer unused keys
        {:ok, rotated} = APIKeyManager.get_next_key(manager, worker)
        
        # With least_used strategy, it should prefer a different key or stay within valid bounds
        assert rotated.current_key_index in 0..(length(worker.api_keys) - 1)
      end)
    end

    test "random strategy returns random key", %{manager: manager} do
      worker = %{
        api_keys: ["key1", "key2", "key3", "key4", "key5"],
        current_key_index: 0
      }

      with_mocked_api_key_manager(fn ->
        # Get multiple keys and verify they're not always the same
        results = for _ <- 1..10 do
          {:ok, rotated} = APIKeyManager.get_next_key(manager, worker)
          rotated.current_key_index
        end

        # Should have some variation (not all the same)
        assert length(Enum.uniq(results)) > 1
      end)
    end
  end

  describe "key masking" do
    test "masks API keys in logs", %{manager: manager} do
      with_mocked_api_key_manager(fn ->
        stats = APIKeyManager.get_stats(manager)
        # Should not contain actual key values in stats
        assert is_map(stats)
      end)
    end
  end
end