#!/usr/bin/env elixir

# Multi-Provider Search Example with Automatic Failover
#
# This example demonstrates CortexCore's Universal Service Gateway
# for search, using multiple providers with priority-based failover.
#
# Priority order:
# 1. Serper (priority 10) - Google results, best quality
# 2. Brave (priority 15) - Privacy-focused, used by Anthropic
# 3. Tavily (priority 20) - AI-optimized search
# 4. DuckDuckGo (priority 30) - Free fallback, no API key needed
#
# Run with:
#   cd examples && elixir multi_search_example.exs

Mix.install([
  {:cortex_core, path: ".."},
  {:req, "~> 0.4"}
])

alias CortexCore.Workers.Adapters.{SerperWorker, BraveWorker, TavilyWorker, DuckDuckGoWorker}

# ============================================
# Configuration
# ============================================

# Get API keys from environment
serper_key = System.get_env("SERPER_API_KEY")
brave_key = System.get_env("BRAVE_API_KEY")
tavily_key = System.get_env("TAVILY_API_KEY")

# Create search workers with different priorities
workers = [
  # Serper: Highest priority (Google results)
  if serper_key do
    SerperWorker.new(
      name: "serper-primary",
      api_keys: [serper_key],
      timeout: 30_000
    )
  end,

  # Brave: High priority (privacy-focused, used by Anthropic)
  if brave_key do
    BraveWorker.new(
      name: "brave-primary",
      api_keys: [brave_key],
      timeout: 30_000
    )
  end,

  # Tavily: Medium priority (AI-optimized)
  if tavily_key do
    TavilyWorker.new(
      name: "tavily-primary",
      api_keys: [tavily_key],
      timeout: 30_000
    )
  end,

  # DuckDuckGo: Lowest priority (free fallback, always available)
  DuckDuckGoWorker.new(
    name: "duckduckgo-fallback",
    timeout: 30_000
  )
]
|> Enum.reject(&is_nil/1)

# ============================================
# Health Check
# ============================================

IO.puts("\n🔍 Search Workers Health Check\n")
IO.puts("=" |> String.duplicate(60))

Enum.each(workers, fn worker ->
  info = worker.__struct__.info(worker)
  health = worker.__struct__.health_check(worker)

  status = case health do
    {:ok, :available} -> "✅ Available"
    {:error, reason} -> "❌ Error: #{inspect(reason)}"
  end

  IO.puts("\n#{info.name} (#{info.service})")
  IO.puts("  Priority: #{worker.__struct__.priority(worker)}")
  IO.puts("  Status: #{status}")
  IO.puts("  Capabilities: #{Enum.join(info.capabilities, ", ")}")
  if Map.has_key?(info, :pricing) do
    IO.puts("  Pricing: #{info.pricing}")
  end
end)

# ============================================
# Search Examples
# ============================================

IO.puts("\n\n📚 Search Examples\n")
IO.puts("=" |> String.duplicate(60))

# Example 1: Basic Web Search
IO.puts("\n1️⃣  Basic Web Search")
IO.puts("-" |> String.duplicate(60))

search_params = %{
  query: "Elixir programming language",
  max_results: 5
}

# Try workers in priority order until one succeeds
result = Enum.find_value(workers, fn worker ->
  case worker.__struct__.call(worker, search_params, []) do
    {:ok, response} ->
      IO.puts("✅ Search successful via #{worker.__struct__.info(worker).name}")
      {:ok, response, worker}

    {:error, reason} ->
      IO.puts("⚠️  #{worker.__struct__.info(worker).name} failed: #{inspect(reason)}")
      nil
  end
end)

case result do
  {:ok, response, worker} ->
    IO.puts("\nQuery: #{response[:query] || search_params.query}")
    IO.puts("Provider: #{worker.__struct__.info(worker).service}")
    IO.puts("Results:\n")

    Enum.each(Enum.take(response.results, 3), fn result ->
      IO.puts("  • #{result["title"]}")
      IO.puts("    #{result["url"]}")
      IO.puts("    #{String.slice(result["snippet"] || "", 0, 100)}...\n")
    end)

  nil ->
    IO.puts("❌ All search providers failed")
end

# Example 2: Search with Brave-specific features (if available)
if brave_key do
  IO.puts("\n2️⃣  Brave Search with Country/Language")
  IO.puts("-" |> String.duplicate(60))

  brave_worker = Enum.find(workers, fn w ->
    w.__struct__ == BraveWorker
  end)

  if brave_worker do
    params = %{
      query: "artificial intelligence news",
      max_results: 3,
      country: "US",
      search_lang: "en",
      freshness: "week"
    }

    case BraveWorker.call(brave_worker, params, []) do
      {:ok, response} ->
        IO.puts("✅ Brave search successful\n")
        IO.puts("Recent AI news (past week):\n")

        Enum.each(response.results, fn result ->
          IO.puts("  📰 #{result["title"]}")
          IO.puts("     #{result["url"]}")
          if result["age"], do: IO.puts("     Age: #{result["age"]}")
          IO.puts("")
        end)

      {:error, reason} ->
        IO.puts("❌ Brave search failed: #{inspect(reason)}")
    end
  end
