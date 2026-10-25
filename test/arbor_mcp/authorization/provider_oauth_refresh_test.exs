defmodule Arbor.MCP.Authorization.ProviderOAuthRefreshTest do
  @moduledoc """
  The default OAuth provider renews an access token with its refresh token,
  before the token expires and when the server rejects it, instead of running
  the browser flow again (which also found the same authorization server and
  stopped with `:auth_loop_detected`).
  """

  use ExUnit.Case, async: true

  @moduletag :oauth

  alias Arbor.MCP.Authorization.Provider.OAuth

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, token_endpoint: "http://localhost:#{bypass.port}/token"}
  end

  defp state(token_endpoint, overrides) do
    struct!(
      %OAuth{
        access_token: "old-token",
        resource_url: "https://mcp.example/mcp",
        auth_config: %{},
        auth_completed: true,
        authorization_server_issuer: "https://auth.example",
        refresh: %{
          refresh_token: "refresh-1",
          token_endpoint: token_endpoint,
          issuer: "https://auth.example",
          auth_methods: ["none"],
          client_info: %{client_id: "client-1"},
          resource: "https://mcp.example/mcp"
        }
      },
      overrides
    )
  end

  defp expect_refresh(bypass, response) do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:token_request, URI.decode_query(body)})

      {status, body} = response

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)
  end

  test "an expiring token is refreshed before a request", %{bypass: bypass} = context do
    expect_refresh(
      bypass,
      {200,
       %{"access_token" => "new-token", "expires_in" => 3600, "refresh_token" => "refresh-2"}}
    )

    expiring = state(context.token_endpoint, expires_at: System.system_time(:second) - 1)

    assert {:ok, "new-token", refreshed} = OAuth.get_token(expiring)

    assert_received {:token_request,
                     %{
                       "grant_type" => "refresh_token",
                       "refresh_token" => "refresh-1",
                       "client_id" => "client-1",
                       "resource" => "https://mcp.example/mcp"
                     }}

    assert refreshed.refresh.refresh_token == "refresh-2"
    assert refreshed.expires_at > System.system_time(:second) + 3_000
  end

  test "a token that is not about to expire is used as is", context do
    fresh = state(context.token_endpoint, expires_at: System.system_time(:second) + 600)
    assert {:ok, "old-token", ^fresh} = OAuth.get_token(fresh)
  end

  test "a rejected token is refreshed instead of rerunning the flow",
       %{bypass: bypass} = context do
    # A server that doesn't rotate refresh tokens: the old one stays.
    expect_refresh(bypass, {200, %{"access_token" => "new-token", "expires_in" => 3600}})

    assert {:ok, "new-token", refreshed} =
             OAuth.handle_unauthorized(
               ~s(Bearer realm="mcp"),
               [],
               state(context.token_endpoint, [])
             )

    assert refreshed.refresh.refresh_token == "refresh-1"
  end

  test "a failed refresh falls back to authenticating again", %{bypass: bypass} = context do
    expect_refresh(bypass, {400, %{"error" => "invalid_grant"}})
    # Discovery for the fallback flow fails at once: nothing listens there.
    rejected =
      state(context.token_endpoint,
        resource_url: "https://127.0.0.1:1/mcp",
        auth_completed: false
      )

    assert {:error, {:oauth_failed, _reason}, _state} =
             OAuth.handle_unauthorized(~s(Bearer realm="mcp"), [], rejected)

    assert_received {:token_request, %{"grant_type" => "refresh_token"}}
  end

  test "tokens stay out of inspect output", context do
    inspected = inspect(state(context.token_endpoint, []))
    refute inspected =~ "old-token"
    refute inspected =~ "refresh-1"
  end
end
