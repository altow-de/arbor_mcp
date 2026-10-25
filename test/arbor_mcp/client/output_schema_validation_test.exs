defmodule Arbor.MCP.Client.OutputSchemaValidationTest do
  @moduledoc """
  Like the TypeScript and Python SDKs, the client checks a tool's result
  against the `outputSchema` its `tools/list` entry declared.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.{Client, Server}
  alias Arbor.MCP.Error.ValidationError

  defmodule Handler do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    @schema %{
      "type" => "object",
      "properties" => %{"n" => %{"type" => "integer"}},
      "required" => ["n"]
    }

    @impl true
    def handle_list_tools(_cursor, state) do
      tools = [
        %{name: "count", inputSchema: %{type: "object"}, outputSchema: @schema},
        %{name: "plain", inputSchema: %{type: "object"}}
      ]

      {:ok, tools, nil, state}
    end

    # The handler returns whatever the test asks for, valid or not.
    @impl true
    def handle_call_tool(_name, %{"reply" => reply}, state), do: {:ok, reply, state}
  end

  # Lists the tools a test puts in its persistent term, so a listing can change.
  defmodule ChangingHandler do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts), do: {:ok, %{key: Keyword.fetch!(opts, :key)}}

    @impl true
    def handle_list_tools(_cursor, state), do: {:ok, :persistent_term.get(state.key), nil, state}

    @impl true
    def handle_call_tool(_name, %{"reply" => reply}, state), do: {:ok, reply, state}
  end

  setup do
    {:ok, server} = Server.start_link(transport: :test, handler: Handler)

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: :legacy_only,
        health_check_interval: nil
      )

    %{client: client, server: server}
  end

  defp call(client, reply, opts \\ []),
    do: Client.call_tool(client, "count", %{"reply" => reply}, [format: :map] ++ opts)

  @invalid %{"content" => [], "structuredContent" => %{"n" => "x"}}

  test "before tools are listed, results aren't checked", %{client: client} do
    assert {:ok, _} = call(client, @invalid)
  end

  test "once listed, structuredContent must match the outputSchema", %{client: client} do
    assert {:ok, _} = Client.list_tools(client)

    assert {:ok, %{"structuredContent" => %{"n" => 1}}} =
             call(client, %{"content" => [], "structuredContent" => %{"n" => 1}})

    assert {:error, %ValidationError{field: :structured_content, reason: reason}} =
             call(client, @invalid)

    assert reason =~ "doesn't match"

    assert {:error, %ValidationError{reason: missing}} =
             call(client, %{"content" => [%{"type" => "text", "text" => "no data"}]})

    assert missing =~ "no structuredContent"
  end

  test "error results, opted-out calls and tools without a schema aren't checked",
       %{client: client} do
    assert {:ok, _} = Client.list_tools(client)

    assert {:ok, %{"isError" => true}} =
             call(client, %{
               "content" => [%{"type" => "text", "text" => "failed"}],
               "isError" => true
             })

    assert {:ok, _} = call(client, @invalid, validate_output: false)

    assert {:ok, _} =
             Client.call_tool(client, "plain", %{"reply" => @invalid}, format: :map)
  end

  # Legacy revisions require an object; 2026-07-28 allows any value.
  test "a present null structuredContent is checked against the schema", %{server: server} do
    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: :modern_only,
        health_check_interval: nil
      )

    assert {:ok, _} = Client.list_tools(client)

    assert {:error, %ValidationError{reason: reason}} =
             call(client, %{"content" => [], "structuredContent" => nil})

    assert reason =~ "doesn't match"
  end

  test "a fresh listing replaces the schemas an earlier one recorded" do
    key = {__MODULE__, make_ref()}
    schema = %{"type" => "object", "properties" => %{"n" => %{"type" => "integer"}}}

    :persistent_term.put(key, [
      %{name: "count", inputSchema: %{type: "object"}, outputSchema: schema}
    ])

    on_exit(fn -> :persistent_term.erase(key) end)

    {:ok, server} =
      Server.start_link(transport: :test, handler: ChangingHandler, handler_args: [key: key])

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: :legacy_only,
        health_check_interval: nil
      )

    assert {:ok, _} = Client.list_tools(client)
    assert {:error, %ValidationError{}} = call(client, @invalid)

    # The tool no longer declares an outputSchema.
    :persistent_term.put(key, [%{name: "count", inputSchema: %{type: "object"}}])
    assert {:ok, _} = Client.list_tools(client)
    assert {:ok, _} = call(client, @invalid)
  end

  test "a tools list change forgets the schemas until tools are listed again",
       %{client: client, server: server} do
    assert {:ok, _} = Client.list_tools(client)
    :ok = Server.notify_tools_changed(server)
    # The notification is delivered before the answer to a later ping.
    assert {:ok, _} = Client.ping(client)

    assert {:ok, _} = call(client, @invalid)
  end
end
