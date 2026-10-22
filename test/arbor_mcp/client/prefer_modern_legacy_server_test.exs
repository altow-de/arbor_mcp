defmodule Arbor.MCP.Client.PreferModernLegacyServerTest do
  # A :prefer_modern client in front of a legacy-only server. Such a server
  # answers server/discover with -32022 and the versions it supports. When
  # that list names a legacy version the client enables and no modern one,
  # the answer is positive legacy evidence and the client falls back to
  # initialize. The tests run the client against a real Runtime-mounted
  # Arbor.MCP.HttpPlug on Bandit.
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.Runtime

  defmodule AppHandler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_opts), do: {:ok, %{}}
  end

  # Reports the method of every request to the test, then serves it with the
  # HttpPlug options the switch holds at that time: those of a modern or a
  # legacy-only mount on the same URL.
  defmodule SwitchPlug do
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(opts[:test_pid], {:app_request, method(body)})
      mount = Agent.get(opts[:switch], & &1)

      conn
      |> Plug.Conn.assign(:raw_body, body)
      |> Arbor.MCP.HttpPlug.call(Map.fetch!(opts[:mounts], mount))
    end

    defp method(body) do
      case Jason.decode(body) do
        {:ok, %{"method" => method}} -> method
        _other -> nil
      end
    end
  end

  # Answers server/discover with -32022 and supported versions the client
  # does not enable, and reports every request to the test.
  defmodule ForeignVersionPlug do
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      send(opts[:test_pid], {:app_request, request["method"]})

      error = %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "error" => %{
          "code" => -32022,
          "message" => "Unsupported protocol version",
          "data" => %{"supported" => ["2024-01-01"], "requested" => "2026-07-28"}
        }
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, Jason.encode!(error))
    end
  end

  test "falls back to initialize and connects on MCP 2025-06-18" do
    {url, _switch} = start_app(:legacy_only)

    assert {:ok, client} = start_client(url, :prefer_modern)

    assert_receive {:app_request, "server/discover"}
    assert_receive {:app_request, "initialize"}
    assert_receive {:app_request, "notifications/initialized"}
    assert Client.negotiated_version(client) == {:ok, "2025-06-18"}
    assert {:ok, _pong} = Client.ping(client)
  end

  test "remembers the fallback as a legacy observation" do
    {url, _switch} = start_app(:legacy_only)
    {:ok, first} = start_client(url, :prefer_modern)
    assert Client.negotiated_version(first) == {:ok, "2025-06-18"}
    flush_requests()

    assert {:ok, second} = start_client(url, :prefer_modern)

    assert_receive {:app_request, "initialize"}
    refute_received {:app_request, "server/discover"}
    assert Client.negotiated_version(second) == {:ok, "2025-06-18"}
  end

  test "keeps a modern observation of the same URL instead of falling back" do
    {url, switch} = start_app(:prefer_modern)
    {:ok, modern} = start_client(url, :prefer_modern)
    assert Client.negotiated_version(modern) == {:ok, "2026-07-28"}
    flush_requests()

    Agent.update(switch, fn _mount -> :legacy_only end)

    assert {:error, {:transport_connect_failed, reason}} = start_client(url, :prefer_modern)
    assert reason =~ "pinned_modern_era_probe_failed"
    assert_receive {:app_request, "server/discover"}
    refute_received {:app_request, "initialize"}
  end

  test "a :modern_only client enables no legacy version and keeps the error" do
    {url, _switch} = start_app(:legacy_only)

    assert {:error, {:transport_connect_failed, reason}} = start_client(url, :modern_only)
    assert reason =~ "no_mutually_supported_modern_version"
    assert_receive {:app_request, "server/discover"}
    refute_received {:app_request, "initialize"}
  end

  test "supported versions without a shared one keep the error and stay unobserved" do
    url = start_listener({ForeignVersionPlug, test_pid: self()})

    for _attempt <- 1..2 do
      assert {:error, {:transport_connect_failed, reason}} = start_client(url, :prefer_modern)
      assert reason =~ "no_mutually_supported_modern_version"
      assert_receive {:app_request, "server/discover"}
      refute_received {:app_request, "initialize"}
    end
  end

  defp flush_requests do
    receive do
      {:app_request, _method} -> flush_requests()
    after
      0 -> :ok
    end
  end

  defp start_app(mode) do
    runtime =
      start_supervised!(
        {Runtime,
         handler: AppHandler,
         handler_args: [],
         transport: :mounted_http,
         execution: :stateless,
         max_concurrency: 4},
        id: make_ref()
      )

    mounts =
      Map.new([:prefer_modern, :legacy_only], fn protocol_mode ->
        {protocol_mode,
         Arbor.MCP.HttpPlug.init(runtime: runtime, path: "/mcp", protocol_mode: protocol_mode)}
      end)

    switch = start_supervised!({Agent, fn -> mode end}, id: make_ref())
    url = start_listener({SwitchPlug, test_pid: self(), switch: switch, mounts: mounts})
    {url, switch}
  end

  defp start_listener(plug) do
    listener =
      start_supervised!({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0}, id: make_ref())

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    "http://127.0.0.1:#{port}/mcp"
  end

  defp start_client(url, mode) do
    Process.flag(:trap_exit, true)

    result =
      Client.start_link(
        transport: :http,
        url: url,
        protocol_mode: mode,
        protocol_version: "2025-06-18",
        use_sse: false,
        security: %{origin: nil},
        health_check_interval: nil,
        reconnect: false
      )

    with {:ok, client} <- result do
      on_exit(fn ->
        if Process.alive?(client) do
          try do
            Client.disconnect(client)
          catch
            :exit, _reason -> :ok
          end
        end
      end)
    end

    result
  end
end
