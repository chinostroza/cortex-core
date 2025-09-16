# AGENTS.md

Buenas prácticas para programar con Elixir en este proyecto.

## Principios Fundamentales de Elixir

### 1. "Let it crash" (Deja que falle)
- No manejes todos los errores defensivamente
- Usa supervisores para reiniciar procesos que fallan
- Falla rápido y claramente cuando algo está mal
- Ejemplo: `GenServer.call/2` sin `try/catch` - deja que el supervisor maneje las fallas

### 2. Inmutabilidad
- Los datos nunca cambian, siempre creates nuevas versiones
- Usa `|>` pipe operator para transformaciones de datos
- Evita variables mutables - usa pattern matching en su lugar

```elixir
# Bueno
result = 
  data
  |> transform_step_1()
  |> transform_step_2()
  |> transform_step_3()

# Evitar
result = transform_step_1(data)
result = transform_step_2(result)  # Reasignación
```

### 3. Pattern Matching
- Usa pattern matching en lugar de condicionales cuando sea posible
- Úsalo para extraer datos de estructuras complejas
- Prefiere múltiples cláusulas de función sobre `case/cond`

```elixir
# Bueno
def handle_response({:ok, %{"data" => data}}), do: process_data(data)
def handle_response({:error, reason}), do: handle_error(reason)

# Menos idiomático
def handle_response(response) do
  case response do
    {:ok, %{"data" => data}} -> process_data(data)
    {:error, reason} -> handle_error(reason)
  end
end
```

## Convenciones de Código

### 1. Naming Conventions
- **Módulos**: `PascalCase` (e.g., `CortexCore.Workers.Pool`)
- **Funciones y variables**: `snake_case` (e.g., `api_key_manager`)
- **Átomos**: `:snake_case` (e.g., `:api_response`)
- **Constantes**: `@module_attribute` en SCREAMING_SNAKE_CASE

### 2. Estructura de Módulos
```elixir
defmodule MyModule do
  @moduledoc """
  Descripción del módulo.
  """

  # Aliases y imports primero
  alias CortexCore.Workers.Worker
  import Logger

  # Module attributes después
  @default_timeout 5000

  # Definiciones de types
  @type option :: {:timeout, pos_integer()}

  # Funciones públicas primero
  @spec public_function(String.t(), [option()]) :: {:ok, term()} | {:error, term()}
  def public_function(param, opts \\ [])

  # Funciones privadas después
  defp private_function(param), do: # ...
end
```

### 3. Manejo de Errores
- Usa tagged tuples: `{:ok, result}` y `{:error, reason}`
- Para funciones que pueden fallar, crea versiones `!` que levantan excepciones
- Usa `with` para encadenar operaciones que pueden fallar

```elixir
# Bueno
def create_user(params) do
  with {:ok, validated} <- validate_params(params),
       {:ok, user} <- insert_user(validated),
       {:ok, _} <- send_welcome_email(user) do
    {:ok, user}
  else
    {:error, reason} -> {:error, reason}
  end
end

# Para casos donde necesitas la excepción
def create_user!(params) do
  case create_user(params) do
    {:ok, user} -> user
    {:error, reason} -> raise "Failed to create user: #{inspect(reason)}"
  end
end
```

### 4. GenServer Patterns
- Mantén el estado simple y bien estructurado
- Usa `handle_continue/2` para inicialización asíncrona
- Implementa timeout en `handle_call/3` cuando sea necesario
- Usa `handle_info/2` para mensajes no manejados

```elixir
defmodule MyGenServer do
  use GenServer

  # Client API
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  # Server Callbacks
  @impl GenServer
  def init(opts) do
    state = %{
      config: Keyword.get(opts, :config, %{}),
      status: :initializing
    }
    {:ok, state, {:continue, :finish_init}}
  end

  @impl GenServer
  def handle_continue(:finish_init, state) do
    # Inicialización pesada aquí
    {:noreply, %{state | status: :ready}}
  end

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end
end
```

## Prácticas Específicas para este Proyecto

