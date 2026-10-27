defmodule Arbor.MCP.HTTPUnsupportedVersionListTest do
  @moduledoc """
  A mount's unsupported-version error lists only the revisions that mount accepts.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Arbor.MCP.HttpPlug
  alias Arbor.MCP.Internal.VersionRegistry
  alias Arbor.MCP.Server.{Runtime, Transport}
  alias Arbor.MCP.Test.RuntimeHTTPFixture

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "version-list", version: "1.0.0"
  end

  @moduletag :capture_log

  @modes [:legacy_only, :prefer_legacy, :prefer_modern, :modern_only]
  @adapters [:plug, :cowboy, :bandit]

  for adapter <- @adapters, mode <- @modes do
    test "#{adapter} #{mode} lists only the versions that mount accepts" do
      server = start_server(unquote(adapter), unquote(mode))
      mode = unquote(mode)

      assert_unknown_modern(server, mode)
      assert_unknown_initialize(server, mode)
      assert_wrong_era(server, mode)
    end
  end

  defp assert_unknown_modern(server, mode) do
    {status, body} = modern_request(server, "tools/list", "2099-01-01")
    assert_supported(status, body, mode, "2099-01-01")
    prove_retries(server, body["error"]["data"]["supported"])
  end

  defp assert_unknown_initialize(server, mode) do
    {status, body} = initialize(server, "1999-01-01")
    assert_supported(status, body, mode, "1999-01-01")
    prove_retries(server, body["error"]["data"]["supported"])
  end

  defp assert_wrong_era(server, :legacy_only) do
    {status, body} = initialize(server, "2026-07-28")
    assert_supported(status, body, :legacy_only, "2026-07-28")
    prove_retries(server, body["error"]["data"]["supported"])
  end

  defp assert_wrong_era(server, :modern_only) do
    {status, body} = initialize(server, "2025-11-25")
    assert_supported(status, body, :modern_only, "2025-11-25")
    prove_retries(server, body["error"]["data"]["supported"])
  end

  defp assert_wrong_era(server, :prefer_legacy) do
    {status, body} = discover(server, "2026-07-28")
    assert status == 200, inspect(body)

    assert body["result"]["supportedVersions"] ==
             VersionRegistry.supported_versions(:prefer_legacy)
  end

  defp assert_wrong_era(server, :prefer_modern) do
    {status, body} = initialize(server, "2025-11-25")
    assert status == 200, inspect(body)
    assert body["result"]["protocolVersion"] == "2025-11-25"
  end

  defp assert_supported(status, body, mode, requested) do
    assert status == 400, inspect(body)
    assert body["error"]["code"] == -32022
    assert body["error"]["message"] == "Unsupported protocol version"
    assert body["error"]["data"]["requested"] == requested

    assert body["error"]["data"]["supported"] == VersionRegistry.supported_versions(mode)
  end

  defp prove_retries(server, versions) do
    Enum.each(versions, fn version ->
      if VersionRegistry.modern?(version) do
        {status, body} = discover(server, version)
        assert status == 200, inspect(body)
        assert body["result"]["supportedVersions"] == versions
      else
        {status, body} = initialize(server, version)
        assert status == 200, inspect(body)
        assert body["result"]["protocolVersion"] == version
      end
    end)
  end

  defp modern_request(server, method, version) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => next_id(),
        "method" => method,
        "params" => %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => version,
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        }
      })

    request(server, body, [
      {"mcp-protocol-version", version},
      {"mcp-method", method}
    ])
  end

  defp discover(server, version), do: modern_request(server, "server/discover", version)

  defp initialize(server, version) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => next_id(),
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => version,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "version-list", "version" => "1.0.0"}
        }
      })

    request(server, body, [])
  end

  defp request({:plug, opts}, body, headers) do
    conn =
      conn(:post, "/mcp", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")

    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn ->
        put_req_header(conn, name, value)
      end)

    conn = HttpPlug.call(conn, opts)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp request({:http, port}, body, headers) do
    url = ~c"http://127.0.0.1:#{port}/mcp"

    header_chars =
      [{"accept", "application/json, text/event-stream"} | headers]
      |> Enum.map(fn {name, value} -> {to_charlist(name), to_charlist(value)} end)

    assert {:ok, {{_version, status, _reason}, _response_headers, response}} =
             :httpc.request(
               :post,
               {url, header_chars, ~c"application/json", body},
               [timeout: 5_000],
               []
             )

    {status, Jason.decode!(to_string(response))}
  end

  defp start_server(:plug, mode) do
    runtime = RuntimeHTTPFixture.start(Handler)
    opts = HttpPlug.init(runtime: runtime, protocol_mode: mode, legacy_http_sse: false)
    {:plug, opts}
  end

  defp start_server(adapter, mode) when adapter in [:cowboy, :bandit] do
    assert {:ok, root} =
             Handler.start_link(
               transport: :http,
               http_adapter: adapter,
               port: 0,
               host: {127, 0, 0, 1},
               protocol_mode: mode,
               legacy_http_sse: false
             )

    on_exit(fn -> if Process.alive?(root), do: Runtime.stop(root) end)
    {:http, listener_port(root, adapter)}
  end

  defp listener_port(root, :cowboy) do
    assert {:ok, %{ranch_ref: ref}} = Transport.http_listener(root)
    :ranch.get_port(ref)
  end

  defp listener_port(root, :bandit) do
    assert {:ok, %{listener: listener}} = Transport.http_listener(root)
    assert {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
    port
  end

  defp next_id do
    Process.put(:version_list_request_id, Process.get(:version_list_request_id, 0) + 1)
  end
end
