# Ejemplo de uso del Universal Service Gateway
# Demuestra cómo usar diferentes tipos de servicios con la misma API unificada
#
# Para ejecutar:
# export TAVILY_API_KEY=tvly-tu-key-aqui
# mix run examples/universal_gateway_example.exs

IO.puts("\n=== Universal Service Gateway Demo ===\n")

# 1. Iniciar CortexCore
IO.puts("📡 Iniciando CortexCore...")
{:ok, _pid} = CortexCore.start_link()

# Esperar a que se configuren los workers (asíncrono)
Process.sleep(5000)

IO.puts("\n=== Workers Configurados ===")
workers = CortexCore.list_workers()

IO.puts("Total workers: #{length(workers)}")
Enum.each(workers, fn worker_info ->
  service_type = worker_info[:type] || worker_info[:service] || "unknown"
  IO.puts("  • #{worker_info[:name]} (#{service_type})")
end)

# 2. Health Status
IO.puts("\n=== Health Status ===")
health = CortexCore.health_status()
Enum.each(health, fn {name, status} ->
  emoji = case status do
    :available -> "✅"
    :unavailable -> "❌"
    _ -> "⚠️"
  end
  IO.puts("#{emoji} #{name}: #{status}")
end)

# 3. Búsqueda web con Tavily (si está configurado)
IO.puts("\n=== Web Search con Universal Gateway ===")
case CortexCore.call(:search, %{
  query: "Elixir programming language advantages",
  max_results: 3,
  search_depth: "basic",
  include_answer: true
}) do
  {:ok, results} ->
    IO.puts("✅ Búsqueda exitosa!")
    IO.puts("\nQuery: #{results.query}")

    if results.answer do
      IO.puts("\n📝 Respuesta generada:")
      IO.puts(results.answer)
    end

    IO.puts("\n🔍 Resultados (#{length(results.results)}):")
    Enum.each(results.results, fn result ->
      IO.puts("\n  • #{result["title"]}")
      IO.puts("    URL: #{result["url"]}")
      content = String.slice(result["content"] || "", 0, 100)
      IO.puts("    #{content}...")
    end)

  {:error, :no_workers_available} ->
    IO.puts("⚠️  No hay workers de búsqueda disponibles")
    IO.puts("   Configura TAVILY_API_KEY para habilitar búsqueda web")

  {:error, reason} ->
    IO.puts("❌ Error en búsqueda: #{inspect(reason)}")
end

# 4. Comparación con LLM (si está configurado)
IO.puts("\n=== LLM Chat (backward compatibility) ===")
case CortexCore.chat([
  %{role: "user", content: "Di 'hola' en una palabra"}
]) do
  {:ok, stream} ->
    IO.write("🤖 Respuesta: ")
    stream |> Enum.take(50) |> Enum.each(&IO.write/1)
    IO.puts("\n")

  {:error, :no_workers_available} ->
    IO.puts("⚠️  No hay LLM workers disponibles")
    IO.puts("   Configura OPENAI_API_KEYS, ANTHROPIC_API_KEYS, etc.")
end

IO.puts("\n=== Demo Complete ===")
IO.puts("""

💡 Universal Service Gateway permite usar múltiples servicios con la misma API:

   # Búsqueda web
   CortexCore.call(:search, %{query: "..."})

   # Text-to-speech (cuando se implemente)
   CortexCore.call(:audio, %{text: "...", voice: "adam"})

   # Image generation (cuando se implemente)
   CortexCore.call(:vision, %{prompt: "..."})

   # LLMs (API existente sigue funcionando)
   CortexCore.chat(messages)

Todos comparten: failover, health checks, API key rotation, retry logic 🚀
""")
