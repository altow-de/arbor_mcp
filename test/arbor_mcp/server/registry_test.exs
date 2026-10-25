defmodule Arbor.MCP.Server.RegistryTest do
  @moduledoc """
  Tools, resources and prompts added to a running server are listed, called
  and advertised, and every change notifies clients, like registerTool in the
  TypeScript SDK and AddTool in Go.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.{Client, Server}
  alias Arbor.MCP.Server.Result

  defmodule Plain do
    @moduledoc false
    use Arbor.MCP.Server.Handler
  end

  defmodule WithDSL do
    @moduledoc false
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "registry-dsl", version: "1"

    tool "static" do
      run(fn _args, state -> {:ok, "static", state} end)
    end

    tool "greet" do
      run(fn _args, state -> {:ok, "from the DSL", state} end)
    end
  end

  defmodule Failing do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    @impl true
    def handle_list_tools(_cursor, state), do: {:error, "Catalog unavailable", state}
  end

  @schema %{
    "type" => "object",
    "properties" => %{"name" => %{"type" => "string"}},
    "required" => ["name"]
  }

  defp start(handler, mode \\ :legacy_only) do
    {:ok, server} = Server.start_link(transport: :test, handler: handler)
    {server, connect(server, mode)}
  end

  defp connect(server, mode) do
    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: mode,
        health_check_interval: nil
      )

    client
  end

  defp greet(args), do: Result.text("Hello, #{args["name"]}")

  for mode <- [:legacy_only, :modern_only] do
    test "a plain handler serves and advertises registered tools (#{mode})" do
      {:ok, server} = Server.start_link(transport: :test, handler: Plain)
      assert :ok = Server.add_tool(server, %{name: "greet", inputSchema: @schema}, &greet/1)
      client = connect(server, unquote(mode))

      assert {:ok, %{"tools" => %{"listChanged" => true}}} = Client.server_capabilities(client)
      assert {:ok, %{"tools" => [%{"name" => "greet"}]}} = Client.list_tools(client, format: :map)

      assert {:ok, %{"content" => [%{"text" => "Hello, Ada"}]}} =
               Client.call_tool(client, "greet", %{"name" => "Ada"}, format: :map)

      assert {:error, %{"code" => -32602}} =
               Client.call_tool(client, "greet", %{"name" => 7}, format: :map)
    end
  end

  test "changes notify listening clients" do
    {server, client} = start(Plain)

    {:ok, _listener} =
      Client.subscribe_notifications(client, %{
        "toolsListChanged" => true,
        "promptsListChanged" => true,
        "resourcesListChanged" => true
      })

    assert :ok = Server.add_tool(server, %{name: "greet"}, &greet/1)
    assert_receive {:ex_mcp_notification, _, "notifications/tools/list_changed", _}, 1_000

    assert :ok = Server.add_prompt(server, %{name: "hello"}, fn _args -> "Say hello" end)
    assert_receive {:ex_mcp_notification, _, "notifications/prompts/list_changed", _}, 1_000

    assert :ok = Server.add_resource(server, %{uri: "mem://a", name: "a"}, fn _uri -> "A" end)
    assert_receive {:ex_mcp_notification, _, "notifications/resources/list_changed", _}, 1_000

    assert :ok = Server.remove_tool(server, "greet")
    assert_receive {:ex_mcp_notification, _, "notifications/tools/list_changed", _}, 1_000
    assert {:ok, %{"tools" => []}} = Client.list_tools(client, format: :map)
    assert {:error, :not_found} = Server.remove_tool(server, "greet")
  end

  test "registered tools join DSL tools and take precedence on a name clash" do
    {server, client} = start(WithDSL)
    assert :ok = Server.add_tool(server, %{name: "greet", inputSchema: @schema}, &greet/1)

    assert {:ok, %{"tools" => tools}} = Client.list_tools(client, format: :map)
    assert Enum.map(tools, & &1["name"]) == ["static", "greet"]
    assert [%{"inputSchema" => @schema}] = Enum.filter(tools, &(&1["name"] == "greet"))

    assert {:ok, %{"content" => [%{"text" => "Hello, Ada"}]}} =
             Client.call_tool(client, "greet", %{"name" => "Ada"}, format: :map)

    assert {:ok, %{"content" => [%{"text" => "static"}]}} =
             Client.call_tool(client, "static", %{}, format: :map)
  end

  test "a handler's own list error stands when tools are registered" do
    {server, client} = start(Failing)
    assert :ok = Server.add_tool(server, %{name: "greet"}, &greet/1)

    assert {:error, %{"message" => message}} = Client.list_tools(client, format: :map)
    assert message =~ "Catalog unavailable"
  end

  test "output schemas are enforced" do
    {server, client} = start(Plain)

    output = %{
      "type" => "object",
      "properties" => %{"n" => %{"type" => "integer"}},
      "required" => ["n"]
    }

    assert :ok =
             Server.add_tool(server, %{name: "count", outputSchema: output}, fn args ->
               %{"content" => [], "structuredContent" => %{"n" => args["n"]}}
             end)

    assert {:ok, %{"structuredContent" => %{"n" => 1}}} =
             Client.call_tool(client, "count", %{"n" => 1}, format: :map)

    assert {:error, _invalid_output} =
             Client.call_tool(client, "count", %{"n" => "x"}, format: :map)
  end

  test "resources, templates and prompts are read through their functions" do
    {server, client} = start(Plain)

    assert :ok =
             Server.add_resource(
               server,
               %{uri: "mem://notes", name: "notes", mimeType: "text/plain"},
               fn uri ->
                 "notes at #{uri}"
               end
             )

    assert :ok =
             Server.add_resource_template(
               server,
               %{uriTemplate: "mem://users/{id}", name: "user"},
               fn uri, vars ->
                 {:ok, %{uri: uri, text: "user #{vars["id"]}"}}
               end
             )

    assert :ok =
             Server.add_prompt(server, %{name: "hello", arguments: [%{name: "who"}]}, fn args ->
               "Say hello to #{args["who"]}"
             end)

    assert {:ok, %{"resources" => [%{"uri" => "mem://notes"}]}} =
             Client.list_resources(client, format: :map)

    assert {:ok, %{"resourceTemplates" => [%{"uriTemplate" => "mem://users/{id}"}]}} =
             Client.list_resource_templates(client, format: :map)

    assert {:ok,
            %{"contents" => [%{"text" => "notes at mem://notes", "mimeType" => "text/plain"}]}} =
             Client.read_resource(client, "mem://notes", format: :map)

    assert {:ok, %{"contents" => [%{"text" => "user 42"}]}} =
             Client.read_resource(client, "mem://users/42", format: :map)

    assert {:ok,
            %{"messages" => [%{"role" => "user", "content" => %{"text" => "Say hello to Ada"}}]}} =
             Client.get_prompt(client, "hello", %{"who" => "Ada"}, format: :map)

    assert :ok = Server.remove_resource_template(server, "mem://users/{id}")
    assert {:error, _not_found} = Client.read_resource(client, "mem://users/42", format: :map)
  end

  test "a mounted HTTP runtime serves registered tools" do
    root =
      start_supervised!({Server.Runtime, handler: Plain, transport: :mounted_http})

    assert :ok = Server.add_tool(root, %{name: "greet", inputSchema: @schema}, &greet/1)
    {:ok, runtime} = Server.Runtime.ref(root)
    opts = Arbor.MCP.HttpPlug.init(runtime: runtime, protocol_mode: :modern_only)

    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => "greet",
        "arguments" => %{"name" => "Ada"},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    conn =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(request))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
      |> Plug.Conn.put_req_header("mcp-protocol-version", "2026-07-28")
      |> Plug.Conn.put_req_header("mcp-method", "tools/call")
      |> Plug.Conn.put_req_header("mcp-name", "greet")
      |> Arbor.MCP.HttpPlug.call(opts)

    assert %{"result" => %{"content" => [%{"text" => "Hello, Ada"}]}} =
             Jason.decode!(conn.resp_body)
  end

  test "invalid definitions are refused" do
    {:ok, server} = Server.start_link(transport: :test, handler: Plain)

    assert {:error, {:invalid_definition, :tool}} = Server.add_tool(server, %{}, &greet/1)

    assert {:error, {:invalid_function, :tool}} =
             Server.add_tool(server, %{name: "x"}, fn -> :ok end)

    assert {:error, {:invalid_schema, _reason}} =
             Server.add_tool(server, %{name: "x", inputSchema: %{"type" => 5}}, &greet/1)

    assert {:error, {:invalid_definition, :resource}} =
             Server.add_resource(server, %{uri: "mem://x"}, fn _uri -> "" end)

    assert {:error, {:invalid_function, :resource_template}} =
             Server.add_resource_template(server, %{uriTemplate: "x://{a}", name: "a"}, fn _ ->
               ""
             end)
  end
end
