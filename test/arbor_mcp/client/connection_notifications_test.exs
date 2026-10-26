defmodule Arbor.MCP.Client.ConnectionNotificationsTest do
  @moduledoc """
  Progress and log notifications reach the client's handler on every
  transport, not only on modern HTTP request streams.
  """

  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server

  defmodule ServerHandler do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts), do: {:ok, %{test_pid: Keyword.get(opts, :test_pid)}}

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-06-18",
         serverInfo: %{name: "notifications", version: "0"},
         capabilities: %{tools: %{}, logging: %{}}
       }, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      tools = [
        %{name: "work", inputSchema: %{type: "object"}},
        %{name: "log", inputSchema: %{type: "object"}}
      ]

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool("work", args, state) do
      token = get_in(args, ["_meta", "progressToken"])
      :ok = Server.notify_progress(self(), token, 1, 2)
      {:ok, %{content: [%{type: "text", text: "done"}]}, state}
    end

    def handle_call_tool("wait", _args, state) do
      send(state.test_pid, {:tool_waiting, self()})
      receive do: (:release -> :ok)
      {:ok, %{content: [%{type: "text", text: "released"}]}, state}
    end

    def handle_call_tool("log", _args, state) do
      :ok = Server.send_log_message(self(), "info", "routine", %{})
      :ok = Server.send_log_message(self(), "error", "serious", %{})
      {:ok, %{content: [%{type: "text", text: "logged"}]}, state}
    end
  end

  defmodule ClientHandler do
    @moduledoc false
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, Keyword.fetch!(opts, :test_pid)}

    @impl true
    def handle_progress(request_id, params, test_pid) do
      send(test_pid, {:client_progress, request_id, params})
      {:ok, test_pid}
    end

    @impl true
    def handle_log_message(request_id, params, test_pid) do
      send(test_pid, {:client_log, request_id, params})
      {:ok, test_pid}
    end

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(_params, state), do: {:error, "not supported", state}
  end

  setup do
    {:ok, server} =
      Server.start_link(
        handler: ServerHandler,
        handler_args: [test_pid: self()],
        transport: :test
      )

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: :legacy_only,
        health_check_interval: nil,
        handler: {ClientHandler, [test_pid: self()]}
      )

    %{client: client}
  end

  test "progress reaches the handler with the id of the request it reports on", %{
    client: client
  } do
    assert {:ok, _} = Client.call_tool(client, "work", %{}, progress_token: "job-1")

    assert_received {:client_progress, request_id,
                     %{"progressToken" => "job-1", "progress" => 1, "total" => 2}}

    refute is_nil(request_id)
  end

  test "a progress token a pending request carries is refused", %{client: client} do
    first = Task.async(fn -> Client.call_tool(client, "wait", %{}, progress_token: "shared") end)
    assert_receive {:tool_waiting, worker}, 1_000

    # Progress names its request only by token, so sharing it would misroute.
    assert {:error,
            %Arbor.MCP.Error.TransportError{
              reason: :not_sent,
              details: %{cause: :duplicate_progress_token}
            }} = Client.call_tool(client, "work", %{}, progress_token: "shared")

    send(worker, :release)
    assert {:ok, _} = Task.await(first)

    # Free again once the first request settled.
    assert {:ok, _} = Client.call_tool(client, "work", %{}, progress_token: "shared")
  end

  test "connection-level log messages reach the handler without a request id", %{
    client: client
  } do
    assert {:ok, _} = Client.call_tool(client, "log", %{})
    assert_received {:client_log, nil, %{"level" => "info"}}
    assert_received {:client_log, nil, %{"level" => "error"}}
  end
end
