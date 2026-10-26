defmodule Arbor.MCP.Client.ProgressTimeoutTest do
  @moduledoc """
  Like the TypeScript SDK's `resetTimeoutOnProgress` and `maxTotalTimeout`,
  `reset_timeout_on_progress: true` makes `:timeout` the time a request may
  go without progress, and `:max_total_timeout` caps it.

  These tests are about timing, so the tool sleeps between progress updates.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.{Client, Server}

  defmodule Handler do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    alias Arbor.MCP.Server
    alias Arbor.MCP.Server.Context

    @impl true
    def handle_list_tools(_cursor, state),
      do: {:ok, [%{name: "work", inputSchema: %{type: "object"}}], nil, state}

    # Reports progress every `every` ms for `steps` steps, then waits `then` ms.
    @impl true
    def handle_call_tool("work", args, state) do
      steps = Map.get(args, "steps", 1)
      server = args |> Map.fetch!("server") |> String.to_charlist() |> :erlang.list_to_pid()

      for step <- 1..steps do
        Process.sleep(Map.fetch!(args, "every"))
        :ok = Server.notify_progress(server, Context.progress_token(), step, steps)
      end

      Process.sleep(Map.get(args, "then", 0))
      text = if args["echo_token"], do: Context.progress_token(), else: "done"
      {:ok, %{content: [%{type: "text", text: text}]}, state}
    end
  end

  defp client(mode, opts \\ []) do
    {:ok, server} = Server.start_link(transport: :test, handler: Handler)
    Process.put(:server, server)

    {:ok, client} =
      Client.start_link(
        [
          transport: :test,
          server: server,
          protocol_mode: mode,
          health_check_interval: nil
        ] ++ opts
      )

    client
  end

  # The tool reports progress through the server it runs in.
  defp work(client, args, opts) do
    server = Process.get(:server) |> :erlang.pid_to_list() |> to_string()
    Client.call_tool(client, "work", Map.put(args, "server", server), [format: :map] ++ opts)
  end

  for mode <- [:legacy_only, :modern_only] do
    test "progress keeps a request alive past its timeout (#{mode})" do
      client = client(unquote(mode))
      args = %{"steps" => 6, "every" => 100}

      assert {:ok, %{"content" => [%{"text" => "done"}]}} =
               work(client, args, timeout: 400, reset_timeout_on_progress: true)

      assert {:error, :timeout} = work(client, args, timeout: 400)
    end
  end

  test "a request that goes its timeout without progress times out" do
    client = client(:legacy_only)
    started = System.monotonic_time(:millisecond)

    assert {:error, :timeout} =
             work(client, %{"every" => 50, "then" => 2_000},
               timeout: 300,
               reset_timeout_on_progress: true
             )

    assert System.monotonic_time(:millisecond) - started < 1_500
  end

  test "max_total_timeout caps a request however much progress it makes" do
    client = client(:legacy_only)

    assert {:error, :timeout} =
             work(client, %{"steps" => 20, "every" => 50},
               timeout: 300,
               reset_timeout_on_progress: true,
               max_total_timeout: 400
             )
  end

  test "the client's default timeout applies when the call gives none" do
    client = client(:legacy_only, timeout: 300)
    started = System.monotonic_time(:millisecond)

    assert {:error, :timeout} =
             work(client, %{"every" => 50, "then" => 3_000}, reset_timeout_on_progress: true)

    assert System.monotonic_time(:millisecond) - started < 2_000
  end

  test "a zero timeout times out at once" do
    client = client(:legacy_only)

    assert {:error, :timeout} =
             work(client, %{"every" => 1_000}, timeout: 0, reset_timeout_on_progress: true)
  end

  test "a settled request leaves no timer behind" do
    client = client(:legacy_only)

    assert {:ok, _} =
             work(client, %{"every" => 10}, timeout: 60_000, reset_timeout_on_progress: true)

    assert :sys.get_state(client).progress_timeouts == %{}
  end

  # The server reports against the token the call gave, so it must be the
  # one the client tracks, not a second one it generated.
  test "a token given under an atom key is the one tracked" do
    client = client(:legacy_only)

    assert {:ok, %{"content" => [%{"text" => "job-1"}]}} =
             work(client, %{"steps" => 6, "every" => 100, "echo_token" => true},
               timeout: 400,
               reset_timeout_on_progress: true,
               meta: %{progressToken: "job-1"}
             )
  end

  test "invalid options are refused before anything is sent" do
    client = client(:legacy_only)

    assert_raise ArgumentError, ~r/reset_timeout_on_progress/, fn ->
      work(client, %{"every" => 0}, reset_timeout_on_progress: :yes)
    end

    assert_raise ArgumentError, ~r/max_total_timeout/, fn ->
      work(client, %{"every" => 0}, reset_timeout_on_progress: true, max_total_timeout: -1)
    end
  end
end
