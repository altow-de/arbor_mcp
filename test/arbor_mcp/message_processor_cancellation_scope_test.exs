defmodule Arbor.MCP.MessageProcessorCancellationScopeTest do
  # A `notifications/cancelled` only reaches a request sent by the same HTTP
  # session, or for sessionless requests the same authenticated principal.
  use ExUnit.Case, async: false

  alias Arbor.MCP.MessageProcessor
  alias Arbor.MCP.Server.{Cancellation, Context}

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(args), do: {:ok, Map.new(args)}

    @impl true
    def handle_initialize(_params, state), do: {:ok, %{}, state}

    @impl true
    def handle_list_tools(_cursor, state), do: {:ok, [], nil, state}

    # Blocks until the test has delivered its cancellation, then reports what
    # the running callback observes.
    @impl true
    def handle_call_tool("wait", _arguments, state) do
      send(state.test_pid, {:handler_waiting, self()})

      receive do
        :report -> :ok
      end

      {:ok, %{content: [%{type: "text", text: to_string(Context.cancelled?())}]}, state}
    end
  end

  setup do
    start_supervised!(Cancellation)
    :ok
  end

  defp call_tool(id),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "wait", "arguments" => %{}}
    }

  defp cancel(id),
    do: %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => id}
    }

  defp process(message, sender) do
    message
    |> MessageProcessor.new(transport: :http, session_id: sender[:session_id])
    |> MessageProcessor.process(%{
      handler: Handler,
      handler_opts: [test_pid: sender[:test_pid]],
      endpoint: "/mcp",
      principal_id: sender[:principal_id],
      tenant_id: sender[:tenant_id]
    })
  end

  # Starts the request as `requester`, delivers the cancellation as
  # `canceller` while the callback runs, and returns what the callback saw.
  defp observed_after_cancel(requester, canceller, id \\ 7) do
    test_pid = self()
    requester = Map.put(requester, :test_pid, test_pid)
    canceller = Map.put(canceller, :test_pid, test_pid)

    task = Task.async(fn -> process(call_tool(id), requester) end)
    assert_receive {:handler_waiting, handler}, 5_000

    %MessageProcessor.Conn{response: nil} = process(cancel(id), canceller)

    send(handler, :report)
    conn = Task.await(task, 5_000)
    [%{"text" => observed}] = conn.response["result"]["content"]
    observed
  end

  test "another session cannot cancel a request with the same id" do
    assert observed_after_cancel(%{session_id: "session-a"}, %{session_id: "session-b"}) ==
             "false"
  end

  test "the request's own session can cancel it" do
    assert observed_after_cancel(%{session_id: "session-a"}, %{session_id: "session-a"}) ==
             "true"
  end

  test "sessionless requests are scoped to the authenticated principal and tenant" do
    alice = %{principal_id: "alice", tenant_id: "acme"}

    assert observed_after_cancel(alice, %{principal_id: "mallory", tenant_id: "acme"}) == "false"
    assert observed_after_cancel(alice, %{principal_id: "alice", tenant_id: "other"}) == "false"
    assert observed_after_cancel(alice, alice) == "true"
  end

  test "anonymous sessionless requests cannot be cancelled from another request" do
    assert observed_after_cancel(%{}, %{}) == "false"
  end

  test "a finished request leaves no row and later cancellations add none" do
    before = :ets.info(:ex_mcp_cancelled_requests, :size)

    assert observed_after_cancel(%{session_id: "session-a"}, %{session_id: "session-a"}) ==
             "true"

    assert :ets.info(:ex_mcp_cancelled_requests, :size) == before

    for id <- 1..100,
        do: process(cancel(id), %{session_id: "session-a", test_pid: self()})

    assert :ets.info(:ex_mcp_cancelled_requests, :size) == before
  end
end
