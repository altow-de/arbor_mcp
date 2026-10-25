defmodule Arbor.MCP.Server.DSL.Matcher do
  @moduledoc false

  # Matches a URI against an RFC 6570 URI template and extracts its variables,
  # the reverse of expansion. Supports every operator (simple, `+`, `#`, `.`,
  # `/`, `;`, `?`, `&`), lists of variables, explode (`*`) and prefixes (`:n`).
  #
  # Values are percent-decoded. An exploded variable yields a list. Query
  # expressions (`?`, `&`) are matched by name and in any order, and their
  # variables are optional, as expansion omits undefined ones. Like Python's
  # MCPServer, values containing a NUL byte are rejected, and so are `..`
  # segments in expansions that may contain a slash.

  @spec match_uri_template(String.t(), String.t()) :: {:ok, map()} | :error
  def match_uri_template(uri, template) when is_binary(uri) and is_binary(template) do
    with {:ok, tokens} <- parse(template),
         {path_tokens, query_vars} = split_query(tokens),
         {:ok, path, query} <- split_uri(uri, query_vars),
         {:ok, regex, groups} <- compile(path_tokens),
         %{} = captures <- Regex.named_captures(regex, path),
         {:ok, path_values} <- path_values(captures, groups),
         {:ok, query_values} <- query_values(query, query_vars) do
      {:ok, path_values |> Map.merge(query_values) |> with_legacy_keys()}
    else
      _no_match -> :error
    end
  end

  # A token is a literal binary or {:expr, operator, [{name, explode?, prefix}]}.
  defp parse(template) do
    ~r/\{([^}]*)\}/
    |> Regex.split(template, include_captures: true, trim: true)
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case parse_part(part) do
        {:ok, token} -> {:cont, {:ok, [token | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, tokens} -> {:ok, Enum.reverse(tokens)}
      :error -> :error
    end
  end

  defp parse_part("{" <> rest = part) do
    if String.ends_with?(part, "}") do
      body = String.trim_trailing(rest, "}")
      {operator, list} = operator(body)

      vars =
        list
        |> String.split(",")
        |> Enum.map(&parse_var/1)

      if vars != [] and Enum.all?(vars, &match?({:ok, _}, &1)),
        do: {:ok, {:expr, operator, Enum.map(vars, fn {:ok, var} -> var end)}},
        else: :error
    else
      {:ok, part}
    end
  end

  defp parse_part(part), do: {:ok, part}

  defp operator(<<op, rest::binary>>) when op in ~c"+#./;?&", do: {<<op>>, rest}
  defp operator(body), do: {"", body}

  defp parse_var(spec) do
    case Regex.run(~r/^([A-Za-z0-9_.%-]+)(\*|:([1-9][0-9]{0,3}))?$/, spec) do
      [_all, name] -> {:ok, {name, false, nil}}
      [_all, name, "*"] -> {:ok, {name, true, nil}}
      [_all, name, _modifier, prefix] -> {:ok, {name, false, String.to_integer(prefix)}}
      _invalid -> :error
    end
  end

  # Query expressions are matched against the parsed query string instead of
  # the regex, so their order and presence don't matter.
  defp split_query(tokens) do
    Enum.reduce(tokens, {[], []}, fn
      {:expr, op, vars}, {path, query} when op in ["?", "&"] -> {path, query ++ vars}
      token, {path, query} -> {path ++ [token], query}
    end)
  end

  defp split_uri(uri, []), do: {:ok, uri, nil}

  defp split_uri(uri, _query_vars) do
    case String.split(uri, "?", parts: 2) do
      [path, query] -> {:ok, path, query}
      [path] -> {:ok, path, ""}
    end
  end

  defp compile(tokens) do
    {source, groups} =
      tokens
      |> Enum.with_index()
      |> Enum.reduce({"", []}, fn
        {literal, _index}, {source, groups} when is_binary(literal) ->
          {source <> Regex.escape(literal), groups}

        {{:expr, op, vars}, index}, {source, groups} ->
          {expr_source, expr_groups} = expression(op, vars, index)
          {source <> expr_source, groups ++ expr_groups}
      end)

    case Regex.compile("^" <> source <> "$") do
      {:ok, regex} -> {:ok, regex, groups}
      {:error, _reason} -> :error
    end
  end

  # Builds the regex for one expression. Each variable gets a safe group name;
  # groups maps it back to the variable and how to decode it.
  defp expression(op, vars, index) do
    {prefix, separator, value_class, named?} = operator_spec(op)

    parts =
      vars
      |> Enum.with_index()
      |> Enum.map(fn {{name, explode?, max}, position} ->
        group = "v#{index}_#{position}"
        class = if explode?, do: exploded_class(op, value_class), else: value_class
        quantifier = if max, do: "{1,#{max}}", else: "+"
        value = "(?<#{group}>#{class}#{quantifier})"
        pattern = if named?, do: Regex.escape(name) <> "=?" <> value, else: value
        {pattern, {group, name, op, explode?}}
      end)

    source =
      case parts do
        [{only, _group}] ->
          Regex.escape(prefix) <> only

        _many ->
          Regex.escape(prefix) <>
            Enum.map_join(parts, Regex.escape(separator), fn {pattern, _group} -> pattern end)
      end

    {source, Enum.map(parts, fn {_pattern, group} -> group end)}
  end

  # {prefix, separator, value character class, named?}
  defp operator_spec(""), do: {"", ",", "[^/?#,]", false}
  defp operator_spec("+"), do: {"", ",", "[^?#,]", false}
  defp operator_spec("#"), do: {"#", ",", "[^,]", false}
  defp operator_spec("."), do: {".", ".", "[^/?#.]", false}
  defp operator_spec("/"), do: {"/", "/", "[^/?#]", false}
  defp operator_spec(";"), do: {";", ";", "[^/?#;]", true}

  defp exploded_class("/", _class), do: "[^?#]"
  defp exploded_class(".", _class), do: "[^/?#]"
  defp exploded_class(_op, class), do: class

  defp path_values(captures, groups) do
    Enum.reduce_while(groups, {:ok, %{}}, fn {group, name, op, explode?}, {:ok, acc} ->
      raw = Map.fetch!(captures, group)

      case decode_value(raw, op, explode?) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp decode_value(raw, op, true) do
    separator = if op in ["/", "."], do: op, else: ","

    raw
    |> String.split(separator)
    |> Enum.reduce_while({:ok, []}, fn segment, {:ok, acc} ->
      case decode(segment, op) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp decode_value(raw, op, false), do: decode(raw, op)

  defp decode(raw, op) do
    value = URI.decode(raw)

    cond do
      String.contains?(value, <<0>>) -> :error
      op in ["+", "#"] and traversal?(value) -> :error
      not String.valid?(value) -> :error
      true -> {:ok, value}
    end
  rescue
    ArgumentError -> :error
  end

  defp traversal?(value), do: ".." in String.split(value, ["/", "\\"])

  # Earlier releases keyed a variable such as `file-name` as `file_name`.
  defp with_legacy_keys(values) do
    Enum.reduce(values, values, fn {name, value}, acc ->
      Map.put_new(acc, String.replace(name, ~r/[^A-Za-z0-9_]/, "_"), value)
    end)
  end

  defp query_values(nil, []), do: {:ok, %{}}

  defp query_values(query, vars) do
    params = URI.query_decoder(query) |> Enum.to_list()

    Enum.reduce_while(vars, {:ok, %{}}, fn {name, explode?, _max}, {:ok, acc} ->
      case Enum.filter(params, fn {key, _value} -> key == name end) do
        [] ->
          {:cont, {:ok, acc}}

        found ->
          values = Enum.map(found, fn {_key, value} -> value end)

          if Enum.any?(values, &String.contains?(&1, <<0>>)) do
            {:halt, :error}
          else
            value = if explode? or length(values) > 1, do: values, else: hd(values)
            {:cont, {:ok, Map.put(acc, name, value)}}
          end
      end
    end)
  rescue
    ArgumentError -> :error
  end
end
