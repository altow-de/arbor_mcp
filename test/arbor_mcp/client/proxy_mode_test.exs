defmodule Arbor.MCP.Client.ProxyModeTest do
  # Proxy mode: per-request client options for a process that forwards a
  # downstream MCP request to an upstream server. Every test runs the client
  # against a real Runtime-mounted Arbor.MCP.HttpPlug on Bandit.
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.{Context, Runtime}

  @key :binary.copy(<<7>>, 32)

  defmodule AppHandler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def handle_list_tools(_cursor, state) do
      tools =
        for name <- ~w(ask) do
          %{name: name, description: name, inputSchema: %{"type" => "object"}}
        end

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool("ask", _arguments, state) do
      case Context.input_responses() do
        nil ->
          requests = %{
            "name" => %{
              "method" => "elicitation/create",
              "params" => %{
                "message" => "What should we call you?",
                "requestedSchema" => %{
                  "type" => "object",
                  "properties" => %{"name" => %{"type" => "string"}}
                }
              }
            }
          }

          {:input_required, requests, %{"step" => 1}, state}

        responses ->
          send(state.test_pid, {:app_retry, responses, Context.request_state()})
          name = get_in(responses, ["name", "content", "name"])
          {:ok, %{content: [%{type: "text", text: "Welcome, #{name}"}]}, state}
      end
    end
  end

  setup do
    url = start_app()
    {:ok, url: url}
  end

  describe "manual MRTR on MCP 2026-07-28" do
    test "returns input_required unchanged instead of fulfilling it", %{url: url} do
      client = start_client(url, capabilities: %{"elicitation" => %{"form" => %{}}})

      assert {:ok, result} = Client.call_tool(client, "ask", %{}, mrtr: :manual, format: :map)

      assert result["resultType"] == "input_required"

      assert %{
               "name" => %{
                 "method" => "elicitation/create",
                 "params" => %{"message" => "What should we call you?"}
               }
             } = result["inputRequests"]

      assert is_binary(result["requestState"])
      refute_received {:app_retry, _responses, _request_state}
    end

    test "a retry carries the caller's inputResponses and requestState to the app", %{url: url} do
      client = start_client(url, capabilities: %{"elicitation" => %{"form" => %{}}})

      assert {:ok, %{"requestState" => request_state}} =
               Client.call_tool(client, "ask", %{}, mrtr: :manual, format: :map)

      responses = %{"name" => %{"action" => "accept", "content" => %{"name" => "Tom"}}}

      assert {:ok, result} =
               Client.call_tool(client, "ask", %{},
                 mrtr: :manual,
                 input_responses: responses,
                 request_state: request_state,
                 format: :map
               )

      assert result["resultType"] == "complete"
      assert result["content"] == [%{"type" => "text", "text" => "Welcome, Tom"}]
      assert_received {:app_retry, ^responses, %{"step" => 1}}
    end
  end

  defp start_app do
    runtime =
      start_supervised!(
        {Runtime,
         handler: AppHandler, handler_args: [test_pid: self()], transport: :mounted_http},
        id: make_ref()
      )

    plug_opts = [
      runtime: runtime,
      path: "/mcp",
      protocol_mode: :prefer_modern,
      request_state: [active_key_id: "proxy", keys: %{"proxy" => @key}],
      principal_id: "proxy-test"
    ]

    listener =
      start_supervised!(
        {Bandit, plug: {Arbor.MCP.HttpPlug, plug_opts}, ip: {127, 0, 0, 1}, port: 0},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    "http://127.0.0.1:#{port}/mcp"
  end

  defp start_client(url, opts) do
    defaults = [
      transport: :http,
      url: url,
      protocol_mode: :modern_only,
      protocol_version: "2026-07-28",
      use_sse: false,
      security: %{origin: nil},
      health_check_interval: nil,
      reconnect: false
    ]

    {:ok, client} = Client.start_link(Keyword.merge(defaults, opts))

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
end
