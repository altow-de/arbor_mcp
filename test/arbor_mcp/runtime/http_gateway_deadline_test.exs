defmodule Arbor.MCP.Server.Runtime.HTTPGatewayDeadlineTest do
  use ExUnit.Case, async: false
  alias Arbor.MCP.Server.Runtime

  alias Arbor.MCP.Server.Runtime.{
    CallbackContext,
    Deadline,
    HTTPGateway,
    HTTPWriterBinding,
    HTTPWriterProxy,
    HTTPWriterRegistry
  }

  defmodule Handler do
    def init(opts) do
      send(opts[:test], :http_handler_init)
      {:ok, %{test: opts[:test], count: 0}}
    end

    def dispatch(request, _module, state, _opts) do
      context = CallbackContext.current()

      send(
        state.test,
        {:gateway_entry, request["id"], self(), System.monotonic_time(:millisecond),
         context.deadline}
      )

      if request["method"] == "hold", do: receive(do: (:finish -> :ok))

      {:response, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => state.count},
       %{state | count: state.count + 1}}
    end
  end

  test "one fixed charged timeout error may use the entry failure tail without reviving success" do
    # The handler counts in its state, one callback at a time.
    root =
      start_supervised!(
        {Runtime,
         handler: Handler,
         dispatcher: Handler,
         handler_args: [test: self()],
         request_timeout_ms: 2000,
         max_queue: 4,
         execution: :stateful}
      )

    {:ok, runtime} = Runtime.ref(root)
    assert_receive :http_handler_init
    # Entry has to land inside the charged cutoff however slow the machine is.
    # The timeout error is then published on the failure tail. Checkout in the
    # gap after the cutoff, before that tail is installed, reports the
    # invocation closed; that is not the outcome.
    {:ok, binding} = HTTPWriterProxy.capture(runtime, timeout: 1_000)
    {:ok, proof} = HTTPWriterBinding.validate(binding, runtime)
    {:ok, _token} = HTTPGateway.submit(runtime, binding, %{message(7) | "method" => "hold"})
    assert_receive {:gateway_entry, 7, _worker, entered, cutoff}, 5_000
    assert cutoff == proof.deadline
    assert entered < cutoff

    if Deadline.now() < cutoff do
      assert :empty = HTTPWriterRegistry.checkout(binding)
    end

    {effect, wire} = await_failure_frame(binding)

    assert %{"id" => 7, "error" => %{"code" => -32603, "message" => "Request timeout"}} =
             Jason.decode!(wire)

    assert {:error, :http_invocation_closed} = HTTPWriterBinding.validate(binding, runtime)

    assert {:error, :http_invocation_closed} =
             HTTPWriterRegistry.prepare(binding, "{\"result\":1}")

    {:ok, {domain, _}} = HTTPWriterBinding.address(binding)
    assert %{in_flight: 1, bytes: bytes} = HTTPWriterRegistry.stats(domain)
    assert bytes > byte_size(wire)
    assert :ok = HTTPWriterRegistry.complete(effect, :ok)
    wait(fn -> match?(%{frames: 0}, HTTPWriterRegistry.stats(domain)) end)
    assert :empty = HTTPWriterRegistry.checkout(binding)
    wait(fn -> match?(%{reserved: 0}, Runtime.stats!(runtime)) end)
    assert {:ok, %{"result" => 0}} = Runtime.request(runtime, message(8))
    refute_receive :http_handler_init, 0
  end

  defp message(id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "read"}

  defp await_failure_frame(binding) do
    {:ok, tail} = HTTPWriterRegistry.wait_deadline(binding)
    await_failure_frame(binding, tail)
  end

  defp await_failure_frame(binding, tail) do
    case HTTPWriterRegistry.checkout(binding) do
      {:ok, effect, wire} ->
        {effect, wire}

      result
      when result in [:empty, {:error, :http_invocation_closed}, {:error, :http_output_expired}] ->
        if Deadline.now() >= tail do
          flunk(
            "timeout error was not published before the failure tail closed: #{inspect(result)}"
          )
        else
          Process.sleep(10)
          await_failure_frame(binding, tail)
        end

      error ->
        flunk("HTTP checkout failed: #{inspect(error)}")
    end
  end

  defp wait(fun, remaining \\ 200)
  defp wait(_fun, 0), do: flunk("HTTP gateway state not reached")

  defp wait(fun, remaining) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _ ->
        Process.sleep(5)
        wait(fun, remaining - 1)
    end
  end
end
