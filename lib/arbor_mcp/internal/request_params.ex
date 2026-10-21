defmodule Arbor.MCP.Internal.RequestParams do
  @moduledoc false

  alias Arbor.MCP.Internal.VersionRegistry
  alias Arbor.MCP.Protocol.Meta

  @spec empty() :: map()
  def empty, do: %{}

  @spec cursor(term()) :: map()
  def cursor(nil), do: %{}
  def cursor(cursor), do: %{"cursor" => cursor}

  @spec cursor_from_opts(keyword()) :: map()
  def cursor_from_opts(opts) do
    opts
    |> Keyword.get(:cursor)
    |> cursor()
  end

  @spec take_cursor(keyword()) :: {map(), keyword()}
  def take_cursor(opts) do
    {cursor, opts} = Keyword.pop(opts, :cursor)
    {cursor(cursor), opts}
  end

  @spec uri(String.t()) :: map()
  def uri(uri), do: %{"uri" => uri}

  @spec named(String.t(), map()) :: map()
  def named(name, arguments \\ %{}) do
    %{"name" => name, "arguments" => arguments}
  end

  @spec completion(term(), term()) :: map()
  def completion(ref, argument) do
    %{"ref" => ref, "argument" => argument}
  end

  @spec with_meta(map(), map() | nil | term()) :: map()
  def with_meta(params, nil), do: params
  def with_meta(params, meta) when is_map(meta), do: Map.put(params, "_meta", meta)
  def with_meta(params, _), do: params

  @spec with_non_empty_meta(map(), map() | nil | term()) :: map()
  def with_non_empty_meta(params, meta) when is_map(meta) and map_size(meta) > 0 do
    Map.put(params, "_meta", meta)
  end

  def with_non_empty_meta(params, _), do: params

  @spec with_opts_meta(map(), keyword()) :: map()
  def with_opts_meta(params, opts) do
    params
    |> with_meta(Keyword.get(opts, :meta))
    |> with_progress_token(Keyword.get(opts, :progress_token))
  end

  # Merges `progressToken` into any `_meta` already built from `opts[:meta]`,
  # so callers can pass both without one clobbering the other.
  @spec with_progress_token(map(), Arbor.MCP.Types.progress_token() | nil) :: map()
  defp with_progress_token(params, nil), do: params

  defp with_progress_token(params, token) when is_binary(token) or is_integer(token) do
    meta =
      params
      |> Map.get("_meta", %{})
      |> Map.put("progressToken", token)

    Map.put(params, "_meta", meta)
  end

  defp with_progress_token(params, _), do: params

  @mrtr_methods ["tools/call", "resources/read", "prompts/get"]

  # Puts a caller-supplied MRTR continuation (`:input_responses` and
  # `:request_state`) on the request, for callers that run MRTR rounds
  # themselves with `mrtr: :manual`. Invalid values are programmer errors.
  @doc false
  @spec with_mrtr_continuation(map(), String.t(), keyword()) :: map()
  def with_mrtr_continuation(params, method, opts) do
    input_responses = Keyword.get(opts, :input_responses)
    request_state = Keyword.get(opts, :request_state)

    cond do
      is_nil(input_responses) and is_nil(request_state) ->
        params

      method not in @mrtr_methods ->
        raise ArgumentError,
              "input_responses and request_state are only valid for " <>
                Enum.join(@mrtr_methods, ", ")

      not (is_nil(input_responses) or is_map(input_responses)) ->
        raise ArgumentError, "input_responses must be a map"

      not (is_nil(request_state) or is_binary(request_state)) ->
        raise ArgumentError, "request_state must be a string"

      true ->
        params
        |> put_present("inputResponses", input_responses)
        |> put_present("requestState", request_state)
    end
  end

  defp put_present(params, _key, nil), do: params
  defp put_present(params, key, value), do: Map.put(params, key, value)

  @spec with_progress_or_meta(map(), Arbor.MCP.Types.progress_token() | nil | map()) :: map()
  def with_progress_or_meta(params, nil), do: params

  def with_progress_or_meta(params, token) when is_binary(token) or is_integer(token) do
    with_non_empty_meta(params, %{"progressToken" => token})
  end

  def with_progress_or_meta(params, meta) when is_map(meta) do
    with_non_empty_meta(params, meta)
  end

  # A request-level `:client_capabilities` option replaces the connection's
  # capabilities in that one modern request's `_meta`. Legacy requests carry
  # no per-request capabilities.
  @doc false
  @spec for_request(map(), map(), keyword()) :: {:ok, map()} | {:error, Meta.validation_error()}
  def for_request(params, context, opts \\ []) when is_map(params) and is_map(context) do
    protocol_version = context_value(context, :protocol_version)

    if VersionRegistry.modern?(protocol_version) do
      meta = Map.get(params, "_meta", %{})
      capabilities = Keyword.get(opts, :client_capabilities) || client_capabilities(context)

      case Meta.build_request_meta(meta, protocol_version, capabilities,
             client_info: context_value(context, :client_info),
             log_level: context_value(context, :log_level),
             trace_context: context_value(context, :trace_context) || %{}
           ) do
        {:ok, modern_meta} -> {:ok, Map.put(params, "_meta", modern_meta)}
        {:error, _reason} = error -> error
      end
    else
      {:ok, params}
    end
  end

  defp client_capabilities(context) do
    context_value(context, :client_capabilities) ||
      context_value(context, :capabilities) ||
      %{}
  end

  defp context_value(context, key) do
    Map.get(context, key) ||
      case Map.get(context, :transport_opts) do
        opts when is_list(opts) -> Keyword.get(opts, key)
        _other -> nil
      end
  end
end
