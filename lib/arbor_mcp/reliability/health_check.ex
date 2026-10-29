defmodule Arbor.MCP.Reliability.HealthCheck do
  @moduledoc """
  Health check system for MCP clients and servers.

  Provides proactive health monitoring, automatic failure detection,
  and recovery mechanisms for MCP services.

  ## Features

  - Periodic health checks with configurable intervals
  - Multiple check strategies (ping, capability check, custom)
  - Automatic status updates and notifications
  - Integration with circuit breakers and retry logic
  - Health metrics and history tracking

  ## Usage

      # Start health checker for a client
      {:ok, checker} = HealthCheck.start_link(
        name: :my_health_check,
        target: client_pid,
        check_interval: 30_000,
        timeout: 5_000,
        failure_threshold: 3,
        recovery_threshold: 2
      )

      # Get current health status
      HealthCheck.get_status(checker)
      #=> {:healthy, %{last_check: ~U[...], consecutive_successes: 5}}

      # Subscribe to health events
      HealthCheck.subscribe(checker)

      # Manual health check
      HealthCheck.check_now(checker)

  ## Checks

  Each check runs in a process of its own, off the checker's loop, so
  `get_status/1` answers while a check is in progress, and stopping the
  checker stops its check with it. Every other call is taken in the order it
  came, after any check in progress or asked for before it, as when checks
  ran in the loop: `check_now/1` and each periodic check get a check of
  their own, one at a time, and a `subscribe/1` or `unsubscribe/1` made
  during a check takes effect after that check has notified the
  subscribers.
  """

  use GenServer
  require Logger

  # 1 minute
  @default_check_interval 60_000
  # 5 seconds
  @default_timeout 5_000
  @default_failure_threshold 3
  @default_recovery_threshold 2
  # How long stopping a check may take; its watcher answers at once.
  @check_shutdown_ms 1_000

  defstruct [
    :name,
    :target,
    :check_fn,
    :check_interval,
    :timeout,
    :failure_threshold,
    :recovery_threshold,
    :on_status_change,
    :timer_ref,
    :check,
    deferred: [],
    status: :unknown,
    consecutive_failures: 0,
    consecutive_successes: 0,
    last_check_time: nil,
    last_check_result: nil,
    history: [],
    subscribers: MapSet.new(),
    metadata: %{}
  ]

  @type status :: :healthy | :unhealthy | :degraded | :unknown

  @type check_result :: %{
          status: status(),
          timestamp: DateTime.t(),
          duration_ms: non_neg_integer(),
          details: map()
        }

  @type t :: %__MODULE__{
          name: atom(),
          target: pid() | atom(),
          check_fn: (any() -> {:ok, map()} | {:error, any()}) | nil,
          check_interval: pos_integer(),
          timeout: pos_integer(),
          failure_threshold: pos_integer(),
          recovery_threshold: pos_integer(),
          on_status_change: (status(), status() -> any()) | nil,
          timer_ref: reference() | nil,
          check: map() | nil,
          deferred: [{term(), GenServer.from() | nil}],
          status: status(),
          consecutive_failures: non_neg_integer(),
          consecutive_successes: non_neg_integer(),
          last_check_time: DateTime.t() | nil,
          last_check_result: check_result() | nil,
          history: [check_result()],
          subscribers: MapSet.t(pid()),
          metadata: map()
        }

  ## Client API

  @doc """
  Starts a health check process.

  ## Options

  - `:name` - Process name (required)
  - `:target` - PID or name of process to check (required)
  - `:check_fn` - Custom check function (optional, defaults to MCP ping)
  - `:check_interval` - Ms between checks (default: 60000)
  - `:timeout` - Check timeout in ms (default: 5000)
  - `:failure_threshold` - Failures before unhealthy (default: 3)
  - `:recovery_threshold` - Successes before healthy (default: 2)
  - `:on_status_change` - Callback for status changes
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Gets the current health status, as the checks finished so far left it.

  It answers at once, also while a check is in progress.
  """
  @spec get_status(GenServer.server()) :: {status(), map()}
  def get_status(checker) do
    GenServer.call(checker, :get_status)
  end

  @doc """
  Runs a health check and returns its result.

  The check starts once any check already running, or asked for earlier,
  has finished, so the result is always a sample taken after the call.
  """
  @spec check_now(GenServer.server()) :: check_result()
  def check_now(checker) do
    GenServer.call(checker, :check_now)
  end

  @doc """
  Gets health check history.
  """
  @spec get_history(GenServer.server(), pos_integer()) :: [check_result()]
  def get_history(checker, limit \\ 10) do
    GenServer.call(checker, {:get_history, limit})
  end

  @doc """
  Subscribes to health status changes.

  Subscribers receive messages: `{:health_status_changed, old_status, new_status, metadata}`
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(checker) do
    GenServer.call(checker, {:subscribe, self()})
  end

  @doc """
  Unsubscribes from health status changes.
  """
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(checker) do
    GenServer.call(checker, {:unsubscribe, self()})
  end

  @doc """
  Pauses health checks.
  """
  @spec pause(GenServer.server()) :: :ok
  def pause(checker) do
    GenServer.call(checker, :pause)
  end

  @doc """
  Resumes health checks.
  """
  @spec resume(GenServer.server()) :: :ok
  def resume(checker) do
    GenServer.call(checker, :resume)
  end

  ## Server Callbacks

  @impl GenServer
  def init(opts) do
    target = Keyword.fetch!(opts, :target)

    state = %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      target: target,
      check_fn: Keyword.get(opts, :check_fn) || default_check_fn(target),
      check_interval: Keyword.get(opts, :check_interval, @default_check_interval),
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      failure_threshold: Keyword.get(opts, :failure_threshold, @default_failure_threshold),
      recovery_threshold: Keyword.get(opts, :recovery_threshold, @default_recovery_threshold),
      on_status_change: Keyword.get(opts, :on_status_change),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    # Start health checks after a short delay
    timer_ref = Process.send_after(self(), :perform_check, 1000)

    {:ok, %{state | timer_ref: timer_ref}}
  end

  @impl GenServer
  def handle_call(:get_status, _from, state) do
    status_info = %{
      status: state.status,
      last_check: state.last_check_time,
      consecutive_failures: state.consecutive_failures,
      consecutive_successes: state.consecutive_successes,
      metadata: state.metadata
    }

    {:reply, {state.status, status_info}, state}
  end

  # Every other call, and a periodic check, is taken in the order it came,
  # after any check in progress or asked for before it, as when checks ran
  # in this loop: only get_status/1 answers at once.
  def handle_call(request, from, %{check: nil} = state),
    do: {:noreply, perform(request, from, state)}

  def handle_call(request, from, state), do: {:noreply, defer(state, {request, from})}

  @impl GenServer
  def handle_info(:perform_check, %{check: nil} = state),
    do: {:noreply, perform(:perform_check, nil, state)}

  def handle_info(:perform_check, state), do: {:noreply, defer(state, {:perform_check, nil})}

  def handle_info({ref, reply}, %{check: %{task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_check(state, check_outcome({:ok, reply}))}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{check: %{task: %Task{ref: ref}}} = state
      ) do
    {:noreply, finish_check(state, check_outcome({:exit, reason}))}
  end

  def handle_info({:check_timeout, ref}, %{check: %{task: %Task{ref: ref} = task}} = state) do
    outcome =
      case stop_check(task) do
        nil -> {:unhealthy, %{error: :timeout}}
        finished -> check_outcome(finished)
      end

    {:noreply, finish_check(state, outcome)}
  end

  def handle_info({:check_timeout, _finished}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_subscribers = MapSet.delete(state.subscribers, pid)
    {:noreply, %{state | subscribers: new_subscribers}}
  end

  @impl GenServer
  def terminate(_reason, %{check: %{task: task}}) do
    stop_check(task)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Private Functions

  defp perform(:check_now, from, state), do: start_check(state, {:reply, from})

  # The next periodic check is scheduled when this one finishes.
  defp perform(:perform_check, _from, state),
    do: start_check(%{state | timer_ref: nil}, :periodic)

  defp perform({:get_history, limit}, from, state) do
    GenServer.reply(from, Enum.take(state.history, limit))
    state
  end

  defp perform({:subscribe, pid}, from, state) do
    Process.monitor(pid)
    GenServer.reply(from, :ok)
    %{state | subscribers: MapSet.put(state.subscribers, pid)}
  end

  defp perform({:unsubscribe, pid}, from, state) do
    GenServer.reply(from, :ok)
    %{state | subscribers: MapSet.delete(state.subscribers, pid)}
  end

  defp perform(:pause, from, state) do
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end

    GenServer.reply(from, :ok)
    %{state | timer_ref: nil}
  end

  defp perform(:resume, from, state) do
    GenServer.reply(from, :ok)
    %{state | timer_ref: Process.send_after(self(), :perform_check, 1000)}
  end

  defp defer(state, request), do: %{state | deferred: state.deferred ++ [request]}

  # After a check, the requests deferred behind it are taken in order, up to
  # one that starts the next check.
  defp run_deferred(%{check: nil, deferred: [{request, from} | deferred]} = state),
    do: run_deferred(perform(request, from, %{state | deferred: deferred}))

  defp run_deferred(state), do: state

  # A check runs off this loop, so the checker answers get_status/1 and a
  # stop (a closing transport's) while a check waits on its target.
  defp start_check(state, request) do
    task = start_check_task(state.check_fn, state.target)

    check = %{
      task: task,
      timer: Process.send_after(self(), {:check_timeout, task.ref}, state.timeout),
      started: System.monotonic_time(:millisecond),
      timestamp: DateTime.utc_now(),
      reply_to: reply_to(request),
      periodic: request == :periodic
    }

    %{state | check: check}
  end

  defp reply_to({:reply, from}), do: from
  defp reply_to(:periodic), do: nil

  # The check function runs in a process of its own under a watcher task,
  # which is linked to the checker and traps exits: however the checker goes
  # down (a stop, a kill, its linker's exit), the watcher kills the check
  # with it, so a check that traps exits itself can't outlive the checker. A
  # check that crashes takes the watcher, and so the checker, down with it,
  # as it did when it was the checker's own task.
  defp start_check_task(check_fn, target) do
    Task.async(fn ->
      Process.flag(:trap_exit, true)
      watcher = self()
      callers = [watcher | Process.get(:"$callers", [])]

      {runner, monitor} =
        spawn_monitor(fn ->
          Process.put(:"$callers", callers)
          send(watcher, {:check_result, self(), check_fn.(target)})
        end)

      await_check(runner, monitor)
    end)
  end

  defp await_check(runner, monitor) do
    receive do
      {:check_result, ^runner, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^runner, reason} ->
        exit(reason)

      {:EXIT, _checker, _reason} ->
        Process.exit(runner, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^runner, _reason} -> exit(:shutdown)
        end
    end
  end

  # The watcher answers a shutdown at once, killing the check first.
  defp stop_check(task), do: Task.shutdown(task, @check_shutdown_ms)

  defp finish_check(%{check: check} = state, {status, details}) do
    Process.cancel_timer(check.timer)

    result = %{
      status: status,
      timestamp: check.timestamp,
      duration_ms: System.monotonic_time(:millisecond) - check.started,
      details: details
    }

    state = update_health_state(%{state | check: nil}, result)
    if check.reply_to, do: GenServer.reply(check.reply_to, result)

    state =
      if check.periodic,
        do: %{
          state
          | timer_ref: Process.send_after(self(), :perform_check, state.check_interval)
        },
        else: state

    run_deferred(state)
  end

  defp check_outcome({:ok, {:ok, details}}), do: {:healthy, details}
  defp check_outcome({:ok, {:error, reason}}), do: {:unhealthy, %{error: reason}}
  # As reported when the check's result was matched in this loop.
  defp check_outcome({:ok, other}),
    do: {:unhealthy, %{error: Exception.format(:error, %CaseClauseError{term: {:ok, other}})}}

  defp check_outcome({:exit, reason}), do: {:unhealthy, %{error: {:exit, reason}}}

  defp update_health_state(state, result) do
    new_state =
      case result.status do
        :healthy ->
          handle_successful_check(state)

        :unhealthy ->
          handle_failed_check(state)

          # Note: :degraded status was intentionally removed to simplify health check logic.
          # The system now uses a binary healthy/unhealthy model for clearer operational status.
          # Any partially functional states are treated as :unhealthy to ensure conservative
          # load balancing and monitoring decisions.
      end

    # Update history (keep last 100 entries)
    history = [result | state.history] |> Enum.take(100)

    %{new_state | last_check_time: result.timestamp, last_check_result: result, history: history}
  end

  defp handle_successful_check(state) do
    new_successes = state.consecutive_successes + 1

    new_status =
      cond do
        state.status == :healthy -> :healthy
        new_successes >= state.recovery_threshold -> :healthy
        true -> state.status
      end

    if new_status != state.status do
      notify_status_change(state, state.status, new_status)
    end

    %{state | status: new_status, consecutive_successes: new_successes, consecutive_failures: 0}
  end

  defp handle_failed_check(state) do
    new_failures = state.consecutive_failures + 1

    new_status =
      if new_failures >= state.failure_threshold do
        :unhealthy
      else
        state.status
      end

    if new_status != state.status do
      notify_status_change(state, state.status, new_status)
    end

    %{state | status: new_status, consecutive_failures: new_failures, consecutive_successes: 0}
  end

  defp notify_status_change(state, old_status, new_status) do
    Logger.info("Health check #{state.name}: #{old_status} -> #{new_status}")

    # Call custom callback if provided
    if state.on_status_change do
      Task.start(fn ->
        state.on_status_change.(old_status, new_status)
      end)
    end

    # Notify subscribers
    metadata = %{
      checker: state.name,
      target: state.target,
      timestamp: DateTime.utc_now(),
      consecutive_failures: state.consecutive_failures,
      consecutive_successes: state.consecutive_successes
    }

    Enum.each(state.subscribers, fn pid ->
      send(pid, {:health_status_changed, old_status, new_status, metadata})
    end)
  end

  defp default_check_fn(target) when is_pid(target) or is_atom(target) do
    fn target ->
      # For generic process health, just check if it's alive
      try do
        if Process.alive?(target) do
          {:ok, %{alive: true}}
        else
          {:error, :process_not_alive}
        end
      catch
        :exit, reason -> {:error, {:exit, reason}}
      end
    end
  end

  @doc """
  Creates a health check function for MCP clients.

  This function attempts to list tools as a health check.
  """
  @spec mcp_client_check_fn() :: (pid() -> {:ok, map()} | {:error, any()})
  def mcp_client_check_fn do
    fn client ->
      case Arbor.MCP.Client.list_tools(client) do
        {:ok, result} ->
          tool_count = length(Map.get(result, "tools", []))
          {:ok, %{method: :list_tools, tool_count: tool_count}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Creates a health check function for MCP servers.

  This function sends an initialize request to check server health.
  """
  @spec mcp_server_check_fn() :: (pid() -> {:ok, map()} | {:error, any()})
  def mcp_server_check_fn do
    fn server ->
      request = %{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{
            "name" => "Arbor.MCP HealthCheck",
            "version" => "1.0.0"
          }
        }
      }

      case GenServer.call(server, {:mcp_request, request}, 5000) do
        {:ok, %{"result" => result}} ->
          {:ok,
           %{
             method: :initialize,
             protocol_version: result["protocolVersion"],
             server_name: get_in(result, ["serverInfo", "name"])
           }}

        {:error, reason} ->
          {:error, reason}

        _ ->
          {:error, :invalid_response}
      end
    end
  end
end
