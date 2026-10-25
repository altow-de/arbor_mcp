defmodule Arbor.MCP.Server.DSL.MatcherTest do
  @moduledoc """
  Resource templates match URIs per RFC 6570, as the TypeScript, Python and Go
  SDKs do, not only simple `{var}` path segments.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.DSL.Matcher

  defp match(uri, template), do: Matcher.match_uri_template(uri, template)

  test "a simple variable matches one segment and is percent-decoded" do
    assert {:ok, %{"id" => "a b"}} = match("users://a%20b/profile", "users://{id}/profile")
    assert :error = match("users://a/b/profile", "users://{id}/profile")
  end

  test "reserved expansion spans slashes" do
    assert {:ok, %{"path" => "docs/guide.md"}} = match("file:///docs/guide.md", "file:///{+path}")
  end

  test "path, label and fragment operators" do
    assert {:ok, %{"dir" => "a", "name" => "b"}} = match("x://root/a/b", "x://root{/dir,name}")

    assert {:ok, %{"segments" => ["a", "b", "c"]}} =
             match("x://root/a/b/c", "x://root{/segments*}")

    assert {:ok, %{"ext" => "json"}} = match("x://file.json", "x://file{.ext}")
    assert {:ok, %{"section" => "intro"}} = match("doc://page#intro", "doc://page{#section}")
  end

  test "path-style parameters" do
    assert {:ok, %{"lang" => "en"}} = match("x://item;lang=en", "x://item{;lang}")
  end

  test "query variables match by name, in any order, and are optional" do
    template = "search://items{?q,limit}"

    assert {:ok, %{"q" => "cats", "limit" => "5"}} =
             match("search://items?limit=5&q=cats", template)

    assert {:ok, %{"q" => "cats"} = values} = match("search://items?q=cats", template)
    refute Map.has_key?(values, "limit")
    assert {:ok, %{}} = match("search://items", template)
  end

  test "a prefix modifier bounds the match" do
    assert {:ok, %{"code" => "abc"}} = match("x://abc", "x://{code:3}")
    assert :error = match("x://abcd", "x://{code:3}")
  end

  test "NUL bytes and traversal in slash-capable expansions are rejected" do
    assert :error = match("file:///a%00b", "file:///{+path}")
    assert :error = match("file:///docs/../secrets", "file:///{+path}")
    assert :error = match("x://a%00b", "x://{id}")
  end

  test "earlier releases' keys stay available for variables with other characters" do
    assert {:ok, %{"file-name" => "a", "file_name" => "a"}} = match("x://a", "x://{file-name}")
  end

  test "literal parts must match exactly" do
    assert :error = match("users://1/settings", "users://{id}/profile")
    assert {:ok, %{}} = match("config://app", "config://app")
  end
end
