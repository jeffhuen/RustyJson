defmodule OrderedObjectTest do
  use ExUnit.Case

  describe "decode with objects: :ordered_objects (Gap 4)" do
    test "preserves key order" do
      json = ~s({"b":2,"a":1,"c":3})
      result = RustyJson.decode!(json, objects: :ordered_objects)
      assert %RustyJson.OrderedObject{values: values} = result
      assert [{"b", 2}, {"a", 1}, {"c", 3}] = values
    end

    test "empty object" do
      json = ~s({})
      result = RustyJson.decode!(json, objects: :ordered_objects)
      assert %RustyJson.OrderedObject{values: []} = result
    end

    test "nested ordered objects" do
      json = ~s({"outer":{"inner":1}})
      result = RustyJson.decode!(json, objects: :ordered_objects)
      assert %RustyJson.OrderedObject{values: [{"outer", inner}]} = result
      assert %RustyJson.OrderedObject{values: [{"inner", 1}]} = inner
    end

    test "array of ordered objects" do
      json = ~s([{"b":1,"a":2},{"d":3,"c":4}])
      [obj1, obj2] = RustyJson.decode!(json, objects: :ordered_objects)
      assert %RustyJson.OrderedObject{values: [{"b", 1}, {"a", 2}]} = obj1
      assert %RustyJson.OrderedObject{values: [{"d", 3}, {"c", 4}]} = obj2
    end

    test "non-object values unaffected" do
      json = ~s([1, "hello", true, null])
      assert [1, "hello", true, nil] = RustyJson.decode!(json, objects: :ordered_objects)
    end
  end

  describe "Access behavior" do
    test "fetch key" do
      obj = %RustyJson.OrderedObject{values: [{"a", 1}, {"b", 2}]}
      assert {:ok, 1} = Access.fetch(obj, "a")
      assert {:ok, 2} = Access.fetch(obj, "b")
      assert :error = Access.fetch(obj, "c")
    end

    test "get_and_update" do
      obj = %RustyJson.OrderedObject{values: [{"a", 1}, {"b", 2}]}
      {old, new_obj} = Access.get_and_update(obj, "a", fn v -> {v, v + 10} end)
      assert old == 1
      assert new_obj.values == [{"a", 11}, {"b", 2}]
    end

    test "pop" do
      obj = %RustyJson.OrderedObject{values: [{"a", 1}, {"b", 2}]}
      {val, new_obj} = Access.pop(obj, "a")
      assert val == 1
      assert new_obj.values == [{"b", 2}]
    end

    test "pop missing key" do
      obj = %RustyJson.OrderedObject{values: [{"a", 1}]}
      {val, same_obj} = Access.pop(obj, "missing")
      assert val == nil
      assert same_obj == obj
    end

    test "pop with default value" do
      obj = %RustyJson.OrderedObject{values: [{"a", 1}]}
      {val, same_obj} = RustyJson.OrderedObject.pop(obj, "missing", :default)
      assert val == :default
      assert same_obj == obj
    end

    test "pop with default returns value when key exists" do
      obj = %RustyJson.OrderedObject{values: [{"a", 1}, {"b", 2}]}
      {val, new_obj} = RustyJson.OrderedObject.pop(obj, "a", :default)
      assert val == 1
      assert new_obj.values == [{"b", 2}]
    end
  end

  describe "Enumerable" do
    test "count" do
      obj = %RustyJson.OrderedObject{values: [{"a", 1}, {"b", 2}]}
      assert Enum.count(obj) == 2
    end

    test "member?" do
      obj = %RustyJson.OrderedObject{values: [{"a", 1}, {"b", 2}]}
      assert Enum.member?(obj, {"a", 1})
      refute Enum.member?(obj, {"c", 3})
    end

    test "map" do
      obj = %RustyJson.OrderedObject{values: [{"a", 1}, {"b", 2}]}
      result = Enum.map(obj, fn {k, v} -> {k, v * 2} end)
      assert result == [{"a", 2}, {"b", 4}]
    end

    test "to_list" do
      obj = %RustyJson.OrderedObject{values: [{"b", 2}, {"a", 1}]}
      assert Enum.to_list(obj) == [{"b", 2}, {"a", 1}]
    end
  end

  describe "get_and_update edge cases" do
    test "get_and_update with :pop removes key" do
      obj = %RustyJson.OrderedObject{values: [{"a", 1}, {"b", 2}, {"c", 3}]}
      {old, new_obj} = Access.get_and_update(obj, "b", fn _ -> :pop end)
      assert old == 2
      assert new_obj.values == [{"a", 1}, {"c", 3}]
    end

    test "get_and_update with missing key inserts at beginning" do
      obj = %RustyJson.OrderedObject{values: [{"a", 1}]}
      {old, new_obj} = Access.get_and_update(obj, "b", fn nil -> {nil, 42} end)
      assert old == nil
      assert new_obj.values == [{"b", 42}, {"a", 1}]
    end

    test "get_and_update with missing key and :pop" do
      obj = %RustyJson.OrderedObject{values: [{"a", 1}]}
      {old, new_obj} = Access.get_and_update(obj, "missing", fn nil -> :pop end)
      assert old == nil
      assert new_obj.values == [{"a", 1}]
    end

    test "get_and_update raises on invalid return" do
      obj = %RustyJson.OrderedObject{values: [{"a", 1}]}

      assert_raise RuntimeError, ~r/must return a two-element tuple or :pop/, fn ->
        Access.get_and_update(obj, "a", fn _ -> :bad end)
      end
    end

    test "get_and_update raises on invalid return for missing key" do
      obj = %RustyJson.OrderedObject{values: [{"a", 1}]}

      assert_raise RuntimeError, ~r/must return a two-element tuple or :pop/, fn ->
        Access.get_and_update(obj, "missing", fn _ -> :bad end)
      end
    end
  end

  describe "pop removes all matching keys" do
    test "pop returns first value and removes ALL occurrences" do
      obj = %RustyJson.OrderedObject{values: [{"a", 1}, {"b", 2}, {"a", 3}]}
      {val, new_obj} = Access.pop(obj, "a")
      # Returns the first matching value
      assert val == 1
      # Removes ALL occurrences of the key, not just the first
      assert new_obj.values == [{"b", 2}]
      # Verify no "a" keys remain
      assert :error = Access.fetch(new_obj, "a")
    end

    test "pop with three duplicate keys removes all" do
      obj = %RustyJson.OrderedObject{values: [{"x", 1}, {"x", 2}, {"y", 3}, {"x", 4}]}
      {val, new_obj} = Access.pop(obj, "x")
      assert val == 1
      assert new_obj.values == [{"y", 3}]
      assert :error = Access.fetch(new_obj, "x")
    end
  end

  describe "encode round-trip" do
    test "ordered object encodes back preserving order" do
      obj = %RustyJson.OrderedObject{values: [{"b", 2}, {"a", 1}]}
      json = RustyJson.encode!(obj, protocol: true)
      assert json == ~s({"b":2,"a":1})
    end
  end

  describe "encoding with opts" do
    test "html_safe escaping applies to values" do
      obj = %RustyJson.OrderedObject{values: [{"url", "a/b"}]}
      json = RustyJson.encode!(obj, escape: :html_safe)
      assert json =~ "\\/"
    end

    test "json escape mode does not escape /" do
      obj = %RustyJson.OrderedObject{values: [{"url", "a/b"}]}
      json = RustyJson.encode!(obj, escape: :json)
      refute json =~ "\\/"
    end
  end

  describe "key transforms on decode" do
    test "keys: :atoms transforms ordered object keys" do
      json = ~s({"hello":"world"})
      result = RustyJson.decode!(json, objects: :ordered_objects, keys: :atoms)
      assert %RustyJson.OrderedObject{values: [{:hello, "world"}]} = result
    end

    test "keys: :atoms! transforms ordered object keys with existing atoms" do
      # Ensure atoms exist
      _ = :existing_key
      json = ~s({"existing_key":"value"})
      result = RustyJson.decode!(json, objects: :ordered_objects, keys: :atoms!)
      assert %RustyJson.OrderedObject{values: [{:existing_key, "value"}]} = result
    end

    test "custom key function transforms ordered object keys" do
      json = ~s({"hello":"world","foo":"bar"})
      result = RustyJson.decode!(json, objects: :ordered_objects, keys: &String.upcase/1)
      assert %RustyJson.OrderedObject{values: [{"HELLO", "world"}, {"FOO", "bar"}]} = result
    end
  end

  describe "intern + ordered_objects combination" do
    test "keys: :intern with objects: :ordered_objects" do
      json = ~s([{"b":2,"a":1},{"b":4,"a":3}])
      result = RustyJson.decode!(json, keys: :intern, objects: :ordered_objects)
      assert [obj1, obj2] = result
      assert %RustyJson.OrderedObject{values: [{"b", 2}, {"a", 1}]} = obj1
      assert %RustyJson.OrderedObject{values: [{"b", 4}, {"a", 3}]} = obj2
    end
  end

  describe "ordered object with pretty printing" do
    test "pretty print via Formatter preserves key order" do
      obj = %RustyJson.OrderedObject{values: [{"z", 1}, {"a", 2}]}
      compact = RustyJson.encode!(obj)
      # Verify compact encoding preserves order (the encode test also checks this)
      assert compact == ~s({"z":1,"a":2})
      # Pretty printing operates on the JSON string, so order is preserved
      pretty = RustyJson.Formatter.pretty_print(compact)
      assert pretty =~ ~r/"z".*"a"/s
    end

    test "pretty: true produces multi-line indented output" do
      obj = %RustyJson.OrderedObject{values: [{"b", 2}, {"a", 1}]}
      result = RustyJson.encode!(obj, pretty: true)
      expected = "{\n  \"b\": 2,\n  \"a\": 1\n}"
      assert result == expected
    end

    test "pretty: true with nested ordered object" do
      inner = %RustyJson.OrderedObject{values: [{"x", 10}]}
      outer = %RustyJson.OrderedObject{values: [{"nested", inner}, {"top", true}]}
      result = RustyJson.encode!(outer, pretty: true)
      expected = "{\n  \"nested\": {\n    \"x\": 10\n  },\n  \"top\": true\n}"
      assert result == expected
    end

    test "pretty: true with ordered object inside a map" do
      obj = %RustyJson.OrderedObject{values: [{"b", 2}, {"a", 1}]}
      result = RustyJson.encode!(%{data: obj}, pretty: true)
      assert result =~ "\"b\": 2"
      assert result =~ "\"a\": 1"
      assert result =~ "\n"
    end

    test "pretty: true with ordered object inside a list" do
      obj = %RustyJson.OrderedObject{values: [{"b", 2}, {"a", 1}]}
      result = RustyJson.encode!([obj], pretty: true)
      expected = "[\n  {\n    \"b\": 2,\n    \"a\": 1\n  }\n]"
      assert result == expected
    end

    test "pretty: true round-trip preserves order" do
      json = ~s({"z":26,"m":13,"a":1})
      obj = RustyJson.decode!(json, objects: :ordered_objects)
      result = RustyJson.encode!(obj, pretty: true)
      expected = "{\n  \"z\": 26,\n  \"m\": 13,\n  \"a\": 1\n}"
      assert result == expected
    end
  end

  describe "invalid objects option" do
    test "raises on invalid option" do
      assert_raise ArgumentError, fn ->
        RustyJson.decode!("{}", objects: :invalid)
      end
    end
  end
end
