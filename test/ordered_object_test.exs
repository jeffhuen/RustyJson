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

  describe "invalid objects option" do
    test "raises on invalid option" do
      assert_raise ArgumentError, fn ->
        RustyJson.decode!("{}", objects: :invalid)
      end
    end
  end
end
