defmodule Arbor.MCP.Authorization.TokenVerifier do
  @moduledoc """
  Checks a bearer access token for `Arbor.MCP.Authorization.ServerGuard`, as
  the TypeScript SDK's `OAuthTokenVerifier` does for `requireBearerAuth`.

  Configure one with `token_verifier: {module, opts}` in the guard's (or
  `Arbor.MCP.HttpPlug`'s) `:auth_config`. A verifier returns the token's
  claims, and the guard still checks their `iss`, `aud`, `exp` and `nbf`
  against its configuration, and their `scope` against the request.
  `Arbor.MCP.Authorization.JWTVerifier` checks JWT access tokens against the
  authorization server's JWKS; without a verifier the guard uses token
  introspection.

      defmodule MyApp.TokenVerifier do
        @behaviour Arbor.MCP.Authorization.TokenVerifier

        @impl true
        def verify_access_token(token, _opts) do
          case MyApp.Tokens.lookup(token) do
            {:ok, claims} -> {:ok, claims}
            :error -> {:error, :invalid_token}
          end
        end
      end
  """

  @doc """
  Returns the claims of a token it accepts. `{:error, :invalid_token}` is
  answered with `401 invalid_token`; any other error means the token
  couldn't be checked (a key set that couldn't be fetched, say), and is
  answered without detail.
  """
  @callback verify_access_token(token :: String.t(), opts :: keyword()) ::
              {:ok, claims :: map()} | {:error, :invalid_token} | {:error, term()}
end
