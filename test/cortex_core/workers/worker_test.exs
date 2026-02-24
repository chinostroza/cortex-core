defmodule CortexCore.Workers.WorkerTest do
  use ExUnit.Case

  alias CortexCore.Workers.Worker

  # A worker that implements call/3 (non-LLM style)
  defmodule CallWorker do
    @moduledoc false
    @behaviour CortexCore.Workers.Worker
    defstruct [:name]
    def service_type, do: :search
    def health_check(_worker), do: {:ok, :available}
    def call(worker, params, opts), do: {:ok, %{worker: worker.name, params: params, opts: opts}}
    def info(worker), do: %{name: worker.name, type: :search}
    def priority(_worker), do: 50
  end

  # A worker that implements stream_completion/3 (LLM style)
  defmodule StreamWorker do
    @moduledoc false
    @behaviour CortexCore.Workers.Worker
    defstruct [:name]
    def service_type, do: :llm
    def health_check(_worker), do: {:ok, :available}

    def stream_completion(_worker, messages, _opts),
      do: {:ok, Stream.map(messages, fn m -> m[:content] || "" end)}

    def info(worker), do: %{name: worker.name, type: :llm}
    def priority(_worker), do: 50
  end

  # A worker that implements neither call/3 nor stream_completion/3
  defmodule MinimalWorker do
    @moduledoc false
    @behaviour CortexCore.Workers.Worker
    defstruct [:name]
    def service_type, do: :custom
    def health_check(_worker), do: {:ok, :available}
    def info(worker), do: %{name: worker.name, type: :custom}
    def priority(_worker), do: 50
  end

  describe "supports_streaming?/1" do
    test "returns true for StreamWorker which implements stream_completion/3" do
      assert Worker.supports_streaming?(StreamWorker)
    end

    test "returns false for CallWorker which does not implement stream_completion/3" do
      refute Worker.supports_streaming?(CallWorker)
    end

    test "returns false for MinimalWorker which implements neither" do
      refute Worker.supports_streaming?(MinimalWorker)
    end
  end

  describe "invoke/3" do
    test "uses call/3 when worker module implements it" do
      worker = %CallWorker{name: "call-worker"}
      assert {:ok, result} = Worker.invoke(worker, %{action: "test"}, [])
      assert result.worker == "call-worker"
      assert result.params == %{action: "test"}
    end

    test "call/3 result includes opts" do
      worker = %CallWorker{name: "call-worker"}
      assert {:ok, result} = Worker.invoke(worker, %{q: "x"}, timeout: 5000)
      assert result.opts == [timeout: 5000]
    end

    test "uses stream_completion/3 when worker has :messages key in params" do
      worker = %StreamWorker{name: "stream-worker"}
      messages = [%{role: "user", content: "hi"}]
      assert {:ok, stream} = Worker.invoke(worker, %{messages: messages}, [])
      # stream should be an enumerable
      result = Enum.to_list(stream)
      assert result == ["hi"]
    end

    test "returns unsupported_operation when worker has no call or stream and no messages" do
      worker = %MinimalWorker{name: "minimal-worker"}
      assert {:error, :unsupported_operation} = Worker.invoke(worker, %{}, [])
    end

    test "returns unsupported_operation when StreamWorker params has no :messages key" do
      worker = %StreamWorker{name: "stream-worker"}
      # StreamWorker has stream_completion but params has no :messages key
      assert {:error, :unsupported_operation} = Worker.invoke(worker, %{query: "test"}, [])
    end

    test "returns unsupported_operation for MinimalWorker even with messages key" do
      worker = %MinimalWorker{name: "minimal-worker"}
      # MinimalWorker has no stream_completion and no call → always unsupported
      assert {:error, :unsupported_operation} =
               Worker.invoke(worker, %{messages: [%{role: "user", content: "hi"}]}, [])
    end
  end
end
