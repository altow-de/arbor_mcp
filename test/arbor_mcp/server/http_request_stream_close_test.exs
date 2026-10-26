defmodule Arbor.MCP.Server.HTTPRequestStreamCloseTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.{Runtime, Transport}
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

  # A borrowed adapter that reports every write to the test process and can
  # hold or fail a keepalive comment. Its callbacks run in the request process.
  defmodule StubAdapter do
    alias Plug.Adapters.Test.Conn

    defdelegate read_req_body(state, opts), to: Conn
    defdelegate send_resp(state, status, headers, body), to: Conn

    def send_chunked(state, status, headers) do
      send(state.observer, {:stream_headers, self(), status})
      Conn.send_chunked(state, status, headers)
    end

    def chunk(state, body) do
      wire = IO.iodata_to_binary(body)
      send(state.observer, {:stream_wire, self(), wire})

      cond do
        wire == ":\r\n\r\n" and state.fail_keepalive ->
          {:error, :closed}

        wire == ":\r\n\r\n" and state.hold_keepalive ->
          send(state.observer, {:keepalive_entered, self()})
          receive do: (:return_io -> :ok)
          Conn.chunk(%{state | hold_keepalive: false}, body)

        true ->
          Conn.chunk(state, body)
      end
    end
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

  for adapter <- [:cowboy, :bandit] do
    @tag :physical_http
    test "owned #{adapter} servers apply :request_keepalive_interval_ms" do
      root =
        start_supervised!(
          {Runtime,
           handler: Handler,
           handler_args: [test_pid: self()],
           transport: :http,
           protocol_mode: :modern_only,
           http: [
             adapter: unquote(adapter),
             port: 0,
             host: {127, 0, 0, 1},
             request_keepalive_interval_ms: 40
           ]}
        )

      conn = connect(owned_port(root))
      {:ok, conn, ref} = request(conn, "hold")
      assert_receive {:tool_started, worker}, 1_000
      # The 15-second default would not write a comment before this times out.
      {conn, events} = receive_until(conn, ref, &heartbeat?/1)
      assert content_type(events, ref) == "text/event-stream"

      send(worker, :release)
      {conn, tail} = receive_until(conn, ref, &Enum.member?(&1, {:done, ref}))
      assert response_body(events ++ tail, ref) =~ "\"text\":\"released\""
      Mint.HTTP.close(conn)
    end

    test "owned #{adapter} servers reject an invalid request interval like the subscription interval" do
      for key <- [:subscription_keepalive_interval_ms, :request_keepalive_interval_ms] do
        http = [{:adapter, unquote(adapter)}, {:port, 0}, {:host, {127, 0, 0, 1}}, {key, 0}]

        # The mount validates both intervals when the listener initializes it.
        assert {:error, _reason} =
                 start_supervised(
                   {Runtime,
                    handler: Handler,
                    handler_args: [test_pid: self()],
                    transport: :http,
                    protocol_mode: :modern_only,
                    http: http},
                   id: key
                 )

        assert_raise ArgumentError, ~r/#{key} must be a positive integer or :infinity/, fn ->
          Arbor.MCP.HttpPlug.init([{key, 0}, runtime: :not_started])
        end
      end
    end
  end

  test "owned and borrowed HTTP configuration keep both keepalive intervals for the mount" do
    for ownership <- [:owned, :borrowed] do
      assert {:ok, %{plug_options: plug}} =
               Arbor.MCP.Server.HTTP.Config.new(
                 [
                   transport: :http,
                   http_adapter: :bandit,
                   request_keepalive_interval_ms: 40,
                   subscription_keepalive_interval_ms: 50
                 ],
                 ownership
               )

      assert plug[:request_keepalive_interval_ms] == 40
      assert plug[:subscription_keepalive_interval_ms] == 50
    end
  end

  test "a handler timeout during an in-flight keepalive still writes the timeout error" do
    runtime = start_runtime(request_timeout_ms: 1_000)
    socket = stream_request(runtime, "hold", hold_keepalive: true)
    assert_receive {:tool_started, worker}, 1_000
    monitor = Process.monitor(worker)
    assert_receive {:keepalive_entered, ^socket}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 3_000

    # The comment is not the request's output, so the gateway still queues
    # the failure response behind it instead of abandoning the stream.
    domain = writer_domain(runtime)

    Arbor.MCP.TestHelpers.wait_until(fn ->
      match?(%{in_flight: 1, queued: 1}, HTTPWriterRegistry.stats(domain))
    end)

    send(socket, :return_io)
    assert_receive {:stream_wire, ^socket, "data: " <> frame}, 1_000
    assert %{"error" => %{"code" => _code, "message" => _message}} = Jason.decode!(frame)
    assert_receive {:stream_result, ^socket, {:returned, conn}}, 1_000
    assert conn.state == :chunked
    assert_released(runtime)
  end

  test "a failed first keepalive returns the chunked conn and cancels the request" do
    runtime = start_runtime([])
    socket = stream_request(runtime, "hold", fail_keepalive: true)
    assert_receive {:tool_started, worker}, 1_000
    monitor = Process.monitor(worker)

    # The headers went out with the first comment and only its chunk failed,
    # as when a reset arrives between the two sends on Bandit.
    assert_receive {:stream_headers, ^socket, 200}, 1_000
    assert_receive {:stream_wire, ^socket, ":\r\n\r\n"}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000
    assert_receive {:stream_result, ^socket, {:returned, conn}}, 1_000

    # An :unset conn here makes Bandit raise Plug.Conn.NotSentError.
    assert conn.state == :chunked
    refute_received {:stream_wire, ^socket, _wire}
    assert_released(runtime)
  end

  defp start_runtime(opts) do
    root =
      start_supervised!(
        {Runtime,
         Keyword.merge(
           [
             handler: Handler,
             handler_args: [test_pid: self()],
             transport: :mounted_http,
             protocol_mode: :modern_only
           ],
           opts
         )},
        id: make_ref()
      )

    {:ok, runtime} = Runtime.ref(root)
    runtime
  end

  defp stream_request(runtime, name, adapter_opts, plug_opts \\ []) do
    parent = self()

    socket =
      spawn(fn ->
        conn =
          Plug.Test.conn(:post, "/mcp", tool_body(name, true))
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
          |> Plug.Conn.put_req_header("mcp-protocol-version", "2026-07-28")
          |> Plug.Conn.put_req_header("mcp-method", "tools/call")
          |> Plug.Conn.put_req_header("mcp-name", name)

        {_adapter, state} = conn.adapter

        stub =
          Map.merge(
            state,
            Map.new(
              Keyword.merge(
                [observer: parent, hold_keepalive: false, fail_keepalive: false],
                adapter_opts
              )
            )
          )

        opts =
          Arbor.MCP.HttpPlug.init(
            Keyword.merge(
              [runtime: runtime, protocol_mode: :modern_only, request_keepalive_interval_ms: 20],
              plug_opts
            )
          )

        result =
          try do
            {:returned, Arbor.MCP.HttpPlug.call(%{conn | adapter: {StubAdapter, stub}}, opts)}
          catch
            kind, reason -> {:raised, kind, reason}
          end

        send(parent, {:stream_result, self(), result})
      end)

    on_exit(fn -> if Process.alive?(socket), do: Process.exit(socket, :kill) end)
    socket
  end

  defp writer_domain(runtime) do
    {:ok, runtime_ref} = Runtime.ref(runtime)
    {:ok, domain} = HTTPWriterProxy.domain(runtime_ref)
    domain
  end

  defp assert_released(runtime) do
    domain = writer_domain(runtime)

    Arbor.MCP.TestHelpers.wait_until(fn ->
      Runtime.stats!(runtime).reserved == 0 and
        match?(%{frames: 0, bytes: 0}, HTTPWriterRegistry.stats(domain))
    end)
  end

  defp owned_port(root) do
    case Transport.http_listener(root) do
      {:ok, %{adapter: :bandit, listener: listener}} ->
        {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
        port

      {:ok, %{adapter: :cowboy, ranch_ref: ref}} ->
        :ranch.get_port(ref)
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
      tool_body(name, stream?)
    )
  end

  # A progress token makes the request own an SSE response stream.
  defp tool_body(name, stream?) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    meta = if stream?, do: Map.put(meta, "progressToken", "heartbeat"), else: meta

    Jason.encode!(%{
      jsonrpc: "2.0",
      id: System.unique_integer([:positive]),
      method: "tools/call",
      params: %{name: name, arguments: %{}, _meta: meta}
    })
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
