defmodule Arbor.MCP.Repro.BClosedStreamAdmissionErrorTest do
  # Repro B: a client closes a modern request stream (SSE) while the tool
  # keeps reporting progress. #147 ends a failed keepalive quietly; this
  # checks what a failed progress frame does: the log, the return value of
  # Context.report_progress/3 and whether the tool is cancelled.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.MCP.Server.{Context, Runtime}

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts), do: {:ok, Keyword.fetch!(opts, :test_pid)}

    # Reports progress every 150 ms until a report fails, at most 40 times.
    @impl true
    def handle_call_tool("ticker", _arguments, test_pid) do
      send(test_pid, {:tool_started, self()})

      _ =
        Enum.reduce_while(1..40, nil, fn i, _ ->
          result = Context.report_progress(i, 40)
          send(test_pid, {:progress, i, result, System.monotonic_time(:millisecond)})

          if result == :ok do
            Process.sleep(150)
            {:cont, nil}
          else
            {:halt, nil}
          end
        end)

      send(test_pid, {:tool_returning, self()})
      {:ok, %{content: [%{type: "text", text: "done"}]}, test_pid}
    end

    # Keeps reporting every 100 ms whatever report_progress/3 returns, 15
    # times, and reports a cancellation message from the runtime.
    def handle_call_tool("stubborn", _arguments, test_pid) do
      send(test_pid, {:tool_started, self()})

      for i <- 1..15 do
        result = Context.report_progress(i, 15)
        send(test_pid, {:progress, i, result, System.monotonic_time(:millisecond)})

        receive do
          {:arbor_mcp_cancelled, _token, reason} ->
            send(test_pid, {:cancelled, reason, System.monotonic_time(:millisecond)})
        after
          100 -> :ok
        end
      end

      send(test_pid, {:tool_returning, self()})
      {:ok, %{content: [%{type: "text", text: "done"}]}, test_pid}
    end
  end

  for {tool, keepalive} <- [{"ticker", 15_000}, {"stubborn", 15_000}, {"ticker", 40}] do
    test "bandit: closing the request stream during progress (#{tool}, keepalive #{keepalive} ms)" do
      parent = self()

      log =
        capture_log(fn ->
          port = start_server(unquote(keepalive))
          {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
          {:ok, conn, ref} = request(conn, unquote(tool))

          assert_receive {:tool_started, worker}, 2_000
          monitor = Process.monitor(worker)

          # Wait until two progress frames reached the client, then close.
          {conn, _events} = receive_until(conn, ref, &(progress_frames(&1) >= 2))
          closed_at = System.monotonic_time(:millisecond)
          Mint.HTTP.close(conn)

          outcome = await_outcome(monitor, closed_at, [])
          # Let Bandit's error report reach the logger.
          Process.sleep(300)
          send(parent, {:outcome, outcome})
        end)

      assert_received {:outcome, outcome}

      IO.puts("\n[B] tool=#{unquote(tool)} keepalive=#{unquote(keepalive)} ms, after close:")
      for line <- outcome, do: IO.puts("    #{inspect(line)}")
      IO.puts("[B] captured log:\n" <> indent(log))

      failed = for {:report_progress, _, {:error, reason}, _} <- outcome, do: reason
      assert :stream_closed in failed

      if unquote(keepalive) == 15_000 do
        # A failed progress frame: Bandit logs the plug's exception.
        assert log =~ "[error] ** (Arbor.MCP.HttpPlug.RuntimeWriter.AdmissionError)"
        assert log =~ "MCP HTTP response capacity unavailable"
        assert log =~ "runtime_writer.ex:206"
      end
    end
  end

  # Collects, after the close: each progress result, the tool's return, and
  # the tool process going down; at most 3 s.
  defp await_outcome(monitor, closed_at, acc) do
    receive do
      {:progress, i, result, at} ->
        await_outcome(monitor, closed_at, [
          {:report_progress, i, result, "+#{at - closed_at} ms"} | acc
        ])

      {:tool_returning, _pid} ->
        await_outcome(monitor, closed_at, [:tool_returned | acc])

      {:cancelled, reason, at} ->
        await_outcome(monitor, closed_at, [
          {:cancel_message, reason, "+#{at - closed_at} ms"} | acc
        ])

      {:DOWN, ^monitor, :process, _pid, reason} ->
        Enum.reverse([
          {:tool_down, reason, "+#{System.monotonic_time(:millisecond) - closed_at} ms"} | acc
        ])
    after
      3_000 -> Enum.reverse([:no_more_events_within_3s | acc])
    end
  end

  defp start_server(keepalive) do
    runtime =
      start_supervised!(
        {Runtime,
         handler: Handler,
         handler_args: [test_pid: self()],
         transport: :mounted_http,
         protocol_mode: :modern_only},
        id: make_ref()
      )

    opts = [
      runtime: runtime,
      path: "/mcp",
      protocol_mode: :modern_only,
      request_keepalive_interval_ms: keepalive
    ]

    listener =
      start_supervised!(
        {Bandit,
         plug: {Arbor.MCP.HttpPlug, opts}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    port
  end

  defp request(conn, tool) do
    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{
          name: tool,
          arguments: %{},
          _meta: %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => %{},
            "progressToken" => "ticker"
          }
        }
      })

    Mint.HTTP.request(
      conn,
      "POST",
      "/mcp",
      [
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"},
        {"mcp-protocol-version", "2026-07-28"},
        {"mcp-method", "tools/call"},
        {"mcp-name", tool}
      ],
      body
    )
  end

  defp progress_frames(events) do
    events
    |> Enum.flat_map(fn
      {:data, _ref, data} -> Regex.scan(~r/notifications\/progress/, data)
      _ -> []
    end)
    |> length()
  end

  defp receive_until(conn, ref, done?, events \\ []) do
    if done?.(events) do
      {conn, events}
    else
      receive do
        {:progress, _, _, _} = message ->
          # Keep the tool's reports for await_outcome/3.
          send(self(), message)
          Process.sleep(5)
          receive_until(conn, ref, done?, events)

        message ->
          case Mint.HTTP.stream(conn, message) do
            {:ok, conn, next} -> receive_until(conn, ref, done?, events ++ next)
            :unknown -> receive_until(conn, ref, done?, events)
          end
      after
        3_000 -> flunk("timed out: #{inspect(events)}")
      end
    end
  end

  defp indent(log),
    do: log |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))
end
