defmodule Arbor.MCP.Authorization.ServerGuardJWTTest do
  @moduledoc """
  The guard checks JWT access tokens locally with `:jwks_uri`, or with any
  `:token_verifier`, and then binds them to the issuer, audience and scopes
  as it does introspected tokens.
  """

  # The OAuth feature flag is global.
  use ExUnit.Case, async: false

  alias Arbor.MCP.Authorization.{JWT, ServerGuard}

  defmodule StaticVerifier do
    @moduledoc false
    @behaviour Arbor.MCP.Authorization.TokenVerifier

    @impl true
    def verify_access_token("good", opts), do: {:ok, Keyword.fetch!(opts, :claims)}
    def verify_access_token("broken", _opts), do: {:error, :store_down}
    def verify_access_token(_token, _opts), do: {:error, :invalid_token}
  end

  @issuer "https://auth.example.com"
  @resource "https://mcp.example.com/mcp"

  setup do
    Application.put_env(:arbor_mcp, :oauth2_enabled, true)
    on_exit(fn -> Application.delete_env(:arbor_mcp, :oauth2_enabled) end)

    key = JWT.generate_rsa_key()
    bypass = Bypass.open()
    jwks = %{"keys" => [key |> JWT.to_public_key() |> JWT.to_map() |> Map.put("kid", "k1")]}

    Bypass.stub(bypass, "GET", "/jwks", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(jwks))
    end)

    config = %{
      jwks_uri: "http://localhost:#{bypass.port}/jwks",
      oauth_http: [allow_insecure_loopback: true],
      expected_issuer: @issuer,
      expected_audience: @resource,
      realm: "mcp"
    }

    %{key: key, config: config}
  end

  defp bearer(key, claims) do
    claims =
      Map.merge(
        %{"iss" => @issuer, "aud" => @resource, "exp" => System.system_time(:second) + 300},
        claims
      )

    {:ok, token} = JWT.sign(claims, key, kid: "k1", typ: "at+jwt")
    [{"authorization", "Bearer " <> token}]
  end

  test "a valid token with the scopes asked for is accepted", %{key: key, config: config} do
    assert {:ok, %{"scope" => "tools:call"}} =
             ServerGuard.authorize(
               bearer(key, %{"scope" => "tools:call"}),
               ["tools:call"],
               config
             )
  end

  test "a token for another issuer or audience, or expired, is refused",
       %{key: key, config: config} do
    for claims <- [
          %{"iss" => "https://other.example.com"},
          %{"aud" => "https://other.example.com/mcp"},
          %{"exp" => System.system_time(:second) - 600}
        ] do
      assert {:error, {401, www_authenticate, _body}} =
               ServerGuard.authorize(bearer(key, claims), [], config)

      assert www_authenticate =~ ~s(error="invalid_token")
    end
  end

  test "a forged token is refused as invalid", %{config: config} do
    assert {:error, {401, www_authenticate, _body}} =
             ServerGuard.authorize(bearer(JWT.generate_rsa_key(), %{}), [], config)

    assert www_authenticate =~ ~s(error="invalid_token")
  end

  test "missing scopes are refused as insufficient", %{key: key, config: config} do
    assert {:error, {403, www_authenticate, _body}} =
             ServerGuard.authorize(bearer(key, %{"scope" => "read"}), ["write"], config)

    assert www_authenticate =~ ~s(error="insufficient_scope")
  end

  test "a JWKS config still needs an issuer and an audience", %{key: key, config: config} do
    for incomplete <- [
          Map.delete(config, :expected_issuer),
          Map.delete(config, :expected_audience)
        ] do
      assert {:error, {500, _, _}} = ServerGuard.authorize(bearer(key, %{}), [], incomplete)
    end
  end

  test "local checks can't be unbound, or mixed with introspection", %{key: key, config: config} do
    unbound = Map.put(config, :legacy_unbound_tokens, true)
    assert {:error, {500, _, _}} = ServerGuard.authorize(bearer(key, %{}), [], unbound)

    mixed =
      Map.merge(config, %{
        introspection_endpoint: "https://auth.example.com/introspect",
        client_id: "rs",
        client_secret: "secret"
      })

    assert {:error, {500, _, _}} = ServerGuard.authorize(bearer(key, %{}), [], mixed)
  end

  test "any token verifier can stand in for introspection" do
    config = %{
      token_verifier:
        {StaticVerifier,
         claims: %{
           "iss" => @issuer,
           "aud" => @resource,
           "exp" => System.system_time(:second) + 60,
           "scope" => "a"
         }},
      expected_issuer: @issuer,
      expected_resource: @resource
    }

    assert {:ok, _claims} =
             ServerGuard.authorize([{"authorization", "Bearer good"}], ["a"], config)

    assert {:error, {401, _, _}} =
             ServerGuard.authorize([{"authorization", "Bearer other"}], [], config)

    assert {:error, {401, www_authenticate, _}} =
             ServerGuard.authorize([{"authorization", "Bearer broken"}], [], config)

    assert www_authenticate =~ "Token validation failed"
  end
end
