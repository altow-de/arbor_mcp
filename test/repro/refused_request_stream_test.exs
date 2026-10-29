defmodule Arbor.MCP.Repro.RefusedRequestStreamTest do
  # Candidate E: on a modern (2026-07-28) HTTP connection, a request that
  # opens its own request stream (call_tool with progress_token:) against a
  # port that refuses the connection. delivery_outcome/1's doc counts "the
  # connection could not be opened" as :not_sent.
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.Runtime

  defmodule Handler do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    @impl true
    def handle_list_tools(_cursor, state),
      do: {:ok, [%{name: "echo", inputSchema: %{"type" => "object"}}], nil, state}

    @impl true
    def handle_call_tool("echo", _args, state),
      do: {:ok, %{content: [%{type: "text", text: "ran"}]}, state}
  end

  setup do
    {client, listener_id, port} = connect()
    assert {:ok, _} = Client.call_tool(client, "echo", %{}, progress_token: "warm")

    # The listener goes away; the port now refuses connections.
    :ok = stop_supervised(listener_id)
    assert {:error, :econnrefused} = :gen_tcp.connect(~c"127.0.0.1", port, [], 500)

    %{client: client}
  end

  test "request stream (progress_token:) on a refused port, default :at_least_once",
       %{client: client} do
    test_pid = self()
    handler = "repro-e-retry-#{inspect(make_ref())}"

    :telemetry.attach(
      handler,
      [:arbor_mcp, :client, :http, :request, :retry],
      fn _event, measurements, metadata, _ ->
        send(test_pid, {:stream_retry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    result = Client.call_tool(client, "echo", %{}, progress_token: "p1", timeout: 5_000)
    outcome = Client.delivery_outcome(result)

    IO.puts(
      "\n[E stream default] result=#{inspect(result)}\n[E stream default] delivery_outcome=#{outcome}"
    )

    # Observed on master: the refused connection counts as an ambiguous
    # stream break, the request is reissued once, and the caller is told
    # the server may have completed it.
    assert {:error,
            %Arbor.MCP.Error.TransportError{
              reason: :outcome_unknown,
              details: %{
                attempts: 2,
                cause: %{cause: %Mint.TransportError{reason: :econnrefused}, delivery: :ambiguous}
              }
            }} = result

    assert_received {:stream_retry, %{attempt: 2}, %{delivery: :at_least_once}}
    assert outcome == :unknown
  end

  test "request stream on a refused port with http_stream_retry: :safe_only (as the gateway)",
       %{client: client} do
    result =
      Client.call_tool(client, "echo", %{},
        progress_token: "p1",
        http_stream_retry: :safe_only,
        timeout: 5_000
      )

    outcome = Client.delivery_outcome(result)

    IO.puts(
      "\n[E stream safe_only] result=#{inspect(result)}\n[E stream safe_only] delivery_outcome=#{outcome}"
    )

    assert {:error,
            %Arbor.MCP.Error.TransportError{
              reason: :outcome_unknown,
              details: %{
                attempts: 1,
                cause: %{cause: %Mint.TransportError{reason: :econnrefused}, delivery: :ambiguous}
              }
            }} = result

    assert outcome == :unknown
  end

  test "ordinary POST (no progress_token) on a refused port, for comparison", %{client: client} do
    result = Client.call_tool(client, "echo", %{}, timeout: 5_000)
    outcome = Client.delivery_outcome(result)
    IO.puts("\n[E post] result=#{inspect(result)}\n[E post] delivery_outcome=#{outcome}")

    assert {:error, _} = result
    assert outcome == :not_sent
  end

  defp connect do
    runtime =
      start_supervised!({Runtime, handler: Handler, transport: :mounted_http}, id: make_ref())

    listener_id = make_ref()

    listener =
      start_supervised!(
        {Bandit,
         plug: {Arbor.MCP.HttpPlug, runtime: runtime, path: "/mcp", protocol_mode: :prefer_modern},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false},
        id: listener_id
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{port}/mcp",
        protocol_mode: :modern_only,
        use_sse: false,
        security: %{origin: nil},
        health_check_interval: nil,
        reconnect: false
      )

    on_exit(fn ->
      try do
        Client.disconnect(client)
      catch
        :exit, _reason -> :ok
      end
    end)

    {client, listener_id, port}
  end
end
