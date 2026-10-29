defmodule Arbor.MCP.Repro.IMRTRMountedKeyRingTest do
  # Repro I: `mrtr: true` with a mounted plug. Where is the requestState key
  # ring validated, and when is it read: at HttpPlug.init/1 or per request?
  use ExUnit.Case, async: false

  alias Arbor.MCP.HttpPlug
  alias Arbor.MCP.Server.{HandlerServer, Runtime}

  @ring [active_key_id: "k1", keys: %{"k1" => :binary.copy(<<9>>, 32)}]

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    @impl true
    def handle_call_tool("ask", _args, state) do
      request = %{
        "name" => %{
          "method" => "elicitation/create",
          "params" => %{
            "message" => "Name?",
            "requestedSchema" => %{
              "type" => "object",
              "properties" => %{"name" => %{"type" => "string"}}
            }
          }
        }
      }

      {:input_required, request, %{"step" => 1}, state}
    end
  end

  setup do
    previous = Application.fetch_env(:arbor_mcp, :request_state)
    Application.delete_env(:arbor_mcp, :request_state)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_mcp, :request_state, value)
        :error -> Application.delete_env(:arbor_mcp, :request_state)
      end
    end)

    :ok
  end

  test "startup: a :mounted_http Runtime takes mrtr: true without any ring" do
    result =
      Runtime.start_link(handler: Handler, transport: :mounted_http, mrtr: true)

    IO.puts("\n[I] Runtime :mounted_http, mrtr: true, no ring -> #{inspect(result)}")
    assert {:ok, pid} = result
    Supervisor.stop(pid)

    # For comparison: the owned HTTP Runtime and HandlerServer refuse to start.
    owned =
      Runtime.start_link(
        handler: Handler,
        transport: :http,
        mrtr: true,
        http: [port: 0, host: {127, 0, 0, 1}]
      )

    IO.puts(
      "[I] Runtime :http (owned listener), mrtr: true, no ring -> #{inspect(owned, limit: 6)}"
    )

    assert {:error, _} = owned

    beam = HandlerServer.start_link(handler: Handler, transport: :test, mrtr: true)
    IO.puts("[I] HandlerServer :test, mrtr: true, no ring -> #{inspect(beam)}")
    assert {:error, {:mrtr_configuration_error, :request_state_not_configured}} = beam
  end

  test "HttpPlug.init/1 with mrtr: true reads the application ring when it runs" do
    error =
      assert_raise ArgumentError, fn ->
        HttpPlug.init(runtime: __MODULE__.Root, mrtr: true)
      end

    IO.puts("\n[I] HttpPlug.init(mrtr: true), no ring -> ** #{inspect(error)}")
    assert error.message =~ "request_state_not_configured"

    Application.put_env(:arbor_mcp, :request_state, @ring)
    assert %{} = HttpPlug.init(runtime: __MODULE__.Root, mrtr: true)
    IO.puts("[I] HttpPlug.init(mrtr: true), ring in app env -> ok")
  end

  test "Plug.Router forward runs HttpPlug.init/1 while the router compiles" do
    source = """
    defmodule #{inspect(__MODULE__)}.CompiledRouter do
      use Plug.Router
      plug :match
      plug :dispatch
      forward "/mcp", to: Arbor.MCP.HttpPlug, init_opts: [runtime: #{inspect(__MODULE__)}.Root, mrtr: true]
    end
    """

    error = assert_raise ArgumentError, fn -> Code.compile_string(source) end

    IO.puts(
      "\n[I] compiling a Plug.Router with forward ..., mrtr: true, no ring -> ** #{inspect(error)}"
    )

    assert error.message =~ "request_state_not_configured"

    Application.put_env(:arbor_mcp, :request_state, @ring)
    assert [{_module, _beam}] = Code.compile_string(source)
    IO.puts("[I] same router with the ring in app env -> compiles")
  end

  describe "per request" do
    setup do
      root =
        start_supervised!(
          {Runtime, handler: Handler, transport: :mounted_http, protocol_mode: :modern_only},
          id: make_ref()
        )

      {:ok, runtime} = Runtime.ref(root)
      %{runtime: runtime}
    end

    test "without mrtr: true the ring is read from the app env when a round is sealed",
         %{runtime: runtime} do
      # Initialized with no ring anywhere.
      opts = HttpPlug.init(runtime: runtime, path: "/mcp", protocol_mode: :modern_only)
      port = serve(opts)

      before = call_ask(port)
      IO.puts("\n[I] plug initialized without ring; request with no ring -> #{before}")
      assert before =~ "error"

      Application.put_env(:arbor_mcp, :request_state, @ring)
      later = call_ask(port)
      IO.puts("[I] same plug, ring put into app env afterwards -> #{String.slice(later, 0, 160)}")
      assert later =~ "\"requestState\":\"mcp-rs1."
    end

    test "with mrtr: true the init check is a snapshot; a request still reads the app env",
         %{runtime: runtime} do
      Application.put_env(:arbor_mcp, :request_state, @ring)

      opts =
        HttpPlug.init(runtime: runtime, path: "/mcp", protocol_mode: :modern_only, mrtr: true)

      port = serve(opts)
      assert call_ask(port) =~ "\"requestState\":\"mcp-rs1."

      Application.delete_env(:arbor_mcp, :request_state)
      later = call_ask(port)
      IO.puts("\n[I] plug initialized with mrtr: true and ring; ring removed -> #{later}")
      assert later =~ "error"
    end
  end

  # Serves options HttpPlug.init/1 already returned, so the test decides
  # when init/1 runs.
  defp serve(opts) do
    listener =
      start_supervised!(
        {Bandit,
         plug: {__MODULE__.Preinitialized, opts}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    port
  end

  defmodule Preinitialized do
    @moduledoc false
    def init(opts), do: opts
    def call(conn, opts), do: Arbor.MCP.HttpPlug.call(conn, opts)
  end

  defp call_ask(port) do
    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: System.unique_integer([:positive]),
        method: "tools/call",
        params: %{
          name: "ask",
          arguments: %{},
          _meta: %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{"form" => %{}}}
          }
        }
      })

    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    {:ok, conn, ref} =
      Mint.HTTP.request(
        conn,
        "POST",
        "/mcp",
        [
          {"content-type", "application/json"},
          {"accept", "application/json, text/event-stream"},
          {"mcp-protocol-version", "2026-07-28"},
          {"mcp-method", "tools/call"},
          {"mcp-name", "ask"}
        ],
        body
      )

    collect(conn, ref, "")
  end

  defp collect(conn, ref, acc) do
    receive do
      message ->
        {:ok, conn, events} = Mint.HTTP.stream(conn, message)
        acc = acc <> for {:data, ^ref, d} <- events, into: "", do: d

        if {:done, ref} in events do
          Mint.HTTP.close(conn)
          acc
        else
          collect(conn, ref, acc)
        end
    after
      5_000 -> flunk("no response: #{acc}")
    end
  end
end
