defmodule Arbor.MCP.Server.RequestInfoTest do
  @moduledoc """
  Callbacks can read the request id, session id, auth info and HTTP headers of
  the request they handle, like the `extra` argument of TypeScript SDK handlers.
  """

  use ExUnit.Case, async: false
  import Plug.Conn

  alias Arbor.MCP.{Client, HttpPlug}
  alias Arbor.MCP.Server.{AuthInfo, Context, Runtime}

  defmodule Handler do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         "protocolVersion" => "2025-11-25",
         "serverInfo" => %{"name" => "request-info", "version" => "1"},
         "capabilities" => %{"tools" => %{}}
       }, state}
    end

    @impl true
    def handle_list_tools(_cursor, state),
      do: {:ok, [%{name: "whoami", inputSchema: %{type: "object"}}], nil, state}

    @impl true
    def handle_call_tool("whoami", _args, state) do
      auth = Context.auth_info()

      info = %{
        "requestId" => Context.request_id(),
        "sessionId" => Context.session_id(),
        "tag" => tag(Context.request_headers()),
        "auth" => auth && Map.take(auth, [:client_id, :subject, :scopes, :token])
      }

      {:ok, %{"content" => [], "structuredContent" => info}, state}
    end

    defp tag(nil), do: nil
    defp tag(headers), do: List.keyfind(headers, "x-request-tag", 0, {nil, nil}) |> elem(1)
  end

  defmodule HostAuth do
    @moduledoc false
    # A host plug that authenticates requests itself.
    def call(conn, opts) do
      conn
      |> HttpPlug.put_auth_info(AuthInfo.from_claims("host-token", %{"sub" => "carol"}))
      |> HttpPlug.call(opts)
    end
  end

  setup do
    previous = Application.fetch_env(:arbor_mcp, :oauth2_enabled)
    Application.put_env(:arbor_mcp, :oauth2_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_mcp, :oauth2_enabled, value)
        :error -> Application.delete_env(:arbor_mcp, :oauth2_enabled)
      end
    end)
  end

  test "a legacy HTTP request carries its session and the introspected token" do
    opts = mount(protocol_mode: :legacy_only, oauth_enabled: true, auth_config: auth_config())

    init = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "clientInfo" => %{"name" => "c", "version" => "1"},
        "capabilities" => %{}
      }
    }

    assert %{status: 200} = conn = post(opts, init, bearer: "alice")
    [session] = get_resp_header(conn, "mcp-session-id")

    initialized = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
    assert %{status: 202} = post(opts, initialized, bearer: "alice", session: session)

    assert %{status: 200} =
             conn = post(opts, whoami("call-7"), bearer: "alice", session: session, tag: "t1")

    assert %{
             "requestId" => "call-7",
             "sessionId" => ^session,
             "tag" => "t1",
             "auth" => %{
               "client_id" => "mcp-client",
               "subject" => "alice",
               "scopes" => ["mcp:tools:execute:whoami"],
               "token" => "alice"
             }
           } = structured(conn)
  end

  test "a modern HTTP request has no session and takes auth info from a host plug" do
    opts = mount(protocol_mode: :modern_only)
    request = whoami(9) |> put_in(["params", "_meta"], modern_meta())

    conn =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(request))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> put_req_header("mcp-method", "tools/call")
      |> put_req_header("mcp-name", "whoami")
      |> put_req_header("x-request-tag", "t2")
      |> HostAuth.call(opts)

    assert %{
             "requestId" => 9,
             "sessionId" => nil,
             "tag" => "t2",
             "auth" => %{"subject" => "carol", "token" => "host-token"}
           } = structured(conn)
  end

  test "an in-process request has an id but no session, auth or headers" do
    {:ok, server} = Arbor.MCP.Server.start_link(transport: :test, handler: Handler)

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: :legacy_only,
        health_check_interval: nil
      )

    assert {:ok, result} = Client.call_tool(client, "whoami", %{}, format: :map)

    assert %{"sessionId" => nil, "tag" => nil, "auth" => nil, "requestId" => id} =
             result["structuredContent"]

    refute is_nil(id)
  end

  test "inspect leaves the token out" do
    auth = AuthInfo.from_claims("secret-token", %{"client_id" => "c", "scope" => "a b"})
    assert auth.scopes == ["a", "b"]
    refute inspect(auth) =~ "secret-token"
  end

  defp mount(options) do
    root =
      start_supervised!(
        {Runtime, handler: Handler, handler_args: [], services: [sessions: []]},
        id: make_ref()
      )

    {:ok, runtime} = Runtime.ref(root)

    [
      runtime: runtime,
      allowed_origins: :any,
      resource: "https://mcp.example",
      authorization_servers: ["https://issuer.example"]
    ]
    |> Keyword.merge(options)
    |> HttpPlug.init()
  end

  defp auth_config do
    %{
      realm: "request-info",
      introspection_endpoint: "https://oauth.example/introspect",
      client_id: "resource-client",
      client_secret: "resource-secret",
      expected_issuer: "https://issuer.example",
      expected_audience: "https://mcp.example",
      clock_skew_seconds: 0,
      oauth_http: [
        dns_resolver: fn _host, _timeout -> {:ok, [{93, 184, 216, 34}]} end,
        request_fun: fn :post, {_url, _headers, _content_type, body}, _options, _request_opts ->
          token = URI.decode_query(body)["token"]
          {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], Jason.encode!(claims(token))}}
        end
      ]
    }
  end

  defp claims(token) do
    now = System.system_time(:second)

    %{
      active: true,
      sub: token,
      client_id: "mcp-client",
      iss: "https://issuer.example",
      aud: "https://mcp.example",
      exp: now + 60,
      scope: "mcp:tools:execute:whoami"
    }
  end

  defp post(opts, value, options) do
    conn =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(value))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-protocol-version", "2025-11-25")
      |> put_req_header("authorization", "Bearer " <> Keyword.fetch!(options, :bearer))

    conn =
      Enum.reduce(options, conn, fn
        {:session, id}, conn -> put_req_header(conn, "mcp-session-id", id)
        {:tag, tag}, conn -> put_req_header(conn, "x-request-tag", tag)
        _other, conn -> conn
      end)

    HttpPlug.call(conn, opts)
  end

  defp whoami(id),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "whoami", "arguments" => %{}}
    }

  defp modern_meta,
    do: %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

  defp structured(conn) do
    body = Jason.decode!(conn.resp_body)
    assert %{"result" => %{"structuredContent" => info}} = body, inspect(body)
    info
  end
end
