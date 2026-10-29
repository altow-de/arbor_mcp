defmodule Arbor.MCP.Server.HandleGetToolTest do
  @moduledoc """
  A modern `tools/call` over Streamable HTTP is checked against the tool's
  `x-mcp-header` annotations. A handler that defines `handle_get_tool/2`
  supplies that one definition, so the check doesn't walk `tools/list`; `nil`
  falls back to the walk, and errors and timeouts fail closed as the walk's
  do (#184).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Arbor.MCP.HttpPlug
  alias Arbor.MCP.MessageProcessor
  alias Arbor.MCP.Server.Context
  alias Arbor.MCP.Test.RuntimeHTTPFixture
  alias Arbor.MCP.Transport.HTTP.RequestHeaders

  @routed %{
    "name" => "routed",
    "inputSchema" => %{
      "type" => "object",
      "properties" => %{"region" => %{"type" => "string", "x-mcp-header" => "Region"}}
    }
  }

  @filler %{"name" => "filler", "inputSchema" => %{"type" => "object"}}

  # Its tools/list has two pages, the routed tool on the second; `:list`
  # makes it fail instead. Every callback reports itself to the test.
  defmodule WalkHandler do
    use Arbor.MCP.Server.Handler

    alias Arbor.MCP.Server.HandleGetToolTest, as: Fixture

    @impl true
    def init(args), do: {:ok, Map.new(args)}

    @impl true
    def handle_list_tools(cursor, state) do
      send(state.test_pid, {:listed, cursor, Fixture.method()})
      Fixture.page(cursor, state)
    end

    @impl true
    def handle_call_tool(name, arguments, state) do
      send(state.test_pid, {:called, name, arguments})
      {:ok, %{"content" => [%{"type" => "text", "text" => "ran #{name}"}]}, state}
    end
  end

  # The same list, plus handle_get_tool/2 answering as `:lookup` says.
  defmodule LookupHandler do
    use Arbor.MCP.Server.Handler

    alias Arbor.MCP.Server.HandleGetToolTest, as: Fixture

    @impl true
    def init(args), do: {:ok, Map.new(args)}

    @impl true
    def handle_list_tools(cursor, state) do
      send(state.test_pid, {:listed, cursor, Fixture.method()})
      Fixture.page(cursor, state)
    end

    @impl true
    def handle_get_tool(name, state) do
      send(state.test_pid, {:got_tool, name, Fixture.method()})
      Fixture.lookup(name, state)
    end

    @impl true
    def handle_call_tool(name, arguments, state) do
      send(state.test_pid, {:called, name, arguments})
      {:ok, %{"content" => [%{"type" => "text", "text" => "ran #{name}"}]}, state}
    end
  end

  # A DSL server paged one tool at a time, the routed tool last.
  defmodule DSLServer do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "get-tool-dsl", version: "1.0.0", page_size: 1

    tool "first", "First filler" do
      run(fn _args, state -> {:ok, "first", state} end)
    end

    tool "second", "Second filler" do
      run(fn _args, state -> {:ok, "second", state} end)
    end

    tool "routed", "Routed by region" do
      input_schema(%{
        type: "object",
        properties: %{region: %{type: "string", "x-mcp-header": "Region"}}
      })

      run(fn args, state -> {:ok, "routed #{inspect(args)}", state} end)
    end
  end

  # The same DSL tools, with the module's own handle_get_tool/2.
  defmodule DSLOwnLookupServer do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "get-tool-dsl-own", version: "1.0.0", page_size: 1

    tool "first", "First filler" do
      run(fn _args, state -> {:ok, "first", state} end)
    end

    tool "routed", "Routed by region" do
      input_schema(%{
        type: "object",
        properties: %{region: %{type: "string", "x-mcp-header": "Region"}}
      })

      run(fn args, state -> {:ok, "routed #{inspect(args)}", state} end)
    end

    @impl true
    def handle_get_tool(_name, state), do: {:ok, nil, state}
  end

  defmodule DSLWithoutTools do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "get-tool-dsl-empty", version: "1.0.0"

    prompt "hello", "Says hello" do
      render(fn _args, state -> {:ok, %{messages: []}, state} end)
    end
  end

  @doc false
  def method do
    case Context.current() do
      %{method: method} -> method
      nil -> nil
    end
  end

  @doc false
  def page(cursor, state) do
    pause(state, :page_ms)

    case {Map.get(state, :list, :paged), cursor} do
      {:paged, nil} -> {:ok, [@filler], "p2", state}
      {:paged, "p2"} -> {:ok, [@routed], nil, state}
      {:endless, _cursor} -> {:ok, [@filler], "more", state}
      {:error, _cursor} -> {:error, :upstream_down, state}
      {:raise, _cursor} -> raise "upstream listing failed"
      {:block, _cursor} -> block()
    end
  end

  @doc false
  def lookup(name, state) do
    pause(state, :lookup_ms)

    case state.lookup do
      :found -> {:ok, Map.get(%{"routed" => @routed}, name), state}
      :atom_keys -> {:ok, atom_keyed(), state}
      :short_found -> {:ok, @routed}
      :short_nil -> {:ok, nil}
      nil -> {:ok, nil, state}
      :other_name -> {:ok, Map.put(@routed, "name", "other"), state}
      :error -> {:error, :upstream_down, state}
      :invalid -> :bogus
      :raise -> raise "upstream lookup failed"
      :block -> block()
    end
  end

  # A handler that is slow on purpose: what is measured is the time.
  defp pause(state, key) do
    case Map.get(state, key, 0) do
      0 -> :ok
      ms -> Process.sleep(ms)
    end
  end

  # Never returns: the server's deadline has to end the request.
  defp block do
    receive do
      :never_sent -> :ok
    end
  end

  defp atom_keyed do
    %{
      name: "routed",
      inputSchema: %{
        type: "object",
        properties: %{region: %{type: "string", "x-mcp-header": "Region"}}
      }
    }
  end

  defp listed do
    receive do
      {:listed, cursor, method} -> [{cursor, method} | listed()]
    after
      0 -> []
    end
  end

  describe "on a Runtime (every HttpPlug mount)" do
    test "handle_get_tool/2 supplies the definition and tools/list is never called" do
      response = post(LookupHandler, [lookup: :found], [{"mcp-param-region", "eu"}])

      assert response.status == 200, inspect(response.body)
      assert response.body["result"]["content"] == [%{"type" => "text", "text" => "ran routed"}]
      assert_received {:got_tool, "routed", "tools/call"}
      assert_received {:called, "routed", %{"region" => "eu"}}
      assert listed() == []
    end

    test "a header mismatch is still rejected through handle_get_tool/2" do
      for headers <- [[{"mcp-param-region", "us"}], []] do
        response = post(LookupHandler, [lookup: :found], headers)

        assert response.status == 400
        assert response.body["error"]["code"] == -32020
        assert_received {:got_tool, "routed", "tools/call"}
      end

      refute_received {:called, _name, _arguments}
      assert listed() == []
    end

    test "an atom-keyed definition is checked like a string-keyed one" do
      assert %{status: 400} =
               post(LookupHandler, [lookup: :atom_keys], [{"mcp-param-region", "us"}])

      assert %{status: 200} =
               post(LookupHandler, [lookup: :atom_keys], [{"mcp-param-region", "eu"}])

      assert listed() == []
    end

    test "a reply without the state is accepted, as for other callbacks" do
      assert %{status: 400} =
               post(LookupHandler, [lookup: :short_found], [{"mcp-param-region", "us"}])

      assert listed() == []

      assert %{status: 400} =
               post(LookupHandler, [lookup: :short_nil], [{"mcp-param-region", "us"}])

      assert listed() == [{nil, "tools/call"}, {"p2", "tools/call"}]
    end

    test "nil falls back to the tools/list walk, which still checks the headers" do
      mismatched = post(LookupHandler, [lookup: nil], [{"mcp-param-region", "us"}])

      assert mismatched.status == 400
      assert mismatched.body["error"]["code"] == -32020
      assert_received {:got_tool, "routed", "tools/call"}
      assert listed() == [{nil, "tools/call"}, {"p2", "tools/call"}]
      refute_received {:called, _name, _arguments}

      matching = post(LookupHandler, [lookup: nil], [{"mcp-param-region", "eu"}])

      assert matching.status == 200, inspect(matching.body)
      assert listed() == [{nil, "tools/call"}, {"p2", "tools/call"}]
      assert_received {:called, "routed", %{"region" => "eu"}}
    end

    test "a handler without handle_get_tool/2 walks tools/list as before" do
      refute function_exported?(WalkHandler, :handle_get_tool, 2)

      mismatched = post(WalkHandler, [], [{"mcp-param-region", "us"}])
      assert mismatched.status == 400
      assert mismatched.body["error"]["code"] == -32020
      assert listed() == [{nil, "tools/call"}, {"p2", "tools/call"}]

      assert %{status: 200} = post(WalkHandler, [], [{"mcp-param-region", "eu"}])
      assert listed() == [{nil, "tools/call"}, {"p2", "tools/call"}]
      refute_received {:got_tool, _name, _method}
    end

    test "an error, an invalid reply or another tool's definition fails closed, as a failed page does" do
      walk_error = post(WalkHandler, [list: :error], [{"mcp-param-region", "eu"}])

      assert walk_error.status == 400
      assert walk_error.body["error"]["code"] == -32020
      assert walk_error.body["error"]["message"] == "Tool schema unavailable"

      for lookup <- [:error, :invalid, :other_name] do
        response = post(LookupHandler, [lookup: lookup], [{"mcp-param-region", "eu"}])

        assert {lookup, response.status, response.body} ==
                 {lookup, walk_error.status, walk_error.body}
      end

      refute_received {:called, _name, _arguments}
      assert listed() == [{nil, "tools/call"}]
    end

    test "a raise in handle_get_tool/2 answers as a raise in the walk does" do
      {{walk, lookup}, _log} =
        with_log(fn ->
          {post(WalkHandler, [list: :raise], [{"mcp-param-region", "eu"}]),
           post(LookupHandler, [lookup: :raise], [{"mcp-param-region", "eu"}])}
        end)

      assert walk.body["error"]
      assert {lookup.status, lookup.body} == {walk.status, walk.body}
      refute_received {:called, _name, _arguments}
    end

    test "a handle_get_tool/2 that never answers ends at the request deadline, as the walk does" do
      timeout = [request_timeout_ms: 300]

      walk = post(WalkHandler, [list: :block], [{"mcp-param-region", "eu"}], timeout)
      lookup = post(LookupHandler, [lookup: :block], [{"mcp-param-region", "eu"}], timeout)

      assert walk.body["error"]["data"]["type"] == "handler_timeout"
      assert {lookup.status, lookup.body} == {walk.status, walk.body}
      refute_received {:called, _name, _arguments}
    end
  end

  describe "through a MessageProcessor handler process" do
    test "handle_get_tool/2 supplies the definition and tools/list is never called" do
      conn = process(LookupHandler, [lookup: :found], [{"mcp-param-region", "eu"}])

      assert conn.response["result"], inspect(conn.response)
      assert_received {:got_tool, "routed", "tools/call"}
      assert_received {:called, "routed", %{"region" => "eu"}}
      assert listed() == []
    end

    test "a header mismatch is still rejected through handle_get_tool/2" do
      conn = process(LookupHandler, [lookup: :found], [{"mcp-param-region", "us"}])

      assert conn.response["error"]["code"] == -32020
      assert conn.assigns.http_status == 400
      refute_received {:called, _name, _arguments}
      assert listed() == []
    end

    test "a reply without the state is accepted, as on a Runtime" do
      conn = process(LookupHandler, [lookup: :short_found], [{"mcp-param-region", "us"}])
      assert conn.response["error"]["code"] == -32020
      assert listed() == []

      conn = process(LookupHandler, [lookup: :short_nil], [{"mcp-param-region", "us"}])
      assert conn.response["error"]["code"] == -32020
      assert [{nil, _method}, {"p2", _method2}] = listed()
    end

    test "nil falls back to the tools/list walk" do
      conn = process(LookupHandler, [lookup: nil], [{"mcp-param-region", "us"}])

      assert conn.response["error"]["code"] == -32020
      assert_received {:got_tool, "routed", "tools/call"}
      assert [{nil, _method}, {"p2", _method2}] = listed()
    end

    test "an error, an invalid reply or another tool's definition fails closed, as a failed page does" do
      walk = process(WalkHandler, [list: :error], [{"mcp-param-region", "eu"}])
      assert walk.response["error"]["data"]["type"] == "tool_schema_unavailable"

      {responses, _log} =
        with_log(fn ->
          for lookup <- [:error, :invalid, :other_name, :raise] do
            conn = process(LookupHandler, [lookup: lookup], [{"mcp-param-region", "eu"}])
            {lookup, conn.response}
          end
        end)

      for {lookup, response} <- responses,
          do: assert({lookup, response} == {lookup, walk.response})

      refute_received {:called, _name, _arguments}
    end

    @tag timeout: 10_000
    test "a handle_get_tool/2 past the handler_call_timeout fails closed without a walk" do
      started = System.monotonic_time(:millisecond)
      conn = process(LookupHandler, [lookup: :block], [{"mcp-param-region", "eu"}], 300)

      assert conn.response["error"]["data"]["type"] == "tool_schema_unavailable"
      assert System.monotonic_time(:millisecond) - started < 5_000
      assert listed() == []
    end

    test "the lookup and the walk after a nil share one handler_call_timeout" do
      # The lookup takes 200 of the 300 ms. A 200 ms page then has 100 ms
      # left, so at most the first page is asked for; a walk with a
      # timeout of its own would reach the second.
      handler_opts = [lookup: nil, lookup_ms: 200, list: :endless, page_ms: 200]
      conn = process(LookupHandler, handler_opts, [{"mcp-param-region", "eu"}], 300)

      assert conn.response["error"]["data"]["type"] == "tool_schema_unavailable"
      assert length(listed()) <= 1
    end
  end

  describe "DSL servers" do
    setup do
      :erlang.trace_pattern({DSLServer, :handle_list_tools, 2}, true, [:call_count])
      :erlang.trace_pattern({DSLOwnLookupServer, :handle_list_tools, 2}, true, [:call_count])

      on_exit(fn ->
        :erlang.trace_pattern({DSLServer, :handle_list_tools, 2}, false, [:call_count])
        :erlang.trace_pattern({DSLOwnLookupServer, :handle_list_tools, 2}, false, [:call_count])
      end)
    end

    test "get handle_get_tool/2 for their declared tools" do
      assert {:ok, %{name: "routed", inputSchema: schema}, :state} =
               DSLServer.handle_get_tool("routed", :state)

      assert schema.properties.region[:"x-mcp-header"] == "Region"
      assert {:ok, %{name: "first"}, :state} = DSLServer.handle_get_tool("first", :state)
      assert {:ok, nil, :state} = DSLServer.handle_get_tool("unknown", :state)
      refute function_exported?(DSLWithoutTools, :handle_get_tool, 2)
    end

    test "check the headers without paging through tools/list" do
      mismatched = post(DSLServer, [], [{"mcp-param-region", "us"}])
      assert mismatched.status == 400
      assert mismatched.body["error"]["code"] == -32020

      matching = post(DSLServer, [], [{"mcp-param-region", "eu"}])
      assert matching.status == 200, inspect(matching.body)

      assert :erlang.trace_info({DSLServer, :handle_list_tools, 2}, :call_count) ==
               {:call_count, 0}
    end

    test "keep a handle_get_tool/2 the module defines" do
      assert {:ok, nil, :state} = DSLOwnLookupServer.handle_get_tool("routed", :state)

      mismatched = post(DSLOwnLookupServer, [], [{"mcp-param-region", "us"}])
      assert mismatched.status == 400
      assert mismatched.body["error"]["code"] == -32020

      # Its nil walks both pages.
      assert :erlang.trace_info({DSLOwnLookupServer, :handle_list_tools, 2}, :call_count) ==
               {:call_count, 2}
    end
  end

  # A modern tools/call for "routed" with region "eu", through a fresh
  # Runtime-mounted HttpPlug.
  defp post(handler, handler_args, headers, runtime_opts \\ []) do
    runtime =
      RuntimeHTTPFixture.start(
        handler,
        Keyword.merge(
          [handler_args: [test_pid: self()] ++ handler_args, request_timeout_ms: 10_000],
          runtime_opts
        )
      )

    request = tools_call()

    conn =
      Enum.reduce(headers, conn(:post, "/", Jason.encode!(request)), fn {name, value}, conn ->
        put_req_header(conn, name, value)
      end)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> put_req_header("mcp-method", "tools/call")
      |> put_req_header("mcp-name", RequestHeaders.encode_value("routed"))
      |> HttpPlug.call(HttpPlug.init(runtime: runtime, sse_mode: :oneshot))

    %{status: conn.status, body: Jason.decode!(conn.resp_body)}
  end

  defp process(handler, handler_opts, headers, timeout \\ 10_000) do
    tools_call()
    |> MessageProcessor.new(transport: :http)
    |> MessageProcessor.process(%{
      handler: handler,
      handler_opts: [test_pid: self()] ++ handler_opts,
      handler_call_timeout: timeout,
      protocol_mode: :modern_only,
      request_headers: headers,
      endpoint: "/mcp"
    })
  end

  defp tools_call do
    %{
      "jsonrpc" => "2.0",
      "id" => 184,
      "method" => "tools/call",
      "params" => %{
        "name" => "routed",
        "arguments" => %{"region" => "eu"},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }
  end
end
