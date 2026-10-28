defmodule Arbor.MCP.Client.ReliabilityHTTPTest do
  @moduledoc """
  A Streamable HTTP client started with `reliability:` behaves like one
  without it, in every protocol mode: it connects, and each request after
  establishment POSTs from its own task, so calls run at the same time. The
  circuit breaker still admits every POST and records its outcome.
  """

  use ExUnit.Case, async: false

  # A client whose test process exits stops through terminate/2, which can
  # log its transport-close worker being refused; that is not under test.
  @moduletag :capture_log

  alias Arbor.MCP.Client
  alias Arbor.MCP.Error.TransportError
  alias Arbor.MCP.Transport.{HTTP, ReliabilityWrapper}

  @reliability [circuit_breaker: [failure_threshold: 2, reset_timeout: 60_000]]

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

  for {mode, era} <- [
        legacy_only: :legacy,
        prefer_legacy: :legacy,
        prefer_modern: :modern,
        modern_only: :modern
      ] do
    test "a #{mode} client connects and runs calls at the same time" do
      client = start_client(unquote(mode))

      assert {:ok, version} = Client.negotiated_version(client)
      assert era(version) == unquote(era)

      # The client sees a bare HTTP transport that carries the breaker.
      assert %{transport_mod: HTTP, transport_state: %HTTP{reliability: %ReliabilityWrapper{}}} =
               :sys.get_state(client)

      tasks =
        for label <- ["a", "b"],
            do: Task.async(fn -> Client.call_tool(client, "hold", %{"label" => label}, 5_000) end)

      # Both reached the server before either was answered, each POSTing
      # from its own task.
      handlers = for _ <- 1..2, do: receive_holding()
      assert map_size(:sys.get_state(client).async_post_tasks) == 2
      Enum.each(handlers, &send(&1, :release))

      assert Enum.all?(Task.await_many(tasks, 5_000), &match?({:ok, _}, &1))
    end
  end

  test "a cancelled request has its POST task stopped" do
    client = start_client(:modern_only)

    task =
      Task.async(fn -> Client.call_tool(client, "hold", %{"label" => "cancelled"}, 5_000) end)

    handler = receive_holding()
    [request_id] = Client.get_pending_requests(client)

    assert [{_monitor, {post_task, ^request_id}}] =
             Map.to_list(:sys.get_state(client).async_post_tasks)

    post_ref = Process.monitor(post_task)

    assert :ok = Client.send_cancelled(client, request_id, "not needed")
    assert {:error, :cancelled} = Task.await(task)
    assert_receive {:DOWN, ^post_ref, :process, ^post_task, :killed}
    send(handler, :release)
  end

  test "an auth challenge is answered by the client and re-sent by the task" do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case {Jason.decode!(body), Plug.Conn.get_req_header(conn, "authorization")} do
        {%{"method" => "server/discover", "id" => id}, _auth} ->
          json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => discover()})

        {%{"method" => "tools/call", "id" => id}, ["Bearer fresh"]} ->
          send(test_pid, :authenticated_call)
          result = %{"resultType" => "complete", "content" => []}
          json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => result})

        {%{"method" => "tools/call"}, _stale} ->
          conn
          |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
          |> Plug.Conn.resp(401, "")
      end
    end)

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        protocol_mode: :modern_only,
        reliability: @reliability,
        auth_provider: {Provider, test_pid: self()},
        health_check_interval: nil,
        reconnect: false
      )

    on_exit(fn -> stop(client) end)

    assert {:ok, _} = Client.call_tool(client, "protected", %{}, 5_000)
    assert_received :authenticated
    assert_received :authenticated_call
  end

  test "an open circuit refuses a request without sending it" do
    client = start_client(:modern_only)
    reliability = :sys.get_state(client).transport_state.reliability
    :ok = ReliabilityWrapper.open_circuit(reliability)

    assert {:error, %TransportError{reason: :circuit_open}} =
             Client.call_tool(client, "hold", %{"label" => "refused"}, 2_000)

    refute_received {:holding, "refused", _handler}
  end

  test "POSTs that fail open the circuit" do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode!(body) do
        %{"method" => "server/discover", "id" => id} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => discover()})
          )

        %{"method" => "tools/call"} ->
          send(test_pid, :call_posted)
          Plug.Conn.resp(conn, 500, "unavailable")
      end
    end)

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        protocol_mode: :modern_only,
        reliability: @reliability,
        health_check_interval: nil,
        reconnect: false
      )

    on_exit(fn -> stop(client) end)

    for _ <- 1..2 do
      assert {:error, %TransportError{}} = Client.call_tool(client, "any", %{}, 2_000)
      assert_received :call_posted
    end

    # Two failures reached the threshold.
    assert {:error, %TransportError{reason: :circuit_open}} =
             Client.call_tool(client, "any", %{}, 2_000)

    refute_received :call_posted
  end

  defp era(version), do: Arbor.MCP.Internal.VersionRegistry.era_for(version)

  defp receive_holding do
    assert_receive {:holding, _label, handler}, 3_000
    handler
  end

  defp discover do
    %{
      "resultType" => "complete",
      "supportedVersions" => ["2026-07-28"],
      "capabilities" => %{"tools" => %{}},
      "ttlMs" => 0,
      "cacheScope" => "private",
      "_meta" => %{
        "io.modelcontextprotocol/serverInfo" => %{"name" => "failing", "version" => "1"}
      }
    }
  end

  # A scripted dual-era server: it answers server/discover and initialize,
  # and holds each tools/call until the test releases it.
  defp start_client(protocol_mode) do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      respond(conn, Jason.decode!(body), test_pid)
    end)

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        protocol_mode: protocol_mode,
        reliability: @reliability,
        health_check_interval: nil,
        reconnect: false
      )

    on_exit(fn -> stop(client) end)
    client
  end

  defp respond(conn, %{"method" => "server/discover", "id" => id}, _test_pid),
    do: json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => discover()})

  defp respond(conn, %{"method" => "initialize", "id" => id}, _test_pid) do
    result = %{
      "protocolVersion" => "2025-06-18",
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "reliability-http", "version" => "1"}
    }

    json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp respond(conn, %{"method" => "tools/call", "id" => id, "params" => params}, test_pid) do
    label = get_in(params, ["arguments", "label"])
    send(test_pid, {:holding, label, self()})

    # A client that cancels closes the connection; end normally when Cowboy
    # stops this handler for that.
    Process.flag(:trap_exit, true)

    receive do
      :release -> :ok
      {:EXIT, _from, _reason} -> :ok
    after
      5_000 -> :ok
    end

    content = [%{"type" => "text", "text" => label}]
    result = %{"resultType" => "complete", "content" => content}
    json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp respond(conn, _notification, _test_pid), do: Plug.Conn.resp(conn, 202, "")

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp stop(client) do
    if Process.alive?(client) do
      try do
        Client.disconnect(client)
      catch
        :exit, _reason -> :ok
      end
    end
  end
end
