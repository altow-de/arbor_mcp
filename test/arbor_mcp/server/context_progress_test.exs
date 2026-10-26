defmodule Arbor.MCP.Server.ContextProgressTest do
  @moduledoc """
  A callback reports progress with `Context.report_progress/3` on every
  transport, as TypeScript (`extra.sendNotification`) and Python
  (`ctx.report_progress`) handlers do. Over BEAM, stdio and the test transport
  it used to return `{:error, :request_not_streaming}`.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.{Client, Server}

  defmodule Handler do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    alias Arbor.MCP.Server.Context

    @impl true
    def handle_list_tools(_cursor, state),
      do: {:ok, [%{name: "work", inputSchema: %{type: "object"}}], nil, state}

    @impl true
    def handle_call_tool("work", _args, state) do
      results = for step <- 1..2, do: Context.report_progress(step, 2, "step #{step}")
      {:ok, %{content: [%{type: "text", text: inspect(results)}]}, state}
    end
  end

  defmodule Recorder do
    @moduledoc false
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}
    @impl true
    def handle_ping(state), do: {:ok, %{}, state}
    @impl true
    def handle_list_roots(state), do: {:ok, [], state}
    @impl true
    def handle_create_message(_params, state), do: {:error, "unused", state}

    @impl true
    def handle_progress(_request_id, params, state) do
      send(state.owner, {:progress, params})
      {:ok, state}
    end
  end

  for mode <- [:legacy_only, :modern_only] do
    test "progress reaches the client ahead of the result (#{mode})" do
      {:ok, server} = Server.start_link(transport: :test, handler: Handler)

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_mode: unquote(mode),
          handler: {Recorder, [owner: self()]},
          health_check_interval: nil
        )

      assert {:ok, %{"content" => [%{"text" => "[:ok, :ok]"}]}} =
               Client.call_tool(client, "work", %{}, format: :map, progress_token: "job")

      assert_received {:progress,
                       %{"progressToken" => "job", "progress" => 1, "message" => "step 1"}}

      assert_received {:progress, %{"progress" => 2, "total" => 2}}
    end
  end

  test "without a progress token there's nothing to report against" do
    {:ok, server} = Server.start_link(transport: :test, handler: Handler)

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: :legacy_only,
        health_check_interval: nil
      )

    assert {:ok, %{"content" => [%{"text" => text}]}} =
             Client.call_tool(client, "work", %{}, format: :map)

    assert text =~ "progress_not_requested"
  end
end
