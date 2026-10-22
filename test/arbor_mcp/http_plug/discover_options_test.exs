defmodule Arbor.MCP.HttpPlug.DiscoverOptionsTest do
  # The instructions and cache hints of server/discover on a Runtime-mounted
  # Arbor.MCP.HttpPlug: set on the mount, in the HTTP options of a Runtime
  # that owns its listener, or for one request by a host plug that passes
  # them to HttpPlug.call/2. The tests send real HTTP requests to Bandit with
  # Arbor.MCP.Client.
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.Runtime

  defmodule AppHandler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_opts), do: {:ok, %{}}
  end

  # A host plug in front of Arbor.MCP.HttpPlug that sets the discovery
  # options for each request from the person the request comes from, as a
  # gateway does after it has authenticated the request.
  defmodule PersonPlug do
    @behaviour Plug

    @impl true
    def init(opts), do: Arbor.MCP.HttpPlug.init(opts)

    @impl true
    def call(conn, opts) do
      per_request =
        case Plug.Conn.get_req_header(conn, "x-person") do
          ["ada"] ->
            %{
              instructions: "Ada reaches the wiki.",
              discover_ttl_ms: 300_000,
              discover_cache_scope: :private
            }

          ["bob"] ->
            %{
              instructions: "Bob reaches the notes.",
              discover_ttl_ms: 0,
              discover_cache_scope: "private"
            }

          _anyone ->
            %{}
        end

      Arbor.MCP.HttpPlug.call(conn, Map.merge(opts, per_request))
    end
  end

  describe "server/discover through a host plug" do
    setup do
      {:ok, url: start_app(PersonPlug, [])}
    end

    test "carries the instructions and cache hints set for each request", %{url: url} do
      ada = start_client(url, "ada")
      bob = start_client(url, "bob")

      assert {:ok, ada_result} = Client.discover(ada, format: :map)
      assert {:ok, bob_result} = Client.discover(bob, format: :map)

      assert %{
               "instructions" => "Ada reaches the wiki.",
               "ttlMs" => 300_000,
               "cacheScope" => "private"
             } = ada_result

      assert %{
               "instructions" => "Bob reaches the notes.",
               "ttlMs" => 0,
               "cacheScope" => "private"
             } = bob_result
    end

    test "keeps the defaults when a request sets none", %{url: url} do
      client = start_client(url, nil)

      assert {:ok, result} = Client.discover(client, format: :map)

      assert result["ttlMs"] == 3_600_000
      assert result["cacheScope"] == "public"
      refute Map.has_key?(result, "instructions")
    end
  end

  test "mount options set the instructions and cache hints of every request" do
    url =
      start_app(Arbor.MCP.HttpPlug,
        instructions: "Every person reaches the same apps.",
        discover_ttl_ms: 60_000,
        discover_cache_scope: :private
      )

    client = start_client(url, nil)

    assert {:ok,
            %{
              "instructions" => "Every person reaches the same apps.",
              "ttlMs" => 60_000,
              "cacheScope" => "private"
            }} = Client.discover(client, format: :map)
  end

  test "the HTTP options of a runtime-owned listener set them for every request" do
    url =
      start_owned_app(
        instructions: "Every person reaches the same apps.",
        discover_ttl_ms: 60_000,
        discover_cache_scope: :private
      )

    client = start_client(url, nil)

    assert {:ok,
            %{
              "instructions" => "Every person reaches the same apps.",
              "ttlMs" => 60_000,
              "cacheScope" => "private"
            }} = Client.discover(client, format: :map)
  end

  describe "invalid discovery options" do
    test "are rejected when the plug is initialized" do
      for invalid <- [
            [discover_ttl_ms: -1],
            [discover_ttl_ms: 1.5],
            [discover_cache_scope: "shared"],
            [discover_cache_scope: :team],
            [instructions: :not_text]
          ] do
        assert_raise ArgumentError, fn ->
          Arbor.MCP.HttpPlug.init([runtime: :some_runtime] ++ invalid)
        end
      end
    end

    test "are rejected for one request before it is dispatched" do
      opts = Arbor.MCP.HttpPlug.init(runtime: :some_runtime)

      for invalid <- [
            %{discover_ttl_ms: -1},
            %{discover_cache_scope: "shared"},
            %{instructions: 42}
          ] do
        conn = Plug.Test.conn(:post, "/mcp", "{}")

        assert_raise ArgumentError, fn ->
          Arbor.MCP.HttpPlug.call(conn, Map.merge(opts, invalid))
        end
      end
    end
  end

  defp start_app(plug, plug_opts) do
    runtime =
      start_supervised!(
        {Runtime,
         handler: AppHandler,
         handler_args: [],
         transport: :mounted_http,
         execution: :stateless,
         max_concurrency: 4},
        id: make_ref()
      )

    listener =
      start_supervised!(
        {Bandit,
         plug:
           {plug, [runtime: runtime, path: "/mcp", protocol_mode: :prefer_modern] ++ plug_opts},
         ip: {127, 0, 0, 1},
         port: 0},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    "http://127.0.0.1:#{port}/mcp"
  end

  # A Runtime with `transport: :http` starts its own Bandit listener and
  # mounts the plug with the plug options among its HTTP options.
  defp start_owned_app(http_opts) do
    runtime =
      start_supervised!(
        {Runtime,
         handler: AppHandler,
         handler_args: [],
         transport: :http,
         execution: :stateless,
         max_concurrency: 4,
         http:
           [
             adapter: :bandit,
             host: {127, 0, 0, 1},
             port: 0,
             path: "/mcp",
             protocol_mode: :prefer_modern,
             listener_options: [startup_log: false]
           ] ++ http_opts},
        id: make_ref()
      )

    {:ok, %{listener: listener}} = Arbor.MCP.Server.Transport.http_listener(runtime)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    "http://127.0.0.1:#{port}/mcp"
  end

  defp start_client(url, person) do
    headers = if person, do: [{"x-person", person}], else: []

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: url,
        headers: headers,
        protocol_mode: :modern_only,
        protocol_version: "2026-07-28",
        use_sse: false,
        security: %{origin: nil},
        health_check_interval: nil,
        reconnect: false
      )

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
