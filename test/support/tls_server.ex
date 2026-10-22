defmodule Arbor.MCP.Test.TLSServer do
  @moduledoc """
  Loopback HTTPS server for tests that need a real TLS handshake.

  `start/1` generates a throwaway CA and a server certificate for `localhost`,
  then serves every accepted connection with `handler`. The handler receives
  the request head and returns `{:close, response}` to write the response and
  close the connection, or `{:keep_open, response}` to write it and hold the
  connection open, as an SSE stream needs. Each request head is also sent to
  the calling test as `{:tls_request, head}`.

  Clients trust the server only when given the returned `:cacerts`. Connect
  to `localhost` with the address pinned to 127.0.0.1: the certificate names
  `localhost`, and the server listens on IPv4 loopback only.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @timeout 5_000

  @type handler :: (binary() -> {:close | :keep_open, iodata()})

  @spec start(handler()) :: %{port: :inet.port_number(), cacerts: [binary()]}
  def start(handler) when is_function(handler, 1) do
    {:ok, _apps} = Application.ensure_all_started(:ssl)
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}
    # pkix_test_data signs with SHA-1 by default, which TLS 1.3 rejects for
    # certificates on some OTP releases (:unable_to_supply_acceptable_cert on
    # OTP 27.0). ECDSA P-256 with SHA-256 is mandatory for TLS 1.3 clients.
    key = [key: {:namedCurve, :secp256r1}, digest: :sha256]

    %{server_config: server_config, client_config: client_config} =
      :public_key.pkix_test_data(%{
        server_chain: %{root: key, intermediates: [], peer: key ++ [extensions: [san]]},
        client_chain: %{root: [], peer: []}
      })

    owner = self()
    acceptor = spawn(fn -> listen(server_config, handler, owner) end)

    port =
      receive do
        {:tls_server_listening, ^acceptor, port} -> port
      after
        @timeout -> raise "TLS test server did not start"
      end

    # Connection processes are linked to the acceptor, so this closes them too.
    on_exit(fn -> Process.exit(acceptor, :kill) end)
    %{port: port, cacerts: client_config[:cacerts]}
  end

  defp listen(server_config, handler, owner) do
    {:ok, listener} =
      :ssl.listen(
        0,
        [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}] ++ server_config
      )

    {:ok, {_address, port}} = :ssl.sockname(listener)
    send(owner, {:tls_server_listening, self(), port})
    accept_loop(listener, handler, owner)
  end

  defp accept_loop(listener, handler, owner) do
    case :ssl.transport_accept(listener) do
      {:ok, transport} ->
        pid = spawn_link(fn -> receive(do: (:serve -> serve(transport, handler, owner))) end)
        :ok = :ssl.controlling_process(transport, pid)
        send(pid, :serve)
        accept_loop(listener, handler, owner)

      {:error, _reason} ->
        :ok
    end
  end

  # A client that rejects the certificate fails the handshake; the connection
  # is then dropped without a request.
  defp serve(transport, handler, owner) do
    with {:ok, socket} <- :ssl.handshake(transport, @timeout),
         {:ok, head, rest} <- read_head(socket, "") do
      :ok = read_body(socket, content_length(head) - byte_size(rest))
      send(owner, {:tls_request, head})

      case handler.(head) do
        {:close, response} ->
          :ok = :ssl.send(socket, response)
          :ssl.close(socket)

        {:keep_open, response} ->
          :ok = :ssl.send(socket, response)
          hold = make_ref()
          receive(do: (^hold -> :ok))
      end
    end
  end

  defp read_head(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        {:ok, head, rest}

      [_partial] ->
        with {:ok, data} <- :ssl.recv(socket, 0, @timeout),
             do: read_head(socket, buffer <> data)
    end
  end

  defp read_body(_socket, remaining) when remaining <= 0, do: :ok

  defp read_body(socket, remaining) do
    {:ok, data} = :ssl.recv(socket, 0, @timeout)
    read_body(socket, remaining - byte_size(data))
  end

  defp content_length(head) do
    case Regex.run(~r/\r\ncontent-length:\s*(\d+)/i, head) do
      [_, length] -> String.to_integer(length)
      nil -> 0
    end
  end
end
