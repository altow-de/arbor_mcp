defmodule Arbor.MCP.Server.Internal.DSLArguments do
  @moduledoc false
  alias Arbor.MCP.Content.SchemaPolicy
  alias Arbor.MCP.Server.DSL.Builder
  alias Arbor.MCP.Server.ResultNormalizer

  def prepare_tool_arguments(arguments, params, input_schema) when is_map(arguments) do
    json = ResultNormalizer.stringify_keys(arguments)

    json =
      Enum.reduce(params, json, fn param, acc ->
        if param.has_default,
          do: Map.put_new(acc, Atom.to_string(param.name), param.default),
          else: acc
      end)

    case SchemaPolicy.validate_optional(Map.drop(json, ["_meta"]), input_schema) do
      :ok -> {:ok, Builder.normalize_arguments(arguments, params)}
      {:error, diagnostics} -> {:error, {:invalid_tool_arguments, List.wrap(diagnostics)}}
    end
  rescue
    ArgumentError -> {:error, {:invalid_tool_arguments, []}}
  end

  def prepare_tool_arguments(_arguments, _params, _input_schema),
    do: {:error, {:invalid_tool_arguments, ["arguments must be an object"]}}

  @doc false
  # Invalid arguments are a tool execution error the model can correct, so
  # they come back as an `isError` result rather than a protocol error, as
  # SEP-1303 recommends and the other MCP SDKs do. Schema diagnostics name
  # the failing location and rule but never the rejected value.
  #
  # The path is followed through the tool's input schema. A segment the schema
  # names there, as a property or an array index, is shown; any other is a key
  # the caller sent, so part of the rejected value (with propertyNames, it is
  # the value), and it and everything below it show as `*`.
  def input_error_message(reason, schema \\ nil)

  def input_error_message({:invalid_tool_arguments, []}, _schema), do: "Input validation error"

  def input_error_message({:invalid_tool_arguments, diagnostics}, schema) do
    schema = if is_map(schema), do: ResultNormalizer.stringify_keys(schema)

    details =
      Enum.map_join(diagnostics, "; ", fn
        {message, path} when is_binary(message) and path in ["#", "", nil] ->
          message

        {message, path} when is_binary(message) and is_binary(path) ->
          "#{safe_path(path, schema)}: #{message}"

        message when is_binary(message) ->
          message

        _other ->
          "invalid"
      end)

    "Input validation error: " <> details
  end

  defp safe_path(path, schema) do
    [root | segments] = String.split(path, "/")

    {shown, _schema} =
      Enum.map_reduce(segments, schema, fn segment, at ->
        case step(at, unescape(segment)) do
          {:ok, next} -> {segment, next}
          :error -> {"*", nil}
        end
      end)

    Enum.join([root | shown], "/")
  end

  # One JSON Pointer step into a schema: a declared property, or an index
  # into an array schema.
  defp step(%{} = schema, key) do
    properties = schema["properties"]

    cond do
      is_map(properties) and Map.has_key?(properties, key) ->
        {:ok, properties[key]}

      array_schema?(schema) and key =~ ~r/^(0|[1-9][0-9]*)$/ ->
        {:ok, item_schema(schema, String.to_integer(key))}

      true ->
        :error
    end
  end

  defp step(_schema, _key), do: :error

  defp array_schema?(schema),
    do:
      schema["type"] == "array" or Map.has_key?(schema, "items") or
        Map.has_key?(schema, "prefixItems")

  defp item_schema(schema, index) do
    case schema["prefixItems"] do
      [_ | _] = prefix when index < length(prefix) -> Enum.at(prefix, index)
      _other -> schema["items"]
    end
  end

  defp unescape(segment),
    do: segment |> String.replace("~1", "/") |> String.replace("~0", "~")

  def validate_tool_response(response, nil), do: {:ok, response}

  def validate_tool_response(response, output_schema) do
    normalized = ResultNormalizer.stringify_keys(response)

    case Map.fetch(normalized, "structuredContent") do
      :error ->
        {:ok, response}

      {:ok, data} ->
        case validate_with_schema(data, output_schema) do
          :ok ->
            {:ok, response}

          {:error, errors} ->
            {:error, "Output validation failed: #{format_validation_errors(errors)}"}
        end
    end
  end

  defp validate_with_schema(data, schema) do
    case SchemaPolicy.validate_optional(data, schema) do
      :ok ->
        :ok

      {:error, reason} when is_tuple(reason) or is_atom(reason) ->
        {:error, [SchemaPolicy.format_error(reason)]}

      {:error, errors} ->
        {:error, errors}
    end
  end

  defp format_validation_errors(errors) when is_list(errors) do
    Enum.map_join(errors, ", ", fn
      message when is_binary(message) -> message
      {message, _path} when is_binary(message) -> message
      _other -> "Invalid structured output"
    end)
  end
end
