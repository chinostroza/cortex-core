defmodule CortexCore.Workers.Pool do
  @moduledoc """
  Pool de workers que gestiona la selección y distribución de trabajo.

  Responsabilidades:
  - Seleccionar el mejor worker disponible según la estrategia
  - Ejecutar health checks periódicos
  - Manejar failover cuando un worker falla
  - Implementar diferentes estrategias de routing
  """

  use GenServer
  require Logger

  alias CortexCore.Workers.Registry
  alias CortexCore.Workers.Worker

  # 30 segundos
  @health_check_interval 30_000

  defstruct [
    :registry,
    :strategy,
    :health_status,
    :check_interval,
    :round_robin_index
  ]

  # Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Obtiene un stream de completion del mejor worker disponible.
  Si el primer worker falla, intenta con el siguiente.
  """
  def stream_completion(pool \\ __MODULE__, messages, opts \\ []) do
    GenServer.call(pool, {:stream_completion, messages, opts}, 30_000)
  end

  @doc """
  Ejecuta una operación genérica en el mejor worker disponible del tipo especificado.

  ## Parameters
    - pool: El pool a usar (default: __MODULE__)
    - service_type: Tipo de servicio (:llm, :search, :audio, :vision, :http)
    - params: Mapa con parámetros específicos del servicio
    - opts: Opciones adicionales (timeout, etc.)

  ## Examples
      Pool.call(:search, %{query: "Elixir benefits", max_results: 5}, [])
      Pool.call(:audio, %{text: "Hello", voice: "adam"}, [])
  """
  def call(pool \\ __MODULE__, service_type, params, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(pool, {:call, service_type, params, opts}, timeout)
  end

  @doc """
  Obtiene el estado de salud de todos los workers.
  """
  def health_status(pool \\ __MODULE__) do
    GenServer.call(pool, :health_status)
  end

  @doc """
  Fuerza un health check inmediato de todos los workers.
  """
  def check_health(pool \\ __MODULE__) do
    GenServer.cast(pool, :check_health)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    registry = Keyword.get(opts, :registry, CortexCore.Workers.Registry)
    strategy = Keyword.get(opts, :strategy, :local_first)
    check_interval = Keyword.get(opts, :check_interval, @health_check_interval)

    state = %__MODULE__{
      registry: registry,
      strategy: strategy,
      health_status: %{},
      check_interval: check_interval,
      round_robin_index: 0
    }

    # Workers are configured externally via config/runtime.exs
    # No need to auto-configure from environment variables

    # Solo programar health checks si están habilitados
    # Primer check después de 10 segundos para dar tiempo a registrar workers
    if check_interval != :disabled do
      Process.send_after(self(), :periodic_health_check, 10_000)
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:stream_completion, messages, opts}, _from, state) do
    case select_and_execute(state, messages, opts) do
      {:ok, stream, new_state} ->
        {:reply, {:ok, stream}, new_state}

      {:ok, stream} ->
        {:reply, {:ok, stream}, state}

      {:error, :no_workers_available} = error ->
        Logger.error("No hay workers disponibles")
        {:reply, error, state}

      {:error, reason} = error ->
        Logger.error("Error al procesar completion: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:call, service_type, params, opts}, _from, state) do
    case select_and_execute_service(state, service_type, params, opts) do
      {:ok, result, new_state} ->
        {:reply, {:ok, result}, new_state}

      {:ok, result} ->
        {:reply, {:ok, result}, state}

      {:error, :no_workers_available} = error ->
        Logger.error("No hay workers disponibles para service_type: #{service_type}")
        {:reply, error, state}

      {:error, reason} = error ->
        Logger.error("Error al procesar llamada #{service_type}: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:health_status, _from, state) do
    {:reply, state.health_status, state}
  end

  @impl true
  def handle_cast(:check_health, state) do
    new_health_status = perform_health_checks(state)
    {:noreply, %{state | health_status: new_health_status}}
  end

  @impl true
  def handle_info(:configure_initial_workers, state) do
    # Configurar workers de forma asíncrona
    Task.start(fn ->
      CortexCore.Workers.Supervisor.configure_initial_workers(state.registry)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({ref, {:chunk, _chunk}}, state) when is_reference(ref) do
    # Ignorar mensajes de chunks de streaming (son manejados por el proceso que hizo el call)
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, :done}, state) when is_reference(ref) do
    # Ignorar mensajes de streams completados
    {:noreply, state}
  end

  @impl true
  def handle_info(:periodic_health_check, state) do
    new_health_status = perform_health_checks(state)

    # Programar el siguiente check solo si no están deshabilitados
    if state.check_interval != :disabled do
      Process.send_after(self(), :periodic_health_check, state.check_interval)
    end

    {:noreply, %{state | health_status: new_health_status}}
  end

  # Private Functions

  defp select_and_execute_service(state, service_type, params, opts) do
    case Keyword.get(opts, :provider) do
      nil ->
        execute_service_by_strategy(state, service_type, params, opts)

      provider_name ->
        execute_service_by_provider(state, service_type, provider_name, params, opts)
    end
  end

  defp execute_service_by_strategy(state, service_type, params, opts) do
    workers = get_workers_by_service_type(state, service_type)

    if Enum.empty?(workers) do
      {:error, :no_workers_available}
    else
      execute_service_with_strategy(state, workers, params, opts)
    end
  end

  defp execute_service_with_strategy(state, workers, params, opts) do
    case state.strategy do
      :round_robin ->
        case execute_service_with_workers(workers, params, opts) do
          {:ok, result} ->
            new_state = %{state | round_robin_index: state.round_robin_index + 1}
            {:ok, result, new_state}

          error ->
            error
        end

      _ ->
        ordered = apply_strategy(workers, state.strategy)
        execute_service_with_workers(ordered, params, opts)
    end
  end

  defp execute_service_by_provider(state, service_type, provider_name, params, opts) do
    case Registry.get(state.registry, provider_name) do
      {:ok, worker} ->
        worker_service_type = worker.__struct__.service_type()

        if worker_service_type == service_type do
          execute_service_with_workers([worker], params, opts)
        else
          {:error,
           {:wrong_service_type,
            "Worker #{provider_name} is #{worker_service_type}, not #{service_type}"}}
        end

      {:error, :not_found} ->
        {:error, {:provider_not_found, provider_name}}
    end
  end

  defp select_and_execute(state, messages, opts) do
    case Keyword.get(opts, :provider) do
      nil -> execute_with_strategy(state, messages, opts)
      provider -> execute_with_workers(get_workers_by_provider(state, provider), messages, opts)
    end
  end

  defp execute_with_strategy(state, messages, opts) do
    workers = get_available_workers(state, :llm)

    case state.strategy do
      :round_robin ->
        case execute_with_workers(workers, messages, opts) do
          {:ok, stream} ->
            new_state = %{state | round_robin_index: state.round_robin_index + 1}
            {:ok, stream, new_state}

          error ->
            error
        end

      _ ->
        execute_with_workers(workers, messages, opts)
    end
  end

  defp execute_with_workers([], _messages, _opts) do
    {:error, :no_workers_available}
  end

  defp execute_with_workers(workers, messages, opts) do
    # Intentar con cada worker hasta que uno funcione
    execute_with_failover(workers, messages, opts)
  end

  defp get_available_workers(state, service_type) do
    all_workers =
      if is_pid(state.registry) do
        GenServer.call(state.registry, :list_all)
      else
        state.registry.list_all()
      end

    workers_by_type = Enum.filter(all_workers, &worker_matches_service_type?(&1, service_type))

    available = Enum.filter(workers_by_type, &worker_available?(&1, state.health_status))

    Logger.debug(
      "Strategy: #{inspect(state.strategy)}, Available LLM workers: #{length(available)} (#{Enum.map_join(available, ", ", & &1.name)})"
    )

    case state.strategy do
      :round_robin -> apply_round_robin_strategy(available, state)
      _ -> apply_strategy(available, state.strategy)
    end
  end

  defp worker_matches_service_type?(worker, service_type) do
    worker_module = worker.__struct__

    function_exported?(worker_module, :service_type, 0) and
      worker_module.service_type() == service_type
  end

  defp worker_available?(worker, health_status) do
    health = Map.get(health_status, worker.name, :unknown)

    health not in [:unavailable, :quota_exceeded, :rate_limited] and
      (health == :available or health == :unknown)
  end

  defp apply_strategy(workers, :local_first) do
    # Ordenar por prioridad (menor número = mayor prioridad)
    Enum.sort_by(workers, fn worker ->
      worker.__struct__.priority(worker)
    end)
  end

  defp apply_strategy(workers, :round_robin) do
    # Esta función no se usa para round_robin, se maneja en apply_round_robin_strategy
    Enum.shuffle(workers)
  end

  defp apply_strategy(workers, _), do: workers

  defp apply_round_robin_strategy(workers, state) do
    # Implementar round-robin real con estado
    if Enum.empty?(workers) do
      []
    else
      # Ordenar workers por nombre para consistencia
      sorted_workers = Enum.sort_by(workers, & &1.name)

      # Obtener el índice actual y rotar
      current_index = rem(state.round_robin_index, length(sorted_workers))

      # Rotar la lista para que el worker actual esté primero
      {front, back} = Enum.split(sorted_workers, current_index)
      rotated = back ++ front

      # Debug logging
      worker_names = Enum.map(sorted_workers, & &1.name)
      rotated_names = Enum.map(rotated, & &1.name)

      Logger.info(
        "Round-robin: workers=#{inspect(worker_names)}, index=#{current_index}, rotated=#{inspect(rotated_names)}"
      )

      rotated
    end
  end

  defp execute_with_failover([worker | rest], messages, opts) do
    execute_with_failover([worker | rest], messages, opts, [])
  end

  defp execute_with_failover([], _messages, _opts, error_details) when is_list(error_details) do
    # Crear mensaje detallado con los errores de cada worker
    detailed_errors =
      Enum.map_join(error_details, "; ", fn {worker, error} -> "#{worker}: #{error}" end)

    Logger.error("Todos los workers fallaron. Errores: #{detailed_errors}")
    {:error, {:all_workers_failed, detailed_errors}}
  end

  defp execute_with_failover([worker | rest], messages, opts, error_details) do
    Logger.debug(
      "Intentando con worker: #{worker.name} (#{length(rest)} workers restantes en cola)"
    )

    case worker.__struct__.stream_completion(worker, messages, opts) do
      {:ok, stream} ->
        case validate_stream(stream) do
          :ok ->
            Logger.info("Worker #{worker.name} respondió exitosamente")
            {:ok, Stream.filter(stream, fn e -> is_binary(e) or match?({:stream_done, _}, e) end)}

          error ->
            error_msg = format_validation_error(error)

            Logger.warning(
              "Worker #{worker.name} falló: #{error_msg}, intentando con siguiente worker"
            )

            execute_with_failover(rest, messages, opts, [{worker.name, error_msg} | error_details])
        end

      {:error, reason} ->
        error_msg = format_error_reason(reason)
        Logger.warning("Worker #{worker.name} falló: #{error_msg}")
        execute_with_failover(rest, messages, opts, [{worker.name, error_msg} | error_details])
    end
  end

  defp format_validation_error({:error, {:http_error, status, message}}),
    do: "HTTP #{status}: #{message}"

  defp format_validation_error({:error, :empty_stream}),
    do: "stream vacío (sin respuesta del provider)"

  defp format_validation_error({:error, :validation_timeout}),
    do: "timeout de validación (posible bloqueo por error HTTP)"

  defp format_validation_error({:error, :invalid_format}),
    do: "formato de respuesta inválido"

  defp format_validation_error({:error, :validation_error}),
    do: "error de validación interno"

  defp format_validation_error(_), do: "error desconocido de validación"

  defp format_error_reason({status, message}) when is_integer(status),
    do: "HTTP #{status}: #{message}"

  defp format_error_reason(reason), do: inspect(reason)

  defp perform_health_checks(state) do
    workers =
      if is_pid(state.registry) do
        GenServer.call(state.registry, :list_all)
      else
        state.registry.list_all()
      end

    tasks = Enum.map(workers, fn worker -> Task.async(fn -> check_worker_health(worker) end) end)

    results =
      tasks
      |> Task.yield_many(5000)
      |> Enum.map(&collect_health_result/1)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    Logger.info("Health check completado: #{inspect(results)}")
    results
  end

  defp check_worker_health(worker) do
    status =
      case worker.__struct__.health_check(worker) do
        {:ok, status} -> status
        {:error, {:quota_exceeded, _}} -> :quota_exceeded
        {:error, {:rate_limited, _}} -> :rate_limited
        {:error, _} -> :unavailable
      end

    {worker.name, status}
  end

  defp collect_health_result({task, result}) do
    case result do
      {:ok, value} ->
        value

      _ ->
        Task.shutdown(task, :brutal_kill)
        nil
    end
  end

  defp validate_stream(stream) do
    # Usar un timeout más corto y mejor manejo de errores
    task =
      Task.async(fn ->
        # Intentar obtener el primer elemento del stream con timeout
        stream
        |> Stream.take(1)
        |> Enum.to_list()
      end)

    # 10 segundos timeout para modelos experimentales
    case Task.yield(task, 10_000) do
      {:ok, []} ->
        Logger.warning("Stream vacío detectado - posible error HTTP (403/503) no manejado")
        {:error, :empty_stream}

      {:ok, [{:stream_error, status, message} | _]} ->
        Logger.warning("Error HTTP detectado en stream: #{status} - #{message}")
        {:error, {:http_error, status, message}}

      {:ok, [{:stream_done, _} | _]} ->
        # Stream que solo emitió el done (respuesta vacía pero válida)
        :ok

      {:ok, [first | _]} when is_binary(first) and byte_size(first) > 0 ->
        Logger.info("Stream válido detectado: #{byte_size(first)} bytes")
        :ok

      {:ok, [first | _]} ->
        Logger.warning("Stream con formato inesperado: #{inspect(first)}")
        {:error, :invalid_format}

      nil ->
        # Timeout - matar la tarea
        Task.shutdown(task, :brutal_kill)
        Logger.error("Timeout validando stream - posible bloqueo por error HTTP")
        {:error, :validation_timeout}
    end
  rescue
    error ->
      Logger.error("Error validando stream: #{inspect(error)}")
      {:error, :validation_error}
  end

  defp get_workers_by_provider(state, provider) do
    all_workers =
      if is_pid(state.registry) do
        GenServer.call(state.registry, :list_all)
      else
        state.registry.list_all()
      end

    # Filtrar por provider y disponibilidad (incluye :unknown cuando health checks están deshabilitados)
    all_workers
    |> Enum.filter(fn worker ->
      worker_name = worker.name
      health = Map.get(state.health_status, worker_name, :unknown)

      health not in [:unavailable, :quota_exceeded, :rate_limited] and
        String.contains?(worker_name, provider)
    end)
  end

  defp get_workers_by_service_type(state, service_type) do
    all_workers =
      if is_pid(state.registry) do
        GenServer.call(state.registry, :list_all)
      else
        state.registry.list_all()
      end

    # Filtrar por service_type y disponibilidad
    filtered_workers =
      all_workers
      |> Enum.filter(fn worker ->
        worker_module = worker.__struct__
        worker_name = worker.name
        health = Map.get(state.health_status, worker_name, :unknown)

        # Verificar que implemente service_type/0 y coincida
        worker_service_type =
          if function_exported?(worker_module, :service_type, 0) do
            worker_module.service_type()
          else
            nil
          end

        # Excluir workers no disponibles
        is_available =
          health not in [:unavailable, :quota_exceeded, :rate_limited] and
            (health == :available or health == :unknown)

        worker_service_type == service_type and is_available
      end)

    Logger.debug(
      "Service type: #{service_type}, Available workers: #{length(filtered_workers)} (#{Enum.map_join(filtered_workers, ", ", & &1.name)})"
    )

    filtered_workers
  end

  defp execute_service_with_workers([], _params, _opts) do
    {:error, :no_workers_available}
  end

  defp execute_service_with_workers(workers, params, opts) do
    execute_service_with_failover(workers, params, opts, [])
  end

  defp execute_service_with_failover([], _params, _opts, error_details)
       when is_list(error_details) do
    # Crear mensaje detallado con los errores de cada worker
    detailed_errors =
      Enum.map_join(error_details, "; ", fn {worker, error} -> "#{worker}: #{error}" end)

    {:error, {:all_workers_failed, detailed_errors}}
  end

  defp execute_service_with_failover([worker | rest], params, opts, error_details) do
    Logger.debug(
      "Intentando servicio #{(params[:messages] && ":llm") || ":generic"} con worker: #{worker.name} (#{length(rest)} workers restantes)"
    )

    try do
      case Worker.invoke(worker, params, opts) do
        {:ok, result} when is_function(result) or is_struct(result, Stream) ->
          validated_stream = validate_stream(result, worker)

          Logger.info(
            "Worker #{worker.name} respondió exitosamente#{get_worker_model_info(worker)}"
          )

          {:ok, validated_stream}

        {:ok, result} ->
          Logger.info(
            "Worker #{worker.name} respondió exitosamente#{get_worker_model_info(worker)}"
          )

          {:ok, result}

        {:error, reason} ->
          error_msg = format_error_reason(reason)
          Logger.warning("Worker #{worker.name} falló: #{error_msg}, intentando siguiente...")

          execute_service_with_failover(rest, params, opts, [
            {worker.name, error_msg} | error_details
          ])
      end
    rescue
      error ->
        handle_service_failover_error(
          worker,
          rest,
          params,
          opts,
          error_details,
          Exception.message(error)
        )
    end
  end

  defp handle_service_failover_error(worker, rest, params, opts, error_details, error_msg) do
    if rate_limit_error?(error_msg) and can_rotate_api_key?(worker) do
      handle_rate_limit_rotation(worker, rest, params, opts, error_details, error_msg)
    else
      Logger.warning(
        "Worker #{worker.name} lanzó excepción: #{error_msg}, intentando siguiente..."
      )

      execute_service_with_failover(rest, params, opts, [{worker.name, error_msg} | error_details])
    end
  end

  defp handle_rate_limit_rotation(worker, rest, params, opts, error_details, error_msg) do
    rotation_key = "#{worker.name}_rotations"
    rotations_count = Keyword.get(error_details, String.to_atom(rotation_key), 0)
    max_rotations = length(worker.api_keys)

    if rotations_count < max_rotations do
      rotated_worker = rotate_worker_api_key(worker)

      Logger.info(
        "Worker #{worker.name} con rate limit, rotando a API key ##{rotated_worker.current_key_index + 1}/#{length(rotated_worker.api_keys)} (intento #{rotations_count + 1}/#{max_rotations})"
      )

      updated_error_details =
        Keyword.put(error_details, String.to_atom(rotation_key), rotations_count + 1)

      execute_service_with_failover([rotated_worker | rest], params, opts, updated_error_details)
    else
      Logger.warning(
        "Worker #{worker.name} agotó todas sus #{max_rotations} API keys, intentando siguiente worker..."
      )

      execute_service_with_failover(rest, params, opts, [
        {worker.name, "#{error_msg} (tried all #{max_rotations} API keys)"} | error_details
      ])
    end
  end

  # Valida que un stream puede comenzar a producir elementos sin error
  defp validate_stream(stream, worker) do
    # Intentar obtener el primer elemento para validar que el HTTP request fue exitoso
    # Si falla, lanzará una excepción que será capturada por el rescue
    case Enum.take(stream, 1) do
      [] ->
        # Stream vacío - puede ser un error silencioso
        raise "Worker #{worker.name} retornó stream vacío"

      [first] ->
        # Primer elemento exitoso, retornar stream completo con el primer elemento
        Stream.concat([first], stream)
    end
  end

  # Detecta si un error es de tipo rate limit (HTTP 429)
  defp rate_limit_error?(error_msg) when is_binary(error_msg) do
    String.contains?(error_msg, "429") or
      String.contains?(String.downcase(error_msg), "rate limit") or
      String.contains?(String.downcase(error_msg), "quota")
  end

  defp rate_limit_error?(_), do: false

  # Verifica si un worker puede rotar a otro API key
  defp can_rotate_api_key?(worker) do
    # Verificar que el worker tenga el campo api_keys y que tenga más de una key
    Map.has_key?(worker, :api_keys) and
      is_list(worker.api_keys) and
      length(worker.api_keys) > 1 and
      Map.has_key?(worker, :current_key_index)
  end

  # Rota el worker al siguiente API key
  defp rotate_worker_api_key(worker) do
    # Llamar al método rotate_api_key del worker si existe
    worker_module = worker.__struct__

    if function_exported?(worker_module, :rotate_api_key, 1) do
      worker_module.rotate_api_key(worker)
    else
      # Fallback: rotación manual si el worker no tiene el método
      new_index = rem(worker.current_key_index + 1, length(worker.api_keys))
      %{worker | current_key_index: new_index, last_rotation: DateTime.utc_now()}
    end
  end

  # Obtiene información del modelo que está usando el worker
  defp get_worker_model_info(worker) do
    cond do
      Map.has_key?(worker, :default_model) and worker.default_model ->
        " (modelo: #{worker.default_model})"

      Map.has_key?(worker, :model) and worker.model ->
        " (modelo: #{worker.model})"

      true ->
        ""
    end
  end
end
