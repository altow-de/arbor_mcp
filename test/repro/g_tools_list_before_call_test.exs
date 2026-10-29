defmodule Arbor.MCP.Repro.GToolsListBeforeCallTest do
  # Repro for candidate G (ki-unit/vibe-apps-paas#334): before every modern
  # tools/call over Streamable HTTP the server walks handle_list_tools/2 to
  # find the tool's x-mcp-header annotations. Server: Runtime-mounted
  # HttpPlug on Bandit. Client: Arbor.MCP.Client (modern) and raw :httpc.
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.{HandlerServer, Runtime}

  defmodule PagedHandler do
    use Arbor.MCP.Server.Handler

    alias Arbor.MCP.Server.Context

    @plain %{"name" => "plain", "inputSchema" => %{"type" => "object"}}
    @routed %{
      "name" => "routed",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"region" => %{"type" => "string", "x-mcp-header" => "Region"}}
      }
    }

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    # Three pages; both tools sit on the last one. In :gateway mode the
    # handler answers [] when listed for a tools/call, as the hub gateway does.
    @impl true
    def handle_list_tools(cursor, state) do
      method =
        case Context.current() do
          %{method: method} -> method
          other -> other
        end

      send(state.test_pid, {:listed, cursor, method})

      cond do
        state.mode == :gateway and method == "tools/call" -> {:ok, [], nil, state}
        cursor == nil -> {:ok, [filler(1)], "p2", state}
        cursor == "p2" -> {:ok, [filler(2)], "p3", state}
        cursor == "p3" -> {:ok, [@plain, @routed], nil, state}
      end
    end

    @impl true
    def handle_call_tool(name, arguments, state) do
      send(state.test_pid, {:called, name, arguments})
      {:ok, %{content: [%{type: "text", text: "ran #{name}"}]}, state}
    end

    defp filler(n), do: %{"name" => "filler-#{n}", "inputSchema" => %{"type" => "object"}}
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    :ok
  end

  defp start_server(mode) do
    runtime =
      start_supervised!(
        {Runtime,
         handler: PagedHandler,
         handler_args: [test_pid: self(), mode: mode],
         transport: :mounted_http},
        id: make_ref()
      )

    listener =
      start_supervised!(
        {Bandit,
         plug:
           {Arbor.MCP.HttpPlug, [runtime: runtime, path: "/mcp", protocol_mode: :prefer_modern]},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    "http://127.0.0.1:#{port}/mcp"
  end

  defp client(url) do
    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: url,
        protocol_mode: :modern_only,
        use_sse: false,
        security: %{origin: nil},
        health_check_interval: nil,
        reconnect: false,
        response_cache: false
      )

    on_exit(fn ->
      try do
        Client.disconnect(client)
      catch
        :exit, _ -> :ok
      end
    end)

    client
  end

  defp drain(acc \\ []) do
    receive do
      {:listed, cursor, method} -> drain([{cursor, method} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  # A modern tools/call by hand, so the Mcp-Param header can be chosen freely.
  defp raw_call(url, name, arguments, extra_headers) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "tools/call",
        "params" => %{
          "name" => name,
          "arguments" => arguments,
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        }
      })

    headers =
      [
        {~c"accept", ~c"application/json, text/event-stream"},
        {~c"mcp-protocol-version", ~c"2026-07-28"},
        {~c"mcp-method", ~c"tools/call"},
        {~c"mcp-name", String.to_charlist(name)}
      ] ++
        Enum.map(extra_headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    {:ok, {{_, status, _}, _headers, resp}} =
      :httpc.request(
        :post,
        {String.to_charlist(url), headers, ~c"application/json", body},
        [],
        body_format: :binary
      )

    {status, Jason.decode!(resp)}
  end

  test "every modern tools/call over HTTP walks the whole list, without any Mcp-Param header" do
    client = client(start_server(:normal))
    {:ok, _tools} = Client.list_tools(client)
    _ = drain()

    for round <- 1..2 do
      assert {:ok, _} = Client.call_tool(client, "plain", %{})
      walked = drain()
      IO.puts("G round #{round}: tools/call \"plain\" listed #{inspect(walked)}")
      assert walked == [{nil, "tools/call"}, {"p2", "tools/call"}, {"p3", "tools/call"}]
    end
  end

  test "normal handler: a mismatched or missing Mcp-Param header is refused with -32020" do
    url = start_server(:normal)

    {status, body} = raw_call(url, "routed", %{"region" => "eu"}, [{"mcp-param-region", "us"}])
    IO.puts("G normal, mismatched header: #{status} #{inspect(body["error"])}")
    assert status == 400
    assert body["error"]["code"] == -32020

    {status, body} = raw_call(url, "routed", %{"region" => "eu"}, [])
    IO.puts("G normal, header missing: #{status} #{inspect(body["error"])}")
    assert status == 400
    assert body["error"]["code"] == -32020
    refute_received {:called, _, _}
  end

  test "handler answering [] for tools/call (gateway): the header check is skipped" do
    url = start_server(:gateway)

    {status, body} = raw_call(url, "routed", %{"region" => "eu"}, [{"mcp-param-region", "us"}])
    IO.puts("G gateway, mismatched header: #{status} #{inspect(body["result"] || body["error"])}")
    IO.puts("G gateway, listed: #{inspect(drain())}")
    assert status == 200
    assert_received {:called, "routed", %{"region" => "eu"}}

    {status, _body} = raw_call(url, "routed", %{"region" => "eu"}, [])
    IO.puts("G gateway, header missing: #{status}")
    assert status == 200
  end

  # Without HTTP request headers (here the in-process test transport) there
  # is no walk: dispatch.ex only looks for the definition when
  # :request_headers is set, which HttpPlug always sets.
  test "over the in-process test transport a modern tools/call does not list" do
    server =
      start_supervised!(
        {HandlerServer,
         handler: PagedHandler,
         handler_args: [test_pid: self(), mode: :normal],
         transport: :test,
         protocol_mode: :modern_only},
        id: make_ref()
      )

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: :modern_only,
        health_check_interval: nil,
        reconnect: false,
        response_cache: false
      )

    assert {:ok, _} = Client.call_tool(client, "plain", %{})
    walked = drain()
    IO.puts("G test transport: tools/call \"plain\" listed #{inspect(walked)}")
    assert walked == []
    assert_received {:called, "plain", _}
  end
end
