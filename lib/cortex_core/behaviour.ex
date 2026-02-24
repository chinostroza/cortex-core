defmodule CortexCore.Behaviour do
  @moduledoc """
  Defines the public contract for CortexCore, allowing Mox-based mocking in tests.
  """

  @callback chat(messages :: list(), opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @callback call(service_type :: atom(), params :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback call_with_tools(messages :: list(), tools :: list(), opts :: keyword()) ::
              {:ok, list(map())} | {:error, term()}

  @callback health_status() :: map()

  @callback list_workers() :: list(map())
end
