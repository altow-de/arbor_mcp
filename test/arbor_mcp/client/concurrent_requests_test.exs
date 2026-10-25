defmodule Arbor.MCP.Client.ConcurrentRequestsTest do
  @moduledoc """
  One client connection keeps several requests in flight on every transport.
  The caller's own timeout decides how long it waits, and a request it stops
  waiting for is cancelled on the server, as the MCP spec asks.
  """

  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server
  alias Arbor.MCP.Server.Runtime

  defmodule Handler do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    @impl true
    def init(args), do: {:ok, %{test_pid: Keyword.fetch!(args, :test_pid)}}

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-06-18",
         serverInfo: %{name: "concurrent-client", version: "0"},
         capabilities: %{tools: %{}}
       }, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      tools = [
        %{name: "hold", inputSchema: %{type: "object"}},
        %{name: "remember", inputSchema: %{type: "object"}}
      ]

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool("hold", _args, state) do
      send(state.test_pid, {:holding, self()})

      receive do
        :release ->
          {:ok, %{content: [%{type: "text", text: "released"}]}, state}

        {:arbor_mcp_cancelled, _token, reason} ->
          send(state.test_pid, {:server_cancelled, reason})
          {:ok, %{content: []}, state}
      end
    end

    def handle_call_tool("remember", _args, state),
      do: {:ok, %{content: []}, Map.put(state, :remembered, true)}
  end

  describe "modern HTTP" do
    test "requests run at the same time instead of one POST after another" do
      client = start_http_client()

      tasks =
        for _ <- 1..3, do: Task.async(fn -> Client.call_tool(client, "hold", %{}, 5_000) end)

      # All three POSTs reached the server before any of them was answered.
      workers = for _ <- 1..3, do: receive_holding()
      Enum.each(workers, &send(&1, :release))

      assert Enum.all?(Task.await_many(tasks, 5_000), &match?({:ok, _}, &1))
    end

    test "the caller's timeout, not the transport's request timeout, bounds the wait" do
      client = start_http_client(request_timeout: 100)

      task = Task.async(fn -> Client.call_tool(client, "hold", %{}, 5_000) end)
      worker = receive_holding()
      # Genuinely about timing: outlast the transport's 100 ms request timeout.
      Process.sleep(300)
      send(worker, :release)

      assert {:ok, _} = Task.await(task)
    end

    test "a changed handler state is reported to the peer as invalid_handler_state" do
      client = start_http_client()

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, %{data: %{"type" => "invalid_handler_state"}}} =
                 Client.call_tool(client, "remember", %{}, 5_000)
      end)
    end

    test "a request that times out is cancelled on the server" do
      client = start_http_client()

      assert {:error, _timeout} = Client.call_tool(client, "hold", %{}, 200)
      _worker = receive_holding()
      assert_receive {:server_cancelled, _reason}, 3_000
    end
  end

  test "a request that times out over a BEAM connection is cancelled on the server" do
    {:ok, server} =
      Server.start_link(handler: Handler, handler_args: [test_pid: self()], transport: :test)

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: :legacy_only,
        health_check_interval: nil
      )

    assert {:error, _timeout} = Client.call_tool(client, "hold", %{}, 200)
    _worker = receive_holding()
    assert_receive {:server_cancelled, _reason}, 3_000
  end

  defp start_http_client(opts \\ []) do
    port = free_port()
    ranch_ref = {__MODULE__, System.unique_integer([:positive])}

    runtime =
      start_supervised!(
        {Runtime, handler: Handler, handler_args: [test_pid: self()], transport: :mounted_http}
      )

    {:ok, _pid} =
      Plug.Cowboy.http(
        Arbor.MCP.HttpPlug,
        [
          runtime: runtime,
          handler_opts: fn _conn -> %{socket: self()} end,
          path: "/mcp",
          protocol_mode: :modern_only,
          allowed_origins: ["http://127.0.0.1:#{port}"]
        ],
        ip: {127, 0, 0, 1},
        port: port,
        ref: ranch_ref
      )

    on_exit(fn ->
      try do
        Plug.Cowboy.shutdown(ranch_ref)
      catch
        :exit, _reason -> :ok
      end
    end)

    {:ok, client} =
      Client.start_link(
        [
          transport: :http,
          url: "http://127.0.0.1:#{port}/mcp",
          protocol_mode: :modern_only,
          protocol_version: "2026-07-28",
          use_sse: false,
          health_check_interval: nil
        ] ++ opts
      )

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

  defp receive_holding do
    assert_receive {:holding, worker}, 2_000
    worker
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
