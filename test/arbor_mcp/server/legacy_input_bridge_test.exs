defmodule Arbor.MCP.Server.LegacyInputBridgeTest do
  @moduledoc """
  A handler that asks for input with an MRTR `input_required` result serves
  both eras: a modern client gets the result and retries, and a legacy
  client gets each input request as the server-to-client request it stands
  for, as the TypeScript, Go and C# SDKs do.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.{Context, HandlerServer}

  @key :binary.copy(<<64>>, 32)

  defmodule ServerHandler do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    @name_schema %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}

    @impl true
    def handle_list_tools(_cursor, state) do
      tools =
        for name <- ["onboard", "summarize", "forever", "mutate"],
            do: %{name: name, inputSchema: %{type: "object", properties: %{}}}

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool("onboard", _arguments, state) do
      case Context.input_responses() do
        nil ->
          requests = %{
            "name" => %{
              "method" => "elicitation/create",
              "params" => %{
                "message" => "What should we call you?",
                "requestedSchema" => @name_schema
              }
            }
          }

          {:input_required, requests, %{"prefix" => "Welcome"}, state}

        %{"name" => %{"content" => %{"name" => name}}} ->
          text = "#{Context.request_state()["prefix"]}, #{name}"
          {:ok, %{content: [%{type: "text", text: text}]}, state}
      end
    end

    def handle_call_tool("summarize", _arguments, state) do
      case Context.input_responses() do
        nil ->
          sample = %{
            "method" => "sampling/createMessage",
            "params" => %{
              "messages" => [
                %{"role" => "user", "content" => %{"type" => "text", "text" => "Summarize"}}
              ],
              "maxTokens" => 10
            }
          }

          {:input_required, %{"summary" => sample}, state}

        %{"summary" => %{"content" => %{"text" => text}}} ->
          {:ok, %{content: [%{type: "text", text: text}]}, state}
      end
    end

    # A stateless handler may not change its state, even between rounds.
    def handle_call_tool("mutate", _arguments, state) do
      request = %{
        "method" => "elicitation/create",
        "params" => %{"message" => "Name?", "requestedSchema" => @name_schema}
      }

      {:input_required, %{"name" => request}, Map.put(state, :changed, true)}
    end

    # Never satisfied: asks again every round.
    def handle_call_tool("forever", _arguments, state) do
      request = %{
        "method" => "elicitation/create",
        "params" => %{"message" => "Again?", "requestedSchema" => @name_schema}
      }

      {:input_required, %{"again" => request}, state}
    end
  end

  defmodule ClientHandler do
    @moduledoc false
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(_params, state) do
      send(state.owner, :sampled)
      result = %{"role" => "assistant", "content" => %{"type" => "text", "text" => "Short."}}
      {:ok, Map.put(result, "model", "test"), state}
    end

    @impl true
    def handle_elicitation_create(message, _schema, state) do
      send(state.owner, {:elicited, message})
      {:ok, %{"action" => "accept", "content" => %{"name" => "Lin"}}, state}
    end
  end

  defmodule SilentClient do
    @moduledoc false
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}
    @impl true
    def handle_ping(state), do: {:ok, %{}, state}
    @impl true
    def handle_list_roots(state), do: {:ok, [], state}
    @impl true
    def handle_create_message(_params, state), do: {:error, "unused", state}

    # Never answers.
    @impl true
    def handle_elicitation_create(_message, _schema, state) do
      send(state.owner, :elicitation_waiting)
      receive do: (:never -> {:ok, %{"action" => "decline"}, state})
    end
  end

  defp connect(mode, opts \\ []) do
    {:ok, server} =
      HandlerServer.start_link(
        handler: ServerHandler,
        transport: :test,
        protocol_mode: mode,
        mrtr: true,
        request_state: [active_key_id: "bridge", keys: %{"bridge" => @key}]
      )

    on_exit(fn -> Arbor.MCP.TestHelpers.safe_stop_process(server) end)

    {:ok, client} =
      Client.start_link(
        [
          transport: :test,
          server: server,
          protocol_mode: mode,
          capabilities: %{"elicitation" => %{"form" => %{}}, "sampling" => %{}},
          handler: {ClientHandler, [owner: self()]},
          health_check_interval: nil
        ]
        |> Keyword.merge(opts)
      )

    Process.put(:bridge_server, server)
    client
  end

  for mode <- [:modern_only, :legacy_only] do
    test "one handler completes an elicitation-driven call (#{mode})" do
      client = connect(unquote(mode))

      assert {:ok, result} = Client.call_tool(client, "onboard", %{}, format: :map)
      assert result["content"] == [%{"type" => "text", "text" => "Welcome, Lin"}]
      assert_receive {:elicited, "What should we call you?"}
    end
  end

  test "a legacy client is asked to sample and the handler gets the result" do
    client = connect(:legacy_only)

    assert {:ok, result} = Client.call_tool(client, "summarize", %{}, format: :map)
    assert result["content"] == [%{"type" => "text", "text" => "Short."}]
    assert_receive :sampled
  end

  test "a stateless handler that changes its state between rounds fails" do
    client = connect(:legacy_only)

    assert {:error, %{"code" => -32603, "data" => %{"type" => "invalid_handler_state"}}} =
             Client.call_tool(client, "mutate", %{}, format: :map)

    refute_received {:elicited, _}
  end

  test "a cancelled call releases its pending input request" do
    client = connect(:legacy_only, handler: {SilentClient, [owner: self()]})

    assert {:error, _timeout} = Client.call_tool(client, "onboard", %{}, timeout: 200)
    assert_received :elicitation_waiting

    {:ok, edge} = Arbor.MCP.Server.Runtime.edge(Process.get(:bridge_server))

    :ok =
      Arbor.MCP.TestHelpers.wait_until(fn -> :sys.get_state(edge).pending_requests == %{} end,
        timeout: 2_000
      )
  end

  test "a request the client didn't declare a capability for isn't sent" do
    client = connect(:legacy_only, capabilities: %{"elicitation" => %{"form" => %{}}})

    assert {:error, %{"message" => "Input request error"}} =
             Client.call_tool(client, "summarize", %{}, format: :map)

    refute_received :sampled
  end

  test "a request the negotiated revision doesn't define isn't sent" do
    client = connect(:legacy_only, protocol_version: "2024-11-05")

    assert {:error, %{"message" => "Input request error"}} =
             Client.call_tool(client, "onboard", %{}, format: :map)

    refute_received {:elicited, _}
  end

  test "a legacy client is asked at most ten times" do
    client = connect(:legacy_only)

    assert {:error, %{"code" => -32603, "message" => message}} =
             Client.call_tool(client, "forever", %{}, format: :map)

    assert message =~ "more than 10 times"

    for _round <- 1..10, do: assert_receive({:elicited, "Again?"})
    refute_received {:elicited, _}
  end
end
