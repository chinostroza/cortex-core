# Configuración de CortexCore - Universal Service Gateway

## Variables de Entorno

Cortex Core lee las API keys desde variables de entorno. **No usa archivos `.env` directamente** - la aplicación que consume cortex_core debe cargar las variables.

### LLM Services

```bash
# OpenAI
export OPENAI_API_KEYS=sk-key1,sk-key2,sk-key3
export OPENAI_MODEL=gpt-5  # opcional, default: gpt-5

# Anthropic
export ANTHROPIC_API_KEYS=sk-ant-key1,sk-ant-key2
export ANTHROPIC_MODEL=claude-sonnet-4-20250514  # opcional

# xAI (Grok)
export XAI_API_KEYS=xai-key1
export XAI_MODEL=grok-code-fast-1  # opcional

# Google Gemini
export GEMINI_API_KEYS=key1,key2
export GEMINI_MODEL=gemini-2.0-flash-001  # opcional

# Gemini Pro 2.5
export GEMINI_PRO_25_API_KEYS=key1
export GEMINI_PRO_25_MODEL=gemini-2.5-pro  # opcional

# Groq
export GROQ_API_KEYS=gsk-key1
export GROQ_MODEL=llama-3.1-8b-instant  # opcional

# Cohere
export COHERE_API_KEYS=key1
export COHERE_MODEL=command-light  # opcional

# Ollama (local)
export OLLAMA_BASE_URL=http://localhost:11434  # opcional
export OLLAMA_MODEL=gemma3:4b  # opcional
```

### Search Services

```bash
# Tavily
export TAVILY_API_KEY=tvly-your-key-here
```

### Audio Services (próximamente)

```bash
# ElevenLabs
export ELEVENLABS_API_KEY=el-your-key-here
```

### Pool Configuration

```bash
# Strategy: local_first, round_robin, least_used, random
export WORKER_POOL_STRATEGY=local_first

# Health checks interval in seconds (0 to disable)
export HEALTH_CHECK_INTERVAL=30
```

## Integración en Aplicaciones

### Phoenix/Elixir Application

1. **Agregar cortex_core a mix.exs:**

```elixir
def deps do
  [
    {:cortex_core, path: "../cortex/cortex-core/cortex_core"}
    # o desde git/hex cuando esté publicado
  ]
end
```

2. **Usar dotenv para cargar variables:**

```elixir
# mix.exs
def project do
  [
    # ...
    aliases: aliases()
  ]
end

defp aliases do
  [
    setup: ["deps.get", "cmd cp .env.example .env"],
    "assets.deploy": ["tailwind default --minify", "esbuild default --minify", "phx.digest"]
  ]
end

# Agregar a deps
{:dotenvy, "~> 0.8.0"}
```

3. **Cargar .env en config/runtime.exs:**

```elixir
import Config
import Dotenvy

# Cargar .env si existe
source!([".env", System.get_env()])

config :cortex_core,
  # Las variables ya están en el entorno, cortex_core las leerá automáticamente
  start_on_boot: true
```

4. **Iniciar en Application supervisor:**

```elixir
# lib/my_app/application.ex
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # ... otros supervisores
      {CortexCore, [strategy: :local_first]},  # Cortex Core
      # ... resto de supervisores
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

5. **Crear .env file:**

```bash
# .env
OPENAI_API_KEYS=sk-proj-xxx
ANTHROPIC_API_KEYS=sk-ant-xxx
TAVILY_API_KEY=tvly-xxx
WORKER_POOL_STRATEGY=local_first
HEALTH_CHECK_INTERVAL=30
```

6. **Agregar .env a .gitignore:**

```
# .gitignore
.env
.env.local
```

## Uso en la Aplicación

### LLM Chat (streaming)

```elixir
# En cualquier parte de tu aplicación
{:ok, stream} = CortexCore.chat([
  %{role: "user", content: "¿Qué es Elixir?"}
])

response = stream |> Enum.join("")
```

### Web Search

```elixir
{:ok, results} = CortexCore.call(:search, %{
  query: "Elixir programming benefits",
  max_results: 5,
  search_depth: "basic",
  include_answer: true
})

IO.puts("Respuesta: #{results.answer}")

Enum.each(results.results, fn result ->
  IO.puts("• #{result["title"]}: #{result["url"]}")
end)
```

### Text-to-Speech (cuando se implemente)

```elixir
{:ok, audio_data} = CortexCore.call(:audio, %{
  text: "Hello from Elixir",
  voice: "adam"
})
```

### Vision/Image Generation (cuando se implemente)

```elixir
{:ok, image_data} = CortexCore.call(:vision, %{
  prompt: "A sunset over mountains",
  size: "1024x1024"
})
```

### Health Status

```elixir
# Ver estado de todos los servicios
health = CortexCore.health_status()
# => %{"openai-primary" => :available, "tavily-primary" => :available, ...}

# Listar workers configurados
workers = CortexCore.list_workers()
# => [%{name: "openai-primary", type: :llm, ...}, %{name: "tavily-primary", service: :search, ...}]

# Forzar health check
CortexCore.check_health()
```

### Runtime Worker Management

```elixir
# Agregar worker dinámicamente
CortexCore.add_worker("tavily-backup",
  type: :tavily,
  api_keys: ["tvly-backup-key"],
  timeout: 30_000
)

# Remover worker
CortexCore.remove_worker("tavily-backup")
```

## Ejemplo: Cerebelum Integration

```elixir
# En un nodo de workflow de Cerebelum
defmodule Cerebelum.Nodes.WebSearchNode do
  @behaviour Cerebelum.Node

  def execute(_node, context) do
    query = get_in(context, ["input", "query"])

    case CortexCore.call(:search, %{query: query, max_results: 5}) do
      {:ok, results} ->
        {:ok, %{
          answer: results.answer,
          sources: Enum.map(results.results, & &1["url"])
        }}

      {:error, reason} ->
        {:error, "Search failed: #{inspect(reason)}"}
    end
  end
end
```

## Troubleshooting

### Workers no se registran

1. Verifica que las variables de entorno estén cargadas:
   ```elixir
   IO.inspect(System.get_env("TAVILY_API_KEY"))
   ```

2. Verifica que CortexCore esté iniciado en el supervision tree

3. Espera a que los workers se configuren (asíncrono):
   ```elixir
   Process.sleep(2000)
   CortexCore.list_workers()
   ```

### Health checks fallan

- Verifica conectividad a internet
- Verifica que las API keys sean válidas
- Revisa logs: `Logger.debug("Worker health: #{inspect(health)}")`
- Deshabilita health checks temporalmente: `export HEALTH_CHECK_INTERVAL=0`

### No hay workers disponibles para :search

- Verifica que `TAVILY_API_KEY` esté configurada (singular, no plural)
- Verifica que el worker se haya registrado: `CortexCore.list_workers()`
- Prueba agregar el worker manualmente: `CortexCore.add_worker("tavily-test", type: :tavily, api_keys: ["tvly-..."])`

## Security Best Practices

1. **Nunca commitear .env al repositorio**
2. **Usar .env.example para documentar variables necesarias**
3. **En producción, usar secrets management** (AWS Secrets Manager, Vault, etc.)
4. **Rotar API keys periódicamente**
5. **Monitorear uso de cuotas** con health checks
6. **Implementar rate limiting** a nivel de aplicación si es necesario
