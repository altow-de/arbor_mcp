defmodule Arbor.MCP.MessageProcessorToolPagesTest do
  @moduledoc """
  A modern `tools/call` through the handler process finds the tool's
  x-mcp-header annotations by walking `tools/list`. The whole walk has one
  `handler_call_timeout`, not one per page, and ends at the first page that
  has the tool.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.MessageProcessor

  # Reports every tools/list page it is asked for. A page takes `page_ms`; the
  # routed tool is on the first page, behind a cursor, when `tool_first`.
  defmodule CountingToolServer do
    use Arbor.MCP.Server.Handler

    @tool %{
      "name" => "routed_tool",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "region" => %{"type" => "string", "x-mcp-header" => "Region"},
          "limit" => %{"type" => "integer", "x-mcp-header" => "Limit"}
        }
      }
    }

    @filler %{"name" => "filler", "inputSchema" => %{"type" => "object"}}

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_initialize(_params, state), do: {:ok, %{}, state}

    @impl true
    def handle_list_tools(cursor, state) do
      send(state.test_pid, {:tools_page, cursor})
      # A handler that is slow on purpose: what is measured is the time.
      if state.page_ms > 0, do: Process.sleep(state.page_ms)
      tools = if state.tool_first, do: [@tool], else: [@filler]
      {:ok, tools, "more", state}
    end

    @impl true
    def handle_call_tool(_name, _arguments, state), do: {:ok, %{"content" => []}, state}
  end

  defp call_tool(handler_opts) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 110,
      "method" => "tools/call",
      "params" => %{
        "name" => "routed_tool",
        "arguments" => %{"region" => "us-west1", "limit" => 42},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    request
    |> MessageProcessor.new(transport: :http)
    |> MessageProcessor.process(%{
      handler: CountingToolServer,
      handler_opts: [test_pid: self()] ++ handler_opts,
      handler_call_timeout: 300,
      protocol_mode: :modern_only,
      request_headers: [{"mcp-param-region", "us-west1"}, {"mcp-param-limit", "42"}],
      endpoint: "/mcp"
    })
  end

  defp pages_listed do
    receive do
      {:tools_page, _cursor} -> 1 + pages_listed()
    after
      0 -> 0
    end
  end

  test "the tools/list walk has one handler_call_timeout in all" do
    # Pages of 100 ms each never end: the walk stops at the 300 ms deadline,
    # not after 100 pages of up to 300 ms each.
    started = System.monotonic_time(:millisecond)
    conn = call_tool(page_ms: 100, tool_first: false)
    assert System.monotonic_time(:millisecond) - started < 2_000

    assert conn.response["error"]["data"]["type"] == "tool_schema_unavailable"
    assert pages_listed() <= 4
  end

  test "the walk ends at the first page that has the tool" do
    conn = call_tool(page_ms: 0, tool_first: true)

    assert conn.response["result"]
    assert_received {:tools_page, nil}
    refute_received {:tools_page, _cursor}
  end
end
