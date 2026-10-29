defmodule Arbor.MCP.Reliability.HealthCheckTest.MockTarget do
  @moduledoc false
  use GenServer

  def init(state) do
    {:ok, state}
  end

  def handle_call(:ping, _from, state) do
    reply =
      case state do
        :healthy -> :pong
        # Will customize check function instead
        :failing -> :pong
        _ -> :pong
      end

    {:reply, reply, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:update, fun}, _from, state) do
    new_state = fun.(state)
    {:reply, :ok, new_state}
  end

  # For toggle functionality
  def handle_cast({:set_state, new_state}, _state) do
    {:noreply, new_state}
  end

  # For Agent.update compatibility in toggle tests
  def handle_cast({:update, fun}, state) do
    {:noreply, fun.(state)}
  end
end

defmodule Arbor.MCP.Reliability.HealthCheckTest do
  use ExUnit.Case, async: true

  import Arbor.MCP.TestHelpers, only: [wait_until: 2]

  alias Arbor.MCP.Reliability.HealthCheck

  setup do
    checker_name = :"test_checker_#{System.unique_integer([:positive])}"
    {:ok, checker_name: checker_name}
  end

  describe "health monitoring" do
    test "starts with unknown status", context do
      {:ok, target} = Agent.start_link(fn -> :ok end)

      # Provide a custom check function that works with Agent
      check_fn = fn agent ->
        try do
          Agent.get(agent, & &1)
          {:ok, %{status: :ok}}
        catch
          _, _ -> {:error, :check_failed}
        end
      end

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: target,
          check_fn: check_fn,
          check_interval: 60_000
        )

      {status, _info} = HealthCheck.get_status(checker)
      assert status == :unknown
    end

    test "becomes healthy after successful checks", context do
      {:ok, target} = start_healthy_target()

      check_fn = fn target ->
        case GenServer.call(target, :ping) do
          :pong -> {:ok, %{status: :healthy}}
          _ -> {:error, :unhealthy}
        end
      end

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: target,
          check_fn: check_fn,
          check_interval: 10_000,
          recovery_threshold: 2
        )

      # Trigger immediate checks
      HealthCheck.check_now(checker)
      HealthCheck.check_now(checker)

      {status, info} = HealthCheck.get_status(checker)
      assert status == :healthy
      assert info.consecutive_successes >= 2
    end

    test "becomes unhealthy after failed checks", context do
      {:ok, target} = start_failing_target()

      # Custom check function that actually fails for failing target
      check_fn = fn target ->
        case GenServer.call(target, :get_state) do
          :failing -> {:error, :unhealthy}
          _ -> {:ok, %{}}
        end
      end

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: target,
          check_fn: check_fn,
          check_interval: 10_000,
          failure_threshold: 2
        )

      # Trigger immediate checks
      HealthCheck.check_now(checker)
      HealthCheck.check_now(checker)

      {status, info} = HealthCheck.get_status(checker)
      assert status == :unhealthy
      assert info.consecutive_failures >= 2
    end

    test "recovers from unhealthy to healthy", context do
      {:ok, target} = start_toggle_target()

      # Custom check function that checks the state
      check_fn = fn target ->
        case GenServer.call(target, :get_state) do
          :failing -> {:error, :unhealthy}
          _ -> {:ok, %{}}
        end
      end

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: target,
          check_fn: check_fn,
          check_interval: 10_000,
          failure_threshold: 2,
          recovery_threshold: 2
        )

      # Make it unhealthy
      HealthCheck.check_now(checker)
      HealthCheck.check_now(checker)

      {status, _} = HealthCheck.get_status(checker)
      assert status == :unhealthy

      # Toggle to healthy
      GenServer.call(target, {:update, fn _ -> :healthy end})

      # Make it healthy again
      HealthCheck.check_now(checker)
      HealthCheck.check_now(checker)

      {status, _} = HealthCheck.get_status(checker)
      assert status == :healthy
    end
  end

  describe "custom check functions" do
    test "uses custom check function", context do
      {:ok, target} = Agent.start_link(fn -> 42 end)

      check_fn = fn target ->
        value = Agent.get(target, & &1)

        if value > 40 do
          {:ok, %{value: value}}
        else
          {:error, :value_too_low}
        end
      end

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: target,
          check_fn: check_fn,
          check_interval: 10_000
        )

      result = HealthCheck.check_now(checker)
      assert result.status == :healthy
      assert result.details.value == 42
    end
  end

  describe "subscriptions" do
    test "notifies subscribers of status changes", context do
      {:ok, target} = start_toggle_target()

      # Custom check function that checks the state
      check_fn = fn target ->
        case GenServer.call(target, :get_state) do
          :failing -> {:error, :unhealthy}
          _ -> {:ok, %{}}
        end
      end

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: target,
          check_fn: check_fn,
          check_interval: 10_000,
          failure_threshold: 1,
          recovery_threshold: 1
        )

      # Subscribe to changes
      HealthCheck.subscribe(checker)

      # Make it healthy
      GenServer.call(target, {:update, fn _ -> :healthy end})
      HealthCheck.check_now(checker)

      assert_receive {:health_status_changed, :unknown, :healthy, metadata}
      assert metadata.checker == context.checker_name

      # Make it unhealthy
      GenServer.call(target, {:update, fn _ -> :failing end})
      HealthCheck.check_now(checker)

      assert_receive {:health_status_changed, :healthy, :unhealthy, _metadata}
    end

    test "handles subscriber crashes", context do
      {:ok, target} = start_healthy_target()

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: target,
          check_interval: 10_000
        )

      # Start a subscriber that will crash
      spawn(fn ->
        HealthCheck.subscribe(checker)
        Process.sleep(10)
        exit(:boom)
      end)

      Process.sleep(50)

      # Should still work
      result = HealthCheck.check_now(checker)
      assert result.status == :healthy
    end
  end

  describe "pause and resume" do
    test "pauses health checks", context do
      {:ok, target} = start_healthy_target()
      check_count = start_counter()

      check_fn = fn target ->
        increment_counter(check_count)

        case GenServer.call(target, :ping) do
          :pong -> {:ok, %{}}
          _ -> {:error, :ping_failed}
        end
      end

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: target,
          check_fn: check_fn,
          check_interval: 50
        )

      # Trigger some immediate checks first
      HealthCheck.check_now(checker)
      HealthCheck.check_now(checker)

      # Let it run a bit and make sure we get some checks
      Process.sleep(150)
      initial_count = get_counter(check_count)
      assert initial_count >= 2

      # Pause
      HealthCheck.pause(checker)
      Process.sleep(120)

      # Count shouldn't increase
      assert get_counter(check_count) == initial_count

      # Resume
      HealthCheck.resume(checker)
      # Trigger immediate check after resume
      HealthCheck.check_now(checker)
      HealthCheck.check_now(checker)
      Process.sleep(150)

      # Should be checking again
      final_count = get_counter(check_count)

      assert final_count > initial_count,
             "Expected count to increase from #{initial_count} but got #{final_count}"
    end
  end

  describe "history tracking" do
    test "maintains check history", context do
      {:ok, target} = start_healthy_target()

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: target,
          check_interval: 10_000
        )

      # Perform multiple checks
      for _ <- 1..5 do
        HealthCheck.check_now(checker)
      end

      history = HealthCheck.get_history(checker, 3)
      assert length(history) == 3
      assert Enum.all?(history, &(&1.status == :healthy))
    end
  end

  describe "status change callbacks" do
    test "calls on_status_change callback", context do
      {:ok, target} = start_toggle_target()
      test_pid = self()

      on_status_change = fn old_status, new_status ->
        send(test_pid, {:status_changed, old_status, new_status})
      end

      # Custom check function that checks the state
      check_fn = fn target ->
        case GenServer.call(target, :get_state) do
          :failing -> {:error, :unhealthy}
          _ -> {:ok, %{}}
        end
      end

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: target,
          check_fn: check_fn,
          check_interval: 10_000,
          failure_threshold: 1,
          # Only need 1 success to become healthy
          recovery_threshold: 1,
          on_status_change: on_status_change
        )

      # Make it healthy
      GenServer.call(target, {:update, fn _ -> :healthy end})
      HealthCheck.check_now(checker)

      # The callback runs in a task of its own.
      assert_receive {:status_changed, :unknown, :healthy}
    end
  end

  describe "MCP-specific health checks" do
    test "MCP client check function", context do
      # Mock MCP client
      {:ok, mock_client} =
        Agent.start_link(fn ->
          %{"tools" => [%{"name" => "tool1"}, %{"name" => "tool2"}]}
        end)

      # Mock client check function for testing
      check_fn = fn client ->
        result = Agent.get(client, & &1)
        tool_count = length(Map.get(result, "tools", []))
        {:ok, %{method: :list_tools, tool_count: tool_count}}
      end

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: mock_client,
          check_fn: check_fn,
          check_interval: 10_000
        )

      result = HealthCheck.check_now(checker)
      assert result.status == :healthy
      assert result.details.tool_count == 2
    end
  end

  # A check runs in a task of the checker's, never in its loop: a check
  # waiting on its target used to hold get_status/1 and a stop (a closing
  # transport's) for the check's whole timeout.
  describe "a check in progress" do
    setup context do
      test_pid = self()

      check_fn = fn _target ->
        send(test_pid, {:checking, self()})

        receive do
          :finish -> {:ok, %{}}
        end
      end

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: self(),
          check_fn: check_fn,
          check_interval: 60_000,
          timeout: 30_000
        )

      {:ok, checker: checker}
    end

    test "doesn't hold the checker's answers", %{checker: checker} do
      asker = Task.async(fn -> HealthCheck.check_now(checker) end)
      assert_receive {:checking, check}

      assert {:unknown, _info} = HealthCheck.get_status(checker)

      send(check, :finish)
      assert %{status: :healthy} = result = Task.await(asker)
      assert [^result] = HealthCheck.get_history(checker)
    end

    # A caller of check_now/1 expects a sample taken after its call.
    test "is followed by a check of its own for a check_now/1 asked meanwhile",
         %{checker: checker} do
      first = Task.async(fn -> HealthCheck.check_now(checker) end)
      assert_receive {:checking, check}

      second = Task.async(fn -> HealthCheck.check_now(checker) end)
      wait_until(fn -> length(:sys.get_state(checker).deferred) == 1 end, timeout: 2_000)
      refute_received {:checking, _another}

      send(check, :finish)
      assert %{status: :healthy} = first_result = Task.await(first)
      assert_receive {:checking, next}
      assert next != check

      send(next, :finish)
      assert %{status: :healthy} = second_result = Task.await(second)
      assert [^second_result, ^first_result] = HealthCheck.get_history(checker)
    end

    test "is taken down by a stop, which doesn't wait for it", %{checker: checker} do
      _asker = spawn(fn -> HealthCheck.check_now(checker) end)
      assert_receive {:checking, check}
      check_ref = Process.monitor(check)

      assert :ok = GenServer.stop(checker, :normal, 1_000)
      assert_receive {:DOWN, ^check_ref, :process, ^check, :killed}
    end
  end

  # Calls other than get_status/1 are taken after a check in progress, as
  # when checks ran in the checker's loop, so a subscriber hears of exactly
  # the transitions it would have.
  describe "a subscription call during a check" do
    setup context do
      test_pid = self()

      {:ok, checker} =
        HealthCheck.start_link(
          name: context.checker_name,
          target: self(),
          check_fn: fn _target ->
            send(test_pid, {:checking, self()})

            receive do
              :finish -> {:ok, %{}}
            end
          end,
          check_interval: 60_000,
          timeout: 30_000,
          recovery_threshold: 1
        )

      {:ok, checker: checker}
    end

    test "an unsubscribe/1 still gets that check's notification", %{checker: checker} do
      test_pid = self()

      subscriber =
        spawn_link(fn ->
          :ok = HealthCheck.subscribe(checker)
          send(test_pid, :subscribed)
          receive do: (:unsubscribe -> :ok)
          :ok = HealthCheck.unsubscribe(checker)
          send(test_pid, {:notified, notification()})
        end)

      assert_receive :subscribed
      asker = Task.async(fn -> HealthCheck.check_now(checker) end)
      assert_receive {:checking, check}

      send(subscriber, :unsubscribe)
      wait_until(fn -> reached?(checker, {:unsubscribe, subscriber}) end, timeout: 2_000)

      send(check, :finish)
      assert %{status: :healthy} = Task.await(asker)
      assert_receive {:notified, {:health_status_changed, :unknown, :healthy, _metadata}}
    end

    test "a subscribe/1 doesn't get that check's notification", %{checker: checker} do
      test_pid = self()
      asker = Task.async(fn -> HealthCheck.check_now(checker) end)
      assert_receive {:checking, check}

      subscriber =
        spawn_link(fn ->
          :ok = HealthCheck.subscribe(checker)
          receive do: (:report -> :ok)
          # A notification would come before this answer.
          HealthCheck.get_status(checker)
          send(test_pid, {:notified, notification()})
        end)

      wait_until(fn -> reached?(checker, {:subscribe, subscriber}) end, timeout: 2_000)

      send(check, :finish)
      assert %{status: :healthy} = Task.await(asker)
      send(subscriber, :report)
      assert_receive {:notified, :none}
    end
  end

  # Killing the checker skips terminate/2, and its link only sends a check
  # that traps exits a message.
  test "a check that traps exits doesn't outlive a checker that is killed", context do
    test_pid = self()

    {:ok, checker} =
      HealthCheck.start_link(
        name: context.checker_name,
        target: self(),
        check_fn: fn _target ->
          Process.flag(:trap_exit, true)
          send(test_pid, {:checking, self()})
          receive do: (:never -> {:ok, %{}})
        end,
        check_interval: 60_000,
        timeout: 30_000
      )

    Process.unlink(checker)
    _asker = spawn(fn -> HealthCheck.check_now(checker) end)
    assert_receive {:checking, check}
    on_exit(fn -> Process.exit(check, :kill) end)
    check_ref = Process.monitor(check)

    Process.exit(checker, :kill)
    assert_receive {:DOWN, ^check_ref, :process, ^check, :killed}
  end

  # Matchers written for the error a check's unexpected result reported
  # keep working.
  test "a check's unexpected result is reported as before", context do
    {:ok, checker} =
      HealthCheck.start_link(
        name: context.checker_name,
        target: self(),
        check_fn: fn _target -> :weird end,
        check_interval: 60_000
      )

    assert %{status: :unhealthy, details: %{error: error}} = HealthCheck.check_now(checker)
    assert error == "** (CaseClauseError) no case clause matching:\n\n    {:ok, :weird}\n"
  end

  test "a check that outlives its timeout is unhealthy and stopped", context do
    test_pid = self()

    {:ok, checker} =
      HealthCheck.start_link(
        name: context.checker_name,
        target: self(),
        check_fn: fn _target ->
          send(test_pid, {:checking, self()})
          receive do: (:never -> {:ok, %{}})
        end,
        check_interval: 60_000,
        timeout: 50
      )

    assert %{status: :unhealthy, details: %{error: :timeout}} = HealthCheck.check_now(checker)
    assert_receive {:checking, check}
    refute Process.alive?(check)
  end

  defp notification do
    receive do
      {:health_status_changed, _old, _new, _metadata} = notification -> notification
    after
      0 -> :none
    end
  end

  # Whether the checker has taken `request` from its caller: done, or put
  # behind the check in progress.
  defp reached?(checker, {action, subscriber} = request) do
    state = :sys.get_state(checker)
    deferred = Enum.any?(Map.get(state, :deferred, []), &match?({^request, _from}, &1))
    subscribed = MapSet.member?(state.subscribers, subscriber)

    deferred or (action == :subscribe and subscribed) or
      (action == :unsubscribe and not subscribed)
  end

  # Helper functions
  defp start_healthy_target do
    {:ok, pid} = GenServer.start_link(__MODULE__.MockTarget, :healthy)
    {:ok, pid}
  end

  defp start_failing_target do
    {:ok, pid} = GenServer.start_link(__MODULE__.MockTarget, :failing)
    {:ok, pid}
  end

  defp start_toggle_target do
    # Starts failing, can be toggled
    {:ok, pid} = GenServer.start_link(__MODULE__.MockTarget, :failing)
    {:ok, pid}
  end

  defp start_counter do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    agent
  end

  defp increment_counter(agent) do
    Agent.get_and_update(agent, fn count -> {count + 1, count + 1} end)
  end

  defp get_counter(agent) do
    Agent.get(agent, & &1)
  end
end
