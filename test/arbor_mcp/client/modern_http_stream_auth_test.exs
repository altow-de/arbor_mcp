defmodule Arbor.MCP.Client.ModernHTTPStreamAuthTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Internal.Headers
  alias Arbor.MCP.Transport.HTTP

  defmodule Provider do
    @behaviour Arbor.MCP.Authorization.Provider

    @impl true
    def init(config), do: {:ok, %{test_pid: Keyword.fetch!(config, :test_pid), generation: 0}}

    @impl true
    def get_token(state), do: {:ok, nil, state}

    @impl true
    def handle_unauthorized(www_auth, scopes, state) do
      send(state.test_pid, {:provider_challenge, www_auth, scopes})
      next = %{state | generation: state.generation + 1}
      {:ok, "request-stream-token", next}
    end

    @impl true
    def handle_forbidden(www_auth, scopes, state) do
      send(state.test_pid, {:provider_step_up, www_auth, scopes})
      next = %{state | generation: state.generation + 1}
      {:ok, "request-stream-step-up-token", next}
    end
  end

  defp client_state(transport_state) do
    %Client{
      transport_mod: HTTP,
      transport_state: transport_state,
      pending_requests: %{},
      pending_batches: %{},
      cancelled_requests: MapSet.new(),
      async_post_tasks: %{}
    }
  end

  # The test is the stream's parent, so it hands each auth challenge to the
  # client's handler, as Arbor.MCP.Client does.
  defp answer_challenge(stream_pid, request_id, client_state) do
    assert_receive {:modern_http_stream_auth_challenge, ^stream_pid, ^request_id, _ref,
                    _challenge} =
                     message,
                   1_000

    assert {:noreply, client_state} = Client.handle_info(message, client_state)
    client_state
  end

  test "a modern POST-owned request stream reauthenticates and persists provider state" do
    bypass = Bypass.open()
    attempts = start_supervised!({Agent, fn -> 0 end})

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      attempt = Agent.get_and_update(attempts, fn current -> {current + 1, current + 1} end)

      case attempt do
        1 ->
          assert Plug.Conn.get_req_header(conn, "authorization") == []

          conn
          |> Plug.Conn.put_resp_header(
            "www-authenticate",
            ~s(Bearer realm="mcp", scope="tools.read tools.call")
          )
          |> Plug.Conn.resp(401, "authentication required")

        2 ->
          assert Plug.Conn.get_req_header(conn, "authorization") ==
                   ["Bearer request-stream-token"]

          body =
            "data: " <>
              Jason.encode!(%{
                "jsonrpc" => "2.0",
                "id" => 42,
                "result" => %{"resultType" => "complete", "content" => []}
              }) <> "\n\n"

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.resp(200, body)
      end
    end)

    {:ok, transport_state} =
      HTTP.connect(
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        protocol_version: "2026-07-28",
        auth_provider: {Provider, test_pid: self()},
        stream_idle_timeout: 2_000
      )

    transport_state = HTTP.settle_protocol_era(transport_state, :modern, "2026-07-28")
    request = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 42, "method" => "tools/call"})

    assert {:ok, transport_state} = HTTP.open_stream(request, transport_state, self())
    stream_pid = Map.fetch!(transport_state.modern_streams, 42)

    client_state = answer_challenge(stream_pid, 42, client_state(transport_state))

    assert_received {:provider_challenge, ~s(Bearer realm="mcp", scope="tools.read tools.call"),
                     ["tools.read", "tools.call"]}

    assert client_state.transport_state.access_token == "request-stream-token"
    assert client_state.transport_state.auth_provider_state.generation == 1

    assert Headers.get(client_state.transport_state.headers, "authorization") ==
             "Bearer request-stream-token"

    assert_receive {:modern_http_stream_message, ^stream_pid, 42,
                    %{
                      "jsonrpc" => "2.0",
                      "id" => 42,
                      "result" => %{"resultType" => "complete", "content" => []}
                    }},
                   1_000

    send(stream_pid, {:modern_http_stream_ack, self(), 42})
    assert_receive {:modern_http_stream_finished, ^stream_pid, 42}, 1_000
    assert Agent.get(attempts, & &1) == 2
  end

  test "a request stream performs one bounded insufficient-scope step-up" do
    bypass = Bypass.open()
    attempts = start_supervised!({Agent, fn -> 0 end})

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      attempt = Agent.get_and_update(attempts, fn current -> {current + 1, current + 1} end)

      case attempt do
        1 ->
          conn
          |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer scope="tools.call"))
          |> Plug.Conn.resp(401, "authentication required")

        2 ->
          assert Plug.Conn.get_req_header(conn, "authorization") ==
                   ["Bearer request-stream-token"]

          conn
          |> Plug.Conn.put_resp_header(
            "www-authenticate",
            ~s(Bearer error="insufficient_scope", scope="admin")
          )
          |> Plug.Conn.resp(403, "more scope required")

        3 ->
          assert Plug.Conn.get_req_header(conn, "authorization") ==
                   ["Bearer request-stream-step-up-token"]

          body =
            "data: " <>
              Jason.encode!(%{"jsonrpc" => "2.0", "id" => 84, "result" => %{}}) <> "\n\n"

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.resp(200, body)
      end
    end)

    {:ok, transport_state} =
      HTTP.connect(
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        protocol_version: "2026-07-28",
        auth_provider: {Provider, test_pid: self()},
        stream_idle_timeout: 2_000
      )

    transport_state = HTTP.settle_protocol_era(transport_state, :modern, "2026-07-28")
    request = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 84, "method" => "tools/call"})

    assert {:ok, transport_state} = HTTP.open_stream(request, transport_state, self())
    stream_pid = Map.fetch!(transport_state.modern_streams, 84)

    client_state = answer_challenge(stream_pid, 84, client_state(transport_state))
    assert_received {:provider_challenge, ~s(Bearer scope="tools.call"), ["tools.call"]}
    assert client_state.transport_state.access_token == "request-stream-token"

    client_state = answer_challenge(stream_pid, 84, client_state)

    assert_received {:provider_step_up, ~s(Bearer error="insufficient_scope", scope="admin"),
                     ["admin"]}

    assert client_state.transport_state.access_token == "request-stream-step-up-token"
    assert client_state.transport_state.auth_provider_state.generation == 2

    assert_receive {:modern_http_stream_message, ^stream_pid, 84,
                    %{"jsonrpc" => "2.0", "id" => 84, "result" => %{}}},
                   1_000

    send(stream_pid, {:modern_http_stream_ack, self(), 84})
    assert_receive {:modern_http_stream_finished, ^stream_pid, 84}, 1_000
    assert Agent.get(attempts, & &1) == 3
  end

  test "a stale stream's challenge neither runs the provider nor changes the transport" do
    active_pid = spawn(fn -> Process.sleep(:infinity) end)
    stale_pid = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      Process.exit(active_pid, :kill)
      Process.exit(stale_pid, :kill)
    end)

    transport_state = %HTTP{
      headers: [{"Authorization", "Bearer current"}],
      access_token: "current",
      auth_provider: Provider,
      auth_provider_state: %{test_pid: self(), generation: 2},
      modern_streams: %{42 => active_pid}
    }

    ref = make_ref()
    challenge = %{status: 401, www_authenticate: "Bearer", scopes: [], token: "current"}

    assert {:noreply, unchanged} =
             Client.handle_info(
               {:modern_http_stream_auth_challenge, self(), 42, ref, challenge},
               client_state(transport_state)
             )

    assert_received {:modern_http_stream_auth_result, ^ref, {:error, :stream_retired}}
    refute_received {:provider_challenge, _, _}
    assert unchanged.transport_state.access_token == "current"
    assert unchanged.transport_state.auth_provider_state.generation == 2
  end

  test "a challenge for a token another stream already replaced reuses the new token" do
    stream_pid = self()

    transport_state = %HTTP{
      headers: [{"Authorization", "Bearer fresh"}],
      access_token: "fresh",
      auth_provider: Provider,
      auth_provider_state: %{test_pid: self(), generation: 1},
      modern_streams: %{7 => stream_pid}
    }

    ref = make_ref()
    # Sent with the token the first stream's 401 already replaced.
    challenge = %{status: 401, www_authenticate: "Bearer", scopes: [], token: "expired"}

    assert {:noreply, client_state} =
             Client.handle_info(
               {:modern_http_stream_auth_challenge, stream_pid, 7, ref, challenge},
               client_state(transport_state)
             )

    assert_received {:modern_http_stream_auth_result, ^ref, {:ok, "fresh"}}
    refute_received {:provider_challenge, _, _}
    assert client_state.transport_state.auth_provider_state.generation == 1
  end
end
