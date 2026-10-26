defmodule Arbor.MCP.Client.HTTPPostStreamEventsTest do
  @moduledoc """
  In the legacy Streamable HTTP revisions a server may answer a POST with an
  event stream that carries the request's notifications, and its own
  requests, ahead of the response. The client read the whole body and joined
  every event's data into one JSON document, so a notification ahead of the
  response left the call waiting until it timed out, and a request the
  server waited on could never be answered.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Client

  defmodule ProgressHandler do
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
    def handle_progress(request_id, params, state) do
      send(state.owner, {:progress, request_id, params})
      {:ok, state}
    end
  end

  @initialize_result %{
    "protocolVersion" => "2025-11-25",
    "capabilities" => %{"tools" => %{}},
    "serverInfo" => %{"name" => "stub", "version" => "1"}
  }

  # `answer_call` gets the tools/call request and the conn, and sends the
  # POST's response itself.
  defp start(answer_call, opts \\ []) do
    bypass = Bypass.open()
    test = self()

    Bypass.stub(bypass, "GET", "/mcp", &Plug.Conn.resp(&1, 405, ""))
    Bypass.stub(bypass, "DELETE", "/mcp", &Plug.Conn.resp(&1, 200, ""))

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode!(body) do
        %{"method" => "initialize", "id" => id} ->
          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "s1")
          |> answer_initialize(id, Keyword.get(opts, :initialize, :json))

        %{"method" => "tools/call"} = request ->
          answer_call.(request, conn)

        %{"id" => id} = response when not is_map_key(response, "method") ->
          send(test, {:client_answered, id, response})
          Plug.Conn.resp(conn, 202, "")

        _notification ->
          Plug.Conn.resp(conn, 202, "")
      end
    end)

    {:ok, client} =
      Client.start_link(
        [
          transport: :http,
          url: "http://127.0.0.1:#{bypass.port}/mcp",
          protocol_mode: :legacy_only,
          protocol_version: "2025-11-25",
          use_sse: false,
          handler: {ProgressHandler, [owner: test]},
          health_check_interval: nil,
          reconnect: false
        ] ++ Keyword.get(opts, :client, [])
      )

    client
  end

  defp answer_initialize(conn, id, :json) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(response(id, @initialize_result)))
  end

  defp answer_initialize(conn, id, :stream_with_log) do
    log = notification("notifications/message", %{"level" => "info", "data" => "starting"})

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.resp(200, event(log) <> event(response(id, @initialize_result)))
  end

  defp open_stream(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_chunked(200)
  end

  defp event(message, fields \\ ""), do: "#{fields}data: #{Jason.encode!(message)}\n\n"

  defp notification(method, params),
    do: %{"jsonrpc" => "2.0", "method" => method, "params" => params}

  defp response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp done(id), do: response(id, %{"content" => [%{"type" => "text", "text" => "done"}]})

  defp progress(token, n),
    do: notification("notifications/progress", %{"progressToken" => token, "progress" => n})

  defp call(client) do
    Task.async(fn ->
      Client.call_tool(client, "slow", %{},
        timeout: 5_000,
        format: :map,
        meta: %{"progressToken" => "t1"}
      )
    end)
  end

  # Sends `first` on the POST stream, then the response once released.
  defp hold_after(first) do
    test = self()

    fn %{"id" => id}, conn ->
      conn = open_stream(conn)
      {:ok, conn} = Plug.Conn.chunk(conn, event(first))
      send(test, {:holding, self()})

      # A watchdog well past the test's own timeouts.
      receive do
        :release -> :ok
      after
        30_000 -> :ok
      end

      {:ok, conn} = Plug.Conn.chunk(conn, event(done(id)))
      conn
    end
  end

  test "progress reaches the handler while the call is still open" do
    client = start(hold_after(progress("t1", 1)))

    task = call(client)
    assert_receive {:holding, server}, 5_000
    assert_receive {:progress, _request_id, %{"progress" => 1}}, 5_000
    send(server, :release)

    assert {:ok, %{"content" => [%{"text" => "done"}]}} = Task.await(task)
  end

  test "a request the server waits on is answered while the stream is open" do
    client =
      start(
        hold_after(%{
          "jsonrpc" => "2.0",
          "id" => "server-ping",
          "method" => "ping",
          "params" => %{}
        })
      )

    task = call(client)
    assert_receive {:holding, server}, 5_000
    assert_receive {:client_answered, "server-ping", %{"result" => %{}}}, 5_000
    send(server, :release)

    assert {:ok, %{"content" => [%{"text" => "done"}]}} = Task.await(task)
  end

  test "an id on a handed-over event still counts for resumption" do
    client =
      start(fn %{"id" => id}, conn ->
        body =
          "id: e0\nretry: 250\ndata: \n\n" <>
            event(progress("t1", 1), "id: e1\n") <> event(done(id))

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, body)
      end)

    assert {:ok, _} = Task.await(call(client))
    assert_received {:progress, _request_id, _params}

    transport = :sys.get_state(client).transport_state
    assert transport.last_event_id == "e1"
    assert transport.retry_delay == 250
  end

  # Its declared length is above the limit; what the client keeps isn't.
  test "a stream of handed-over messages isn't limited by :max_response_bytes" do
    client =
      start(
        fn %{"id" => id}, conn ->
          body = Enum.map_join(1..40, &event(progress("t1", &1))) <> event(done(id))

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.resp(200, body)
        end,
        client: [max_response_bytes: 2_048]
      )

    assert {:ok, %{"content" => [%{"text" => "done"}]}} = Task.await(call(client))
    assert_received {:progress, _request_id, %{"progress" => 40}}
  end

  test "a notification ahead of the initialize response doesn't stop the client connecting" do
    client =
      start(fn _request, conn -> Plug.Conn.resp(conn, 500, "") end,
        initialize: :stream_with_log
      )

    assert {:ok, %{"name" => "stub"}} = Client.server_info(client)
  end
end
