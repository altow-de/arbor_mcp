defmodule Arbor.MCP.Server.HandlerServerListChangedTest do
  @moduledoc """
  A connection that hasn't sent `initialize` or a modern request has no era
  yet. A list change sent then reached a client still establishing the
  connection, whose `server/discover` probe took it for the answer it was
  waiting for and failed.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.HandlerServer

  test "a connection with no era yet gets no list change" do
    state = %{connection_era: nil, protocol_version: nil}

    for control <- [{:notify_tools_changed}, {:notify_prompts_changed}] do
      assert {:noreply, ^state} = HandlerServer.handle_cast(control, state)
    end
  end
end
