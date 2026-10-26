defmodule Arbor.MCP.Server.MRTRElicitationValidationTest do
  @moduledoc """
  An elicitation a handler asks for in an `input_required` result is held to
  the protocol's ElicitRequest schema in both eras. The legacy bridge always
  checked it; a modern client used to get whatever the handler returned.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.HandlerServer

  @key :binary.copy(<<7>>, 32)

  defmodule ServerHandler do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    alias Arbor.MCP.Server.Context

    @impl true
    def handle_list_tools(_cursor, state) do
      tools = for name <- ["valid", "invalid"], do: %{name: name, inputSchema: %{type: "object"}}
      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool(name, _arguments, state) do
      case Context.input_responses() do
        nil ->
          {:input_required, %{"answer" => elicitation(name)}, state}

        %{"answer" => %{"content" => %{"name" => answer}}} ->
          {:ok, %{content: [%{type: "text", text: answer}]}, state}
      end
    end

    defp elicitation("valid") do
      %{
        "method" => "elicitation/create",
        "params" => %{
          "message" => "Name?",
          "requestedSchema" => %{
            "type" => "object",
            "properties" => %{"name" => %{"type" => "string"}}
          }
        }
      }
    end

    # A requested schema must be a flat object of primitive fields.
    defp elicitation("invalid") do
      %{
        "method" => "elicitation/create",
        "params" => %{"message" => "Name?", "requestedSchema" => %{"type" => "array"}}
      }
    end
  end

  defmodule ClientHandler do
    @moduledoc false
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(_opts), do: {:ok, %{}}
    @impl true
    def handle_ping(state), do: {:ok, %{}, state}
    @impl true
    def handle_list_roots(state), do: {:ok, [], state}
    @impl true
    def handle_create_message(_params, state), do: {:error, "unused", state}

    @impl true
    def handle_elicitation_create(_message, _schema, state),
      do: {:ok, %{"action" => "accept", "content" => %{"name" => "Ada"}}, state}
  end

  setup do
    {:ok, server} =
      HandlerServer.start_link(
        handler: ServerHandler,
        transport: :test,
        protocol_mode: :modern_only,
        mrtr: true,
        request_state: [active_key_id: "k", keys: %{"k" => @key}]
      )

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: :modern_only,
        capabilities: %{"elicitation" => %{"form" => %{}}},
        handler: {ClientHandler, []},
        health_check_interval: nil
      )

    %{client: client}
  end

  test "a valid elicitation goes to the client", %{client: client} do
    assert {:ok, %{"content" => [%{"text" => "Ada"}]}} =
             Client.call_tool(client, "valid", %{}, format: :map)
  end

  test "an invalid one is refused before it reaches the client", %{client: client} do
    assert {:error, %{"code" => -32602, "data" => %{"inputRequestId" => "answer"}}} =
             Client.call_tool(client, "invalid", %{}, format: :map)
  end
end
