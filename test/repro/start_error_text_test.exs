defmodule Arbor.MCP.Repro.StartErrorTextTest do
  # Candidate F: Client.start_link/1 fails to connect (401 from the server, or
  # a refused port). What does the caller get back, is the HTTP status there
  # as a term, and what does the client log?
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Arbor.MCP.Client

  # Like a forwarding gateway's provider: it hands a token and ends the
  # request on 401 and 403.
  defmodule RefusingProvider do
    @moduledoc false
    @behaviour Arbor.MCP.Authorization.Provider

    @impl true
    def init(config), do: {:ok, config}

    @impl true
    def get_token(state), do: {:ok, "app-token", state}

    @impl true
    def handle_unauthorized(_www, _scopes, state), do: {:error, :unauthorized, state}

    @impl true
    def handle_forbidden(_www, _scopes, state), do: {:error, :forbidden, state}
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  for mode <- [:prefer_modern, :legacy_only] do
    test "401 with WWW-Authenticate, provider refuses (#{mode})" do
      url = unauthorized_server()
      {result, log} = start(url, unquote(mode), auth_provider: {RefusingProvider, %{}})
      report("401 provider #{unquote(mode)}", result, log)

      assert {:error, {:transport_connect_failed, reason}} = result
      assert is_binary(reason)
      assert log =~ "Failed to initialize MCP client"
    end

    test "401 with WWW-Authenticate, no provider (#{mode})" do
      url = unauthorized_server()
      {result, log} = start(url, unquote(mode), [])
      report("401 no provider #{unquote(mode)}", result, log)

      assert {:error, {:transport_connect_failed, _reason}} = result
      assert log =~ "Failed to initialize MCP client"
    end
  end

  test "503 from the server (prefer_modern): the status only inside the text" do
    bypass = Bypass.open()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      Plug.Conn.resp(conn, 503, "busy")
    end)

    {result, log} = start("http://127.0.0.1:#{bypass.port}/mcp", :prefer_modern, [])
    report("503 prefer_modern", result, log)

    assert {:error, {:transport_connect_failed, reason}} = result
    assert is_binary(reason)
    assert reason =~ "503"
  end

  test "refused port (prefer_modern)" do
    {result, log} = start("http://127.0.0.1:#{refused_port()}/mcp", :prefer_modern, [])
    report("refused prefer_modern", result, log)

    assert {:error, {:transport_connect_failed, reason}} = result
    assert is_binary(reason)
    assert log =~ "Failed to initialize MCP client"
  end

  test "the log line carries no option to switch it off but a filter on its mfa" do
    filter = :repro_f_mute

    :ok =
      :logger.add_primary_filter(filter, {
        fn
          %{meta: %{mfa: {Client, :handle_connection_error, 1}}}, _ -> :stop
          _event, _ -> :ignore
        end,
        nil
      })

    on_exit(fn -> :logger.remove_primary_filter(filter) end)

    {result, log} = start("http://127.0.0.1:#{refused_port()}/mcp", :prefer_modern, [])
    report("refused with mfa filter", result, log)

    assert {:error, {:transport_connect_failed, _}} = result
    refute log =~ "Failed to initialize MCP client"
  end

  test "a module level silences it too, with every other line of the client" do
    Logger.put_module_level(Client, :none)
    on_exit(fn -> Logger.delete_module_level(Client) end)

    {result, log} = start("http://127.0.0.1:#{refused_port()}/mcp", :prefer_modern, [])

    assert {:error, {:transport_connect_failed, _}} = result
    refute log =~ "Failed to initialize MCP client"
  end

  defp start(url, mode, extra) do
    opts =
      [
        transport: :http,
        url: url,
        protocol_mode: mode,
        use_sse: false,
        security: %{origin: nil},
        health_check_interval: nil,
        reconnect: false
      ] ++ extra

    parent = self()

    log =
      capture_log([level: :debug], fn ->
        send(parent, {:result, Client.start_link(opts)})
      end)

    assert_received {:result, result}
    {result, log}
  end

  defp report(label, result, log) do
    lines =
      log
      |> String.split("\n", trim: true)
      |> Enum.filter(&(&1 =~ ~r/\[(error|warning)\]/))

    IO.puts("\n[F #{label}] result=#{inspect(result, printable_limit: 400)}")
    Enum.each(lines, &IO.puts("[F #{label}] log: " <> String.slice(&1, 0, 400)))
  end

  defp unauthorized_server do
    bypass = Bypass.open()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      conn
      |> Plug.Conn.put_resp_header(
        "www-authenticate",
        ~s(Bearer realm="app", error="invalid_token")
      )
      |> Plug.Conn.resp(401, "")
    end)

    "http://127.0.0.1:#{bypass.port}/mcp"
  end

  defp refused_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
