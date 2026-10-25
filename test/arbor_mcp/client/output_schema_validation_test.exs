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

  test "a tools list change forgets the schemas until tools are listed again",
       %{client: client, server: server} do
    assert {:ok, _} = Client.list_tools(client)
    :ok = Server.notify_tools_changed(server)
    # The notification is delivered before the answer to a later ping.
    assert {:ok, _} = Client.ping(client)

    assert {:ok, _} = call(client, @invalid)
  end
end
