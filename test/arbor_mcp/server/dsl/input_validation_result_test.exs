defmodule Arbor.MCP.Server.DSL.InputValidationResultTest do
  @moduledoc """
  A DSL tool called with invalid arguments returns an `isError` tool result
  naming what is wrong, as SEP-1303 recommends and the other MCP SDKs do, so a
  model can correct the call. It used to be a `-32602` protocol error with no
  details. The rejected values themselves are never echoed back.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Client

  defmodule Server do
    @moduledoc false
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "validation", version: "1.0.0"

    tool "repeat", "Repeat a message" do
      param(:message, :string, required: true)
      param(:times, :integer, minimum: 1)

      run(fn %{message: message}, state -> {:ok, message, state} end)
    end
  end

  setup do
    {:ok, server} = Server.start_link(transport: :test)

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: :legacy_only,
        health_check_interval: nil
      )

    %{client: client}
  end

  test "a missing argument is an isError result that names it", %{client: client} do
    assert {:ok, %{is_error: true} = response} = Client.call_tool(client, "repeat", %{})
    assert [%{text: "Input validation error: " <> details}] = response.content
    assert details =~ "message"
  end

  test "a wrongly typed argument is reported without echoing the value", %{client: client} do
    assert {:ok, %{is_error: true} = response} =
             Client.call_tool(client, "repeat", %{"message" => "hi", "times" => -987_654})

    assert [%{text: "Input validation error: " <> details}] = response.content
    assert details =~ "times"
    refute details =~ "987"
  end

  test "valid arguments still reach the tool", %{client: client} do
    assert {:ok, %{is_error: false} = response} =
             Client.call_tool(client, "repeat", %{"message" => "hi"})

    assert [%{text: "hi"}] = response.content
  end
end
