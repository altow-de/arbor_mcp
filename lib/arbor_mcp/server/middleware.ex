defmodule Arbor.MCP.Server.Middleware do
  @moduledoc """
  Wraps the MCP requests and notifications a server handles, like Python's
  `MCPServer(middleware=[...])` and Go's `AddReceivingMiddleware`.

  Configure a list on the runtime, outermost first:

      Arbor.MCP.Server.start_link(
        transport: :http,
        handler: MyServer,
        middleware: [MyApp.MCPAudit, {MyApp.MCPRateLimit, per_minute: 60}]
      )

  The same `:middleware` option works on an `Arbor.MCP.Server.Runtime` child
  spec and on a DSL server's `start_link/1` and `child_spec/1`.

  A middleware gets the request and a `next` function that runs the rest of
  the chain and then the handler:

      defmodule MyApp.MCPAudit do
        @behaviour Arbor.MCP.Server.Middleware

        @impl true
        def call(request, next, _opts) do
          started = System.monotonic_time()
          result = next.(request)
          MyApp.Audit.record(request.method, Arbor.MCP.Server.Context.auth_info(), result, started)
          result
        end
      end

  It can return without calling `next` to refuse a request, for example
  `{:error, %{"code" => -32001, "message" => "Rate limited"}}`, or call `next`
  with different `:params`, which are validated again. The method and id
  can't change.

  Every request and notification dispatched to the handler goes through the
  chain, including `initialize`, `server/discover` and `ping`. The runtime
  handles `notifications/cancelled` itself, so it doesn't, and neither do
  messages rejected before dispatch for invalid parameters or metadata or the
  wrong protocol era.

  The chain runs in the request's callback process, so
  `Arbor.MCP.Server.Context` works inside it, and it counts against the
  request's deadline. Call `next` from that process. Middleware never sees or
  changes the handler state.
  """

  alias Arbor.MCP.Server.RequestContext

  @typedoc """
  The request being handled. `:id` is `nil` for a notification.
  """
  @type request :: %{
          method: String.t(),
          id: Arbor.MCP.Types.request_id() | nil,
          params: map(),
          context: RequestContext.t()
        }

  @typedoc """
  What the handler answered: the result map or JSON-RPC error object as it
  goes on the wire, or `:noreply` for a notification.
  """
  @type result :: {:ok, map()} | {:error, map()} | :noreply

  @type next :: (request() -> result())

  @callback call(request(), next(), opts :: term()) :: result()

  @doc false
  # Runs request through the chain; inner is the handler.
  @spec run([{module(), term()}], request(), next()) :: result()
  def run(middleware, request, inner) do
    middleware
    |> Enum.reverse()
    |> Enum.reduce(inner, fn {module, opts}, next ->
      fn request -> module.call(request, next, opts) end
    end)
    |> then(& &1.(request))
  end

  @doc false
  # Validates a middleware list at runtime start.
  @spec normalize([module() | {module(), term()}]) ::
          {:ok, [{module(), term()}]} | {:error, term()}
  def normalize(middleware) when is_list(middleware) do
    Enum.reduce_while(middleware, {:ok, []}, fn entry, {:ok, acc} ->
      case normalize_entry(entry) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, {:error, {:invalid_middleware, entry}}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  def normalize(other), do: {:error, {:invalid_middleware, other}}

  defp normalize_entry({module, opts}) when is_atom(module), do: check(module, opts)
  defp normalize_entry(module) when is_atom(module), do: check(module, [])
  defp normalize_entry(_entry), do: :error

  defp check(module, opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :call, 3),
      do: {:ok, {module, opts}},
      else: :error
  end
end
