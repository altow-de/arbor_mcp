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
        for name <- ~w(ask context progress hold) do
          %{name: name, description: name, inputSchema: %{"type" => "object"}}
        end

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_list_prompts(_cursor, state) do
      {:ok, [%{name: "greeting", description: "Greets a named person"}], nil, state}
    end

    @impl true
    def handle_get_prompt("greeting", _arguments, state) do
      case Context.input_responses() do
        nil ->
          {:input_required, name_request(), %{"step" => 1}, state}

        responses ->
          send(state.test_pid, {:app_retry, responses, Context.request_state()})
          name = get_in(responses, ["name", "content", "name"])
          message = %{role: "user", content: %{type: "text", text: "Greet #{name}"}}
          {:ok, %{messages: [message]}, state}
      end
    end

    @impl true
    def handle_call_tool("ask", _arguments, state) do
      case Context.input_responses() do
        nil ->
          {:input_required, name_request(), %{"step" => 1}, state}

        responses ->
          send(state.test_pid, {:app_retry, responses, Context.request_state()})
          name = get_in(responses, ["name", "content", "name"])
          {:ok, %{content: [%{type: "text", text: "Welcome, #{name}"}]}, state}
      end
    end

    def handle_call_tool("context", _arguments, state) do
      context = Context.current()
      send(state.test_pid, {:app_context, context.era, context.client_capabilities, context.meta})
      {:ok, %{content: [%{type: "text", text: "seen"}]}, state}
    end

    def handle_call_tool("progress", _arguments, state) do
      :ok = Context.report_progress(50, 100, "half")
      send(state.test_pid, {:app_waiting, self()})

      receive do
        :release -> {:ok, %{content: [%{type: "text", text: "done"}]}, state}
      end
    end

    defp name_request do
      %{
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
    end

    # Holds the request open without writing to its response stream until the
    # test releases it or the request is cancelled.
    def handle_call_tool("hold", _arguments, state) do
      send(state.test_pid, {:app_waiting, self()})
      hold(state, System.monotonic_time(:millisecond) + 5_000)
    end

    defp hold(state, deadline) do
      cond do
        Context.cancelled?() ->
          send(state.test_pid, :app_cancelled)
          {:error, "cancelled", state}

        System.monotonic_time(:millisecond) > deadline ->
          {:ok, %{content: [%{type: "text", text: "never cancelled"}]}, state}

        true ->
          receive do
            :release -> {:ok, %{content: [%{type: "text", text: "released"}]}, state}
          after
            10 -> hold(state, deadline)
          end
      end
    end
  end

  defmodule ClientHandler do
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, Keyword.fetch!(opts, :test_pid)}

    @impl true
    def handle_progress(request_id, params, test_pid) do
      send(test_pid, {:client_handler_progress, request_id, params})
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

    test "applies to prompts/get the same way", %{url: url} do
      client = start_client(url, capabilities: %{"elicitation" => %{"form" => %{}}})

      assert {:ok, %{"resultType" => "input_required", "requestState" => request_state}} =
               Client.get_prompt(client, "greeting", %{}, mrtr: :manual, format: :map)

      responses = %{"name" => %{"action" => "accept", "content" => %{"name" => "Tom"}}}

      assert {:ok, %{"resultType" => "complete", "messages" => [message]}} =
               Client.get_prompt(client, "greeting", %{},
                 mrtr: :manual,
                 input_responses: responses,
                 request_state: request_state,
                 format: :map
               )

      assert message["content"]["text"] == "Greet Tom"
      assert_received {:app_retry, ^responses, %{"step" => 1}}
    end
  end

  describe "proxy options" do
    test "reject invalid values before anything is sent", %{url: url} do
      client = start_client(url)

      for {opts, message} <- [
            {[mrtr: :later], "mrtr must be :auto or :manual"},
            {[input_responses: []], "input_responses must be a map"},
            {[request_state: %{}], "request_state must be a string"},
            {[client_capabilities: []], "client_capabilities must be a map"},
            {[progress_to: :owner], "progress_to must be a pid"},
            {[cancel_on_caller_exit: :yes], "cancel_on_caller_exit must be a boolean"}
          ] do
        assert_raise ArgumentError, message, fn ->
          Client.call_tool(client, "context", %{}, [format: :map] ++ opts)
        end
      end

      assert_raise ArgumentError, ~r/only valid for tools\/call/, fn ->
        Client.list_tools(client, input_responses: %{})
      end

      refute_received {:app_context, _era, _capabilities, _meta}
    end

    test "treat nil as unset", %{url: url} do
      started = %{"elicitation" => %{"form" => %{}}}
      client = start_client(url, capabilities: started)

      assert {:ok, %{"content" => [%{"text" => "seen"}]}} =
               Client.call_tool(client, "context", %{},
                 format: :map,
                 input_responses: nil,
                 request_state: nil,
                 client_capabilities: nil,
                 progress_to: nil,
                 cancel_on_caller_exit: nil
               )

      assert_received {:app_context, :modern, ^started, _meta}
    end
  end

  describe "client capabilities per request" do
    test "replace the start capabilities for that request only on MCP 2026-07-28", %{url: url} do
      started = %{"elicitation" => %{"form" => %{}, "url" => %{}}}
      client = start_client(url, capabilities: started)
      requested = %{"elicitation" => %{"form" => %{}}}

      assert {:ok, _result} =
               Client.call_tool(client, "context", %{},
                 client_capabilities: requested,
                 format: :map
               )

      assert_received {:app_context, :modern, ^requested, _meta}

      assert {:ok, _result} = Client.call_tool(client, "context", %{}, format: :map)
      assert_received {:app_context, :modern, ^started, _meta}
    end

    test "do not reach the wire on MCP 2025-06-18", %{url: url} do
      client = start_legacy_client(url)

      assert {:ok, _result} =
               Client.call_tool(client, "context", %{},
                 client_capabilities: %{"elicitation" => %{"form" => %{}}},
                 format: :map
               )

      assert_received {:app_context, :legacy, nil, meta}
      refute Map.has_key?(meta, "io.modelcontextprotocol/clientCapabilities")
    end
  end

  describe "a watched request on MCP 2026-07-28" do
    test "delivers its progress to progress_to instead of the client handler", %{url: url} do
      client = start_client(url, handler: {ClientHandler, [test_pid: self()]})
      owner = self()

      task =
        Task.async(fn ->
          Client.call_tool(client, "progress", %{},
            progress_token: "gateway-1",
            progress_to: owner,
            format: :map,
            timeout: 5_000
          )
        end)

      assert_receive {:arbor_mcp_progress, "gateway-1",
                      %{"progress" => 50, "total" => 100, "message" => "half"}},
                     2_000

      assert_receive {:app_waiting, app}, 2_000
      send(app, :release)

      assert {:ok, %{"content" => [%{"text" => "done"}]}} = Task.await(task, 2_000)
      refute_received {:client_handler_progress, _request_id, _params}
    end

    test "leaves the client free for other requests while it runs", %{url: url} do
      client = start_client(url)

      task =
        Task.async(fn ->
          Client.call_tool(client, "hold", %{},
            cancel_on_caller_exit: true,
            format: :map,
            timeout: 5_000
          )
        end)

      assert_receive {:app_waiting, app}, 2_000

      assert {:ok, %{"content" => [%{"text" => "seen"}]}} =
               Client.call_tool(client, "context", %{}, format: :map, timeout: 1_000)

      send(app, :release)
      assert {:ok, %{"content" => [%{"text" => "released"}]}} = Task.await(task, 2_000)
    end

    test "is cancelled at the app when its caller exits", %{url: url} do
      client = start_client(url)

      {caller, caller_ref} =
        spawn_monitor(fn ->
          Client.call_tool(client, "hold", %{},
            cancel_on_caller_exit: true,
            format: :map,
            timeout: 10_000
          )
        end)

      assert_receive {:app_waiting, _app}, 2_000
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}

      assert_receive :app_cancelled, 1_000
      assert Client.get_pending_requests(client) == []
    end

    test "settles its caller at once when it is cancelled", %{url: url} do
      client = start_client(url)

      task =
        Task.async(fn ->
          Client.call_tool(client, "hold", %{},
            cancel_on_caller_exit: true,
            format: :map,
            timeout: 10_000
          )
        end)

      assert_receive {:app_waiting, _app}, 2_000
      assert [request_id] = Client.get_pending_requests(client)
      assert :ok = Client.send_cancelled(client, request_id, "superseded")

      assert {:error, :cancelled} = Task.await(task, 1_000)
      assert Client.get_pending_requests(client) == []
    end
  end

  describe "a watched request on MCP 2025-06-18" do
    test "is cancelled at the app when its caller exits", %{url: url} do
      client = start_legacy_client(url, use_sse: true)

      {caller, caller_ref} =
        spawn_monitor(fn ->
          Client.call_tool(client, "hold", %{},
            cancel_on_caller_exit: true,
            format: :map,
            timeout: 10_000
          )
        end)

      assert_receive {:app_waiting, _app}, 2_000
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}

      assert_receive :app_cancelled, 1_000
      assert Client.get_pending_requests(client) == []
    end
  end

  defp start_app do
    runtime =
      start_supervised!(
        {Runtime,
         handler: AppHandler,
         handler_args: [test_pid: self()],
         transport: :mounted_http,
         execution: :stateless,
         max_concurrency: 4},
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

  defp start_client(url, opts \\ []) do
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
    on_exit_disconnect(client)
    client
  end

  defp start_legacy_client(url, opts \\ []) do
    start_client(
      url,
      Keyword.merge([protocol_mode: :legacy_only, protocol_version: "2025-06-18"], opts)
    )
  end

  defp on_exit_disconnect(client) do
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
