defmodule Arbor.MCP.Server.AuthInfo do
  @moduledoc """
  The validated access token of the request being handled.

  Read it inside a callback with `Arbor.MCP.Server.Context.auth_info/0`. It
  matches the `authInfo` the TypeScript SDK passes to handlers and the access
  token Python's `get_access_token()` returns.

  `Arbor.MCP.HttpPlug` fills it in when `oauth_enabled: true` validates a bearer
  token. A host that authenticates requests in its own plug can call
  `Arbor.MCP.HttpPlug.put_auth_info/2` before the MCP plug instead.

  Fields:

  - `:token` - the bearer token, for token exchange (RFC 8693). Don't pass it
    to another service: MCP forbids token passthrough. `inspect/1` leaves it
    out.
  - `:client_id` - the OAuth client the token was issued to.
  - `:subject` - the `sub` claim, the user or service the token represents.
  - `:scopes` - the granted scopes.
  - `:expires_at` - expiry in seconds since the Unix epoch, if known.
  - `:audience` - the `aud` claim, the resource the token is valid for.
  - `:claims` - every claim or introspection field, as received.
  """

  @derive {Inspect, except: [:token]}
  defstruct [:token, :client_id, :subject, :expires_at, :audience, scopes: [], claims: %{}]

  @type t :: %__MODULE__{
          token: String.t() | nil,
          client_id: String.t() | nil,
          subject: String.t() | nil,
          scopes: [String.t()],
          expires_at: integer() | nil,
          audience: String.t() | [String.t()] | nil,
          claims: map()
        }

  @doc """
  Builds the auth info from a bearer token and its validated claims or
  introspection response (RFC 7662).
  """
  @spec from_claims(String.t() | nil, map()) :: t()
  def from_claims(token, claims) when is_map(claims) do
    %__MODULE__{
      token: token,
      client_id: claim(claims, "client_id", :client_id),
      subject: claim(claims, "sub", :sub),
      scopes: scopes(claim(claims, "scope", :scope) || claim(claims, "scp", :scp)),
      expires_at: expires_at(claim(claims, "exp", :exp)),
      audience: claim(claims, "aud", :aud),
      claims: claims
    }
  end

  defp claim(claims, key, atom), do: Map.get(claims, key) || Map.get(claims, atom)

  defp scopes(scope) when is_binary(scope), do: String.split(scope, " ", trim: true)
  defp scopes(scopes) when is_list(scopes), do: Enum.filter(scopes, &is_binary/1)
  defp scopes(_scope), do: []

  defp expires_at(exp) when is_integer(exp), do: exp
  defp expires_at(_exp), do: nil
end
