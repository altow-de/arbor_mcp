defmodule Arbor.MCP.Client.StdioProbeStartupTest do
  @moduledoc """
  A stdio server is a child process the client has just spawned, so the first
  message it reads also waits for it to start: a BEAM under `mix run`, `npx` or
  `uvx` on a cold cache, or any server on a loaded host. That start is not
  evidence of either protocol era. The `server/discover` probe must wait for
  it as long as a legacy `initialize` would, in every protocol mode and on
  every reconnect, while a server that never answers still fails within a
  bounded time and without being downgraded.

  The servers are scripted in `sh` so the start-up delay is the only slow
  part. Each records the method of every message it reads, so a test can
  assert what was and was not sent.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Client

  @moduletag :tmp_dir

  # Longer than the 2 s default `:era_probe_timeout`, well inside the 10 s
  # default `:handshake_timeout`.
  @start_delay_s 3

  # Reads one JSON-RPC message per line and answers as the era in $2 does:
  #
  #   modern  a 2026-07-28-only server: answers server/discover, rejects
  #           initialize with UnsupportedProtocolVersionError
  #   legacy  a 2025-11-25 server: rejects the unknown server/discover with
  #           -32601, answers initialize
  #   mute    reads everything and answers nothing
  #   garbage answers server/discover with a response for another request id
  #
  # $1 is the start-up delay in seconds and $3 the file each method is logged
  # to. When $4 names a file that does not exist yet, the server creates it and
  # starts at once, so only the servers started after it are slow.
  @server_script ~S"""
  if [ -n "$4" ] && [ ! -e "$4" ]; then : > "$4"; else sleep "$1"; fi
  era=$2
  log=$3
  while IFS= read -r line; do
    id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
    case "$line" in
      *'"method":"server/discover"'*) method=server/discover ;;
      *'"method":"initialize"'*) method=initialize ;;
      *'"method":"notifications/initialized"'*) method=notifications/initialized ;;
      *) method=other ;;
    esac
    printf '%s\n' "$method" >> "$log"
    [ -z "$id" ] && continue
    case "$era:$method" in
      modern:server/discover)
        printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"ttlMs":0,"cacheScope":"private","_meta":{"io.modelcontextprotocol/serverInfo":{"name":"scripted-modern","version":"1"}}}}\n' "$id" ;;
      modern:initialize)
        printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32022,"message":"Unsupported protocol version","data":{"supported":["2026-07-28"],"requested":"2025-11-25"}}}\n' "$id" ;;
      legacy:server/discover)
        printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id" ;;
      legacy:initialize)
        printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"scripted-legacy","version":"1"}}}\n' "$id" ;;
      garbage:server/discover)
        printf '{"jsonrpc":"2.0","id":0,"result":{}}\n' ;;
      mute:*|garbage:*) ;;
      *)
        printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id" ;;
    esac
  done
  """

  @modes [:modern_only, :prefer_modern, :prefer_legacy, :legacy_only]

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "a modern server that is slow to start" do
    test "connects in every mode that enables the modern era", %{tmp_dir: tmp_dir} do
      # The same holds for stdio inside the reliability wrapper.
      wrapped = {:wrapped_modern_only, :modern_only, reliability: [circuit_breaker: false]}
      results = connect_concurrently(tmp_dir, :modern, [wrapped | @modes])

      for mode <- [:modern_only, :prefer_modern, :wrapped_modern_only] do
        %{result: result, methods: methods} = results[mode]
        assert {:ok, client} = result, "#{mode}: #{inspect(result)}"
        assert {:ok, "2026-07-28"} = Client.negotiated_version(client)
        assert {:ok, %{"name" => "scripted-modern"}} = Client.server_info(client)
        # Settled by the probe alone: initialize is never sent.
        assert methods == ["server/discover"], "#{mode}: #{inspect(methods)}"
      end

      # prefer_legacy opens with initialize and moves forward only because the
      # server, once started, rejected it as a modern server does.
      %{result: result, methods: methods} = results[:prefer_legacy]
      assert {:ok, client} = result, "prefer_legacy: #{inspect(result)}"
      assert {:ok, "2026-07-28"} = Client.negotiated_version(client)
      assert methods == ["initialize", "server/discover"]

      # Strict legacy never probes, so it fails on the server's own answer.
      %{result: result, methods: methods} = results[:legacy_only]
      assert {:error, {:initialize_error, %{"code" => -32022}}} = result
      assert methods == ["initialize"]
    end
  end

  describe "a legacy server that is slow to start" do
    test "connects in every mode that enables the legacy era", %{tmp_dir: tmp_dir} do
      results = connect_concurrently(tmp_dir, :legacy, @modes)

      # prefer_modern falls back on the server's own answer to the probe, the
      # -32601 it sends once started, not on the time it took to start.
      %{result: result, methods: methods} = results[:prefer_modern]
      assert {:ok, client} = result, "prefer_modern: #{inspect(result)}"
      assert {:ok, "2025-11-25"} = Client.negotiated_version(client)
      assert methods == ["server/discover", "initialize", "notifications/initialized"]

      for mode <- [:prefer_legacy, :legacy_only] do
        %{result: result, methods: methods} = results[mode]
        assert {:ok, client} = result, "#{mode}: #{inspect(result)}"
        assert {:ok, "2025-11-25"} = Client.negotiated_version(client)
        assert methods == ["initialize", "notifications/initialized"], "#{mode}"
      end

      # Strict modern never falls back: it fails on the server's -32601, which
      # it waited for, rather than on a timeout.
      %{result: result, methods: methods} = results[:modern_only]
      assert {:error, {:transport_connect_failed, reason}} = result
      assert reason =~ "{:era_probe_failed, {:json_rpc_error, "
      assert reason =~ "-32601"
      assert methods == ["server/discover"]
    end
  end

  describe "a server that never answers" do
    test "fails within the handshake bound and is never downgraded", %{tmp_dir: tmp_dir} do
      results =
        connect_concurrently(tmp_dir, :mute, [:modern_only, :prefer_modern],
          start_delay_s: 0,
          handshake_timeout: 1_000
        )

      for mode <- [:modern_only, :prefer_modern] do
        %{result: result, methods: methods, elapsed_ms: elapsed_ms} = results[mode]

        # The probe gets the handshake bound, then fails as it did before:
        # a stdio probe timeout is not evidence of a legacy server.
        assert {:error, {:transport_connect_failed, reason}} = result, "#{mode}"
        assert reason == "{:era_probe_failed, {:transport_error, :handshake_timeout}}"
        assert elapsed_ms >= 1_000, "#{mode} gave up after #{elapsed_ms} ms"
        assert elapsed_ms < 5_000, "#{mode} took #{elapsed_ms} ms"
        assert methods == ["server/discover"], "#{mode}: #{inspect(methods)}"
      end
    end

    test "an explicit :era_probe_timeout still bounds the probe", %{tmp_dir: tmp_dir} do
      %{prefer_modern: %{result: result, methods: methods, elapsed_ms: elapsed_ms}} =
        connect_concurrently(tmp_dir, :mute, [:prefer_modern],
          start_delay_s: 0,
          era_probe_timeout: 300
        )

      assert {:error, {:transport_connect_failed, reason}} = result
      assert reason == "{:era_probe_failed, {:transport_error, :handshake_timeout}}"
      # Well short of the 10 s default handshake bound it would get otherwise.
      assert elapsed_ms < 5_000, "took #{elapsed_ms} ms"
      assert methods == ["server/discover"]
    end
  end

  describe "an unusable answer to the probe" do
    test "is not legacy evidence after a slow start", %{tmp_dir: tmp_dir} do
      %{prefer_modern: %{result: result, methods: methods}} =
        connect_concurrently(tmp_dir, :garbage, [:prefer_modern])

      assert {:error, {:transport_connect_failed, reason}} = result
      assert reason =~ "{:era_probe_failed, {:unexpected_response, "
      assert methods == ["server/discover"]
    end
  end

  describe "a reconnect" do
    test "waits for the restarted server to start", %{tmp_dir: tmp_dir} do
      log = Path.join(tmp_dir, "reconnect.log")
      attach_reconnect_events()

      # Only the first server starts at once, so the client connects and
      # only its reconnect meets a slow start.
      {:ok, client} =
        start_client(:modern, :prefer_modern, log, @start_delay_s,
          first_start: Path.join(tmp_dir, "first-start"),
          reconnect: true,
          reconnect_backoff: [initial: 10, max: 40]
        )

      on_exit(fn -> stop_client(client) end)
      assert {:ok, "2026-07-28"} = Client.negotiated_version(client)

      %{transport_state: %{os_pid: os_pid}} = :sys.get_state(client)
      assert {_output, 0} = System.cmd("kill", ["-KILL", "#{os_pid}"])

      assert_receive {:reconnect, :success, ^client}, 15_000
      refute_received {:reconnect, :error, ^client}

      assert {:ok, "2026-07-28"} = Client.negotiated_version(client)
      # A modern ping is a server/discover of its own.
      assert {:ok, _result} = Client.ping(client)
      assert logged_methods(log) == ["server/discover", "server/discover", "server/discover"]
    end
  end

  # Starts one client per mode at the same time, each against its own copy of
  # the scripted server, and returns what each start returned, how long it
  # took, and the methods its server read, by mode. A mode may also be given
  # as `{key, mode, client_opts}`.
  defp connect_concurrently(tmp_dir, era, modes, opts \\ []) do
    {start_delay_s, client_opts} = Keyword.pop(opts, :start_delay_s, @start_delay_s)

    modes
    |> Enum.map(fn
      {key, mode, extra_opts} -> {key, mode, Keyword.merge(client_opts, extra_opts)}
      mode -> {mode, mode, client_opts}
    end)
    |> Enum.map(fn {key, mode, client_opts} ->
      log = Path.join(tmp_dir, "#{era}-#{key}.log")

      task =
        Task.async(fn ->
          Process.flag(:trap_exit, true)
          started = System.monotonic_time(:millisecond)
          result = start_client(era, mode, log, start_delay_s, client_opts)
          elapsed_ms = System.monotonic_time(:millisecond) - started

          # A client must outlive the task that started it.
          with {:ok, client} <- result, do: Process.unlink(client)

          {result, elapsed_ms}
        end)

      {key, log, task}
    end)
    |> Map.new(fn {key, log, task} ->
      {result, elapsed_ms} = Task.await(task, 30_000)
      {key, %{result: result, elapsed_ms: elapsed_ms, methods: methods_read(result, log)}}
    end)
  end

  # A failed start returns once its server has exited, so the log is complete.
  # A connected client's last message, notifications/initialized in the
  # legacy era, may still be unread: a ping answered after it says it was
  # read, and is itself left out.
  defp methods_read({:ok, client}, log) do
    on_exit(fn -> stop_client(client) end)
    assert {:ok, _result} = Client.ping(client)
    log |> logged_methods() |> Enum.drop(-1)
  end

  defp methods_read({:error, _reason}, log), do: logged_methods(log)

  defp start_client(era, mode, log, start_delay_s, client_opts) do
    sh = System.find_executable("sh") || flunk("sh is required")
    File.write!(log, "")
    {first_start, client_opts} = Keyword.pop(client_opts, :first_start, "")

    [
      transport: :stdio,
      command: [
        sh,
        "-c",
        @server_script,
        "scripted-server",
        "#{start_delay_s}",
        "#{era}",
        log,
        first_start
      ],
      protocol_mode: mode,
      health_check_interval: nil,
      reconnect: false
    ]
    |> Keyword.merge(client_opts)
    |> Client.start_link()
  end

  defp logged_methods(log), do: log |> File.read!() |> String.split("\n", trim: true)

  defp attach_reconnect_events do
    test_pid = self()
    handler_id = "stdio-probe-startup-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [[:arbor_mcp, :client, :reconnect, :success], [:arbor_mcp, :client, :reconnect, :error]],
      fn [_, _, _, outcome], _measurements, %{pid: pid}, _config ->
        send(test_pid, {:reconnect, outcome, pid})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp stop_client(client) do
    Client.stop(client)
  catch
    :exit, _reason -> :ok
  end
end
