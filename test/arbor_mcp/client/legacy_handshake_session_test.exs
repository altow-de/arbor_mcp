defmodule Arbor.MCP.Client.LegacyHandshakeSessionTest do
  @moduledoc """
  The HTTP transport adopts the version `initialize` negotiated before
  `notifications/initialized` is sent, but the handshake stays in the legacy
  era until establishment settles it: the session `initialize` minted must
  still travel with `notifications/initialized`, whatever version string the
  server chose.
  """

  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.EraCache
  alias Arbor.MCP.Transport.HTTP

  test "notifications/initialized keeps the session initialize minted" do
    bypass = Bypass.open()
    test_pid = self()
    # Era observations outlive listener PIDs, so each fixture needs its own endpoint.
    path = "/mcp/#{System.unique_integer([:positive, :monotonic])}"

    # Model a modern observation left by an earlier listener on this port.
    # Keep it pinned throughout the handshake instead of clearing the cache.
    {:ok, prior_transport} =
      HTTP.connect(url: "http://127.0.0.1:#{bypass.port}/mcp", use_sse: false)

    prior_identity = EraCache.identity(HTTP, prior_transport, [])
    assert :ok = EraCache.observe(prior_identity, :modern, "2026-07-28")
    assert :ok = HTTP.close(prior_transport)
    on_exit(fn -> EraCache.clear(prior_identity) end)

    Bypass.expect(bypass, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode!(body) do
        %{"method" => "initialize", "id" => id} ->
          result = %{
            "protocolVersion" => "2026-07-28",
            "capabilities" => %{},
            "serverInfo" => %{"name" => "session-minting", "version" => "1"}
          }

          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "session-from-initialize")
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
          )

        %{"method" => "notifications/initialized"} ->
          send(
            test_pid,
            {:initialized,
             %{
               session: Plug.Conn.get_req_header(conn, "mcp-session-id"),
               version: Plug.Conn.get_req_header(conn, "mcp-protocol-version")
             }}
          )

          Plug.Conn.resp(conn, 202, "")

        _other ->
          Plug.Conn.resp(conn, 202, "")
      end
    end)

    Bypass.stub(bypass, "DELETE", path, fn conn -> Plug.Conn.resp(conn, 204, "") end)

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{bypass.port}#{path}",
        use_sse: false,
        protocol_mode: :prefer_legacy,
        health_check_interval: nil,
        reconnect: false
      )

    assert_receive {:initialized, headers}, 2_000
    assert headers.session == ["session-from-initialize"]
    assert headers.version == ["2026-07-28"]

    assert {:ok, %{era: :modern, protocol_version: "2026-07-28", expires_at: :infinity}} =
             EraCache.lookup(prior_identity)

    Client.stop(client)
  end
end
