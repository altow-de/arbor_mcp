# When does a Phoenix router call init/1 of a plug mounted with `forward`?
# Run: elixir -pa <phoenix build libs>/ebin phoenix_forward_init_probe.exs
defmodule Probe do
  def init(opts) do
    count = :persistent_term.get(:probe_inits, 0) + 1
    :persistent_term.put(:probe_inits, count)
    IO.puts("Probe.init/1 call ##{count} (#{inspect(opts)}) in #{inspect(self())}")
    opts
  end

  def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "ok")
end

_ = Application.load(:phoenix)
vsn = Application.spec(:phoenix, :vsn)
IO.puts("plug_init_mode: #{inspect(Phoenix.plug_init_mode())}, phoenix #{vsn}")
IO.puts("-- compiling router")

defmodule ProbeRouter do
  use Phoenix.Router
  forward("/mcp", Probe, mrtr: true)
end

IO.puts("-- router compiled, init calls so far: #{:persistent_term.get(:probe_inits, 0)}")

for i <- 1..3 do
  conn = Plug.Test.conn(:post, "/mcp", "")
  conn = ProbeRouter.call(conn, ProbeRouter.init([]))
  IO.puts("request #{i}: status #{conn.status}")
end

IO.puts("-- init calls after 3 requests: #{:persistent_term.get(:probe_inits, 0)}")
