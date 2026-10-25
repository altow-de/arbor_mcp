defmodule Arbor.MCP.Server.Registry do
  @moduledoc false

  # Tools, resources, resource templates and prompts added to a running
  # server with Arbor.MCP.Server.add_tool/3 and its siblings. Each runtime
  # owns one table, so entries survive restarts of the runtime's children.
  # Dispatch lists entries after the handler's own, routes calls to them
  # first, and advertises their capabilities.

  alias Arbor.MCP.Content.SchemaPolicy
  alias Arbor.MCP.Server.ResultNormalizer
  alias Arbor.MCP.Server.Runtime.CallbackContext

  @kinds [:tool, :resource, :resource_template, :prompt]

  @type kind :: :tool | :resource | :resource_template | :prompt
  @type entry :: %{
          kind: kind(),
          id: String.t(),
          definition: map(),
          fun: function(),
          input_schema: term(),
          output_schema: term(),
          seq: integer()
        }

  @doc false
  def new, do: :ets.new(__MODULE__, [:set, :public, read_concurrency: true])

  @doc false
  # The registry of the runtime running the current callback, if any.
  def current do
    case CallbackContext.current() do
      %{table: table} -> of_table(table)
      _outside -> nil
    end
  end

  @doc false
  def of_table(table) do
    case :ets.lookup(table, :registry) do
      [{:registry, registry}] -> registry
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc false
  @spec put(:ets.tid(), kind(), map(), function()) :: :ok | {:error, term()}
  def put(registry, kind, definition, fun) when kind in @kinds and is_map(definition) do
    definition = ResultNormalizer.stringify_keys(definition)

    with :ok <- check_fun(kind, fun),
         {:ok, id} <- identifier(kind, definition),
         {:ok, definition, input, output} <- schemas(kind, definition) do
      entry = %{
        kind: kind,
        id: id,
        definition: definition,
        fun: fun,
        input_schema: input,
        output_schema: output,
        seq: System.unique_integer([:monotonic])
      }

      :ets.insert(registry, {{kind, id}, entry})
      :ok
    end
  end

  def put(_registry, kind, _definition, _fun), do: {:error, {:invalid_definition, kind}}

  @doc false
  @spec delete(:ets.tid(), kind(), String.t()) :: :ok | {:error, :not_found}
  def delete(registry, kind, id) do
    case :ets.take(registry, {kind, id}) do
      [_entry] -> :ok
      [] -> {:error, :not_found}
    end
  end

  @doc false
  @spec entries(:ets.tid() | nil, kind()) :: [entry()]
  def entries(nil, _kind), do: []

  def entries(registry, kind) do
    registry
    |> :ets.match_object({{kind, :_}, :_})
    |> Enum.map(fn {_key, entry} -> entry end)
    |> Enum.sort_by(& &1.seq)
  end

  @doc false
  @spec lookup(:ets.tid() | nil, kind(), term()) :: {:ok, entry()} | :error
  def lookup(nil, _kind, _id), do: :error

  def lookup(registry, kind, id) when is_binary(id) do
    case :ets.lookup(registry, {kind, id}) do
      [{_key, entry}] -> {:ok, entry}
      [] -> :error
    end
  end

  def lookup(_registry, _kind, _id), do: :error

  @doc false
  @spec any?(:ets.tid() | nil, kind()) :: boolean()
  def any?(nil, _kind), do: false

  def any?(registry, kind),
    do: :ets.match_object(registry, {{kind, :_}, :_}, 1) != :"$end_of_table"

  defp check_fun(:resource_template, fun) when is_function(fun, 2), do: :ok
  defp check_fun(kind, fun) when kind != :resource_template and is_function(fun, 1), do: :ok
  defp check_fun(kind, _fun), do: {:error, {:invalid_function, kind}}

  defp identifier(:tool, %{"name" => name}), do: non_empty(name, :tool)
  defp identifier(:prompt, %{"name" => name}), do: non_empty(name, :prompt)

  defp identifier(:resource, %{"uri" => uri, "name" => name}) when is_binary(name),
    do: non_empty(uri, :resource)

  defp identifier(:resource_template, %{"uriTemplate" => template, "name" => name})
       when is_binary(name),
       do: non_empty(template, :resource_template)

  defp identifier(kind, _definition), do: {:error, {:invalid_definition, kind}}

  defp non_empty(id, kind) do
    if is_binary(id) and String.trim(id) != "",
      do: {:ok, id},
      else: {:error, {:invalid_definition, kind}}
  end

  # A tool's input schema defaults to an object. Both schemas are checked when
  # the tool is added, as the TypeScript and Java SDKs do.
  defp schemas(:tool, definition) do
    definition = Map.put_new(definition, "inputSchema", %{"type" => "object"})

    with {:ok, input} <- compile(definition["inputSchema"]),
         {:ok, output} <- compile(definition["outputSchema"]) do
      {:ok, definition, input, output}
    end
  end

  defp schemas(_kind, definition), do: {:ok, definition, nil, nil}

  defp compile(nil), do: {:ok, nil}

  defp compile(schema) do
    case SchemaPolicy.compile(schema) do
      {:ok, compiled} -> {:ok, compiled}
      {:error, reason} -> {:error, {:invalid_schema, SchemaPolicy.format_error(reason)}}
    end
  end
end
