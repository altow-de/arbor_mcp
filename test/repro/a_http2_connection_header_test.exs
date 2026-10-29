defmodule Arbor.MCP.Repro.AHTTP2ConnectionHeaderTest do
  # Repro A: Arbor.MCP.HttpPlug puts `connection: keep-alive` on the legacy
  # HTTP+SSE GET stream. Over HTTP/2 a connection-specific header field makes
  # a response malformed (RFC 9113, 8.2.2). Bandit serves h2c with prior
  # knowledge on a plain listener; this checks what it sends and how Mint and
  # an nghttp2 client (curl) take it.
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.{Context, Runtime}

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    @impl true
    def handle_call_tool("tick", _args, state) do
      _ = Context.report_progress(1)
      {:ok, %{content: [%{type: "text", text: "done"}]}, state}
    end
  end

  setup do
    root =
      start_supervised!(
        {Runtime, handler: Handler, transport: :mounted_http},
        id: make_ref()
      )

    {:ok, runtime} = Runtime.ref(root)

    opts = [
      runtime: runtime,
      path: "/mcp",
      protocol_mode: :prefer_modern,
      legacy_http_sse: true
    ]

    listener =
      start_supervised!(
        {Bandit,
         plug: {Arbor.MCP.HttpPlug, opts}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    %{port: port}
  end

  test "legacy GET /sse over h2c: Bandit sends connection: keep-alive, Mint accepts it",
       %{port: port} do
    {:ok, conn} = Mint.HTTP2.connect(:http, "127.0.0.1", port)
    assert Mint.HTTP.protocol(conn) == :http2

    {:ok, conn, ref} =
      Mint.HTTP2.request(conn, "GET", "/sse", [{"accept", "text/event-stream"}], nil)

    {conn, events} = receive_until(conn, ref, &endpoint_event?/1)
    Mint.HTTP.close(conn)

    status = for {:status, ^ref, s} <- events, do: s
    headers = for {:headers, ^ref, h} <- events, pair <- h, do: pair
    data = for {:data, ^ref, d} <- events, into: "", do: d

    IO.puts("\n[A] h2c GET /sse status=#{inspect(status)}")
    IO.puts("[A] response headers: #{inspect(headers)}")
    IO.puts("[A] first data: #{inspect(String.slice(data, 0, 120))}")

    assert status == [200]
    assert {"connection", "keep-alive"} in headers
    assert data =~ "event: endpoint"
  end

  test "modern request stream over h2c carries no connection header", %{port: port} do
    {:ok, conn} = Mint.HTTP2.connect(:http, "127.0.0.1", port)

    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{
          name: "tick",
          arguments: %{},
          _meta: %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => %{},
            "progressToken" => "p"
          }
        }
      })

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"},
      {"mcp-protocol-version", "2026-07-28"},
      {"mcp-method", "tools/call"},
      {"mcp-name", "tick"}
    ]

    {:ok, conn, ref} = Mint.HTTP2.request(conn, "POST", "/mcp", headers, body)
    {conn, events} = receive_until(conn, ref, &Enum.member?(&1, {:done, ref}))
    Mint.HTTP.close(conn)

    headers = for {:headers, ^ref, h} <- events, pair <- h, do: pair
    IO.puts("\n[A] h2c modern POST response headers: #{inspect(headers)}")

    assert {"content-type", "text/event-stream"} in headers
    refute Enum.any?(headers, fn {name, _} -> name == "connection" end)
  end

  # curl 8.7.1 with nghttp2 1.68.1 drops the stream on the header and then
  # waits for --max-time, so the exit code is 28 either way; what differs is
  # whether the endpoint event arrives. Over HTTP/1.1 it does.
  @tag :curl
  test "an nghttp2 client (curl --http2-prior-knowledge) rejects the legacy GET stream",
       %{port: port} do
    curl = System.find_executable("curl")
    {version, 0} = System.cmd(curl, ["--version"])
    IO.puts("\n[A] #{String.trim(hd(String.split(version, "\n")))}")

    if not String.contains?(version, "nghttp2") do
      IO.puts("[A] curl without nghttp2, skipped")
    else
      {h2, _exit} = curl_sse(curl, "--http2-prior-knowledge", port)
      {h1, _exit} = curl_sse(curl, "--http1.1", port)

      IO.puts("[A] curl h2c:\n" <> h2)
      IO.puts("[A] curl HTTP/1.1:\n" <> h1)

      assert h2 =~
               "Invalid HTTP header field was received: frame type: 1, stream: 1, name: [connection], value: [keep-alive]"

      refute h2 =~ "event: endpoint"
      assert h2 =~ "size_download=0"

      assert h1 =~ "event: endpoint"
      refute h1 =~ "Invalid HTTP header"
    end
  end

  # Note for the gateway (vibe-apps-hub, Hub.Gateway.MCP.refuse/3): the same
  # pattern with `connection: close` on a plain response, served over h2c.
  defmodule RefusePlug do
    def init(opts), do: opts

    def call(conn, _opts) do
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.put_resp_header("connection", "close")
      |> Plug.Conn.send_resp(413, "too large")
      |> Plug.Conn.halt()
    end
  end

  @tag :curl
  test "gateway note: connection: close on a plain response over h2c" do
    listener =
      start_supervised!(
        {Bandit, plug: RefusePlug, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    curl = System.find_executable("curl")

    {out, exit_code} =
      System.cmd(
        curl,
        [
          "--http2-prior-knowledge",
          "-sS",
          "-w",
          "\nhttp_version=%{http_version} status=%{response_code} size_download=%{size_download}",
          "--max-time",
          "2",
          "http://127.0.0.1:#{port}/mcp"
        ],
        stderr_to_stdout: true
      )

    IO.puts("\n[A/gateway] curl h2c exit=#{exit_code}:\n" <> out)
    assert out =~ "name: [connection], value: [close]"
    refute out =~ "too large"
  end

  defp curl_sse(curl, protocol, port) do
    System.cmd(
      curl,
      [
        protocol,
        "-sS",
        "-N",
        "-w",
        "\nhttp_version=%{http_version} status=%{response_code} size_download=%{size_download}",
        "--max-time",
        "2",
        "-H",
        "accept: text/event-stream",
        "http://127.0.0.1:#{port}/sse"
      ],
      stderr_to_stdout: true
    )
  end

  defp endpoint_event?(events),
    do: Enum.any?(events, &match?({:data, _ref, "event: endpoint" <> _}, &1))

  defp receive_until(conn, ref, done?, events \\ []) do
    if done?.(events) do
      {conn, events}
    else
      receive do
        message ->
          case Mint.HTTP.stream(conn, message) do
            {:ok, conn, next} ->
              receive_until(conn, ref, done?, events ++ next)

            {:error, conn, reason, next} ->
              IO.puts("[A] Mint error: #{inspect(reason)}")
              {conn, events ++ next ++ [{:error, ref, reason}]}

            :unknown ->
              receive_until(conn, ref, done?, events)
          end
      after
        3_000 -> flunk("timed out: #{inspect(events)}")
      end
    end
  end
end
