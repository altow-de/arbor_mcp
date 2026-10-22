defmodule Arbor.MCP.Authorization.MetadataFetchCACertsTest do
  # Sets :arbor_mcp application env, so it cannot run concurrently with others.
  use ExUnit.Case, async: false

  alias Arbor.MCP.Authorization.{FullOAuthFlow, MetadataFetcher}

  @public_v4 {93, 184, 216, 34}
  @call_ca [<<"call CA">>]
  @fetch_ca [<<"metadata fetch CA">>]
  @oauth_ca [<<"oauth_http CA">>]

  setup do
    for key <- [:oauth_metadata_fetch, :oauth_http] do
      previous = Application.fetch_env(:arbor_mcp, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:arbor_mcp, key, value)
          :error -> Application.delete_env(:arbor_mcp, key)
        end
      end)
    end

    Application.delete_env(:arbor_mcp, :oauth_metadata_fetch)
    Application.delete_env(:arbor_mcp, :oauth_http)
    :ok
  end

  describe "MetadataFetcher :cacerts" do
    test "is passed to the HTTP client" do
      assert {:ok, _response} = fetch(cacerts: @call_ca)
      assert_received {:cacerts, @call_ca}
    end

    test "defaults to nil, so the client uses the default trust store" do
      assert {:ok, _response} = fetch([])
      assert_received {:cacerts, nil}
    end

    test "can be set in :oauth_metadata_fetch and overridden per call" do
      Application.put_env(:arbor_mcp, :oauth_metadata_fetch, cacerts: @fetch_ca)
      assert {:ok, _response} = fetch([])
      assert_received {:cacerts, @fetch_ca}

      assert {:ok, _response} = fetch(cacerts: @call_ca)
      assert_received {:cacerts, @call_ca}
    end

    # :oauth_http may name only the authorization server's CA, while metadata
    # also comes from the resource server and from issuers' JWKS hosts.
    test "is not taken from :oauth_http" do
      Application.put_env(:arbor_mcp, :oauth_http, cacerts: @oauth_ca)
      assert {:ok, _response} = fetch([])
      assert_received {:cacerts, nil}
    end

    test "rejects a value that is not a non-empty list of certificates" do
      for invalid <- [[], "ca.pem", [:not_a_certificate]] do
        assert fetch(cacerts: invalid) == {:error, {:metadata_fetch_error, :invalid_options}}
      end

      refute_received {:cacerts, _cacerts}
    end
  end

  test "a FullOAuthFlow passes metadata_fetch: [cacerts: ...] to its metadata fetches" do
    FullOAuthFlow.execute(
      flow_config(oauth_http: [cacerts: @oauth_ca], metadata_fetch: [cacerts: @fetch_ca])
    )

    assert_received {:cacerts, @fetch_ca}
    refute_received {:cacerts, @oauth_ca}
  end

  defp fetch(opts) do
    MetadataFetcher.fetch(
      "https://metadata.example/document",
      Keyword.merge([dns_resolver: public_dns(), http_client: recording_client()], opts)
    )
  end

  defp flow_config(overrides) do
    metadata_fetch =
      Keyword.merge(
        [dns_resolver: public_dns(), http_client: recording_client(404)],
        Keyword.get(overrides, :metadata_fetch, [])
      )

    %{
      resource_url: "https://mcp.example/mcp",
      oauth_http: Keyword.fetch!(overrides, :oauth_http),
      metadata_fetch: metadata_fetch
    }
  end

  defp public_dns, do: fn _host, _timeout -> {:ok, [@public_v4]} end

  defp recording_client(status \\ 200) do
    test = self()

    fn _uri, _address, opts ->
      send(test, {:cacerts, opts[:cacerts]})
      {:ok, %{status: status, headers: [{"content-type", "application/json"}], body: "{}"}}
    end
  end
end
