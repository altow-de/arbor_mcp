defmodule Arbor.MCP.Server.HTTPRequestStreamCloseTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{HTTPWriterProxy, HTTPWriterRegistry}

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts), do: {:ok, Keyword.fetch!(opts, :test_pid)}

    @impl true
    def handle_call_tool("hold", _arguments, test_pid) do
      send(test_pid, {:tool_started, self()})

      receive do
        :release -> {:ok, %{content: [%{type: "text", text: "released"}]}, test_pid}
      end
    end

    def handle_call_tool("fast", _arguments, test_pid),
      do: {:ok, %{content: [%{type: "text", text: "fast"}]}, test_pid}
  end

  for adapter <- [:cowboy, :bandit] do
    @tag :physical_http
    test "#{adapter} cancels a blocked tool when its request SSE stream closes" do
      {runtime, port} = start_server(unquote(adapter))
      conn = connect(port)
      {:ok, conn, ref} = request(conn, "hold")
      assert_receive {:tool_started, worker}, 1_000
      monitor = Process.monitor(worker)
      {conn, events} = receive_until(conn, ref, &heartbeat?/1)
      assert {:status, ref, 200} in events
      assert heartbeat?(events)
      assert content_type(events, ref) == "text/event-stream"

      other_conn = connect(port)
      {:ok, other_conn, other_ref} = request(other_conn, "hold")
      assert_receive {:tool_started, other_worker}, 1_000
      {other_conn, _other_events} = receive_until(other_conn, other_ref, &heartbeat?/1)

      Mint.HTTP.close(conn)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000
      assert Process.alive?(other_worker)
      send(other_worker, :release)

      {other_conn, other_tail} =
        receive_until(other_conn, other_ref, &Enum.member?(&1, {:done, other_ref}))

      assert response_body(other_tail, other_ref) =~ "\"text\":\"released\""
      Mint.HTTP.close(other_conn)
      {:ok, runtime_ref} = Runtime.ref(runtime)
      {:ok, domain} = HTTPWriterProxy.domain(runtime_ref)

      Arbor.MCP.TestHelpers.wait_until(fn ->
        Runtime.stats!(runtime).reserved == 0 and
          match?(%{frames: 0, bytes: 0}, HTTPWriterRegistry.stats(domain))
      end)
    end

    @tag :physical_http
    test "#{adapter} keeps a connected tool running and stops comments at completion" do
      {_runtime, port} = start_server(unquote(adapter))
      conn = connect(port)
      {:ok, conn, ref} = request(conn, "hold")
      assert_receive {:tool_started, worker}, 1_000
      {conn, events} = receive_until(conn, ref, &heartbeat?/1)
      assert heartbeat?(events)
      assert content_type(events, ref) == "text/event-stream"
      assert Process.alive?(worker)

      send(worker, :release)
      {conn, tail} = receive_until(conn, ref, &Enum.member?(&1, {:done, ref}))
      body = response_body(events ++ tail, ref)
      assert body =~ "\"text\":\"released\""
      assert String.starts_with?(body, ":\r\n\r\n")
      assert String.ends_with?(body, "\r\n\r\n")
      Mint.HTTP.close(conn)

      conn = connect(port)
      {:ok, conn, ref} = request(conn, "fast")
      {conn, events} = receive_until(conn, ref, &Enum.member?(&1, {:done, ref}))
      assert response_body(events, ref) =~ "\"text\":\"fast\""
      refute response_body(events, ref) =~ ":\r\n\r\n"
      Mint.HTTP.close(conn)

      conn = connect(port)
      {:ok, conn, ref} = request(conn, "fast", false)
      {conn, events} = receive_until(conn, ref, &Enum.member?(&1, {:done, ref}))
      assert content_type(events, ref) =~ "application/json"

      assert Jason.decode!(response_body(events, ref))["result"]["content"] == [
               %{"type" => "text", "text" => "fast"}
             ]

      Mint.HTTP.close(conn)
    end
  end

  defp start_server(adapter) do
    runtime =
      start_supervised!(
        {Runtime,
         handler: Handler,
         handler_args: [test_pid: self()],
         transport: :mounted_http,
         protocol_mode: :modern_only}
      )

    opts = [
      runtime: runtime,
      path: "/mcp",
      protocol_mode: :modern_only,
      request_keepalive_interval_ms: 40
    ]

    port = free_port()

    case adapter do
      :cowboy ->
        ref = {:request_stream_close, make_ref()}
        {:ok, _listener} = Plug.Cowboy.http(Arbor.MCP.HttpPlug, opts, port: port, ref: ref)
        on_exit(fn -> Plug.Cowboy.shutdown(ref) end)

      :bandit ->
        {:ok, listener} =
          Bandit.start_link(
            plug: {Arbor.MCP.HttpPlug, opts},
            port: port,
            ip: {127, 0, 0, 1},
            startup_log: false
          )

        on_exit(fn ->
          try do
            if Process.alive?(listener), do: Supervisor.stop(listener)
          catch
            :exit, _reason -> :ok
          end
        end)
    end

    {runtime, port}
  end

  defp connect(port) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
    conn
  end

  defp request(conn, name, stream? \\ true) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    meta = if stream?, do: Map.put(meta, "progressToken", "heartbeat"), else: meta

    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: System.unique_integer([:positive]),
        method: "tools/call",
        params: %{name: name, arguments: %{}, _meta: meta}
      })

    Mint.HTTP.request(
      conn,
      "POST",
      "/mcp",
      [
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"},
        {"mcp-protocol-version", "2026-07-28"},
        {"mcp-method", "tools/call"},
        {"mcp-name", name}
      ],
      body
    )
  end

  defp receive_until(conn, ref, predicate, events \\ []) do
    if predicate.(events) do
      {conn, events}
    else
      receive do
        message ->
          case Mint.HTTP.stream(conn, message) do
            {:ok, conn, next} ->
              receive_until(conn, ref, predicate, events ++ next)

            :unknown ->
              receive_until(conn, ref, predicate, events)
          end
      after
        2_000 -> flunk("timed out waiting for request stream #{inspect(ref)}: #{inspect(events)}")
      end
    end
  end

  defp heartbeat?(events),
    do:
      Enum.any?(events, fn
        {:data, _ref, data} -> String.contains?(data, ":\r\n\r\n")
        _ -> false
      end)

  defp response_body(events, ref) do
    for {:data, ^ref, data} <- events, into: "", do: data
  end

  defp content_type(events, ref) do
    values =
      for {:headers, ^ref, headers} <- events,
          {name, value} <- headers,
          name == "content-type",
          do: value

    List.first(values)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
