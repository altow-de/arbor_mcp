defmodule Arbor.MCP.Server.Cancellation do
  @moduledoc false

  # Supervised owner of the table that lets a handler-process callback observe
  # `notifications/cancelled` through `Arbor.MCP.Server.Context.cancelled?/0`
  # while the callback is still running.
  #
  # Rows are keyed by `{scope, request_id}`. The scope identifies who sent the
  # request (an HTTP session, or an authenticated principal for sessionless
  # requests), so a cancellation only reaches requests from its own scope. The
  # process dispatching a request registers its row and removes it when
  # dispatch ends; a cancellation only flags a row that already exists, so
  # unknown or foreign request ids never add rows. Registration stops at a
  # fixed cap, and a periodic sweep removes rows whose owner exited without
  # running its cleanup (for example a killed HTTP request process).

  use GenServer

  @table :ex_mcp_cancelled_requests
  @limits_key :__limits__
  @default_max_rows 65_536
  @default_sweep_interval 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Runs `fun` with `{scope, request_id}` registered as cancellable when both
  are known. The row belongs to the calling process and is removed when `fun`
  returns or raises. Without a scope, or once the table is full, `fun` still
  runs but cannot be cancelled through this table.
  """
  @spec track(term(), term(), (-> result)) :: result when result: var
  def track(scope, request_id, fun) when is_function(fun, 0) do
    key = {scope, request_id}

    if not is_nil(scope) and not is_nil(request_id) and register(key) do
      try do
        fun.()
      after
        unregister(key)
      end
    else
      fun.()
    end
  end

  @doc "Flags the in-flight `request_id` of `scope`; unknown requests are ignored."
  @spec cancel(term(), term()) :: :ok
  def cancel(scope, request_id) when is_nil(scope) or is_nil(request_id), do: :ok

  def cancel(scope, request_id) do
    _updated? = :ets.update_element(@table, {scope, request_id}, {3, true})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec cancel_from_message(term(), term()) :: :ok
  def cancel_from_message(scope, %{"method" => "notifications/cancelled", "params" => params})
      when is_map(params),
      do: cancel(scope, Map.get(params, "requestId"))

  def cancel_from_message(_scope, _message), do: :ok

  @spec cancelled?(term(), term()) :: boolean()
  def cancelled?(scope, request_id) when is_nil(scope) or is_nil(request_id), do: false

  def cancelled?(scope, request_id) do
    match?([{_key, _owner, true}], :ets.lookup(@table, {scope, request_id}))
  rescue
    ArgumentError -> false
  end

  @doc false
  # Removes rows whose owner has exited and returns how many were removed.
  @spec sweep() :: non_neg_integer()
  def sweep, do: GenServer.call(__MODULE__, :sweep)

  defp register(key) do
    case :ets.lookup(@table, @limits_key) do
      # The limits row is the only non-request row in the table.
      [{@limits_key, max_rows}] ->
        :ets.info(@table, :size) <= max_rows and :ets.insert_new(@table, {key, self(), false})

      [] ->
        false
    end
  rescue
    ArgumentError -> false
  end

  defp unregister(key) do
    :ets.match_delete(@table, {key, self(), :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(opts) do
    max_rows = Keyword.get(opts, :max_rows, @default_max_rows)
    sweep_interval = Keyword.get(opts, :sweep_interval, @default_sweep_interval)

    table =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    :ets.insert(table, {@limits_key, max_rows})
    schedule_sweep(sweep_interval)
    {:ok, %{sweep_interval: sweep_interval}}
  end

  @impl true
  def handle_call(:sweep, _from, state), do: {:reply, remove_orphans(), state}

  @impl true
  def handle_info(:sweep, state) do
    remove_orphans()
    schedule_sweep(state.sweep_interval)
    {:noreply, state}
  end

  defp remove_orphans do
    @table
    |> :ets.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.count(fn {key, owner} ->
      not Process.alive?(owner) and :ets.match_delete(@table, {key, owner, :_})
    end)
  end

  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)
end
