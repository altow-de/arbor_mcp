defmodule Arbor.MCP.Transport.StdioShutdownTest do
  @moduledoc """
  The stdio transport follows the MCP shutdown order: close the server's stdin,
  wait `:eof_grace` (2 s, as in the reference SDKs), then SIGTERM and SIGKILL.
  The client's close limit grows to cover that budget.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Client.Deadline
  alias Arbor.MCP.Transport.Stdio
  alias Arbor.RPC.Subprocess

  describe "shutdown_options/1" do
    test "defaults give the server 2 s after EOF within a 2.5 s budget" do
      opts = Stdio.shutdown_options(command: ["true"])
      assert opts[:eof_grace] == 2_000
      assert opts[:cleanup_timeout] == 2_500
    end

    test "an explicit EOF grace sets the budget around it" do
      assert Stdio.shutdown_options(eof_grace: 5_000)[:cleanup_timeout] == 5_500
      assert Stdio.shutdown_options(eof_grace: 0, term_grace: 200)[:cleanup_timeout] == 600
    end

    test "an explicit budget keeps the EOF grace that fits inside it" do
      assert Stdio.shutdown_options(cleanup_timeout: 500)[:eof_grace] == 350
      assert Stdio.shutdown_options(cleanup_timeout: 100)[:eof_grace] == 0
      assert Stdio.shutdown_options(cleanup_timeout: 10_000)[:eof_grace] == 2_000
    end

    test "explicit and invalid values pass through for the subprocess to validate" do
      opts = [eof_grace: 10, cleanup_timeout: 400]
      assert Stdio.shutdown_options(opts) == opts
      assert Stdio.shutdown_options(term_grace: :bad) == [term_grace: :bad]
    end
  end

  describe "client close limit" do
    test "covers a stdio server's shutdown budget" do
      assert Deadline.cleanup_timeout(transport: :stdio, command: ["true"]) == 3_000

      assert Deadline.cleanup_timeout(transport: :stdio, command: ["true"], eof_grace: 5_000) ==
               6_000

      assert Deadline.cleanup_timeout(transports: [{:stdio, command: ["true"]}]) == 3_000
    end

    test "stays at the default for other transports and unusable options" do
      assert Deadline.cleanup_timeout(transport: :http, url: "http://localhost:1/mcp") == 1_000
      assert Deadline.cleanup_timeout([]) == 1_000

      assert Deadline.cleanup_timeout(transport: :stdio, command: ["true"], cleanup_timeout: 100) ==
               1_000
    end
  end

  test "close lets a server that exits on EOF do so without a signal" do
    # Exits 0 on stdin EOF; a SIGTERM delivered first would make it exit 143.
    script = ~s(trap 'exit 143' TERM; while read -r _; do :; done; exit 0)
    {:ok, state} = Stdio.connect(command: ["/bin/sh", "-c", script])

    assert :ok = Stdio.close(state)
    receipt = Subprocess.cleanup_receipt(state.subprocess)

    # EOF-first shutdown arrives with the ArborRPC release that adds
    # `Subprocess.close_input/1`; earlier releases still send SIGTERM at once.
    if function_exported?(Subprocess, :close_input, 1) do
      assert {:ok, %{direct_child: :reaped, vendor_status: 0}} = receipt
    else
      assert {:ok, %{direct_child: :reaped}} = receipt
    end
  end
end
