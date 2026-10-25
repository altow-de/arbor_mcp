defmodule Arbor.MCP.Server.ConcurrentExecutionTest do
  @moduledoc """
  Servers run requests on one connection concurrently by default, like the
  other MCP SDKs. Request callbacks then see a snapshot of the handler state
  and cannot change it; `handle_initialize` and cancellation trackers still
  can, one at a time. `execution: :stateful` runs one callback at a time so
  each can return the next handler state, and still answers `ping` meanwhile.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server
  alias Arbor.MCP.Server.{Runtime, StdioServer}
  alias Arbor.MCP.Server.Runtime.Config
  alias Arbor.MCP.Test.StdioRuntimeFixture.Device

  defmodule Handler do
    @moduledoc false
    use Arbor.MCP.Server.Handler
    defoverridable handle_call: 3

    @impl true
    def init(args) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(args, :test_pid),
         count: 0,
         client: nil,
         cancelled_requests: MapSet.new()
       }}
    end

    @impl true
    def handle_initialize(params, state) do
      {:ok,
       %{
         protocolVersion: "2025-06-18",
         serverInfo: %{name: "concurrent", version: "0"},
         capabilities: %{tools: %{}}
       }, %{state | client: get_in(params, ["clientInfo", "name"])}}
    end

    @impl true
    def handle_call(:snapshot, _from, state),
      do: {:reply, Map.take(state, [:client, :cancelled_requests]), state}

    @impl true
    def handle_list_tools(_cursor, state) do
      tools = [
        %{name: "hold", inputSchema: %{type: "object"}},
        %{name: "inc", inputSchema: %{type: "object"}}
      ]

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool("hold", _args, state) do
      send(state.test_pid, {:holding, self()})

      receive do
        :release -> {:ok, %{content: [%{type: "text", text: "released"}]}, state}
        {:arbor_mcp_cancelled, _token, _reason} -> {:ok, %{content: []}, state}
      end
    end

    def handle_call_tool("inc", _args, state) do
      count = state.count + 1
      {:ok, %{content: [], structuredContent: %{count: count}}, %{state | count: count}}
    end
  end

  test "the runtime defaults to concurrent execution and a one-hour deadline" do
    assert {:ok, config} = Config.new(handler: Handler)
    assert %{execution: :stateless, max_concurrency: 64, request_timeout_ms: 3_600_000} = config

    assert {:ok, %{max_concurrency: 1}} = Config.new(handler: Handler, execution: :stateful)

    assert {:error, :invalid_execution_configuration} =
             Config.new(handler: Handler, execution: :stateful, max_concurrency: 2)
  end

  describe "BEAM/test transport" do
    test "tool calls on one connection run at the same time by default" do
      client = start_client()

      tasks =
        for _ <- 1..3, do: Task.async(fn -> Client.call_tool(client, "hold", %{}, 5_000) end)

      # All three are running before any of them is released.
      workers = for _ <- 1..3, do: receive_holding()
      Enum.each(workers, &send(&1, :release))

      assert Enum.all?(Task.await_many(tasks, 5_000), &match?({:ok, _}, &1))
    end

    test "a stateless server's handle_initialize can still set up handler state" do
      {client, server} = start_pair()

      assert %{client: client_name} = Server.call(server, :snapshot)
      assert is_binary(client_name)
      assert {:ok, _} = Client.ping(client, 2_000)
    end

    test "a commit made while a callback runs does not fail that callback" do
      {client, server} = start_pair()

      cancelled = Task.async(fn -> Client.call_tool(client, "hold", %{}, 200) end)
      _cancelled_worker = receive_holding()
      running = Task.async(fn -> Client.call_tool(client, "hold", %{}, 5_000) end)
      running_worker = receive_holding()

      # The timeout cancels the first call; the cancellation tracker commits a
      # new state while the second call still holds its older snapshot.
      assert {:error, _timeout} = Task.await(cancelled)

      wait_until(fn ->
        %{cancelled_requests: set} = Server.call(server, :snapshot)
        MapSet.size(set) == 1
      end)

      send(running_worker, :release)
      assert {:ok, _} = Task.await(running)
    end

    test "a stateless server rejects a changed handler state and says how to fix it" do
      client = start_client()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, %{data: %{"type" => "invalid_handler_state"}}} =
                   Client.call_tool(client, "inc", %{}, 5_000)
        end)

      assert log =~ "returned a changed handler state"
      assert log =~ "execution: :stateful"
    end

    test "a stateful server runs one callback at a time and still answers ping" do
      client = start_client(execution: :stateful)

      first = Task.async(fn -> Client.call_tool(client, "hold", %{}, 5_000) end)
      first_worker = receive_holding()
      second = Task.async(fn -> Client.call_tool(client, "hold", %{}, 5_000) end)

      # Answered while the first call holds the serial slot.
      assert {:ok, _} = Client.ping(client, 2_000)
      refute_received {:holding, _}

      send(first_worker, :release)
      assert {:ok, _} = Task.await(first)
      send(receive_holding(), :release)
      assert {:ok, _} = Task.await(second)

      assert {:ok, %{structuredOutput: %{"count" => 1}}} =
               Client.call_tool(client, "inc", %{}, 5_000)
    end
  end

  describe "stdio transport" do
    test "a stateless server runs stdio requests at the same time" do
      {input, _root} = start_stdio([])
      write(input, [tool_call(1, "hold"), tool_call(2, "hold")])

      workers = for _ <- 1..2, do: receive_holding()
      Enum.each(workers, &send(&1, :release))

      assert MapSet.new([1, 2]) == MapSet.new(for _ <- 1..2, do: receive_response()["id"])
    end

    test "a stateful server answers ping while a callback holds its slot" do
      {input, _root} = start_stdio(execution: :stateful)
      write(input, [tool_call(1, "hold"), tool_call(2, "hold")])
      worker = receive_holding()

      write(input, [%{"jsonrpc" => "2.0", "id" => "ping-1", "method" => "ping"}])
      assert %{"id" => "ping-1", "result" => %{}} = receive_response()
      refute_received {:holding, _}

      send(worker, :release)
      assert %{"id" => 1} = receive_response()
      send(receive_holding(), :release)
      assert %{"id" => 2} = receive_response()
    end
  end

  defp start_client(opts \\ []), do: opts |> start_pair() |> elem(0)

  defp start_pair(opts \\ []) do
    {:ok, server} =
      Server.start_link(
        [handler: Handler, handler_args: [test_pid: self()], transport: :test] ++ opts
      )

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: :legacy_only,
        health_check_interval: nil
      )

    {client, server}
  end

  defp wait_until(fun), do: Arbor.MCP.TestHelpers.wait_until(fun, timeout: 2_000)

  defp start_stdio(opts) do
    input = start_supervised!({Device, [owner: self()]}, id: make_ref())
    output = start_supervised!({Device, [owner: self()]}, id: make_ref())

    {:ok, root} =
      StdioServer.start_link(
        [
          module: Handler,
          handler_args: [test_pid: self()],
          stdio_input: input,
          stdio_output: output,
          stdio_startup_delay: 0,
          shutdown_timeout_ms: 100
        ] ++ opts
      )

    Process.unlink(root)
    on_exit(fn -> if Process.alive?(root), do: Runtime.stop(root) end)
    {input, root}
  end

  defp tool_call(id, name),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => %{}}
    }

  defp write(device, messages) do
    bytes = Enum.map_join(messages, &(Jason.encode!(&1) <> "\n"))
    :ok = GenServer.call(device, {:input, bytes, false})
  end

  defp receive_holding do
    assert_receive {:holding, worker}, 2_000
    worker
  end

  defp receive_response do
    assert_receive {:written, bytes}, 2_000
    Jason.decode!(String.trim(bytes))
  end
end
