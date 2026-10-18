defmodule Arbor.MCP.Server.CancellationTableTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.Cancellation

  @table :ex_mcp_cancelled_requests

  setup do
    start_supervised!(Cancellation)
    :ok
  end

  defp scope(name), do: {:session, __MODULE__, "#{name}-#{System.unique_integer([:positive])}"}
  defp rows, do: :ets.info(@table, :size)

  test "cancellations for requests that are not in flight add no rows" do
    before = rows()
    scope = scope("flood")

    for id <- 1..1_000, do: :ok = Cancellation.cancel(scope, id)

    assert rows() == before
    refute Cancellation.cancelled?(scope, 1)
  end

  test "a cancellation only flags the request in its own scope" do
    owner = scope("owner")
    other = scope("other")

    Cancellation.track(owner, 1, fn ->
      :ok = Cancellation.cancel(other, 1)
      refute Cancellation.cancelled?(owner, 1)

      :ok = Cancellation.cancel(owner, 1)
      assert Cancellation.cancelled?(owner, 1)
      refute Cancellation.cancelled?(other, 1)
    end)
  end

  test "the row is removed when the tracked function returns or raises" do
    scope = scope("cleanup")
    before = rows()

    assert :done =
             Cancellation.track(scope, "returns", fn ->
               assert rows() == before + 1
               :done
             end)

    assert rows() == before

    assert_raise RuntimeError, fn ->
      Cancellation.track(scope, "raises", fn -> raise "boom" end)
    end

    assert rows() == before
  end

  test "a duplicate in-flight id is not tracked twice and keeps the first owner's row" do
    scope = scope("duplicate")
    parent = self()

    first =
      spawn(fn ->
        Cancellation.track(scope, 1, fn ->
          send(parent, :first_tracked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :first_tracked
    Cancellation.track(scope, 1, fn -> :ok end)

    :ok = Cancellation.cancel(scope, 1)
    assert Cancellation.cancelled?(scope, 1)

    ref = Process.monitor(first)
    send(first, :release)
    assert_receive {:DOWN, ^ref, :process, ^first, _reason}
    refute Cancellation.cancelled?(scope, 1)
  end

  test "the sweep removes rows whose owner exited without cleaning up" do
    scope = scope("killed")
    parent = self()

    owner =
      spawn(fn ->
        Cancellation.track(scope, 1, fn ->
          send(parent, :tracked)

          receive do
            :never -> :ok
          end
        end)
      end)

    assert_receive :tracked
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}

    before = rows()
    assert Cancellation.sweep() == 1
    assert rows() == before - 1
  end

  test "registration stops at the configured cap" do
    stop_supervised!(Cancellation)
    start_supervised!({Cancellation, max_rows: 1})
    scope = scope("cap")

    Cancellation.track(scope, 1, fn ->
      Cancellation.track(scope, 2, fn ->
        :ok = Cancellation.cancel(scope, 2)
        refute Cancellation.cancelled?(scope, 2)
      end)

      :ok = Cancellation.cancel(scope, 1)
      assert Cancellation.cancelled?(scope, 1)
    end)
  end
end
