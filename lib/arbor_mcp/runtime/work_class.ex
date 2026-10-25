defmodule Arbor.MCP.Server.Runtime.WorkClass do
  @moduledoc false

  # Snapshot work never changes handler state, so a stateful runtime runs it
  # beside the callback holding the serial slot instead of queueing it behind
  # that callback. Only `ping` qualifies: the dispatcher answers it without
  # calling the handler, and peers use it to tell a busy server from a dead one.
  def snapshot?(%{"method" => "ping", "id" => id}) when not is_nil(id), do: true
  def snapshot?(_message), do: false
end
