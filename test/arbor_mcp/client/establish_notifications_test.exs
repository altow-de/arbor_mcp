defmodule Arbor.MCP.Client.EstablishNotificationsTest do
  @moduledoc """
  A server may send a notification, such as a log message, before it answers
  `initialize` or `server/discover`. The client used to take it for the
  answer and fail to connect.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Client

  defmodule ChattyTransport do
    @moduledoc false
    @behaviour Arbor.MCP.Transport

    @impl true
    def connect(opts), do: {:ok, %{opts: opts}}

    @impl true
    def send_message(message, state) do
      request = Jason.decode!(message)
      queue(request)
      {:ok, state}
    end

    defp queue(%{"method" => method, "id" => id})
         when method in ["server/discover", "initialize"] do
      log = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/message",
        "params" => %{"level" => "info", "data" => "starting"}
      }

      send(self(), {:chatty, Jason.encode!(log)})

      send(
        self(),
        {:chatty, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result(method)})}
      )
    end

    defp queue(_other), do: :ok

    defp result("server/discover") do
      %{
        "resultType" => "complete",
        "supportedVersions" => ["2026-07-28"],
        "capabilities" => %{},
        "ttlMs" => 0,
        "cacheScope" => "private",
        "_meta" => %{
          "io.modelcontextprotocol/serverInfo" => %{"name" => "chatty", "version" => "1"}
        }
      }
    end

    defp result("initialize") do
      %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "serverInfo" => %{"name" => "chatty", "version" => "1"}
      }
    end

    @impl true
    def receive_message(state) do
      receive do
        {:chatty, message} -> {:ok, message, state}
      end
    end

    def receive_message(state, timeout) do
      receive do
        {:chatty, message} -> {:ok, message, state}
      after
        timeout -> {:error, {:timeout_error, :receive_timeout}}
      end
    end

    @impl true
    def connected?(_state), do: true

    @impl true
    def close(_state), do: :ok
  end

  for mode <- [:modern_only, :legacy_only] do
    test "a notification before the answer doesn't stop the client connecting (#{mode})" do
      assert {:ok, client} =
               Client.start_link(
                 transport: ChattyTransport,
                 protocol_mode: unquote(mode),
                 health_check_interval: nil,
                 reconnect: false
               )

      assert {:ok, %{"name" => "chatty"}} = Client.server_info(client)
    end
  end
end
