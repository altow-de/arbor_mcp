defmodule Arbor.MCP.Internal.OmittedParamsTest do
  @moduledoc """
  JSON-RPC lets a request or notification leave out `params`, and MCP's
  `ping` and `notifications/*/list_changed` usually do; the TypeScript SDK
  sends them that way. The parser took such a message for an invalid one,
  so the client never answered a server's ping or saw a list change.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Internal.Protocol

  test "a request or notification without params parses with empty params" do
    assert {:request, "ping", %{}, "p1"} =
             Protocol.parse_message(~s({"jsonrpc":"2.0","id":"p1","method":"ping"}))

    assert {:notification, "notifications/tools/list_changed", %{}} =
             Protocol.parse_message(
               ~s({"jsonrpc":"2.0","method":"notifications/tools/list_changed"})
             )
  end

  test "a message without a method still needs a result or an error" do
    assert {:error, :invalid_message} = Protocol.parse_message(~s({"jsonrpc":"2.0","id":1}))
  end

  @tool %{
    "name" => "count",
    "inputSchema" => %{"type" => "object"},
    "outputSchema" => %{"type" => "object"}
  }

  test "the client answers a ping and sees a list change that have no params" do
    bypass = Bypass.open()
    test = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode!(body) do
        %{"method" => "initialize", "id" => id} ->
          result = %{
            "protocolVersion" => "2025-11-25",
            "capabilities" => %{"tools" => %{"listChanged" => true}},
            "serverInfo" => %{"name" => "stub", "version" => "1"}
          }

          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "s1")
          |> json(id, result)

        %{"method" => "tools/list", "id" => id} ->
          json(conn, id, %{"tools" => [@tool]})

        %{"id" => id} = answer when not is_map_key(answer, "method") ->
          send(test, {:client_answered, id, answer})
          Plug.Conn.resp(conn, 202, "")

        _notification ->
          Plug.Conn.resp(conn, 202, "")
      end
    end)

    Bypass.stub(bypass, "GET", "/mcp", fn conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      send(test, {:stream_open, self()})
      relay(conn)
    end)

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        protocol_mode: :legacy_only,
        protocol_version: "2025-11-25",
        use_sse: true,
        health_check_interval: nil,
        reconnect: false
      )

    assert {:ok, _} = Client.list_tools(client)
    assert %{"count" => _} = :sys.get_state(client).tool_output_schemas
    assert_receive {:stream_open, stream}, 5_000

    send(stream, {:event, %{"jsonrpc" => "2.0", "id" => "server-ping", "method" => "ping"}})
    assert_receive {:client_answered, "server-ping", %{"result" => %{}}}, 5_000

    send(stream, {:event, %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}})

    :ok =
      Arbor.MCP.TestHelpers.wait_until(
        fn -> :sys.get_state(client).tool_output_schemas == %{} end,
        timeout: 5_000
      )

    send(stream, :close)
  end

  defp json(conn, id, result) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
  end

  # Sends each event the test passes it on the GET stream.
  defp relay(conn) do
    receive do
      {:event, message} ->
        {:ok, conn} = Plug.Conn.chunk(conn, "data: #{Jason.encode!(message)}\n\n")
        relay(conn)

      :close ->
        conn
    after
      10_000 -> conn
    end
  end
end
