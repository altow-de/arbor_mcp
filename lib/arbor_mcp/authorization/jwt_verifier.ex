defmodule Arbor.MCP.Authorization.JWTVerifier do
  @moduledoc """
  Checks JWT access tokens (RFC 9068) locally, against the authorization
  server's published keys, instead of asking its introspection endpoint.
  Like the JWT bearer handlers used with the C# SDK, a resource server can
  then authorize requests without a round trip per token.

  Turn it on with `jwks_uri:` in `Arbor.MCP.HttpPlug`'s `:auth_config` (or
  `Arbor.MCP.Authorization.ServerGuard`'s config):

      auth_config: %{
        jwks_uri: "https://auth.example.com/.well-known/jwks.json",
        expected_issuer: "https://auth.example.com",
        expected_audience: "https://mcp.example.com/mcp"
      }

  or with `token_verifier: {Arbor.MCP.Authorization.JWTVerifier, opts}`. The
  signature is checked here; the guard then checks the issuer, audience,
  expiry and scopes as it does for an introspected token.

  ## Options

  - `:jwks_uri` - The authorization server's JWKS URL (required). It's
    fetched through the same hardened client as OAuth metadata.
  - `:algorithms` - The signing algorithms accepted (default: the RSA,
    RSA-PSS and ECDSA ones). Symmetric algorithms and `none` are never
    accepted.
  - `:require_at_jwt_typ` - Accept only tokens whose `typ` header is `at+jwt`,
    as RFC 9068 asks (default: `false`, since many authorization servers
    still issue `JWT`). A `typ` other than those two is always refused.
  - `:max_token_bytes` - The longest token checked (default: 16_384).
  - `:jwks_cache_ttl_ms`, `:jwks_min_refresh_ms`, `:jwks_max_stale_ms` - How
    long a key set is kept (10 minutes), how often a token signed with an
    unknown key may fetch it again (1 minute), and how long the last set is
    used while fetching fails (1 hour).
  - `:oauth_http` - Options for the fetch, as for OAuth metadata.

  A `scp` claim, which some servers use instead of `scope`, is read as the
  token's scopes.
  """

  @behaviour Arbor.MCP.Authorization.TokenVerifier

  alias Arbor.MCP.Authorization.{JWKSCache, JWT}

  @asymmetric ~w(RS256 RS384 RS512 PS256 PS384 PS512 ES256 ES384 ES512)
  @at_jwt ["at+jwt", "application/at+jwt"]

  @impl true
  def verify_access_token(token, opts) when is_binary(token) and is_list(opts) do
    uri = Keyword.fetch!(opts, :jwks_uri)

    with :ok <- within_size(token, Keyword.get(opts, :max_token_bytes, 16_384)),
         {:ok, header} <- header(token),
         {:ok, alg} <- algorithm(header, Keyword.get(opts, :algorithms, @asymmetric)),
         :ok <- typ(header, Keyword.get(opts, :require_at_jwt_typ, false)),
         {:ok, keys} <- key_set(JWKSCache.keys(uri, opts)),
         {:ok, claims} <- verify(token, alg, header["kid"], keys, uri, opts) do
      {:ok, with_scope(claims)}
    end
  end

  def verify_access_token(_token, _opts), do: {:error, :invalid_token}

  defp within_size(token, max) when byte_size(token) <= max, do: :ok
  defp within_size(_token, _max), do: {:error, :invalid_token}

  defp header(token) do
    case JWT.peek_header(token) do
      {:ok, %{} = header} -> {:ok, header}
      _not_a_jws -> {:error, :invalid_token}
    end
  end

  defp algorithm(%{"alg" => alg}, allowed) when is_binary(alg) do
    if alg in allowed and alg in @asymmetric, do: {:ok, alg}, else: {:error, :invalid_token}
  end

  defp algorithm(_header, _allowed), do: {:error, :invalid_token}

  defp typ(header, require_at_jwt?) do
    case header |> Map.get("typ") |> normalize_typ() do
      typ when typ in @at_jwt -> :ok
      typ when typ in [nil, "jwt"] and not require_at_jwt? -> :ok
      _other -> {:error, :invalid_token}
    end
  end

  defp normalize_typ(typ) when is_binary(typ), do: String.downcase(typ)
  defp normalize_typ(_typ), do: nil

  defp key_set({:ok, keys}), do: {:ok, keys}
  defp key_set({:error, reason}), do: {:error, {:jwks_unavailable, reason}}

  # A token naming a key the set lacks fetches the set again, once.
  defp verify(token, alg, kid, keys, uri, opts) do
    case check(token, alg, signing_keys(keys, kid, alg)) do
      {:ok, claims} ->
        {:ok, claims}

      :no_key when is_binary(kid) ->
        with {:ok, keys} <- key_set(JWKSCache.refresh(uri, opts)) do
          case check(token, alg, signing_keys(keys, kid, alg)) do
            {:ok, claims} -> {:ok, claims}
            _no_key_or_invalid -> {:error, :invalid_token}
          end
        end

      _no_key_or_invalid ->
        {:error, :invalid_token}
    end
  end

  defp signing_keys(keys, kid, alg) do
    Enum.filter(keys, fn jwk ->
      {_modules, fields} = JOSE.JWK.to_map(jwk)

      Map.get(fields, "use", "sig") == "sig" and Map.get(fields, "alg", alg) == alg and
        (is_nil(kid) or Map.get(fields, "kid") == kid)
    end)
  end

  defp check(_token, _alg, []), do: :no_key

  defp check(token, alg, keys) do
    Enum.find_value(keys, :invalid, fn jwk ->
      case JOSE.JWK.verify_strict(token, [alg], jwk) do
        {true, payload, _jws} ->
          case Jason.decode(payload) do
            {:ok, %{} = claims} -> {:ok, claims}
            _not_claims -> nil
          end

        {false, _payload, _jws} ->
          nil
      end
    end)
  rescue
    _malformed -> :invalid
  end

  defp with_scope(%{"scope" => scope} = claims) when is_binary(scope), do: claims

  defp with_scope(%{"scp" => scopes} = claims) when is_list(scopes) do
    if Enum.all?(scopes, &is_binary/1),
      do: Map.put(claims, "scope", Enum.join(scopes, " ")),
      else: claims
  end

  defp with_scope(%{"scp" => scope} = claims) when is_binary(scope),
    do: Map.put(claims, "scope", scope)

  defp with_scope(claims), do: claims
end
