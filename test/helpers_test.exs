defmodule HelpersTest do
  use ExUnit.Case
  import RustyJson.Helpers

  describe "json_map/1" do
    test "encodes keyword list as JSON fragment" do
      name = "Alice"
      age = 30
      fragment = json_map(name: name, age: age)
      assert %RustyJson.Fragment{} = fragment
      json = RustyJson.encode!(fragment, protocol: true)
      decoded = RustyJson.decode!(json)
      assert decoded == %{"age" => 30, "name" => "Alice"}
    end

    test "keys are preserved (matches Jason)" do
      # Jason preserves key order
      fragment = json_map(z: 1, a: 2)
      json = RustyJson.encode!(fragment, protocol: true)
      assert json == ~s({"z":1,"a":2})
    end

    test "handles nested values" do
      inner = %{x: 1}
      fragment = json_map(data: inner)
      json = RustyJson.encode!(fragment, protocol: true)
      decoded = RustyJson.decode!(json)
      assert decoded == %{"data" => %{"x" => 1}}
    end

    test "handles empty keyword list" do
      fragment = json_map([])
      json = RustyJson.encode!(fragment, protocol: true)
      assert json == "{}"
    end

    test "propagates escape opts to values" do
      fragment = json_map(url: "a/b")
      json = RustyJson.encode!(fragment, protocol: true, escape: :html_safe)
      assert json =~ "\\/"
    end

    test "json escape mode does not escape /" do
      fragment = json_map(url: "a/b")
      json = RustyJson.encode!(fragment, protocol: true, escape: :json)
      refute json =~ "\\/"
      assert json =~ "a/b"
    end
  end

  describe "json_map_take/2" do
    test "takes specified keys from map" do
      user = %{name: "Alice", age: 30, email: "alice@example.com"}
      fragment = json_map_take(user, [:name, :age])
      json = RustyJson.encode!(fragment, protocol: true)
      decoded = RustyJson.decode!(json)
      assert decoded == %{"age" => 30, "name" => "Alice"}
    end

    test "raises ArgumentError on missing key (matches Jason)" do
      user = %{name: "Alice"}

      assert_raise ArgumentError, ~r/expected a map with keys.*:missing/, fn ->
        json_map_take(user, [:name, :missing])
      end
    end

    test "keys are preserved (matches Jason)" do
      data = %{z: 1, a: 2, m: 3}
      # Request z, then a. Should be z, then a.
      fragment = json_map_take(data, [:z, :a])
      json = RustyJson.encode!(fragment, protocol: true)
      assert json == ~s({"z":1,"a":2})
    end
  end
end
