defmodule Arbor.MCP.Server.ContextTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.Cancellation
  alias Arbor.MCP.Server.Context
  alias Arbor.MCP.Server.RequestContext

  setup do
    start_supervised!(Cancellation)
    :ok
  end

  defp context(request_id, scope) do
    %RequestContext{
      method: "tools/call",
      request_id: request_id,
      request?: true,
      era: :legacy,
      cancellation_scope: scope
    }
  end

  defp scope(name), do: {:session, __MODULE__, "#{name}-#{System.unique_integer([:positive])}"}

  # Runs `fun` inside a tracked request, as MessageProcessor dispatches one.
  defp in_request(request_id, scope, fun) do
    Cancellation.track(scope, request_id, fn ->
      Context.with_context(context(request_id, scope), fun)
    end)
  end

  describe "cancelled?/0" do
    test "is false when there is no request context" do
      refute Context.cancelled?()
    end

    test "is false when the current request has not been cancelled" do
      in_request("ctx-not-cancelled", scope("a"), fn ->
        refute Context.cancelled?()
      end)
    end

    test "is true after a cancel is recorded for the current request in its scope" do
      scope = scope("a")

      in_request("ctx-cancelled", scope, fn ->
        refute Context.cancelled?()
        :ok = Cancellation.cancel(scope, "ctx-cancelled")
        assert Context.cancelled?()
      end)
    end

    test "is false for a different request id than the one that was cancelled" do
      scope = scope("a")

      in_request("ctx-current", scope, fn ->
        :ok = Cancellation.cancel(scope, "ctx-other")
        refute Context.cancelled?()
      end)
    end

    test "is false when another scope cancels the same request id" do
      in_request(7, scope("a"), fn ->
        :ok = Cancellation.cancel(scope("b"), 7)
        refute Context.cancelled?()
      end)
    end

    test "is false without a cancellation scope" do
      Cancellation.track(nil, "anonymous", fn ->
        Context.with_context(context("anonymous", nil), fn ->
          :ok = Cancellation.cancel(nil, "anonymous")
          refute Context.cancelled?()
        end)
      end)
    end

    test "becomes true when another process records the cancel" do
      scope = scope("oob")
      parent = self()

      in_request("ctx-oob", scope, fn ->
        refute Context.cancelled?()

        spawn(fn ->
          :ok = Cancellation.cancel(scope, "ctx-oob")
          send(parent, :marked)
        end)

        assert_receive :marked, 1_000
        assert Context.cancelled?()
      end)
    end
  end

  test "scope is absent outside runtime work, including legacy request context" do
    assert Context.scope() == nil

    Context.with_context(context("legacy", nil), fn ->
      assert Context.scope() == nil
    end)
  end
end
