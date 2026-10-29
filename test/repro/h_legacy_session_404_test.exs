defmodule Arbor.MCP.Repro.HLegacySession404Test do
  # Repro for candidate H (ki-unit/vibe-apps-paas#334): a legacy Streamable
  # HTTP client keeps its Mcp-Session-Id after the server restarts. The
  # server answers 404; the 2025-06-18 and 2025-11-25 transports say the
  # client MUST then start a new session with a fresh initialize.
  #
  # Server: Runtime-mounted HttpPlug, protocol_mode :legacy_only, on Bandit
  # at a fixed, dynamically chosen port. A restart is a new Runtime and a new
  # listener on the same port, so the old session is unknown.
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.Runtime

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_initialize(params, state) do
      send(state.test_pid, {:initialize, state.generation, params["protocolVersion"]})

      {:ok, %{serverInfo: %{name: "legacy-repro", version: "1"}, capabilities: %{tools: %{}}},
       state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      send(state.test_pid, {:listed, state.generation})
      {:ok, [%{name: "echo", inputSchema: %{"type" => "object"}}], nil, state}
    end
  end

  defmodule Recorder do
    # Reports method, Mcp-Session-Id and the status sent back.
    def init(opts) do
      {owner, opts} = Keyword.pop!(opts, :owner)
      {owner, Arbor.MCP.HttpPlug.init(opts)}
    end

    def call(conn, {owner, plug_opts}) do
      session = conn |> Plug.Conn.get_req_header("mcp-session-id") |> List.first()

      conn
      |> Plug.Conn.register_before_send(fn conn ->
        send(owner, {:http, conn.method, session, conn.status})
        conn
      end)
      |> Arbor.MCP.HttpPlug.call(plug_opts)
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp start_server(port, generation) do
    runtime_id = {:runtime, generation}
    listener_id = {:listener, generation}

    runtime =
      start_supervised!(
        {Runtime,
         handler: Handler,
         handler_args: [test_pid: self(), generation: generation],
         transport: :mounted_http,
         protocol_mode: :legacy_only},
        id: runtime_id
      )

    start_supervised!(
      {Bandit,
       plug:
         {Recorder, [owner: self(), runtime: runtime, path: "/mcp", protocol_mode: :legacy_only]},
       ip: {127, 0, 0, 1},
       port: port,
       startup_log: false},
      id: listener_id
    )

    {runtime_id, listener_id}
  end

  defp restart({runtime_id, listener_id}, port) do
    :ok = stop_supervised(listener_id)
    :ok = stop_supervised(runtime_id)
    start_server(port, 2)
  end

  defp start_client(port, opts) do
    defaults = [
      transport: :http,
      url: "http://127.0.0.1:#{port}/mcp",
      protocol_mode: :legacy_only,
      use_sse: false,
      security: %{origin: nil},
      response_cache: false,
      reconnect_backoff: [initial: 50, max: 100, multiplier: 1]
    ]

    {:ok, client} = Client.start_link(Keyword.merge(defaults, opts))

    on_exit(fn ->
      try do
        Client.disconnect(client)
      catch
        :exit, _ -> :ok
      end
    end)

    client
  end

  # Everything reported until 300 ms pass without a message, at most 3 s.
  defp messages, do: messages([], System.monotonic_time(:millisecond) + 3_000)

  defp messages(acc, until) do
    wait = min(300, max(until - System.monotonic_time(:millisecond), 0))

    receive do
      {:http, _, _, _} = m -> messages([m | acc], until)
      {:initialize, _, _} = m -> messages([m | acc], until)
      {:listed, _} = m -> messages([m | acc], until)
    after
      wait -> Enum.reverse(acc)
    end
  end

  # Counts of {method, with or without session id, status}, initialize and list.
  defp summary(wire) do
    Enum.frequencies_by(wire, fn
      {:http, method, nil, status} -> {method, :no_session, status}
      {:http, method, _session, status} -> {method, :with_session, status}
      other -> other
    end)
  end

  defp show(result), do: inspect(result, limit: 6, printable_limit: 200)

  # With use_sse: false the client runs no receiver and therefore no health
  # check (client.ex schedule_next_health_check/1); reconnect never fires.
  for reconnect <- [false, true] do
    test "use_sse: false, reconnect: #{reconnect}: every request after the restart gets 404" do
      port = free_port()
      server = start_server(port, 1)

      client =
        start_client(port, reconnect: unquote(reconnect), health_check_interval: 200)

      assert {:ok, _} = Client.list_tools(client)
      before = messages()

      restart(server, port)
      results = for _ <- 1..3, do: Client.list_tools(client)
      Process.sleep(1_000)
      late = Client.list_tools(client)
      wire = messages()
      {:ok, status} = Client.get_status(client)

      IO.puts("""
      H use_sse false, reconnect #{unquote(reconnect)}:
        before restart: #{inspect(before)}
        1st list_tools after restart: #{show(hd(results))}
        all results: #{inspect(Enum.map(results ++ [late], &elem(&1, 0)))}
        status: #{inspect(Map.take(status, [:connection_status, :reconnect_attempts]))}
        wire after restart: #{inspect(wire)}
      """)

      session =
        Enum.find_value(before, fn
          {:http, "POST", s, 200} when is_binary(s) -> s
          _ -> nil
        end)

      for result <- results ++ [late] do
        assert {:error, %{reason: {:http_error, 404, body}}} = result
        assert body =~ "Session not found"
      end

      assert Enum.all?(wire, &match?({:http, "POST", ^session, 404}, &1))
      assert status.connection_status == :ready
      refute_received {:initialize, 2, _}
    end
  end

  # With the default use_sse: true the client also holds the session's GET
  # stream. When the GET is reopened after the restart it gets 404, which
  # closes the transport; only then does reconnect run a new initialize.
  # A request in between still gets the 404.
  test "use_sse: true, reconnect: true: recovers via the GET stream, not via the POST's 404" do
    port = free_port()
    server = start_server(port, 1)
    client = start_client(port, use_sse: true, reconnect: true, health_check_interval: nil)

    assert {:ok, _} = Client.list_tools(client)
    _ = messages()

    restart(server, port)
    at_once = Client.list_tools(client)
    Process.sleep(1_000)
    later = Client.list_tools(client)
    wire = messages()

    IO.puts("""
    H use_sse true, reconnect true:
      list_tools right after restart: #{show(at_once)}
      list_tools 1 s later: #{inspect(elem(later, 0))}
      wire after restart: #{inspect(summary(wire))}
    """)

    assert {:error, %{reason: {:http_error, 404, _}}} = at_once
    assert {:ok, _} = later
    assert Map.has_key?(summary(wire), {"GET", :with_session, 404})
    assert {:initialize, 2, "2025-11-25"} in wire
  end

  test "use_sse: true, reconnect: false: the GET's 404 leaves the client disconnected" do
    port = free_port()
    server = start_server(port, 1)
    client = start_client(port, use_sse: true, reconnect: false, health_check_interval: nil)

    assert {:ok, _} = Client.list_tools(client)
    _ = messages()

    restart(server, port)
    Process.sleep(1_000)
    result = Client.list_tools(client)
    {:ok, status} = Client.get_status(client)
    wire = messages()

    IO.puts("""
    H use_sse true, reconnect false:
      list_tools 1 s after restart: #{show(result)}
      status: #{inspect(Map.take(status, [:connection_status]))}
      wire after restart: #{inspect(summary(wire))}
    """)

    assert {:error, :not_connected} = result
    assert status.connection_status == :disconnected
    refute_received {:initialize, 2, _}
  end
end
