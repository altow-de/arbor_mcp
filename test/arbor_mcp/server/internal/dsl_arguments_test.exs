defmodule Arbor.MCP.Server.Internal.DSLArgumentsTest do
  @moduledoc """
  Input-validation messages follow each error path through the schema and
  show only the segments the schema names, so a key the caller sent is never
  echoed back.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.Internal.DSLArguments

  @schema %{
    "type" => "object",
    "properties" => %{
      "labels" => %{"type" => "object", "propertyNames" => %{"maxLength" => 3}},
      "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
      "a/b" => %{"type" => "string"},
      "secret" => %{"type" => "string"}
    }
  }

  defp shown(path) do
    DSLArguments.input_error_message({:invalid_tool_arguments, [{"invalid", path}]}, @schema)
  end

  test "declared properties and array indices are shown" do
    assert shown("#/tags/0") == "Input validation error: #/tags/0: invalid"
    assert shown("#/a~1b") == "Input validation error: #/a~1b: invalid"
  end

  test "keys the caller sent are masked, numeric or named elsewhere in the schema" do
    assert shown("#/labels/sk_live_SECRET") == "Input validation error: #/labels/*: invalid"
    assert shown("#/labels/123") == "Input validation error: #/labels/*: invalid"
    assert shown("#/labels/secret") == "Input validation error: #/labels/*: invalid"
    assert shown("#/unknown/tags") == "Input validation error: #/*/*: invalid"
  end

  test "without a schema every segment is masked" do
    assert DSLArguments.input_error_message({:invalid_tool_arguments, [{"invalid", "#/x"}]}) ==
             "Input validation error: #/*: invalid"
  end
end
