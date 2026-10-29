defmodule Arbor.MCP.Repro.KUnimplementedMethodsTest do
  # Repro K: a handler built with `use Arbor.MCP.Server.Handler` that serves
  # only tools answers resources/list, prompts/list, completion/complete and
  # the other optional methods through the default callbacks with a generic
  # error, not with JSON-RPC -32601 "Method not found", although it announces
  # none of these capabilities.
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.{Dispatch, Runtime}
  alias Arbor.MCP.Test.RuntimeHTTPFixture

  defmodule ToolsOnly do
    use Arbor.MCP.Server.Handler

    @impl true
    def handle_list_tools(_cursor, state),
      do: {:ok, [%{name: "echo", inputSchema: %{"type" => "object"}}], nil, state}

    @impl true
    def handle_call_tool("echo", _args, state),
      do: {:ok, %{content: [%{type: "text", text: "ok"}]}, state}
  end

  @modern "2026-07-28"
  @legacy "2025-06-18"

  # Method => params. Every method is optional for a server and needs a
  # capability the handler does not announce.
  @methods [
    {"resources/list", %{}},
    {"resources/templates/list", %{}},
    {"resources/read", %{"uri" => "memo://x"}},
    {"resources/subscribe", %{"uri" => "memo://x"}},
    {"prompts/list", %{}},
    {"prompts/get", %{"name" => "x"}},
    {"completion/complete",
     %{
       "ref" => %{"type" => "ref/prompt", "name" => "x"},
       "argument" => %{"name" => "a", "value" => "b"}
     }},
    {"logging/setLevel", %{"level" => "info"}},
    {"no/such_method", %{}}
  ]

  defp modern_meta,
    do: %{
      "io.modelcontextprotocol/protocolVersion" => @modern,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

  defp request(method, params, :legacy),
    do: %{"jsonrpc" => "2.0", "id" => id(), "method" => method, "params" => params}

  defp request(method, params, :modern),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id(),
      "method" => method,
      "params" => Map.put(params, "_meta", modern_meta())
    }

  defp id, do: System.unique_integer([:positive])

  defp summary({:response, %{"error" => %{"code" => code, "message" => message}}, _state}),
    do: {:error, code, message}

  defp summary({:response, %{"result" => result}, _state}), do: {:result, result}

  test "capabilities the handler announces (server/discover and initialize)" do
    {:ok, state} = ToolsOnly.init([])

    {:response, %{"result" => discover}, _} =
      Dispatch.dispatch(request("server/discover", %{}, :modern), ToolsOnly, state, [])

    init_params = %{
      "protocolVersion" => @legacy,
      "capabilities" => %{},
      "clientInfo" => %{"name" => "repro", "version" => "0"}
    }

    {:response, %{"result" => initialize}, _} =
      Dispatch.dispatch(request("initialize", init_params, :legacy), ToolsOnly, state, [])

    IO.puts("\n[K] server/discover capabilities: #{inspect(discover["capabilities"])}")
    IO.puts("[K] initialize capabilities: #{inspect(initialize["capabilities"])}")

    for caps <- [discover["capabilities"], initialize["capabilities"]] do
      refute Map.has_key?(caps, "resources")
      refute Map.has_key?(caps, "prompts")
      refute Map.has_key?(caps, "completions")
    end
  end

  for era <- [:legacy, :modern] do
    test "Dispatch.dispatch/4 answers unimplemented optional methods (#{era})" do
      {:ok, state} = ToolsOnly.init([])

      results =
        for {method, params} <- @methods do
          {method,
           summary(Dispatch.dispatch(request(method, params, unquote(era)), ToolsOnly, state, []))}
        end

      IO.puts("\n[K] Dispatch.dispatch/4, #{unquote(era)}:")
      for {method, result} <- results, do: IO.puts("    #{method} -> #{inspect(result)}")

      results = Map.new(results)
      # The genuinely unknown method gets -32601.
      assert {:error, -32601, _} = results["no/such_method"]
      # The optional methods the handler does not implement do not.
      assert {:error, -32000, _} = results["resources/list"]
      assert {:error, -32000, _} = results["prompts/list"]
      assert {:error, -32000, _} = results["completion/complete"]
      assert {:error, -32000, _} = results["resources/templates/list"]

      # resources/subscribe and logging/setLevel are gone in 2026-07-28, so a
      # modern request for them is an unknown method; legacy ones reach the
      # handler defaults.
      if unquote(era) == :legacy do
        assert {:error, -32000, _} = results["resources/subscribe"]
        assert {:result, %{}} = results["logging/setLevel"]
      else
        assert {:error, -32601, _} = results["resources/subscribe"]
        assert {:error, -32601, _} = results["logging/setLevel"]
      end
    end
  end

  describe "over HTTP (Runtime-mounted HttpPlug on Bandit)" do
    setup do
      root =
        start_supervised!(
          {Runtime, handler: ToolsOnly, transport: :mounted_http},
          id: make_ref()
        )

      {:ok, runtime} = Runtime.ref(root)

      opts = [runtime: runtime, path: "/mcp", protocol_mode: :prefer_modern]

      listener =
        start_supervised!(
          {Bandit,
           plug: {Arbor.MCP.HttpPlug, opts}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: make_ref()
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
      %{port: port, runtime: runtime}
    end

    test "modern requests", %{port: port} do
      IO.puts("\n[K] HTTP, modern (#{@modern}):")

      results =
        for {method, params} <- @methods do
          headers = [
            {"mcp-protocol-version", @modern},
            {"mcp-method", method}
          ]

          {status, body} = post(port, request(method, params, :modern), headers)
          IO.puts("    #{method} -> HTTP #{status} #{body}")
          {method, {status, Jason.decode!(body)}}
        end
        |> Map.new()

      assert {404, %{"error" => %{"code" => -32601}}} = results["no/such_method"]
      assert {200, %{"error" => %{"code" => -32000}}} = results["resources/list"]
      assert {200, %{"error" => %{"code" => -32000}}} = results["prompts/list"]
      assert {200, %{"error" => %{"code" => -32000}}} = results["completion/complete"]
    end

    test "legacy requests on an initialized session", %{port: port, runtime: runtime} do
      session = RuntimeHTTPFixture.session(runtime)
      IO.puts("\n[K] HTTP, legacy (#{@legacy}, session #{session}):")

      results =
        for {method, params} <- @methods do
          headers = [{"mcp-protocol-version", @legacy}, {"mcp-session-id", session}]
          {status, body} = post(port, request(method, params, :legacy), headers)
          IO.puts("    #{method} -> HTTP #{status} #{body}")
          {method, {status, Jason.decode!(body)}}
        end
        |> Map.new()

      assert {200, %{"error" => %{"code" => -32601}}} = results["no/such_method"]
      assert {200, %{"error" => %{"code" => -32000}}} = results["resources/list"]
      assert {200, %{"error" => %{"code" => -32000}}} = results["prompts/list"]
      assert {200, %{"error" => %{"code" => -32000}}} = results["completion/complete"]
    end
  end

  defp post(port, body, headers) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers =
      [
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"}
      ] ++ headers

    {:ok, conn, ref} = Mint.HTTP.request(conn, "POST", "/mcp", headers, Jason.encode!(body))
    {status, data} = collect(conn, ref, nil, "")
    {status, data}
  end

  defp collect(conn, ref, status, data) do
    receive do
      message ->
        {:ok, conn, events} = Mint.HTTP.stream(conn, message)

        {status, data, done?} =
          Enum.reduce(events, {status, data, false}, fn
            {:status, ^ref, s}, {_, d, done} -> {s, d, done}
            {:data, ^ref, chunk}, {s, d, done} -> {s, d <> chunk, done}
            {:done, ^ref}, {s, d, _} -> {s, d, true}
            _other, acc -> acc
          end)

        if done? do
          Mint.HTTP.close(conn)
          {status, data}
        else
          collect(conn, ref, status, data)
        end
    after
      5_000 -> flunk("no response: #{inspect({status, data})}")
    end
  end
end
