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
  # A path segment the schema doesn't declare is a key the caller sent, and
  # so part of the rejected value (with propertyNames, it is the value), so
  # it's shown as `*`. Only declared property names and array indices stay.
  def input_error_message(reason, declared \\ MapSet.new())

  def input_error_message({:invalid_tool_arguments, []}, _declared), do: "Input validation error"

  def input_error_message({:invalid_tool_arguments, diagnostics}, declared) do
    details =
      Enum.map_join(diagnostics, "; ", fn
        {message, path} when is_binary(message) and path in ["#", "", nil] ->
          message

        {message, path} when is_binary(message) and is_binary(path) ->
          "#{safe_path(path, declared)}: #{message}"

        message when is_binary(message) ->
          message

        _other ->
          "invalid"
      end)

    "Input validation error: " <> details
  end

  defp safe_path(path, declared) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn segment ->
      if segment == "#" or segment =~ ~r/^\d+$/ or MapSet.member?(declared, segment),
        do: segment,
        else: "*"
    end)
  end

  @doc false
  # The property names a schema declares, at any depth.
  def declared_names(schemas) when is_list(schemas),
    do: schemas |> Enum.flat_map(&property_names/1) |> MapSet.new()

  def declared_names(schema), do: declared_names([schema])

  defp property_names(%{} = schema) do
    own =
      case Map.get(schema, "properties") || Map.get(schema, :properties) do
        %{} = properties -> Enum.map(Map.keys(properties), &to_string/1)
        _none -> []
      end

    own ++ (schema |> Map.values() |> Enum.flat_map(&property_names/1))
  end

  defp property_names(list) when is_list(list), do: Enum.flat_map(list, &property_names/1)
  defp property_names(_other), do: []

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
