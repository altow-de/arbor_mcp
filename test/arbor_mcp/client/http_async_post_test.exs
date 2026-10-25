defmodule Arbor.MCP.Client.HTTPAsyncPostTest do
  @moduledoc """
  The HTTP client POSTs each request from its own task. It must still behave
  as the synchronous path did: a POST's response answers the request it
  carried, a POST that runs past its caller's deadline is the caller's timeout
  and is cancelled on the server, and concurrent auth challenges run one
  authentication, from the client process.
  """

  use ExUnit.Case, async: false

  alias Arbor.MCP.Client

  defmodule Provider do
    @moduledoc false
    @behaviour Arbor.MCP.Authorization.Provider

    @impl true
    def init(config), do: {:ok, %{token: "stale", test_pid: Keyword.fetch!(config, :test_pid)}}

    @impl true
    def get_token(state), do: {:ok, state.token, state}

    @impl true
    def handle_unauthorized(_www_authenticate, _scopes, state) do
      send(state.test_pid, :authenticated)
      {:ok, "fresh", %{state | token: "fresh"}}
    end

    @impl true
    def handle_forbidden(www_authenticate, scopes, state),
      do: handle_unauthorized(www_authenticate, scopes, state)
  end

  test "a response with a null or different id answers the request its POST carried" do
    client = start_client()

    assert {:error, %{code: -32600}} = Client.call_tool(client, "null_id", %{}, timeout: 5_000)
    assert {:ok, _result} = Client.call_tool(client, "string_id", %{}, timeout: 5_000)
  end

  test "a request whose POST outlives an explicit timeout is cancelled on the server" do
    client = start_client()

    assert {:error, :timeout} = Client.call_tool(client, "hang", %{}, timeout: 300)
    assert_receive {:tool_call_started, "hang", _handler}
    assert_receive {:notification, "notifications/cancelled", %{"requestId" => _id}}, 2_000
  end

  test "concurrent auth challenges run one authentication" do
    client = start_client(auth_provider: {Provider, test_pid: self()})

    tasks =
      for _ <- 1..4,
          do: Task.async(fn -> Client.call_tool(client, "protected", %{}, timeout: 5_000) end)

    assert Enum.all?(Task.await_many(tasks, 10_000), &match?({:ok, _}, &1))
    assert_received :authenticated
    refute_received :authenticated
  end

  defp start_client(opts \\ []) do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      respond(conn, Jason.decode!(body), test_pid)
    end)

    {:ok, client} =
      Client.start_link(
        [
          transport: :http,
          url: "http://127.0.0.1:#{bypass.port}/mcp",
          use_sse: false,
          protocol_mode: :legacy_only,
          health_check_interval: nil,
          reconnect: false
        ] ++ opts
      )

    on_exit(fn -> if Process.alive?(client), do: Process.exit(client, :kill) end)
    client
  end

  defp respond(conn, %{"method" => "initialize", "id" => id}, _test_pid) do
    json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "async-post", "version" => "1"}
      }
    })
  end

  defp respond(conn, %{"method" => "tools/call", "id" => id, "params" => params}, test_pid) do
    name = params["name"]
    send(test_pid, {:tool_call_started, name, self()})

    case name do
      "null_id" ->
        json(conn, %{
          "jsonrpc" => "2.0",
          "id" => nil,
          "error" => %{"code" => -32600, "message" => "Invalid Request"}
        })

      "string_id" ->
        json(conn, %{"jsonrpc" => "2.0", "id" => to_string(id), "result" => %{"content" => []}})

      "hang" ->
        # The client gives up at its deadline and closes the connection;
        # end normally when Cowboy stops this handler for that.
        Process.flag(:trap_exit, true)

        receive do
          :release -> :ok
          {:EXIT, _from, _reason} -> :ok
        after
          2_000 -> :ok
        end

        json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"content" => []}})

      "protected" ->
        if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fresh"] do
          json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"content" => []}})
        else
          conn
          |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
          |> Plug.Conn.resp(401, "")
        end
    end
  end

  defp respond(conn, %{"method" => method} = message, test_pid) do
    send(test_pid, {:notification, method, Map.get(message, "params", %{})})
    Plug.Conn.resp(conn, 202, "")
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end
end