end

# Example 3: Serper with different search types (if available)
if serper_key do
  IO.puts("\n3️⃣  Serper News Search")
  IO.puts("-" |> String.duplicate(60))

  serper_worker = Enum.find(workers, fn w ->
    w.__struct__ == SerperWorker
  end)

  if serper_worker do
    params = %{
      query: "SpaceX launches",
      max_results: 3,
      search_type: "news"
    }

    case SerperWorker.call(serper_worker, params, []) do
      {:ok, response} ->
        IO.puts("✅ Serper news search successful\n")
        IO.puts("Latest SpaceX news:\n")

        Enum.each(response.results, fn result ->
          IO.puts("  🚀 #{result["title"]}")
          IO.puts("     Source: #{result["source"]}")
          IO.puts("     #{result["url"]}")
          if result["date"], do: IO.puts("     Date: #{result["date"]}")
          IO.puts("")
        end)

      {:error, reason} ->
        IO.puts("❌ Serper news search failed: #{inspect(reason)}")
    end
  end
end

# Example 4: DuckDuckGo Instant Answer (always available)
IO.puts("\n4️⃣  DuckDuckGo Instant Answer")
IO.puts("-" |> String.duplicate(60))

ddg_worker = Enum.find(workers, fn w ->
  w.__struct__ == DuckDuckGoWorker
end)

if ddg_worker do
  params = %{
    query: "Elixir creator",
    max_results: 3
  }

  case DuckDuckGoWorker.call(ddg_worker, params, []) do
    {:ok, response} ->
      IO.puts("✅ DuckDuckGo search successful\n")

      if response[:instant_answer] do
        IO.puts("📌 Instant Answer:")
        IO.puts("   #{response[:instant_answer]}\n")
      end

      if response[:heading] do
        IO.puts("Heading: #{response[:heading]}")
      end

      IO.puts("\nRelated Topics:")
      Enum.each(Enum.take(response.results, 3), fn result ->
        IO.puts("  • #{result["title"]}")
        IO.puts("    #{result["url"]}\n")
      end)

    {:error, reason} ->
      IO.puts("❌ DuckDuckGo search failed: #{inspect(reason)}")
  end
end

# ============================================
# Generic Worker Invocation
# ============================================

IO.puts("\n\n🔧 Generic Worker API\n")
IO.puts("=" |> String.duplicate(60))

alias CortexCore.Workers.Worker

# You can use Worker.invoke/3 for generic calls
IO.puts("\nUsing Worker.invoke/3 for generic search:\n")

first_worker = List.first(workers)
if first_worker do
  params = %{query: "Phoenix Framework", max_results: 3}

  case Worker.invoke(first_worker, params, []) do
    {:ok, response} ->
      IO.puts("✅ Search via Worker.invoke successful")
      IO.puts("Found #{length(response.results)} results for '#{params.query}'\n")

    {:error, reason} ->
      IO.puts("❌ Search failed: #{inspect(reason)}")
  end
end

# ============================================
# Configuration Example
# ============================================

IO.puts("\n\n⚙️  Configuration Example\n")
IO.puts("=" |> String.duplicate(60))

IO.puts("""

To configure search workers in your application:

# config/config.exs
config :cortex_core,
  workers: [
    # Serper: Best quality (Google results)
    {:serper, [
      type: :search,
      api_keys: [System.get_env("SERPER_API_KEY")],
      timeout: 30_000
    ]},

    # Brave: Privacy-focused (used by Anthropic)
    {:brave, [
      type: :search,
      api_keys: [System.get_env("BRAVE_API_KEY")],
      timeout: 30_000
    ]},

    # Tavily: AI-optimized search
    {:tavily, [
      type: :search,
      api_keys: [System.get_env("TAVILY_API_KEY")],
      timeout: 30_000
    ]},

    # DuckDuckGo: Free fallback (no API key needed)
    {:duckduckgo, [
      type: :search,
      timeout: 30_000
    ]}
  ]

# The system will automatically:
# 1. Health check all workers
# 2. Select by priority (Serper > Brave > Tavily > DuckDuckGo)
# 3. Failover to next worker if one fails
# 4. Rotate API keys if rate limited

# Usage in your code:
CortexCore.call(:search, %{query: "..."}, [])
""")

IO.puts("\n✅ Example completed!\n")
