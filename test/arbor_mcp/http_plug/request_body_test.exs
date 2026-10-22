defmodule Arbor.MCP.HttpPlug.RequestBodyTest do
  # A request body that a Runtime-mounted Arbor.MCP.HttpPlug does not read in
  # full is answered and the connection closed (RFC 9110, 15.5.14): the
  # unread rest stays on it, and the next request over the same connection,
  # possibly someone else's behind a proxy, must not start inside it. A body
  # read in full before the plug leaves nothing on the connection.
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.Runtime

  @body_limit 1_000

  # Well below the 15 s for which Bandit would otherwise wait for the rest of
  # the body before it serves or closes the connection.
  @deadline 5_000

  defmodule AppHandler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_opts), do: {:ok, %{}}
  end

  # The Plug test adapter, except that reading the request body fails.
  defmodule UnreadableBodyAdapter do
    @behaviour Plug.Conn.Adapter

    alias Plug.Adapters.Test.Conn, as: TestAdapter

    @impl true
    def read_req_body(_payload, _opts), do: {:error, :timeout}

    @impl true
    defdelegate send_resp(payload, status, headers, body), to: TestAdapter

    @impl true
    defdelegate send_file(payload, status, headers, path, offset, length), to: TestAdapter

    @impl true
    defdelegate send_chunked(payload, status, headers), to: TestAdapter

    @impl true
    defdelegate chunk(payload, body), to: TestAdapter

    @impl true
    defdelegate inform(payload, status, headers), to: TestAdapter

    @impl true
    defdelegate upgrade(payload, protocol, opts), to: TestAdapter

    @impl true
    defdelegate push(payload, path, headers), to: TestAdapter

    @impl true
    defdelegate get_peer_data(payload), to: TestAdapter

    @impl true
    defdelegate get_sock_data(payload), to: TestAdapter

    @impl true
    defdelegate get_ssl_data(payload), to: TestAdapter

    @impl true
    defdelegate get_http_protocol(payload), to: TestAdapter
  end

  setup do
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

    {:ok, runtime: runtime}
  end

  test "a too large body gets 413 and the connection closes at once", %{runtime: runtime} do
    port = start_listener(runtime)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    # The body announces far more than the limit; only the part the plug
    # reads arrives.
    :ok =
      :gen_tcp.send(socket, [
        "POST /mcp HTTP/1.1\r\n",
        "host: 127.0.0.1\r\n",
        "content-type: application/json\r\n",
        "accept: application/json, text/event-stream\r\n",
        "content-length: 1000000\r\n\r\n",
        :binary.copy("x", @body_limit)
      ])

    started = System.monotonic_time(:millisecond)
    assert {:closed, response} = read_until_closed(socket, started + @deadline, "")

    assert response =~ ~r/\AHTTP\/1\.1 413 /
    assert response =~ ~r/\r\nconnection: close\r\n/i
    assert response =~ "Request body too large"
  end

  # HTTP/2 forbids connection-specific header fields (RFC 9113, 8.2.2); a
  # client treats a response with `connection` as malformed. Bandit ends the
  # stream itself, so the 413 needs no close there.
  test "under HTTP/2 a too large body gets 413 without a connection header", %{
    runtime: runtime
  } do
    port = start_listener(runtime)
    {:ok, conn} = Mint.HTTP2.connect(:http, "127.0.0.1", port)

    {:ok, conn, ref} =
      Mint.HTTP2.request(
        conn,
        "POST",
        "/mcp",
        [
          {"content-type", "application/json"},
          {"accept", "application/json, text/event-stream"},
          {"content-length", "1000000"}
        ],
        :stream
      )

    # Bandit's HTTP/2 read reports the rest only once it holds more than the
    # limit.
    {:ok, conn} = Mint.HTTP2.stream_request_body(conn, ref, :binary.copy("x", 2 * @body_limit))

    started = System.monotonic_time(:millisecond)
    assert {:done, response} = receive_h2_response(conn, ref, started + @deadline, %{})

    assert response.status == 413
    refute List.keymember?(response.headers, "connection", 0)
    assert response.body == "Request body too large"

    Mint.HTTP2.close(conn)
  end

  test "an unreadable body gets 400 and closes the connection", %{runtime: runtime} do
    opts = Arbor.MCP.HttpPlug.init(runtime: runtime, path: "/mcp", body_limit: @body_limit)

    conn =
      Plug.Test.conn(:post, "/mcp", "{}")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> then(fn %Plug.Conn{adapter: {_adapter, payload}} = conn ->
        %{conn | adapter: {UnreadableBodyAdapter, payload}}
      end)
      |> Arbor.MCP.HttpPlug.call(opts)

    assert conn.status == 400
    assert conn.resp_body == "Invalid request body"
    assert Plug.Conn.get_resp_header(conn, "connection") == ["close"]
  end

  # An upstream plug that read the body has left nothing on the connection,
  # so a too large body is answered without closing it.
  test "a too large pre-read body gets 413 and keeps the connection", %{runtime: runtime} do
    opts = Arbor.MCP.HttpPlug.init(runtime: runtime, path: "/mcp", body_limit: @body_limit)

    conn =
      Plug.Test.conn(:post, "/mcp", "")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.assign(:raw_body, :binary.copy("x", @body_limit + 1))
      |> Arbor.MCP.HttpPlug.call(opts)

    assert conn.status == 413
    assert conn.resp_body == "Request body too large"
    assert Plug.Conn.get_resp_header(conn, "connection") == []
  end

  test "a too large parsed body gets 413 and keeps the connection", %{runtime: runtime} do
    opts = Arbor.MCP.HttpPlug.init(runtime: runtime, path: "/mcp", body_limit: @body_limit)

    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "ping",
      "params" => %{"padding" => :binary.copy("x", @body_limit)}
    }

    # As after Plug.Parsers: the body is read, and only `body_params` holds it.
    conn =
      Plug.Test.conn(:post, "/mcp", "")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Map.merge(%{body_params: request, params: request})
      |> Arbor.MCP.HttpPlug.call(opts)

    assert conn.status == 413
    assert conn.resp_body == "Request body too large"
    assert Plug.Conn.get_resp_header(conn, "connection") == []
  end

  defp start_listener(runtime) do
    listener =
      start_supervised!(
        {Bandit,
         plug:
           {Arbor.MCP.HttpPlug,
            runtime: runtime, path: "/mcp", protocol_mode: :prefer_modern, body_limit: @body_limit},
         ip: {127, 0, 0, 1},
         port: 0},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    port
  end

  defp read_until_closed(socket, deadline, received) do
    remaining = deadline - System.monotonic_time(:millisecond)

    case :gen_tcp.recv(socket, 0, max(remaining, 0)) do
      {:ok, data} -> read_until_closed(socket, deadline, received <> data)
      {:error, :closed} -> {:closed, received}
      {:error, reason} -> {reason, received}
    end
  end

  defp receive_h2_response(conn, ref, deadline, response) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      message ->
        case Mint.HTTP2.stream(conn, message) do
          {:ok, conn, responses} ->
            case collect_h2_response(responses, ref, response) do
              {:done, response} -> {:done, response}
              {:cont, response} -> receive_h2_response(conn, ref, deadline, response)
            end

          {:error, _conn, reason, _responses} ->
            {:error, reason, response}

          :unknown ->
            receive_h2_response(conn, ref, deadline, response)
        end
    after
      remaining -> {:timeout, response}
    end
  end

  defp collect_h2_response([], _ref, response), do: {:cont, response}

  defp collect_h2_response([{:status, ref, status} | rest], ref, response),
    do: collect_h2_response(rest, ref, Map.put(response, :status, status))

  defp collect_h2_response([{:headers, ref, headers} | rest], ref, response),
    do: collect_h2_response(rest, ref, Map.put(response, :headers, headers))

  defp collect_h2_response([{:data, ref, data} | rest], ref, response),
    do: collect_h2_response(rest, ref, Map.update(response, :body, data, &(&1 <> data)))

  defp collect_h2_response([{:done, ref} | _rest], ref, response), do: {:done, response}

  defp collect_h2_response([{:error, ref, reason} | _rest], ref, response),
    do: {{:error, reason}, response}

  defp collect_h2_response([_other | rest], ref, response),
    do: collect_h2_response(rest, ref, response)
end
