defmodule Arbor.MCP.Transport.ReliabilityWrapperTest do
  use ExUnit.Case, async: true
  alias Arbor.MCP.Client.Deadline
  alias Arbor.MCP.Transport.{ReliabilityWrapper, Test}

  defmodule StatefulFailure do
    @behaviour Arbor.MCP.Transport
    @impl true
    def connect(_opts), do: {:ok, 0}
    @impl true
    def send_message(_message, _state), do: {:error, {:connection_error, :refused}}
    @doc false
    def send_message_with_state(_message, state),
      do: {:error, {:connection_error, :refused}, state + 1}

    @impl true
    def receive_message(state), do: {:ok, "", state}
    @impl true
    def close(_state), do: :ok
    @impl true
    def connected?(_state), do: true
  end

  test "public wrapped failures keep two-tuples while internal sends retain state" do
    assert {:ok, wrapped} = ReliabilityWrapper.wrap(StatefulFailure, 0, [])
    on_exit(fn -> ReliabilityWrapper.close(wrapped) end)

    assert {:error, {:connection_error, :refused}} =
             ReliabilityWrapper.send_message("body", wrapped)

    assert {:error, {:connection_error, :refused}, %{wrapped_state: 1}} =
             ReliabilityWrapper.send_message_with_state("body", wrapped)
  end

  @tag :reauth_round8
  test "failed sends preserve wrapped state and still count toward the circuit breaker" do
    assert {:ok, wrapped} =
             ReliabilityWrapper.wrap(StatefulFailure, 0, circuit_breaker: [failure_threshold: 1])

    on_exit(fn -> ReliabilityWrapper.close(wrapped) end)

    assert {:error, {:connection_error, :refused}, updated} =
             ReliabilityWrapper.send_message_with_state("body", wrapped)

    assert updated.wrapped_state == 1
    assert {:error, :circuit_open} = ReliabilityWrapper.send_message("body", updated)
  end

  describe "wrap/3" do
    test "successfully wraps a transport with circuit breaker" do
      {:ok, transport_state} = Test.connect([])

      reliability_opts = [
        circuit_breaker: [
          failure_threshold: 3,
          reset_timeout: 1000
        ]
      ]

      assert {:ok, wrapped_state} =
               ReliabilityWrapper.wrap(Test, transport_state, reliability_opts)

      assert %ReliabilityWrapper{} = wrapped_state
      assert wrapped_state.wrapped_module == Test
      assert wrapped_state.wrapped_state == transport_state
      assert is_pid(wrapped_state.circuit_breaker_pid)
      assert wrapped_state.health_check_pid == nil
    end

    test "successfully wraps a transport with health check" do
      {:ok, transport_state} = Test.connect([])

      reliability_opts = [
        health_check: [
          check_interval: 1000,
          failure_threshold: 2
        ]
      ]

      assert {:ok, wrapped_state} =
               ReliabilityWrapper.wrap(Test, transport_state, reliability_opts)

      assert %ReliabilityWrapper{} = wrapped_state
      assert wrapped_state.circuit_breaker_pid == nil
      assert is_pid(wrapped_state.health_check_pid)
    end

    test "successfully wraps a transport with both circuit breaker and health check" do
      {:ok, transport_state} = Test.connect([])

      reliability_opts = [
        circuit_breaker: [failure_threshold: 2],
        health_check: [check_interval: 1000]
      ]

      assert {:ok, wrapped_state} =
               ReliabilityWrapper.wrap(Test, transport_state, reliability_opts)

      assert %ReliabilityWrapper{} = wrapped_state
      assert is_pid(wrapped_state.circuit_breaker_pid)
      assert is_pid(wrapped_state.health_check_pid)
    end

    test "disables components when set to false" do
      {:ok, transport_state} = Test.connect([])

      reliability_opts = [
        circuit_breaker: false,
        health_check: false
      ]

      assert {:ok, wrapped_state} =
               ReliabilityWrapper.wrap(Test, transport_state, reliability_opts)

      assert wrapped_state.circuit_breaker_pid == nil
      assert wrapped_state.health_check_pid == nil
    end
  end

  describe "send_message/2" do
    test "passes through successful operations" do
      {:ok, transport_state} = Test.connect([])

      reliability_opts = [
        circuit_breaker: [failure_threshold: 3]
      ]

      {:ok, wrapped_state} = ReliabilityWrapper.wrap(Test, transport_state, reliability_opts)

      assert {:ok, updated_state} = ReliabilityWrapper.send_message("test message", wrapped_state)
      assert %ReliabilityWrapper{} = updated_state
    end

    test "handles transport errors through circuit breaker" do
      # Create a mock transport that will fail
      defmodule FailingTransport do
        @behaviour Arbor.MCP.Transport

        def connect(_opts), do: {:ok, %{fail_count: 0}}

        def send_message(_message, state) do
          new_state = %{state | fail_count: state.fail_count + 1}

          if new_state.fail_count <= 2 do
            {:error, {:connection_error, :simulated_failure}}
          else
            {:ok, new_state}
          end
        end

        def receive_message(state), do: {:ok, "response", state}
        def close(_state), do: :ok
        def connected?(_state), do: true
      end

      {:ok, transport_state} = FailingTransport.connect([])

      reliability_opts = [
        circuit_breaker: [
          failure_threshold: 2,
          reset_timeout: 100
        ]
      ]

      {:ok, wrapped_state} =
        ReliabilityWrapper.wrap(FailingTransport, transport_state, reliability_opts)

      # First failure
      assert {:error, {:connection_error, :simulated_failure}} =
               ReliabilityWrapper.send_message("test", wrapped_state)

      # Second failure
      assert {:error, {:connection_error, :simulated_failure}} =
               ReliabilityWrapper.send_message("test", wrapped_state)

      # Circuit should now be open
      assert {:error, :circuit_open} =
               ReliabilityWrapper.send_message("test", wrapped_state)
    end

    # A synchronous transport answers send_message/2 with {:ok, state,
    # response} and receive_message with {:ok, message, state}; the wrapper
    # used to read both as {:ok, result, state}, which swapped the state and
    # the response of a send.
    # A caller bounds a transport's close and kills it at its deadline (a
    # stuck stdio server, a stalled HTTP session DELETE), so the components
    # must already be stopped by then, or they outlive the transport.
    test "close stops its components before the wrapped transport's close" do
      defmodule BlockingCloseTransport do
        @behaviour Arbor.MCP.Transport

        def connect(opts), do: {:ok, %{test: opts[:test]}}
        def send_message(_message, state), do: {:ok, state}
        def receive_message(state), do: {:ok, "message", state}
        def connected?(_state), do: true

        def close(state) do
          send(state.test, {:closing, self()})

          receive do
            :finish -> :ok
          end
        end
      end

      {:ok, transport_state} = BlockingCloseTransport.connect(test: self())

      {:ok, wrapped} =
        ReliabilityWrapper.wrap(BlockingCloseTransport, transport_state,
          circuit_breaker: [failure_threshold: 3],
          health_check: [check_interval: 60_000]
        )

      breaker_ref = Process.monitor(wrapped.circuit_breaker_pid)
      checker_ref = Process.monitor(wrapped.health_check_pid)
      closer = Task.async(fn -> ReliabilityWrapper.close(wrapped) end)

      assert_receive {:closing, closing}, 2_000
      # Both are down while the transport's close is still running.
      assert_receive {:DOWN, ^breaker_ref, :process, _breaker, _reason}, 2_000
      assert_receive {:DOWN, ^checker_ref, :process, _checker, _reason}, 2_000

      send(closing, :finish)
      assert :ok = Task.await(closer)
    end

    # A health check waiting on its target held the checker's loop, so
    # close/1 waited out its stop and killed it, and the kill took down the
    # process that wrapped the transport when another one closed it.
    test "close stops a checker mid-check gracefully, sparing the wrapper's owner" do
      defmodule ClosingTransport do
        @behaviour Arbor.MCP.Transport

        def connect(opts), do: {:ok, %{test: opts[:test]}}
        def send_message(_message, state), do: {:ok, state}
        def receive_message(state), do: {:ok, "message", state}
        def connected?(_state), do: true

        def close(state) do
          send(state.test, :transport_closed)
          :ok
        end
      end

      test_pid = self()
      {:ok, transport_state} = ClosingTransport.connect(test: test_pid)

      {:ok, wrapped} =
        ReliabilityWrapper.wrap(ClosingTransport, transport_state,
          health_check: [
            check_interval: 60_000,
            timeout: 30_000,
            check_fn: fn _target ->
              send(test_pid, {:checking, self()})
              receive do: (:never -> {:ok, %{}})
            end
          ]
        )

      assert_receive {:checking, check}, 3_000
      checker_ref = Process.monitor(wrapped.health_check_pid)
      check_ref = Process.monitor(check)

      # Closed from a process other than the checker's linker (this one).
      assert :ok = Task.await(Task.async(fn -> ReliabilityWrapper.close(wrapped) end))
      assert_received :transport_closed
      assert_receive {:DOWN, ^checker_ref, :process, _checker, :normal}
      assert_receive {:DOWN, ^check_ref, :process, ^check, _reason}
    end

    # The client kills its close at the cleanup deadline. A stop that waited
    # past what was left of it (a 50 ms floor) was cut off with it: the
    # breaker was never killed and the transport's close never called.
    test "close kills a stuck component at once when too little of the budget is left" do
      defmodule ShortBudgetTransport do
        @behaviour Arbor.MCP.Transport

        def connect(opts), do: {:ok, %{test: opts[:test]}}
        def send_message(_message, state), do: {:ok, state}
        def receive_message(state), do: {:ok, "message", state}
        def connected?(_state), do: true

        def close(state) do
          send(state.test, :transport_closed)
          :ok
        end
      end

      test_pid = self()
      {:ok, transport_state} = ShortBudgetTransport.connect(test: test_pid)

      {:ok, wrapped} =
        ReliabilityWrapper.wrap(ShortBudgetTransport, transport_state,
          circuit_breaker: [failure_threshold: 3]
        )

      breaker = wrapped.circuit_breaker_pid
      Process.unlink(breaker)

      # Held inside a call of its own, the breaker can't answer a stop.
      spawn(fn ->
        :sys.replace_state(breaker, fn state ->
          send(test_pid, :stuck)
          receive do: (:never -> state)
        end)
      end)

      assert_receive :stuck
      breaker_ref = Process.monitor(breaker)

      closing = Deadline.put_on_transport(ReliabilityWrapper, wrapped, Deadline.after_ms(20))

      # As the client does, the close gets 20 ms before it is killed.
      closer = Task.async(fn -> ReliabilityWrapper.close(closing) end)
      _result = Task.yield(closer, 20) || Task.shutdown(closer, :brutal_kill)

      assert_receive :transport_closed
      assert_receive {:DOWN, ^breaker_ref, :process, ^breaker, :killed}
    end

    test "keeps a synchronous send's response apart from its state" do
      defmodule SyncTransport do
        @behaviour Arbor.MCP.Transport

        def connect(_opts), do: {:ok, %{sent: 0}}
        def send_message(_message, state), do: {:ok, %{state | sent: state.sent + 1}, "reply"}
        def receive_message(state), do: {:ok, "message", state}
        def close(_state), do: :ok
        def connected?(_state), do: true
      end

      {:ok, transport_state} = SyncTransport.connect([])

      for opts <- [[circuit_breaker: [failure_threshold: 3]], []] do
        {:ok, wrapped} = ReliabilityWrapper.wrap(SyncTransport, transport_state, opts)

        assert {:ok, %ReliabilityWrapper{wrapped_state: %{sent: 1}}, "reply"} =
                 ReliabilityWrapper.send_message("request", wrapped)

        assert {:ok, "message", %ReliabilityWrapper{wrapped_state: %{sent: 0}}} =
                 ReliabilityWrapper.receive_message(wrapped)

        ReliabilityWrapper.close(wrapped)
      end
    end

    test "operates without circuit breaker when disabled" do
      {:ok, transport_state} = Test.connect([])

      {:ok, wrapped_state} = ReliabilityWrapper.wrap(Test, transport_state, [])

      assert {:ok, _updated_state} =
               ReliabilityWrapper.send_message("test message", wrapped_state)
    end
  end

  describe "connected?/1" do
    test "returns health check status when enabled" do
      {:ok, transport_state} = Test.connect([])

      reliability_opts = [
        health_check: [
          check_interval: 1000,
          failure_threshold: 1
        ]
      ]

      {:ok, wrapped_state} = ReliabilityWrapper.wrap(Test, transport_state, reliability_opts)

      # Give health check time to initialize and perform first check
      :timer.sleep(50)

      # Since Test transport returns false for connected? (no peer_pid),
      # and health check status is unknown initially, the wrapped transport
      # should fall back to the base transport's connected status
      assert ReliabilityWrapper.connected?(wrapped_state) == false
    end

    test "falls back to wrapped transport status when health check disabled" do
      {:ok, transport_state} = Test.connect([])

      {:ok, wrapped_state} = ReliabilityWrapper.wrap(Test, transport_state, [])

      assert ReliabilityWrapper.connected?(wrapped_state) == Test.connected?(transport_state)
    end
  end

  describe "circuit breaker management" do
    test "can manually control circuit breaker" do
      {:ok, transport_state} = Test.connect([])

      reliability_opts = [
        circuit_breaker: [failure_threshold: 5]
      ]

      {:ok, wrapped_state} = ReliabilityWrapper.wrap(Test, transport_state, reliability_opts)

      # Get initial stats
      stats = ReliabilityWrapper.get_circuit_breaker_stats(wrapped_state)
      assert stats.state == :closed

      # Manually open circuit
      :ok = ReliabilityWrapper.open_circuit(wrapped_state)
      stats = ReliabilityWrapper.get_circuit_breaker_stats(wrapped_state)
      assert stats.state == :open

      # Manually close circuit
      :ok = ReliabilityWrapper.close_circuit(wrapped_state)
      stats = ReliabilityWrapper.get_circuit_breaker_stats(wrapped_state)
      assert stats.state == :closed

      # Reset circuit
      :ok = ReliabilityWrapper.reset_circuit(wrapped_state)
      stats = ReliabilityWrapper.get_circuit_breaker_stats(wrapped_state)
      assert stats.state == :closed
    end

    test "returns error when circuit breaker is disabled" do
      {:ok, transport_state} = Test.connect([])

      {:ok, wrapped_state} = ReliabilityWrapper.wrap(Test, transport_state, [])

      assert ReliabilityWrapper.get_circuit_breaker_stats(wrapped_state) == nil
      assert ReliabilityWrapper.open_circuit(wrapped_state) == {:error, :not_enabled}
      assert ReliabilityWrapper.close_circuit(wrapped_state) == {:error, :not_enabled}
      assert ReliabilityWrapper.reset_circuit(wrapped_state) == {:error, :not_enabled}
    end
  end

  describe "unwrap/1" do
    test "returns original transport module and state" do
      {:ok, transport_state} = Test.connect([])

      {:ok, wrapped_state} = ReliabilityWrapper.wrap(Test, transport_state, [])

      assert {Test, ^transport_state} = ReliabilityWrapper.unwrap(wrapped_state)
    end
  end

  describe "close/1" do
    test "properly closes reliability components and wrapped transport" do
      {:ok, transport_state} = Test.connect([])

      reliability_opts = [
        circuit_breaker: [failure_threshold: 5],
        health_check: [check_interval: 1000]
      ]

      {:ok, wrapped_state} = ReliabilityWrapper.wrap(Test, transport_state, reliability_opts)

      cb_pid = wrapped_state.circuit_breaker_pid
      hc_pid = wrapped_state.health_check_pid

      assert Process.alive?(cb_pid)
      assert Process.alive?(hc_pid)

      assert :ok = ReliabilityWrapper.close(wrapped_state)

      # Give processes time to terminate
      :timer.sleep(10)

      refute Process.alive?(cb_pid)
      refute Process.alive?(hc_pid)
    end
  end

  describe "capabilities/1" do
    test "passes through capabilities from wrapped transport" do
      {:ok, transport_state} = Test.connect([])

      {:ok, wrapped_state} = ReliabilityWrapper.wrap(Test, transport_state, [])

      # Test transport implements capabilities/1 and returns [:push]
      assert ReliabilityWrapper.capabilities(wrapped_state) == [:push]
    end
  end
end
