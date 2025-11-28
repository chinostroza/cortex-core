# Ejemplo de uso de TavilyWorker
# Este ejemplo muestra cómo usar el nuevo Universal Service Gateway de Cortex

# Para ejecutar:
# mix run examples/tavily_search_example.exs

# Asegúrate de tener TAVILY_API_KEY en tu entorno:
# export TAVILY_API_KEY=tvly-...

alias CortexCore.Workers.Adapters.TavilyWorker
alias CortexCore.Workers.Registry

# 1. Crear worker de Tavily
tavily_worker = TavilyWorker.new(
  name: "tavily-example",
  api_keys: [System.get_env("TAVILY_API_KEY") || "demo-key"],
  timeout: 30_000
)

IO.puts("\n=== Tavily Worker Created ===")
IO.inspect(tavily_worker, label: "Worker")

# 2. Health check
IO.puts("\n=== Health Check ===")
case TavilyWorker.health_check(tavily_worker) do
  {:ok, status} ->
    IO.puts("✅ Worker is #{status}")

  {:error, reason} ->
    IO.puts("❌ Health check failed: #{inspect(reason)}")
end

# 3. Info del worker
IO.puts("\n=== Worker Info ===")
info = TavilyWorker.info(tavily_worker)
IO.inspect(info, label: "Info")

# 4. Realizar búsqueda
IO.puts("\n=== Executing Search ===")
search_params = %{
  query: "Elixir programming language benefits",
  max_results: 3,
  search_depth: "basic",
  include_answer: true
}

case TavilyWorker.call(tavily_worker, search_params, []) do
  {:ok, results} ->
    IO.puts("✅ Search successful!")
    IO.puts("\nQuery: #{results.query}")

    if results.answer do
      IO.puts("\n📝 Answer:")
      IO.puts(results.answer)
    end

    IO.puts("\n🔍 Results:")
    Enum.each(results.results, fn result ->
      IO.puts("\n  - #{result["title"]}")
      IO.puts("    URL: #{result["url"]}")
      content = String.slice(result["content"] || "", 0, 150)
      IO.puts("    #{content}...")
    end)

  {:error, reason} ->
    IO.puts("❌ Search failed: #{inspect(reason)}")
    IO.puts("\nMake sure you have set TAVILY_API_KEY environment variable")
    IO.puts("Get your key at: https://tavily.com")
end

# 5. Demostrar uso con Worker.invoke (API genérica)
IO.puts("\n=== Using Worker.invoke (Generic API) ===")
case CortexCore.Workers.Worker.invoke(tavily_worker, search_params, []) do
  {:ok, results} ->
    IO.puts("✅ Generic invoke successful! Found #{length(results.results)} results")

  {:error, reason} ->
    IO.puts("❌ Invoke failed: #{inspect(reason)}")
end

IO.puts("\n=== Example Complete ===\n")
