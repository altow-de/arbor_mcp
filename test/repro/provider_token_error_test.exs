defmodule Arbor.MCP.Repro.ProviderTokenErrorTest do
  # Candidate D: an auth provider whose get_token/1 returns {:error, reason}.
  # The transport's apply_provider_token/1 maps that to {:ok, state}, so the
  # request goes out with whatever Authorization header the state still
  # carries: the previous token, or none.
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.Runtime

  defmodule Handler do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    @impl true
    def handle_list_tools(_cursor, state),
      do: {:ok, [%{name: "echo", inputSchema: %{"type" => "object"}}], nil, state}

    @impl true
    def handle_call_tool("echo", _args, state),
      do: {:ok, %{content: [%{type: "text", text: "ran"}]}, state}
  end

  # Reports each request's JSON-RPC method and Authorization header, then
  # hands the request to the arbor_mcp server.
  defmodule Spy do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%Plug.Conn{method: "POST"} = conn, {owner, inner}) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      method =
        case Jason.decode(body) do
          {:ok, %{"method" => method}} -> method
          _other -> :other
        end

      send(owner, {:seen, method, Plug.Conn.get_req_header(conn, "authorization")})
      conn |> Plug.Conn.assign(:raw_body, body) |> Arbor.MCP.HttpPlug.call(inner)
    end

    def call(conn, {owner, inner}) do
      send(owner, {:seen, conn.method, Plug.Conn.get_req_header(conn, "authorization")})
      Arbor.MCP.HttpPlug.call(conn, inner)
    end
  end

  # Gives "t1" while its agent says :ok and {:error, :expired} once it says
  # :error. get_token/1's error shape carries no state, so the switch lives
  # in the agent.
  defmodule ScriptedProvider do
    @moduledoc false
    @behaviour Arbor.MCP.Authorization.Provider

    @impl true
    def init(config), do: {:ok, %{mode: Keyword.fetch!(config, :mode)}}

    @impl true
    def get_token(%{mode: mode} = state) do
      case Agent.get(mode, & &1) do
        :ok -> {:ok, "t1", state}
        :error -> {:error, :expired}
        nil -> {:ok, nil, state}
      end
    end

    @impl true
    def handle_unauthorized(_www, _scopes, state), do: {:error, :unauthorized, state}

    @impl true
    def handle_forbidden(_www, _scopes, state), do: {:error, :forbidden, state}
  end

  for {era, mode} <- [modern: :modern_only, legacy: :legacy_only] do
    describe "#{era} session" do
      test "a request after get_token/1 fails still goes out, with the previous token" do
        {client, provider_mode} = connect(unquote(mode), :ok)
        assert {:ok, _} = Client.list_tools(client)
        assert_receive {:seen, "tools/list", ["Bearer t1"]}, 2_000

        Agent.update(provider_mode, fn _ -> :error end)
        flush_seen()

        result = Client.list_tools(client)
        assert_receive {:seen, "tools/list", auth}, 2_000

        IO.puts(
          "\n[D #{unquote(era)} tools/list after {:error, :expired}] authorization=#{inspect(auth)} " <>
            "result=#{inspect(result, limit: 4)}"
        )

        # Observed on master: the request is sent with the stale token and
        # the caller gets the server's answer.
        assert auth == ["Bearer t1"]
        assert {:ok, _} = result
      end

      test "a provider failing from the start sends every request without Authorization" do
        {client, _provider_mode} = connect(unquote(mode), :error)
        assert {:ok, _} = Client.list_tools(client)

        seen = collect_seen()
        IO.puts("\n[D #{unquote(era)} provider failing from start] requests=#{inspect(seen)}")

        assert seen != []
        assert Enum.all?(seen, fn {_method, auth} -> auth == [] end)
      end
    end
  end

  test "modern request stream (progress_token) after get_token/1 fails" do
    {client, provider_mode} = connect(:modern_only, :ok)
    assert {:ok, _} = Client.call_tool(client, "echo", %{}, progress_token: "p1")
    assert_receive {:seen, "tools/call", ["Bearer t1"]}, 2_000

    Agent.update(provider_mode, fn _ -> :error end)
    flush_seen()

    result = Client.call_tool(client, "echo", %{}, progress_token: "p2")
    assert_receive {:seen, "tools/call", auth}, 2_000

    IO.puts(
      "\n[D modern tools/call stream after {:error, :expired}] authorization=#{inspect(auth)} " <>
        "result=#{inspect(result, limit: 4)}"
    )

    assert auth == ["Bearer t1"]
    assert {:ok, _} = result
  end

  # Side check: {:ok, nil, state} ("no token yet") after a token was given
  # takes the same path and keeps the previous Authorization header.
  test "modern tools/list after get_token/1 turns to {:ok, nil, state}" do
    {client, provider_mode} = connect(:modern_only, :ok)
    assert {:ok, _} = Client.list_tools(client)
    assert_receive {:seen, "tools/list", ["Bearer t1"]}, 2_000

    Agent.update(provider_mode, fn _ -> nil end)
    flush_seen()

    result = Client.list_tools(client)
    assert_receive {:seen, "tools/list", auth}, 2_000
    IO.puts("\n[D modern tools/list after {:ok, nil, _}] authorization=#{inspect(auth)}")

    assert auth == ["Bearer t1"]
    assert {:ok, _} = result
  end

  defp connect(protocol_mode, provider_start) do
    provider_mode = start_supervised!({Agent, fn -> provider_start end}, id: make_ref())

    runtime =
      start_supervised!({Runtime, handler: Handler, transport: :mounted_http}, id: make_ref())

    inner = Arbor.MCP.HttpPlug.init(runtime: runtime, path: "/mcp", protocol_mode: :prefer_modern)

    listener =
      start_supervised!(
        {Bandit, plug: {Spy, {self(), inner}}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{port}/mcp",
        protocol_mode: protocol_mode,
        use_sse: false,
        security: %{origin: nil},
        health_check_interval: nil,
        reconnect: false,
        auth_provider: {ScriptedProvider, mode: provider_mode}
      )

    on_exit(fn ->
      try do
        Client.disconnect(client)
      catch
        :exit, _reason -> :ok
      end
    end)

    {client, provider_mode}
  end

  defp flush_seen do
    receive do
      {:seen, _method, _auth} -> flush_seen()
    after
      100 -> :ok
    end
  end

  defp collect_seen(acc \\ []) do
    receive do
      {:seen, method, auth} -> collect_seen([{method, auth} | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end
end
