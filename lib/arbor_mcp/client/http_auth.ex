defmodule Arbor.MCP.Client.HTTPAuth do
  @moduledoc false

  alias Arbor.MCP.Client.{ConnectionScope, Deadline, Lifetime}
  alias Arbor.MCP.Transport.HTTP

  @auth_wait_ms 600_000
  @derive {Inspect, except: [:waiters]}
  defstruct worker: nil, waiters: %{}, monitors: %{}

  # The client owns one inline flow. Its challengers retain separate deadlines
  # and monitors; the OAuth worker itself never sends an application request.
  def challenge(state, kind, pid, request_id, ref, challenge) do
    deadline = Deadline.earliest(Map.get(challenge, :deadline), Deadline.after_ms(@auth_wait_ms))

    waiter = %{kind: kind, pid: pid, request_id: request_id, ref: ref, deadline: deadline}

    cond do
      Deadline.expired?(deadline) ->
        reply(waiter, {:error, :timeout}, state.transport_state)
        state

      token = cached_token(state.transport_state, challenge) ->
        reply(waiter, {:ok, token}, state.transport_state)
        state

      true ->
        monitor = Process.monitor(pid)

        timer =
          Process.send_after(
            self(),
            {:http_auth_waiter_timeout, ref},
            Deadline.remaining(deadline)
          )

        waiter = Map.merge(waiter, %{monitor: monitor, timer: timer})
        auth = state.http_auth

        auth = %{
          auth
          | waiters: Map.put(auth.waiters, ref, waiter),
            monitors: Map.put(auth.monitors, monitor, ref)
        }

        state = %{state | http_auth: auth}
        state = if auth.worker, do: state, else: start_worker(state, challenge)
        update_bound(state)
    end
  end

  def cached_token(%HTTP{access_token: current} = transport, challenge)
      when is_binary(current) and current != :erlang.map_get(:token, challenge) do
    if challenge.status == 401 or scopes_granted?(granted_scopes(transport), challenge.scopes),
      do: current
  end

  def cached_token(_transport, _challenge), do: nil

  def reply(%{kind: :post, pid: pid, ref: ref}, {:ok, token}, transport) do
    context = %{session_id: transport.session_id, headers: transport.headers}
    send(pid, {:http_post_auth_result, ref, {:ok, token, context}})
  end

  def reply(%{kind: :post, pid: pid, ref: ref}, result, _transport),
    do: send(pid, {:http_post_auth_result, ref, result})

  def reply(%{kind: :stream, pid: pid, ref: ref}, result, _transport),
    do: send(pid, {:modern_http_stream_auth_result, ref, result})

  def result(%{http_auth: %{worker: %{pid: pid, id: id}}} = state, pid, id, result) do
    state = stop_worker(state)

    transport =
      case result do
        {:ok, token, scopes} ->
          if Enum.any?(state.http_auth.waiters, fn {_ref, waiter} -> live?(waiter, state) end) do
            HTTP.put_oauth_token(
              state.transport_state,
              %{access_token: token, scope: Enum.join(scopes, " ")},
              scopes
            )
          else
            state.transport_state
          end

        {:error, _reason} ->
          state.transport_state
      end

    reply_result =
      case result do
        {:ok, token, _scopes} -> {:ok, token}
        error -> error
      end

    finish_waiters(%{state | transport_state: transport}, reply_result)
  end

  def result(state, _pid, _id, _result), do: state

  def waiter_timeout(state, ref) do
    case Map.get(state.http_auth.waiters, ref) do
      nil ->
        state

      waiter ->
        reply(waiter, {:error, :timeout}, state.transport_state)
        state |> remove_waiter(ref) |> update_bound()
    end
  end

  def worker_timeout(
        %{http_auth: %{worker: %{id: id, deadline: deadline}}} = state,
        id,
        deadline
      ),
      do: state |> stop_worker() |> finish_waiters({:error, :timeout})

  def worker_timeout(state, _id, _deadline), do: state

  def down(%{http_auth: %{worker: %{monitor: ref}}} = state, ref),
    do:
      state
      |> stop_worker()
      |> finish_waiters({:error, {:oauth_failed, :authentication_worker_failed}})

  def down(state, monitor) do
    case Map.get(state.http_auth.monitors, monitor) do
      nil -> state
      ref -> state |> remove_waiter(ref) |> update_bound()
    end
  end

  def cancel_request(state, request_id) do
    state.http_auth.waiters
    |> Enum.filter(fn {_ref, waiter} -> waiter.request_id == request_id end)
    |> Enum.reduce(state, fn {ref, waiter}, acc ->
      reply(waiter, {:error, :stream_retired}, acc.transport_state)
      remove_waiter(acc, ref)
    end)
    |> update_bound()
  end

  def retire(state) do
    state |> stop_worker() |> finish_waiters({:error, :client_disconnected})
  end

  defp start_worker(state, challenge) do
    parent = self()
    id = make_ref()
    transport = state.transport_state

    {pid, monitor} =
      ConnectionScope.spawn_monitor(fn ->
        result =
          case HTTP.answer_challenge_inline(transport, challenge) do
            {{:ok, token}, authenticated} -> {:ok, token, authenticated.granted_scopes}
            {{:error, reason}, _transport} -> {:error, reason}
          end

        Lifetime.deliver(parent, {:http_inline_auth_result, self(), id, result})
      end)

    worker = %{pid: pid, monitor: monitor, id: id, timer: nil, deadline: nil}
    %{state | http_auth: %{state.http_auth | worker: worker}}
  end

  defp update_bound(%{http_auth: %{worker: nil}} = state), do: state

  defp update_bound(%{http_auth: %{waiters: waiters}} = state) when map_size(waiters) == 0,
    do: stop_worker(state)

  defp update_bound(state) do
    worker = state.http_auth.worker

    deadline =
      state.http_auth.waiters |> Enum.map(fn {_ref, waiter} -> waiter.deadline end) |> Enum.max()

    cancel_timer(worker.timer)

    timer =
      Process.send_after(
        self(),
        {:http_auth_worker_timeout, worker.id, deadline},
        Deadline.remaining(deadline)
      )

    %{
      state
      | http_auth: %{state.http_auth | worker: %{worker | deadline: deadline, timer: timer}}
    }
  end

  defp stop_worker(%{http_auth: %{worker: nil}} = state), do: state

  defp stop_worker(state) do
    worker = state.http_auth.worker
    cancel_timer(worker.timer)
    Process.demonitor(worker.monitor, [:flush])
    if Process.alive?(worker.pid), do: Process.exit(worker.pid, :kill)
    %{state | http_auth: %{state.http_auth | worker: nil}}
  end

  defp finish_waiters(state, result) do
    Enum.reduce(state.http_auth.waiters, state, fn {ref, waiter}, acc ->
      outcome =
        cond do
          Deadline.expired?(waiter.deadline) -> {:error, :timeout}
          not eligible?(waiter, acc) -> {:error, :stream_retired}
          true -> result
        end

      reply(waiter, outcome, acc.transport_state)
      remove_waiter(acc, ref)
    end)
  end

  defp remove_waiter(state, ref) do
    {waiter, waiters} = Map.pop(state.http_auth.waiters, ref)
    cancel_timer(waiter.timer)
    Process.demonitor(waiter.monitor, [:flush])

    %{
      state
      | http_auth: %{
          state.http_auth
          | waiters: waiters,
            monitors: Map.delete(state.http_auth.monitors, waiter.monitor)
        }
    }
  end

  defp live?(waiter, state),
    do: not Deadline.expired?(waiter.deadline) and eligible?(waiter, state)

  defp eligible?(%{kind: :stream, pid: pid, request_id: id}, state),
    do: HTTP.stream_owner?(state.transport_state, id, pid)

  defp eligible?(%{kind: :post, pid: pid, request_id: id}, state) do
    (is_nil(id) or Map.has_key?(state.pending_requests, id)) and
      Enum.any?(state.async_post_tasks, fn {_ref, entry} -> entry == {pid, id} end)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: false, info: false)

  defp granted_scopes(%HTTP{auth_provider: nil, granted_scopes: scopes}), do: scopes
  defp granted_scopes(%HTTP{auth_provider_state: %{granted_scopes: scopes}}), do: scopes
  defp granted_scopes(_transport), do: []

  defp scopes_granted?(granted, [_ | _] = scopes) when is_list(granted),
    do: Enum.all?(scopes, &(&1 in granted))

  defp scopes_granted?(_granted, _scopes), do: false
end
