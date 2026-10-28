defmodule Arbor.MCP.Client.ManualMRTRTest do
  # A client that forwards requests for another client, such as a gateway,
  # leaves each MRTR round to that client: `mrtr: :manual` returns the round
  # as `{:input_required, ...}`, `input_responses:` and `request_state:`
  # continue the call, and `client_capabilities:` declares that client's
  # capabilities for one request.
  #
  # The first part runs against arbor_mcp servers, over modern Streamable
  # HTTP (a Runtime-mounted HttpPlug on Bandit) and over the in-process test
  # transport. The second part scripts the server's replies to check exactly
  # what the client sends and how it validates what it gets.
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Error.{ProtocolError, ValidationError}
  alias Arbor.MCP.Server.{Context, HandlerServer, Runtime}

  @key :binary.copy(<<7>>, 32)
  @caps_key "io.modelcontextprotocol/clientCapabilities"
  @form %{"elicitation" => %{"form" => %{}}}
  @name_schema %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}
  @elicitation %{
    "name" => %{
      "method" => "elicitation/create",
      "params" => %{"message" => "What should we call you?", "requestedSchema" => @name_schema}
    }
  }

  defmodule AppHandler do
    use Arbor.MCP.Server.Handler

    @name_schema %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}

    @impl true
    def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def handle_list_tools(_cursor, state) do
      tools =
        for name <- ~w(ask choose context),
            do: %{name: name, description: name, inputSchema: %{"type" => "object"}}

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool("ask", _arguments, state) do
      case Context.input_responses() do
        nil ->
          {:input_required, name_request(), %{"step" => 1}, state}

        responses ->
          send(state.test_pid, {:app_retry, responses, Context.request_state()})
          {:ok, %{content: [%{type: "text", text: "Welcome, #{name(responses)}"}]}, state}
      end
    end

    # A server picks its input from the capabilities of the request it is
    # answering: a summary when the client can sample, else a question.
    def handle_call_tool("choose", _arguments, state) do
      if Map.has_key?(Context.current().client_capabilities || %{}, "sampling") do
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
      else
        {:input_required, name_request(), state}
      end
    end

    def handle_call_tool("context", _arguments, state) do
      context = Context.current()

      send(
        state.test_pid,
        {:app_context, context.era, context.client_capabilities, Context.input_responses(),
         Context.request_state()}
      )

      {:ok, %{content: [%{type: "text", text: "seen"}]}, state}
    end

    @impl true
    def handle_list_prompts(_cursor, state),
      do: {:ok, [%{name: "greeting", description: "Greets a named person"}], nil, state}

    @impl true
    def handle_get_prompt("greeting", _arguments, state) do
      case Context.input_responses() do
        nil ->
          {:input_required, name_request(), %{"step" => 1}, state}

        responses ->
          send(state.test_pid, {:app_retry, responses, Context.request_state()})
          message = %{role: "user", content: %{type: "text", text: "Greet #{name(responses)}"}}
          {:ok, %{messages: [message]}, state}
      end
    end

    @impl true
    def handle_list_resources(_cursor, state),
      do: {:ok, [%{uri: "memo://note", name: "note"}], nil, state}

    @impl true
    def handle_read_resource("memo://note", state) do
      case Context.input_responses() do
        nil ->
          {:input_required, name_request(), %{"step" => 1}, state}

        responses ->
          send(state.test_pid, {:app_retry, responses, Context.request_state()})
          text = "A note for #{name(responses)}"
          {:ok, %{contents: [%{uri: "memo://note", mimeType: "text/plain", text: text}]}, state}
      end
    end

    defp name_request do
      %{
        "name" => %{
          "method" => "elicitation/create",
          "params" => %{
            "message" => "What should we call you?",
            "requestedSchema" => @name_schema
          }
        }
      }
    end

    defp name(responses), do: get_in(responses, ["name", "content", "name"])
  end

  # The gateway from "Forwarding clients" in docs/CONFIGURATION.md: an
  # arbor_mcp server whose tools forward to an upstream server and whose
  # downstream client answers the upstream rounds.
  defmodule GatewayHandler do
    use Arbor.MCP.Server.Handler

    alias Arbor.MCP.Server.Context

    @impl true
    def init(opts), do: {:ok, %{upstream: Keyword.fetch!(opts, :upstream)}}

    @impl true
    def handle_list_tools(_cursor, state),
      do: {:ok, [%{name: "ask", inputSchema: %{"type" => "object"}}], nil, state}

    @impl true
    def handle_call_tool(name, arguments, state) do
      sealed = Context.request_state() || %{}

      opts = [
        mrtr: :manual,
        client_capabilities: Context.current().client_capabilities,
        input_responses: Context.input_responses(),
        request_state: sealed["upstream"],
        format: :map
      ]

      case Arbor.MCP.Client.call_tool(state.upstream, name, arguments, opts) do
        {:input_required, %{input_requests: requests, request_state: upstream}} ->
          {:input_required, requests, %{"upstream" => upstream}, state}

        {:ok, result} ->
          {:ok, result, state}

        {:error, reason} ->
          {:error, reason, state}
      end
    end
  end

  defmodule ClientHandler do
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts),
      do: {:ok, %{owner: Keyword.fetch!(opts, :owner), name: Keyword.get(opts, :name, "Lin")}}

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(_params, state), do: {:error, "not used", state}

    @impl true
    def handle_elicitation_create(message, _schema, state) do
      send(state.owner, {:elicited, message})
      {:ok, %{"action" => "accept", "content" => %{"name" => state.name}}, state}
    end
  end

  # Answers each request with the next scripted result and reports what it
  # was sent.
  defmodule ScriptedTransport do
    def send_message(encoded, state) do
      request = Jason.decode!(encoded)
      send(state.owner, {:wire, request})

      {result, results} =
        case state.results do
          [result | rest] -> {result, rest}
          [] -> {%{"resultType" => "complete", "content" => []}, []}
        end

      response = %{"jsonrpc" => "2.0", "id" => request["id"], "result" => result}
      {:ok, %{state | results: results}, Jason.encode!(response)}
    end
  end

  @tom %{"name" => %{"action" => "accept", "content" => %{"name" => "Tom"}}}

  for transport <- [:http, :test] do
    describe "mrtr: :manual against an arbor_mcp server (#{transport})" do
      @describetag transport: transport

      test "returns the round as {:input_required, ...} without calling the client handler",
           %{transport: transport} do
        client = connect(transport)

        for format <- [:map, :struct] do
          assert {:input_required,
                  %{
                    input_requests: %{
                      "name" => %{
                        "method" => "elicitation/create",
                        "params" => %{"message" => "What should we call you?"}
                      }
                    },
                    request_state: request_state
                  }} = Client.call_tool(client, "ask", %{}, mrtr: :manual, format: format)

          assert is_binary(request_state)
        end

        refute_received {:elicited, _message}
        refute_received {:app_retry, _responses, _state}
      end

      test "input_responses and request_state continue the call to its result",
           %{transport: transport} do
        client = connect(transport)

        assert {:input_required, %{request_state: request_state}} =
                 Client.call_tool(client, "ask", %{"topic" => "intro"}, mrtr: :manual)

        assert {:ok, result} =
                 Client.call_tool(client, "ask", %{"topic" => "intro"},
                   mrtr: :manual,
                   input_responses: @tom,
                   request_state: request_state,
                   format: :map
                 )

        assert result["resultType"] == "complete"
        assert result["content"] == [%{"type" => "text", "text" => "Welcome, Tom"}]
        assert_received {:app_retry, @tom, %{"step" => 1}}
        refute_received {:elicited, _message}
      end

      test "prompts/get and resources/read run manual rounds the same way",
           %{transport: transport} do
        client = connect(transport)

        assert {:input_required, %{input_requests: %{"name" => _}, request_state: state}} =
                 Client.get_prompt(client, "greeting", %{}, mrtr: :manual)

        assert {:ok, %{"messages" => [message]}} =
                 Client.get_prompt(client, "greeting", %{},
                   mrtr: :manual,
                   input_responses: @tom,
                   request_state: state,
                   format: :map
                 )

        assert message["content"]["text"] == "Greet Tom"
        assert_received {:app_retry, @tom, %{"step" => 1}}

        assert {:input_required, %{input_requests: %{"name" => _}, request_state: state}} =
                 Client.read_resource(client, "memo://note", mrtr: :manual)

        assert {:ok, %{"contents" => [%{"text" => "A note for Tom"}]}} =
                 Client.read_resource(client, "memo://note",
                   mrtr: :manual,
                   input_responses: @tom,
                   request_state: state,
                   format: :map
                 )

        assert_received {:app_retry, @tom, %{"step" => 1}}
        refute_received {:elicited, _message}
      end

      test "an explicit timeout covers each round on its own", %{transport: transport} do
        client = connect(transport)

        assert {:input_required, %{request_state: state}} =
                 Client.call_tool(client, "ask", %{}, mrtr: :manual, timeout: 5_000)

        assert {:ok, %{"content" => [%{"text" => "Welcome, Tom"}]}} =
                 Client.call_tool(client, "ask", %{},
                   mrtr: :manual,
                   input_responses: @tom,
                   request_state: state,
                   timeout: 5_000,
                   format: :map
                 )
      end

      test "client_capabilities replace the start capabilities in that request only",
           %{transport: transport} do
        started = %{"elicitation" => %{"form" => %{}, "url" => %{}}, "sampling" => %{}}
        client = connect(transport, capabilities: started)

        assert {:ok, _result} =
                 Client.call_tool(client, "context", %{},
                   mrtr: :manual,
                   client_capabilities: @form,
                   format: :map
                 )

        assert_received {:app_context, :modern, @form, nil, nil}

        assert {:ok, _result} = Client.call_tool(client, "context", %{}, format: :map)
        assert_received {:app_context, :modern, ^started, nil, nil}
      end

      test "the server chooses its input from the request's capabilities",
           %{transport: transport} do
        client = connect(transport, capabilities: Map.put(@form, "sampling", %{}))

        assert {:input_required, %{input_requests: %{"summary" => %{"method" => method}}}} =
                 Client.call_tool(client, "choose", %{}, mrtr: :manual)

        assert method == "sampling/createMessage"

        assert {:input_required, %{input_requests: %{"name" => %{"method" => method}}}} =
                 Client.call_tool(client, "choose", %{},
                   mrtr: :manual,
                   client_capabilities: @form
                 )

        assert method == "elicitation/create"
      end

      # An arbor_mcp server binds requestState to the request's params, _meta
      # included, and to the capabilities it declared.
      test "every round repeats the arguments, capabilities and progress token",
           %{transport: transport} do
        client = connect(transport)

        round = [
          mrtr: :manual,
          client_capabilities: @form,
          progress_token: "upstream-1",
          format: :map
        ]

        assert {:input_required, %{request_state: state}} =
                 Client.call_tool(client, "ask", %{"topic" => "intro"}, round)

        retry = round ++ [input_responses: @tom, request_state: state]

        for {arguments, changed} <- [
              {%{"topic" => "other"}, retry},
              {%{"topic" => "intro"}, Keyword.put(retry, :progress_token, "upstream-2")},
              {%{"topic" => "intro"},
               Keyword.put(retry, :client_capabilities, Map.put(@form, "roots", %{}))}
            ] do
          assert {:error,
                  %{"code" => -32_602, "data" => %{"reason" => "request_state_binding_mismatch"}}} =
                   Client.call_tool(client, "ask", arguments, changed)
        end

        refute_received {:app_retry, _responses, _state}

        assert {:ok, %{"content" => [%{"text" => "Welcome, Tom"}]}} =
                 Client.call_tool(client, "ask", %{"topic" => "intro"}, retry)
      end

      test "automatic MRTR is unchanged", %{transport: transport} do
        client = connect(transport)

        for opts <- [[], [mrtr: :auto], [mrtr: nil]] do
          assert {:ok, %{"resultType" => "complete", "content" => [%{"text" => "Welcome, Lin"}]}} =
                   Client.call_tool(client, "ask", %{}, [format: :map] ++ opts)

          assert_received {:elicited, "What should we call you?"}
          assert_received {:app_retry, %{"name" => _}, %{"step" => 1}}
        end
      end

      test "nil leaves every option unset", %{transport: transport} do
        client = connect(transport)

        for mrtr <- [nil, :auto, :manual] do
          assert {:ok, %{"content" => [%{"text" => "seen"}]}} =
                   Client.call_tool(client, "context", %{},
                     format: :map,
                     mrtr: mrtr,
                     input_responses: nil,
                     request_state: nil,
                     client_capabilities: nil
                   )

          assert_received {:app_context, :modern, @form, nil, nil}
        end
      end
    end
  end

  describe "a gateway" do
    for mode <- [:modern_only, :legacy_only] do
      test "hands the upstream rounds to its downstream client (#{mode} downstream)" do
        # Were the gateway's own client to answer, the call would greet Gate.
        upstream = connect(:http, handler: {ClientHandler, [owner: self(), name: "Gate"]})

        gateway =
          start_supervised!(
            {HandlerServer,
             handler: GatewayHandler,
             handler_args: [upstream: upstream],
             transport: :test,
             protocol_mode: unquote(mode),
             mrtr: true,
             request_state: [active_key_id: "gateway", keys: %{"gateway" => @key}]},
            id: make_ref()
          )

        downstream =
          start_client(transport: :test, server: gateway, protocol_mode: unquote(mode))

        assert {:ok, %{"content" => [%{"text" => "Welcome, Lin"}]}} =
                 Client.call_tool(downstream, "ask", %{"topic" => "intro"}, format: :map)

        # The downstream client answered, and only it.
        assert_received {:elicited, "What should we call you?"}
        refute_received {:elicited, _message}
        assert_received {:app_retry, %{"name" => %{"content" => %{"name" => "Lin"}}}, _state}
      end
    end
  end

  describe "on a legacy connection" do
    for transport <- [:http, :test] do
      test "client_capabilities and the continuation are refused before anything is sent (#{transport})" do
        client = connect(unquote(transport), protocol_mode: :legacy_only)

        for {key, value} <- [
              client_capabilities: @form,
              input_responses: @tom,
              request_state: "state"
            ] do
          assert {:error, %ValidationError{field: ^key, reason: reason}} =
                   Client.call_tool(client, "context", %{}, [mrtr: :manual] ++ [{key, value}])

          assert reason =~ "requires MCP 2026-07-28, but the connection settled on 2025-"
        end

        refute_received {:app_context, _era, _capabilities, _responses, _state}
      end
    end

    # A legacy server asks with server-to-client requests, which the client
    # handler answers: there is no round to hand back.
    test "mrtr: :manual leaves the server's input requests to the client handler" do
      client = connect(:test, protocol_mode: :legacy_only)

      assert {:ok, %{"content" => [%{"text" => "Welcome, Lin"}]}} =
               Client.call_tool(client, "ask", %{}, mrtr: :manual, format: :map)

      assert_received {:elicited, "What should we call you?"}
    end
  end

  describe "the returned round is validated as automatic MRTR validates it" do
    for {name, result, message} <- [
          {"inputRequests that is not an object", %{"inputRequests" => [], "requestState" => "s"},
           "inputRequests must be an object"},
          {"a requestState that is not a string",
           %{"inputRequests" => @elicitation, "requestState" => 1},
           "requestState must be a string"},
          {"neither inputRequests nor requestState", %{},
           "input_required must contain inputRequests or requestState"},
          {"an input method MRTR doesn't define",
           %{"inputRequests" => %{"x" => %{"method" => "tools/call", "params" => %{}}}},
           "Invalid MRTR input request"}
        ] do
      test "#{name} is an error in both modes" do
        result = Map.put(unquote(Macro.escape(result)), "resultType", "input_required")

        for mrtr <- [:auto, :manual] do
          client = scripted([result])

          assert {:error, %ProtocolError{code: -32_602, message: unquote(message)}} =
                   Client.call_tool(client, "ask", %{}, mrtr: mrtr, format: :map)
        end
      end
    end

    test "the input request and byte limits apply in both modes" do
      round = input_required(@elicitation)

      for mrtr <- [:auto, :manual] do
        assert {:error, %ProtocolError{message: "MRTR input request limit exceeded"}} =
                 Client.call_tool(scripted([round]), "ask", %{},
                   mrtr: mrtr,
                   max_input_requests: 0
                 )

        assert {:error, %ProtocolError{message: "MRTR byte limit exceeded"}} =
                 Client.call_tool(scripted([round]), "ask", %{}, mrtr: mrtr, max_mrtr_bytes: 16)
      end
    end

    test "an input request the request declared no capability for is an error in both modes" do
      round =
        input_required(%{"summary" => %{"method" => "sampling/createMessage", "params" => %{}}})

      errors =
        for mrtr <- [:auto, :manual] do
          assert {:error, %ProtocolError{code: -32_021} = error} =
                   Client.call_tool(scripted([round]), "ask", %{}, mrtr: mrtr)

          error
        end

      assert [same, same] = errors
      assert same.data == %{"requiredCapabilities" => %{"sampling" => %{}}}

      # Declared for this request, the same round is the caller's to answer.
      assert {:input_required, %{input_requests: %{"summary" => _}}} =
               Client.call_tool(scripted([round]), "ask", %{},
                 mrtr: :manual,
                 client_capabilities: %{"sampling" => %{}}
               )

      # A URL elicitation needs `elicitation.url`, which @form doesn't declare.
      url = %{
        "method" => "elicitation/create",
        "params" => %{"mode" => "url", "message" => "Sign in", "url" => "https://example.test"}
      }

      assert {:error, %ProtocolError{code: -32_021}} =
               Client.call_tool(scripted([input_required(%{"login" => url})]), "ask", %{},
                 mrtr: :manual
               )
    end

    test "an input_required result on a legacy connection is an error in both modes" do
      for mrtr <- [:auto, :manual] do
        client = scripted([input_required(@elicitation)], protocol_version: "2025-06-18")

        assert {:error, %ProtocolError{message: "MRTR requires MCP 2026-07-28"}} =
                 Client.call_tool(client, "ask", %{}, mrtr: mrtr)
      end

      refute_received {:elicited, _message}
    end

    test "a valid round comes back the same in both formats" do
      for format <- [:map, :struct] do
        assert {:input_required, %{input_requests: @elicitation, request_state: "sealed"}} =
                 Client.call_tool(scripted([input_required(@elicitation)]), "ask", %{},
                   mrtr: :manual,
                   format: format
                 )
      end

      # requestState is optional when there are input requests.
      round = Map.delete(input_required(@elicitation), "requestState")

      assert {:input_required, %{input_requests: @elicitation, request_state: nil}} =
               Client.call_tool(scripted([round]), "ask", %{}, mrtr: :manual)
    end
  end

  describe "request options" do
    test "the continuation and the capabilities reach the wire as given" do
      client = scripted([])
      capabilities = %{"elicitation" => %{"form" => %{}}, "extensions" => %{"x/y" => %{}}}

      assert {:ok, _result} =
               Client.call_tool(client, "ask", %{"topic" => "intro"},
                 mrtr: :manual,
                 input_responses: @tom,
                 request_state: "sealed",
                 client_capabilities: capabilities,
                 format: :map
               )

      assert_received {:wire, %{"method" => "tools/call", "params" => params}}
      assert params["arguments"] == %{"topic" => "intro"}
      assert params["inputResponses"] == @tom
      assert params["requestState"] == "sealed"
      assert params["_meta"][@caps_key] == capabilities
    end

    test "nil options are unset" do
      client = scripted([])

      assert {:ok, _result} =
               Client.call_tool(client, "ask", %{},
                 mrtr: nil,
                 input_responses: nil,
                 request_state: nil,
                 client_capabilities: nil,
                 format: :map
               )

      assert_received {:wire, %{"params" => params}}
      refute Map.has_key?(params, "inputResponses")
      refute Map.has_key?(params, "requestState")
      assert params["_meta"][@caps_key] == @form
    end

    test "client_capabilities and the continuation need mrtr: :manual" do
      client = scripted([])

      for mrtr <- [[], [mrtr: nil], [mrtr: :auto]],
          {key, value} <- [
            client_capabilities: @form,
            input_responses: @tom,
            request_state: "sealed"
          ] do
        assert {:error, %ValidationError{field: ^key, reason: "requires mrtr: :manual"}} =
                 Client.call_tool(client, "ask", %{}, [{key, value} | mrtr])
      end

      refute_received {:wire, _request}
    end

    test "a continuation is only valid for the operations that can return input_required" do
      tools = %{
        "resultType" => "complete",
        "tools" => [],
        "ttlMs" => 0,
        "cacheScope" => "private"
      }

      client = scripted([tools])

      assert {:error, %ValidationError{field: :input_responses, reason: reason}} =
               Client.list_tools(client, mrtr: :manual, input_responses: @tom)

      assert reason == "is only valid for tools/call, resources/read, prompts/get, not tools/list"

      assert {:error, %ValidationError{field: :request_state}} =
               Client.list_prompts(client, mrtr: :manual, request_state: "sealed")

      refute_received {:wire, _request}

      # Capabilities may go on any modern request.
      assert {:ok, _result} = Client.list_tools(client, mrtr: :manual, client_capabilities: @form)
      assert_received {:wire, %{"method" => "tools/list", "params" => %{"_meta" => meta}}}
      assert meta[@caps_key] == @form
    end

    test "malformed values are refused before anything is sent" do
      client = scripted([])

      for {key, value, reason} <- [
            {:input_responses, [], "must map input request ids to response objects"},
            {:input_responses, %{"name" => "accept"},
             "must map input request ids to response objects"},
            {:input_responses, %{"" => %{}}, "must map input request ids to response objects"},
            {:input_responses, %{name: %{}}, "must map input request ids to response objects"},
            {:input_responses, %{"name" => %{"pid" => self()}}, "must be JSON encodable"},
            {:request_state, 1, "must be a string"},
            {:client_capabilities, [], "must be a capabilities object"},
            {:client_capabilities, %{"elicitation" => true},
             "must be a capabilities object whose known capabilities are objects"},
            {:client_capabilities, %{elicitation: %{form: true}},
             "must be a capabilities object whose known capabilities are objects"},
            {:client_capabilities, %{"extensions" => %{"x/y" => 1}},
             "must be a capabilities object whose known capabilities are objects"},
            {:client_capabilities, %{"custom" => self()}, "must be JSON encodable"}
          ] do
        assert {:error, %ValidationError{field: ^key, reason: ^reason}} =
                 Client.call_tool(client, "ask", %{}, [{:mrtr, :manual}, {key, value}])
      end

      refute_received {:wire, _request}
    end

    test "input_responses are held to :max_mrtr_bytes" do
      client = scripted([])

      assert {:error, %ValidationError{field: :input_responses, reason: reason}} =
               Client.call_tool(client, "ask", %{},
                 mrtr: :manual,
                 input_responses: @tom,
                 max_mrtr_bytes: 16
               )

      assert reason == "exceed the MRTR byte limit of 16 (:max_mrtr_bytes)"
      refute_received {:wire, _request}
    end

    test "the errors don't carry the input responses or the request state" do
      client = scripted([])

      for {key, value} <- [input_responses: %{"name" => "secret"}, request_state: %{"s" => 1}] do
        assert {:error, %ValidationError{value: nil}} =
                 Client.call_tool(client, "ask", %{}, [{:mrtr, :manual}, {key, value}])
      end

      assert {:error, %ValidationError{value: nil}} =
               Client.call_tool(client, "ask", %{}, input_responses: %{"name" => %{}})
    end

    test "mrtr must be :auto or :manual" do
      client = scripted([])

      assert_raise ArgumentError, "mrtr must be :auto or :manual", fn ->
        Client.call_tool(client, "ask", %{}, mrtr: :later)
      end
    end

    test "a legacy request with client_capabilities is refused, not answered from the cache" do
      note = %{"contents" => [%{"uri" => "memo://note", "text" => "cached"}]}

      client =
        scripted([note],
          protocol_version: "2025-06-18",
          client: [default_cache_ttl_ms: 60_000]
        )

      assert {:ok, ^note} = Client.read_resource(client, "memo://note", format: :map)
      assert_received {:wire, %{"method" => "resources/read"}}

      assert {:error, %ValidationError{field: :client_capabilities}} =
               Client.read_resource(client, "memo://note",
                 mrtr: :manual,
                 client_capabilities: @form
               )

      # The cache still answers the same read without the option.
      assert {:ok, ^note} = Client.read_resource(client, "memo://note", format: :map)
      refute_received {:wire, _request}
    end

    test "a request without the options carries nothing new to a legacy server" do
      client = scripted([], protocol_version: "2025-06-18")

      assert {:ok, _result} = Client.call_tool(client, "ask", %{}, mrtr: :manual, format: :map)
      assert_received {:wire, %{"params" => params}}
      refute Map.has_key?(params, "_meta")

      assert {:error, %ValidationError{field: :client_capabilities}} =
               Client.call_tool(client, "ask", %{}, mrtr: :manual, client_capabilities: @form)

      refute_received {:wire, _request}
    end
  end

  # Servers

  defp connect(transport, opts \\ [])

  defp connect(:http, opts) do
    url = start_http_app()
    {mode, opts} = Keyword.pop(opts, :protocol_mode, :modern_only)

    start_client(
      [
        transport: :http,
        url: url,
        protocol_mode: mode,
        use_sse: false,
        security: %{origin: nil}
      ] ++ opts
    )
  end

  defp connect(:test, opts) do
    {mode, opts} = Keyword.pop(opts, :protocol_mode, :modern_only)

    server =
      start_supervised!(
        {HandlerServer,
         handler: AppHandler,
         handler_args: [test_pid: self()],
         transport: :test,
         protocol_mode: mode,
         mrtr: true,
         request_state: [active_key_id: "manual", keys: %{"manual" => @key}]},
        id: make_ref()
      )

    start_client([transport: :test, server: server, protocol_mode: mode] ++ opts)
  end

  defp start_http_app do
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
      request_state: [active_key_id: "manual", keys: %{"manual" => @key}],
      principal_id: "gateway-test"
    ]

    listener =
      start_supervised!(
        {Bandit,
         plug: {Arbor.MCP.HttpPlug, plug_opts}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    "http://127.0.0.1:#{port}/mcp"
  end

  defp start_client(opts) do
    defaults = [
      capabilities: @form,
      handler: {ClientHandler, [owner: self()]},
      health_check_interval: nil,
      reconnect: false
    ]

    {:ok, client} = Client.start_link(Keyword.merge(defaults, opts))

    on_exit(fn ->
      try do
        Client.disconnect(client)
      catch
        :exit, _reason -> :ok
      end
    end)

    client
  end

  # A ready client whose server answers with `results`, one per request.
  defp scripted(results, opts \\ []) do
    owner = self()
    version = Keyword.get(opts, :protocol_version, "2026-07-28")

    client_opts =
      [
        _skip_connect: true,
        handler: {ClientHandler, [owner: owner]},
        capabilities: @form,
        health_check_interval: nil
      ] ++ Keyword.get(opts, :client, [])

    client = start_supervised!({Client, client_opts}, id: make_ref())

    :sys.replace_state(client, fn state ->
      %{
        state
        | transport_mod: ScriptedTransport,
          transport_state: %{owner: owner, results: results},
          protocol_version: version,
          connection_status: :ready,
          initialized: true
      }
    end)

    client
  end

  defp input_required(input_requests) do
    %{
      "resultType" => "input_required",
      "inputRequests" => input_requests,
      "requestState" => "sealed"
    }
  end
end
