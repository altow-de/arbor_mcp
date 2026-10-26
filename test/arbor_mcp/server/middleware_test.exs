defmodule Arbor.MCP.Server.MiddlewareTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.Context

  defmodule Handler do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_opts), do: {:ok, %{count: 0}}

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         "protocolVersion" => "2025-11-25",
         "serverInfo" => %{"name" => "middleware", "version" => "1"},
         "capabilities" => %{"tools" => %{}}
       }, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      tools = for name <- ["echo", "secret", "count"], do: %{name: name, inputSchema: %{}}
      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool("count", _args, state) do
      count = state.count + 1

      {:ok, %{"content" => [], "structuredContent" => %{"count" => count}},
       %{state | count: count}}
    end

    def handle_call_tool(_name, args, state),
      do: {:ok, %{"content" => [], "structuredContent" => args}, state}
  end

  defmodule Recorder do
    @moduledoc false
    @behaviour Arbor.MCP.Server.Middleware

    @impl true
    def call(request, next, opts) do
      send(opts[:pid], {:before, opts[:name], request.method, request.id, Context.request_id()})
      result = next.(request)
      send(opts[:pid], {:after, opts[:name], request.method, result})
      result
    end
  end

  defmodule Policy do
    @moduledoc false
    @behaviour Arbor.MCP.Server.Middleware

    @impl true
    def call(%{method: "tools/call", params: %{"name" => "secret"}}, _next, _opts),
      do: {:error, %{"code" => -32001, "message" => "Forbidden"}}

    def call(%{method: "tools/call", params: %{"name" => "echo"} = params} = request, next, _opts) do
      case params["arguments"] do
        %{"invalid" => true} -> next.(%{request | params: Map.put(params, "name", 42)})
        arguments -> next.(put_in(request.params["arguments"], Map.put(arguments, "seen", true)))
      end
    end

    def call(%{method: "tools/list"} = request, next, _opts) do
      with {:ok, result} <- next.(request) do
        {:ok,
         Map.update!(result, "tools", &Enum.reject(&1, fn tool -> tool["name"] == "secret" end))}
      end
    end

    def call(request, next, _opts), do: next.(request)
  end

  defmodule Broken do
    @moduledoc false
    @behaviour Arbor.MCP.Server.Middleware

    @impl true
    def call(%{method: "tools/call"}, _next, _opts), do: :oops
    def call(request, next, _opts), do: next.(request)
  end

  defp start(middleware, opts \\ []) do
    {mode, opts} = Keyword.pop(opts, :protocol_mode, :legacy_only)

    {:ok, server} =
      Arbor.MCP.Server.start_link(
        [transport: :test, handler: Handler, middleware: middleware] ++ opts
      )

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: mode,
        health_check_interval: nil
      )

    client
  end

  test "middleware wraps every dispatched message, outermost first, inside the request context" do
    pid = self()
    client = start([{Recorder, pid: pid, name: :outer}, {Recorder, pid: pid, name: :inner}])

    assert_receive {:before, :outer, "initialize", id, id} when not is_nil(id)
    assert_receive {:before, :inner, "initialize", ^id, ^id}
    assert_receive {:after, :inner, "initialize", {:ok, %{"protocolVersion" => _}}}
    assert_receive {:after, :outer, "initialize", {:ok, _}}

    assert_receive {:before, :outer, "notifications/initialized", nil, nil}
    assert_receive {:after, :outer, "notifications/initialized", :noreply}

    assert {:ok, _} = Client.call_tool(client, "echo", %{"a" => 1}, format: :map)
    assert_receive {:before, :outer, "tools/call", id, id} when not is_nil(id)
    assert_receive {:after, :outer, "tools/call", {:ok, %{"structuredContent" => %{"a" => 1}}}}

    assert {:ok, _} = Client.ping(client)
    assert_receive {:before, :outer, "ping", _id, _context_id}
  end

  for mode <- [:legacy_only, :modern_only] do
    test "middleware refuses, rewrites and changes results (#{mode})" do
      client = start([Policy], protocol_mode: unquote(mode))

      assert {:ok, %{"tools" => tools}} = Client.list_tools(client, format: :map)
      assert tools |> Enum.map(& &1["name"]) |> Enum.sort() == ["count", "echo"]

      assert {:error, %{"code" => -32001, "message" => "Forbidden"}} =
               Client.call_tool(client, "secret", %{}, format: :map)

      assert {:ok, %{"structuredContent" => %{"a" => 1, "seen" => true}}} =
               Client.call_tool(client, "echo", %{"a" => 1}, format: :map)

      assert {:error, %{"code" => -32602}} =
               Client.call_tool(client, "echo", %{"invalid" => true}, format: :map)
    end
  end

  test "the handler state is threaded through the chain" do
    client = start([{Recorder, pid: self(), name: :only}], execution: :stateful)

    for expected <- 1..3 do
      assert {:ok, %{"structuredContent" => %{"count" => ^expected}}} =
               Client.call_tool(client, "count", %{}, format: :map)
    end
  end

  test "an invalid middleware result becomes an internal error" do
    client = start([Broken])

    assert {:error, %{"code" => -32603, "data" => %{"type" => "invalid_middleware_result"}}} =
             Client.call_tool(client, "echo", %{}, format: :map)
  end

  test "an invalid middleware list fails at start" do
    Process.flag(:trap_exit, true)

    assert {:error, _reason} =
             Arbor.MCP.Server.start_link(transport: :test, handler: Handler, middleware: [String])
  end
end
