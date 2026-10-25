defmodule Arbor.MCP.Server.HTTPRuntimeControlsTest do
  @moduledoc """
  An HTTP runtime has no edge process. Server helpers called outside a
  request used to message its supervisor instead, which crashed it.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Server
  alias Arbor.MCP.Server.Runtime

  defmodule Plain do
    @moduledoc false
    use Arbor.MCP.Server.Handler
  end

  test "controls, calls and casts outside a request leave the runtime running" do
    root = start_supervised!({Runtime, handler: Plain, transport: :mounted_http})

    # List changes go to the subscriptions service, which HTTP runtimes have.
    assert :ok = Server.notify_tools_changed(root)
    assert :ok = Server.notify_prompts_changed(root)
    assert {:error, :runtime_unavailable} = Server.cast(root, :anything)
    assert {:error, :runtime_unavailable} = Server.call(root, :anything)

    # Processed after any cast above, so it exits if one crashed the supervisor.
    assert [_ | _] = Supervisor.which_children(root)
  end
end
