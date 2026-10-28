# A stdio server whose "steps" tool reports two progress updates before it
# returns. The protocol mode is the first argument (`legacy_only` or
# `modern_only`). Run with `mix run --no-compile --no-start`.
Application.put_env(:arbor_mcp, :stdio_mode, true)
Application.put_env(:arbor_mcp, :stdio_startup_delay, 0)
Logger.configure(level: :emergency)

{:ok, _supervisor} =
  DynamicSupervisor.start_link(strategy: :one_for_one, name: Arbor.MCP.DynamicSupervisor)

defmodule Arbor.MCP.Test.ProgressStdioServer do
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL, name: "progress-stdio-server", version: "1.0.0"

  alias Arbor.MCP.Server.Context

  tool "steps", "Report two progress updates" do
    run(fn _arguments, state ->
      results = for step <- 1..2, do: Context.report_progress(step, 2, "step #{step}")
      {:ok, %{content: [%{type: "text", text: inspect(results)}]}, state}
    end)
  end
end

mode =
  case System.argv() do
    ["modern_only" | _rest] -> :modern_only
    _legacy -> :legacy_only
  end

{:ok, server} =
  Arbor.MCP.Test.ProgressStdioServer.start_link(transport: :stdio, protocol_mode: mode)

# Finish with the transport, when the client closes stdin, rather than leave
# a BEAM VM behind.
server_ref = Process.monitor(server)

receive do
  {:DOWN, ^server_ref, :process, ^server, _reason} -> :ok
end
