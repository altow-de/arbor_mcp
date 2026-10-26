defmodule Arbor.MCP.Server.LogLevelScopeTest do
  @moduledoc """
  A client's `logging/setLevel` sets the minimum level of the
  `notifications/message` its own connection receives. The default handler
  used to call `Logger.configure/1`, so any connected client could change the
  host application's global log level.
  """

  use ExUnit.Case, async: false

  alias Arbor.MCP.Server
  alias Arbor.MCP.Transport.Test

  defmodule Handler do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-06-18",
         serverInfo: %{name: "log-level", version: "0"},
         capabilities: %{tools: %{}, logging: %{}}
       }, state}
    end

    @impl true
    def handle_list_tools(_cursor, state),
      do: {:ok, [%{name: "log", inputSchema: %{type: "object"}}], nil, state}

    @impl true
    def handle_call_tool("log", _args, state) do
      :ok = Server.send_log_message(self(), "info", "routine", %{})
      :ok = Server.send_log_message(self(), "error", "serious", %{})
      {:ok, %{content: [%{type: "text", text: "logged"}]}, state}
    end
  end

  setup do
    {:ok, server} = Server.start_link(handler: Handler, transport: :test)
    {:ok, transport} = Test.connect(server: server)

    {_messages, transport} =
      request(transport, 1, "initialize", %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test", "version" => "0"}
      })

    {:ok, transport} =
      Test.send_message(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, transport)

    %{transport: transport}
  end

  test "before any setLevel, every log message is sent", %{transport: transport} do
    {messages, _transport} = request(transport, 2, "tools/call", %{"name" => "log"})
    assert log_levels(messages) == ["info", "error"]
  end

  test "setLevel filters the log messages this connection receives", %{transport: transport} do
    {_messages, transport} = request(transport, 2, "logging/setLevel", %{"level" => "warning"})
    {messages, _transport} = request(transport, 3, "tools/call", %{"name" => "log"})
    assert log_levels(messages) == ["error"]
  end

  test "setLevel leaves the host's Logger level alone", %{transport: transport} do
    level = Logger.level()

    {[response | _], _transport} =
      request(transport, 2, "logging/setLevel", %{"level" => "emergency"})

    assert %{"id" => 2, "result" => %{}} = response
    assert Logger.level() == level
  end

  # Sends a request and collects every message up to and including its
  # response, which is returned first.
  defp request(transport, id, method, params) do
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    {:ok, transport} = Test.send_message(message, transport)
    collect(transport, id, [])
  end

  defp collect(transport, id, notifications) do
    {:ok, wire, transport} = Test.receive_message(transport, 2_000)
    message = if is_binary(wire), do: Jason.decode!(wire), else: wire

    case message do
      %{"id" => ^id} -> {[message | Enum.reverse(notifications)], transport}
      _notification -> collect(transport, id, [message | notifications])
    end
  end

  defp log_levels(messages) do
    for %{"method" => "notifications/message", "params" => %{"level" => level}} <- messages,
        do: level
  end
end
