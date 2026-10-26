defmodule Arbor.MCP.Server.InvalidResultTest do
  @moduledoc """
  A result the connection's protocol revision can't carry is the handler's
  bug. The caller gets a JSON-RPC error saying so, not an opaque crash.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Arbor.MCP.{Client, Server}

  defmodule Handler do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    @impl true
    def handle_list_tools(_cursor, state),
      do: {:ok, [%{name: "nulls", inputSchema: %{type: "object"}}], nil, state}

    # Legacy revisions require structuredContent to be an object.
    @impl true
    def handle_call_tool("nulls", _args, state),
      do: {:ok, %{"content" => [], "structuredContent" => nil}, state}
  end

  test "non-object structuredContent in a legacy era is an invalid result" do
    {:ok, server} = Server.start_link(transport: :test, handler: Handler)

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: :legacy_only,
        health_check_interval: nil
      )

    log =
      capture_log(fn ->
        assert {:error, %{"code" => -32603, "data" => %{"type" => "invalid_result"}}} =
                 Client.call_tool(client, "nulls", %{}, format: :map)
      end)

    assert log =~ "structured tool content must be an object"
  end
end
