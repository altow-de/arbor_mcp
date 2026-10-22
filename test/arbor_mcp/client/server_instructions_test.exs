defmodule Arbor.MCP.Client.ServerInstructionsTest do
  # The instructions a server sends while the client establishes the
  # connection: in the initialize result on MCP 2025-06-18, in the
  # server/discover result on MCP 2026-07-28. Every test runs the client
  # against a real Runtime-mounted Arbor.MCP.HttpPlug on Bandit.
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.Runtime

  @instructions "Use the search tool before you answer."

  defmodule AppHandler do
    use Arbor.MCP.Server.Handler

    alias Arbor.MCP.Protocol.Initialize

    @impl true
    def init(opts), do: {:ok, %{source: Keyword.fetch!(opts, :source)}}

    @impl true
    def handle_initialize(params, state) do
      fields = %{serverInfo: %{name: "instructions-app", version: "1.0.0"}, capabilities: %{}}

      fields =
        case Agent.get(state.source, & &1) do
          nil -> fields
          instructions -> Map.put(fields, :instructions, instructions)
        end

      {:ok, Initialize.build_initialize_result(params, fields), state}
    end
  end

  # Serves the app like Arbor.MCP.HttpPlug, with the instructions the source
  # holds at the time of each request.
  defmodule InstructionsPlug do
    @behaviour Plug

    @impl true
    def init(opts) do
      {source, opts} = Keyword.pop!(opts, :source)
      {source, Arbor.MCP.HttpPlug.init(opts)}
    end

    @impl true
    def call(conn, {source, opts}) do
      Arbor.MCP.HttpPlug.call(conn, %{opts | instructions: Agent.get(source, & &1)})
    end
  end

  for {era, version, mode} <- [
        {"MCP 2026-07-28", "2026-07-28", :modern_only},
        {"MCP 2025-06-18", "2025-06-18", :legacy_only}
      ] do
    describe "server_instructions/1 on #{era}" do
      @describetag version: version, mode: mode

      test "returns the instructions from the handshake", context do
        {url, _source} = start_app(@instructions)
        client = start_client(url, context)

        assert Client.server_instructions(client) == {:ok, @instructions}
      end

      test "returns nil when the server sends none", context do
        {url, _source} = start_app(nil)
        client = start_client(url, context)

        assert Client.server_instructions(client) == {:ok, nil}
      end

      test "returns the instructions of the latest connection", context do
        {url, source} = start_app(@instructions)
        client = start_client(url, Map.put(context, :reconnect, true))
        assert Client.server_instructions(client) == {:ok, @instructions}

        Agent.update(source, fn _instructions -> nil end)
        reconnected = attach_reconnect_success(client)
        send(client, {:transport_closed, :connection_lost})
        assert_receive {^reconnected, :success}, 2_000

        assert Client.server_instructions(client) == {:ok, nil}
      end
    end
  end

  test "server_instructions/1 answers like server_info/1 before the connection" do
    {:ok, client} =
      Client.start_link(transport: :http, url: "http://127.0.0.1:1/mcp", _skip_connect: true)

    on_exit_disconnect(client)

    assert Client.server_info(client) == {:ok, nil}
    assert Client.server_instructions(client) == {:ok, nil}
  end

  test "discover/2 updates the instructions of a modern connection" do
    {url, source} = start_app(@instructions)
    client = start_client(url, %{version: "2026-07-28", mode: :modern_only})

    Agent.update(source, fn _instructions -> "Ask before you delete." end)
    assert {:ok, %{"instructions" => "Ask before you delete."}} = Client.discover(client)

    assert Client.server_instructions(client) == {:ok, "Ask before you delete."}
  end

  defp attach_reconnect_success(client) do
    ref = make_ref()
    test_pid = self()
    handler_id = "server-instructions-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:arbor_mcp, :client, :reconnect, :success],
      fn _event, _measurements, %{pid: pid}, _config ->
        if pid == client, do: send(test_pid, {ref, :success})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  defp start_app(instructions) do
    source = start_supervised!({Agent, fn -> instructions end}, id: make_ref())

    runtime =
      start_supervised!(
        {Runtime,
         handler: AppHandler,
         handler_args: [source: source],
         transport: :mounted_http,
         execution: :stateless,
         max_concurrency: 4},
        id: make_ref()
      )

    listener =
      start_supervised!(
        {Bandit,
         plug:
           {InstructionsPlug,
            source: source, runtime: runtime, path: "/mcp", protocol_mode: :prefer_modern},
         ip: {127, 0, 0, 1},
         port: 0},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    {"http://127.0.0.1:#{port}/mcp", source}
  end

  defp start_client(url, context) do
    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: url,
        protocol_mode: context.mode,
        protocol_version: context.version,
        use_sse: false,
        security: %{origin: nil},
        health_check_interval: nil,
        reconnect: Map.get(context, :reconnect, false),
        reconnect_backoff: [initial: 10, max: 10, multiplier: 1]
      )

    on_exit_disconnect(client)
  end

  defp on_exit_disconnect(client) do
    on_exit(fn ->
      if Process.alive?(client) do
        try do
          Client.disconnect(client)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    client
  end
end
