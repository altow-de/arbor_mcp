defmodule Arbor.MCP.Transport.HTTPTrustStoreTest do
  # Sets :arbor_mcp application env, so it cannot run concurrently with others.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.MCP.Authorization.PinnedHTTPClient, as: AuthorizationPinnedHTTPClient
  alias Arbor.MCP.Internal.PinnedHTTPClient
  alias Arbor.MCP.Transport.HTTP
  alias Arbor.MCP.Transport.HTTP.{BoundedClient, BoundedStream, LegacySSE}

  @loopback {127, 0, 0, 1}

  setup do
    previous = Application.fetch_env(:arbor_mcp, :cacerts)
    key = {__MODULE__, make_ref()}
    Application.put_env(:arbor_mcp, :cacerts, loader: fn -> [] end, cache_key: key)

    on_exit(fn ->
      :persistent_term.erase(key)

      case previous do
        {:ok, value} -> Application.put_env(:arbor_mcp, :cacerts, value)
        :error -> Application.delete_env(:arbor_mcp, :cacerts)
      end
    end)
  end

  test "an HTTPS request fails closed with an error when the trust store is unavailable" do
    {:ok, state} = HTTP.connect(url: "https://127.0.0.1:1", endpoint: "/mcp", use_sse: false)
    message = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

    capture_log(fn ->
      assert HTTP.send_message(message, state) ==
               {:error, {:trust_store_unavailable, :no_certificates}}
    end)
  end

  # Without :cacerts, Mint loads the OS store itself and falls back to CAStore
  # without the fallback: :castore opt-in. Every client that connects with
  # Mint must fail closed instead, before it opens a connection.
  describe "an HTTPS connection without CA options fails closed before connecting" do
    setup do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: @loopback])
      {:ok, port} = :inet.port(listener)
      on_exit(fn -> :gen_tcp.close(listener) end)
      %{listener: listener, port: port}
    end

    test "BoundedClient", %{listener: listener, port: port} do
      capture_log(fn ->
        assert BoundedClient.request(
                 :post,
                 "https://127.0.0.1:#{port}/mcp",
                 [],
                 "application/json",
                 "{}",
                 connect_timeout: 1_000,
                 request_timeout: 1_000,
                 max_request_bytes: 1_024,
                 max_response_bytes: 1_024,
                 transport_opts: []
               ) == {:error, {:trust_store_unavailable, :no_certificates}}
      end)

      refute_connected(listener)
    end

    test "BoundedStream", %{listener: listener, port: port} do
      capture_log(fn ->
        assert {:ok, worker} =
                 BoundedStream.start(self(), :get, "https://127.0.0.1:#{port}/mcp", [], nil,
                   connect_timeout: 1_000,
                   max_response_bytes: 1_024
                 )

        assert_receive {:bounded_http, ^worker,
                        {:error, {:trust_store_unavailable, :no_certificates}}},
                       1_000
      end)

      refute_connected(listener)
    end

    test "the legacy HTTP+SSE transport", %{listener: listener, port: port} do
      capture_log(fn ->
        assert LegacySSE.connect(
                 url: "https://127.0.0.1:#{port}",
                 timeout: 1_000,
                 stream_handshake_timeout: 1_000
               ) == {:error, {:sse_error, {:trust_store_unavailable, :no_certificates}}}
      end)

      refute_connected(listener)
    end

    test "the OAuth metadata and JSON Schema fetch client", %{listener: listener, port: port} do
      capture_log(fn ->
        assert PinnedHTTPClient.get(URI.parse("https://127.0.0.1:#{port}/"), @loopback,
                 connect_timeout_ms: 1_000,
                 request_timeout_ms: 1_000,
                 max_response_bytes: 1_024,
                 request_headers: []
               ) == {:error, :fetch_failed}
      end)

      refute_connected(listener)
    end

    test "the OAuth request client", %{listener: listener, port: port} do
      capture_log(fn ->
        assert AuthorizationPinnedHTTPClient.request(
                 :get,
                 URI.parse("https://127.0.0.1:#{port}/"),
                 @loopback,
                 {"", []},
                 [ssl: []],
                 connect_timeout_ms: 1_000,
                 request_timeout_ms: 1_000,
                 max_header_bytes: 65_536,
                 max_response_bytes: 1_024
               ) == {:error, {:trust_store_unavailable, :no_certificates}}
      end)

      refute_connected(listener)
    end
  end

  defp refute_connected(listener) do
    assert :gen_tcp.accept(listener, 0) == {:error, :timeout}
  end
end