### 1. Worker Implementation
- Todos los workers deben implementar el behaviour `CortexCore.Workers.Worker`
- Usa `APIWorkerBase` como base para adaptadores HTTP
- Normaliza todas las respuestas al formato común
- Maneja tanto streaming como respuestas normales

### 2. Testing
- Usa `ExUnit` para tests unitarios
- Mock HTTP requests con `Bypass`
- Para GenServers, testa la API pública, no la implementación interna
- Usa `start_supervised!/2` para procesos en tests

```elixir
defmodule MyWorkerTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  setup do
    bypass = Bypass.open()
    worker = start_supervised!({MyWorker, base_url: "http://localhost:#{bypass.port}"})
    %{bypass: bypass, worker: worker}
  end

  test "handles successful response", %{bypass: bypass, worker: worker} do
    Bypass.expect_once(bypass, "POST", "/chat", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"response" => "test"}))
    end)

    assert {:ok, response} = MyWorker.chat_completion(worker, %{message: "test"})
    assert response.content == "test"
  end
end
```

### 3. Configuración
- Usa `Application.get_env/3` para configuración en tiempo de ejecución
- Valida configuración en el `init/1` de GenServers
- Proporciona valores por defecto sensatos
- Documenta todas las opciones de configuración

### 4. Logging
- Usa `Logger` del stdlib de Elixir
- Niveles: `:debug`, `:info`, `:warn`, `:error`
- Incluye contexto relevante en logs
- No loggees información sensible (API keys, datos de usuario)

```elixir
import Logger

def handle_api_call(request) do
  Logger.info("Making API call", provider: @provider_name, model: request.model)
  
  case make_request(request) do
    {:ok, response} ->
      Logger.debug("API call successful", response_tokens: response.usage.total_tokens)
      {:ok, response}
    
    {:error, reason} ->
      Logger.warn("API call failed", reason: inspect(reason), provider: @provider_name)
      {:error, reason}
  end
end
```

### 5. Performance
- Usa connection pooling (ya configurado con Finch)
- Para operaciones costosas, considera usar `Task.async/1`
- Profile con `:observer.start()` cuando tengas problemas de performance
- Evita crear muchos procesos cortos - prefiere pools de workers

## Herramientas de Desarrollo

### 1. Análisis de Código
```bash
# Credo para análisis estático
mix credo --strict

# Dialyzer para análisis de tipos
mix dialyzer

# Formateo de código
mix format

# Verificar formato sin cambiar
mix format --check-formatted
```

### 2. Debugging
```elixir
# En desarrollo, usa IO.inspect/2 para debug
result
|> IO.inspect(label: "Debug point")
|> process_further()

# Para debugging más avanzado
require IEx; IEx.pry()

# En producción, usa Logger
Logger.debug("Debug info", data: inspect(data))
```

### 3. Benchmarking
```elixir
# Usar :timer.tc/1 para timing simple
{time_microseconds, result} = :timer.tc(fn -> expensive_operation() end)
Logger.info("Operation took #{time_microseconds / 1000}ms")

# Para benchmarking más completo, usar Benchee
```

## Anti-Patterns a Evitar

1. **No uses `throw/catch` - usa tagged tuples**
2. **No modifiques estado fuera de GenServers**
3. **No uses `Process.sleep/1` en tests - usa herramientas como Bypass**
4. **No hardcodees URLs o configuración - usa environment variables**
5. **No uses `String.to_atom/1` con input del usuario - riesgo de memory leak**
6. **No uses `apply/3` cuando pattern matching es suficiente**

## Elixir Guidelines Específicas

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if condition do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if condition do
          assign(socket, :val, val)
        else
          socket
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field`
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix Guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Recursos Útiles

- [Elixir Style Guide](https://github.com/christopheradams/elixir_style_guide)
- [OTP Design Principles](https://www.erlang.org/doc/design_principles/users_guide.html)
- [Elixir Documentation](https://hexdocs.pm/elixir/)
- [GenServer Best Practices](https://hexdocs.pm/elixir/GenServer.html)