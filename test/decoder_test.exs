defmodule DecoderTest do
  use ExUnit.Case

  describe "Basic Decoding" do
    test "simple map" do
      assert RustyJson.decode!(~s({"foo":5})) == %{"foo" => 5}
    end

    test "charlist input" do
      assert RustyJson.decode!(~c({"foo":5})) == %{"foo" => 5}
    end
  end

  describe "JSON spec compliance" do
    # === Primitives ===
    test "null" do
      assert RustyJson.decode!("null") == nil
    end

    test "true" do
      assert RustyJson.decode!("true") == true
    end

    test "false" do
      assert RustyJson.decode!("false") == false
    end

    # === Numbers ===
    test "integer zero" do
      assert RustyJson.decode!("0") == 0
    end

    test "positive integer" do
      assert RustyJson.decode!("123") == 123
    end

    test "negative integer" do
      assert RustyJson.decode!("-123") == -123
    end

    test "float with decimal" do
      assert RustyJson.decode!("123.456") == 123.456
    end

    test "float with exponent" do
      assert RustyJson.decode!("1e10") == 1.0e10
    end

    test "float with negative exponent" do
      assert RustyJson.decode!("1e-10") == 1.0e-10
    end

    test "float with positive exponent sign" do
      assert RustyJson.decode!("1e+10") == 1.0e10
    end

    test "float with decimal and exponent" do
      assert RustyJson.decode!("1.5e10") == 1.5e10
    end

    test "negative float" do
      assert RustyJson.decode!("-123.456") == -123.456
    end

    test "large integer" do
      assert RustyJson.decode!("9223372036854775807") == 9_223_372_036_854_775_807
    end

    test "large negative integer" do
      assert RustyJson.decode!("-9223372036854775808") == -9_223_372_036_854_775_808
    end

    # Leading zeros should be rejected
    test "rejects leading zeros" do
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.decode("01")
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.decode("00")
    end

    # === Strings ===
    test "empty string" do
      assert RustyJson.decode!(~s("")) == ""
    end

    test "simple string" do
      assert RustyJson.decode!(~s("hello")) == "hello"
    end

    test "string with spaces" do
      assert RustyJson.decode!(~s("hello world")) == "hello world"
    end

    test "escape: quote" do
      assert RustyJson.decode!(~s("a\\"b")) == "a\"b"
    end

    test "escape: backslash" do
      assert RustyJson.decode!(~s("a\\\\b")) == "a\\b"
    end

    test "escape: forward slash" do
      assert RustyJson.decode!(~s("a\\/b")) == "a/b"
    end

    test "escape: backspace" do
      assert RustyJson.decode!(~s("a\\bb")) == "a\bb"
    end

    test "escape: form feed" do
      assert RustyJson.decode!(~s("a\\fb")) == "a\fb"
    end

    test "escape: newline" do
      assert RustyJson.decode!(~s("a\\nb")) == "a\nb"
    end

    test "escape: carriage return" do
      assert RustyJson.decode!(~s("a\\rb")) == "a\rb"
    end

    test "escape: tab" do
      assert RustyJson.decode!(~s("a\\tb")) == "a\tb"
    end

    test "escape: unicode BMP" do
      assert RustyJson.decode!(~s("\\u0041")) == "A"
      assert RustyJson.decode!(~s("\\u00e9")) == "é"
      assert RustyJson.decode!(~s("\\u4e2d")) == "中"
    end

    test "escape: unicode surrogate pair (emoji)" do
      # 😀 is U+1F600, encoded as \uD83D\uDE00
      assert RustyJson.decode!(~s("\\uD83D\\uDE00")) == "😀"
    end

    test "raw UTF-8 characters" do
      assert RustyJson.decode!(~s("日本語")) == "日本語"
      assert RustyJson.decode!(~s("émoji: 🎉")) == "émoji: 🎉"
    end

    test "rejects unescaped control characters" do
      # Control characters (0x00-0x1F) must be escaped
      # "\x00"
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.decode(<<34, 0, 34>>)
      # literal newline
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.decode(<<34, 10, 34>>)
    end

    # === Arrays ===
    test "empty array" do
      assert RustyJson.decode!("[]") == []
    end

    test "array with one element" do
      assert RustyJson.decode!("[1]") == [1]
    end

    test "array with multiple elements" do
      assert RustyJson.decode!("[1, 2, 3]") == [1, 2, 3]
    end

    test "array with mixed types" do
      assert RustyJson.decode!(~s([1, "two", true, null])) == [1, "two", true, nil]
    end

    test "nested arrays" do
      assert RustyJson.decode!("[[1, 2], [3, 4]]") == [[1, 2], [3, 4]]
    end

    test "deeply nested arrays" do
      json = "[[[[[[[[[[1]]]]]]]]]]"
      assert RustyJson.decode!(json) == [[[[[[[[[[1]]]]]]]]]]
    end

    # === Objects ===
    test "empty object" do
      assert RustyJson.decode!("{}") == %{}
    end

    test "object with one key" do
      assert RustyJson.decode!(~s({"a": 1})) == %{"a" => 1}
    end

    test "object with multiple keys" do
      assert RustyJson.decode!(~s({"a": 1, "b": 2})) == %{"a" => 1, "b" => 2}
    end

    test "object with mixed value types" do
      json = ~s({"n": null, "b": true, "i": 42, "s": "str", "a": [1], "o": {}})

      assert RustyJson.decode!(json) == %{
               "n" => nil,
               "b" => true,
               "i" => 42,
               "s" => "str",
               "a" => [1],
               "o" => %{}
             }
    end

    test "nested objects" do
      assert RustyJson.decode!(~s({"a": {"b": {"c": 1}}})) == %{"a" => %{"b" => %{"c" => 1}}}
    end

    test "object with duplicate keys (last wins)" do
      # RFC 8259 says keys SHOULD be unique, but doesn't forbid duplicates
      # We use "last wins" semantics like most parsers
      result = RustyJson.decode!(~s({"a": 1, "a": 2}))
      assert result == %{"a" => 2}
    end

    test "object with duplicate keys preserves non-duplicate keys" do
      result = RustyJson.decode!(~s({"a": 1, "b": 2, "b": 3, "c": 4}))
      assert result == %{"a" => 1, "b" => 3, "c" => 4}
    end

    test "object with duplicate keys at end preserves earlier keys" do
      result = RustyJson.decode!(~s({"a": 1, "b": 2, "b": 3}))
      assert result == %{"a" => 1, "b" => 3}
    end

    # === Whitespace ===
    test "leading whitespace" do
      assert RustyJson.decode!("  \t\n\r123") == 123
    end

    test "trailing whitespace" do
      assert RustyJson.decode!("123  \t\n\r") == 123
    end

    test "whitespace in arrays" do
      assert RustyJson.decode!("[ 1 , 2 , 3 ]") == [1, 2, 3]
    end

    test "whitespace in objects" do
      assert RustyJson.decode!(~s({  "a"  :  1  })) == %{"a" => 1}
    end

    # === Error cases ===
    test "rejects trailing comma in array" do
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.decode("[1,]")
    end

    test "rejects trailing comma in object" do
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.decode(~s({"a": 1,}))
    end

    test "rejects single quotes" do
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.decode("'hello'")
    end

    test "rejects unquoted keys" do
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.decode("{a: 1}")
    end

    test "rejects trailing content" do
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.decode("123abc")
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.decode("true false")
    end

    test "rejects garbage between value and comma in large object (structural index path)" do
      # Construct JSON with a known injection point using unambiguous marker
      valid = large_object("target", "999")
      assert byte_size(valid) >= 256
      assert {:ok, _} = RustyJson.decode(valid)

      # Inject 'x' between value and comma: 999x,
      # The marker "999," is unambiguous — no other value contains "999"
      invalid = String.replace(valid, "999,", "999x,")
      refute valid == invalid
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.decode(invalid)

      # Same pattern must also be rejected on small input (no structural index)
      small = ~s({"a":1x,"b":2})
      assert byte_size(small) < 256
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.decode(small)
    end

    test "rejects garbage between value and closing brace in large object (structural index path)" do
      # Put marker as the last key so its value is followed by }
      padding =
        for i <- 1..10 do
          val = String.duplicate("v", 20)
          ~s("padding_key_#{i}":"#{val}")
        end
        |> Enum.join(",")

      valid = ~s({#{padding},"last":999})
      assert byte_size(valid) >= 256
      assert {:ok, _} = RustyJson.decode(valid)

      # Inject 'x' between value and closing brace: 999x}
      invalid = String.replace(valid, "999}", "999x}")
      refute valid == invalid
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.decode(invalid)

      # Same rejection on small input
      small = ~s({"a":1x})
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.decode(small)
    end

    test "rejects garbage between key and colon in large object (structural index path)" do
      valid = large_object("target", "999")
      assert byte_size(valid) >= 256

      # Inject 'x' between key and colon: "target"x:999
      invalid = String.replace(valid, ~s("target":), ~s("target"x:))
      refute valid == invalid
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.decode(invalid)

      # Same rejection on small input
      small = ~s({"a"x:1})
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.decode(small)
    end

    test "rejects garbage between value and comma in large array (structural index path)" do
      valid = large_array([111, 222, 333])
      assert byte_size(valid) >= 256
      assert {:ok, _} = RustyJson.decode(valid)

      # Inject 'x' after 222: unambiguous since no padding contains "222"
      invalid = String.replace(valid, "222,", "222x,")
      refute valid == invalid
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.decode(invalid)

      # Same rejection on small input
      small = "[1x,2]"
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.decode(small)
    end

    test "correctly parses large arrays with mixed nesting" do
      # Arrays of objects — commas inside objects must not confuse the parser.
      # This exercises the capacity estimator's cross-bracket depth tracking.
      objects =
        for i <- 1..20 do
          ~s({"a":#{i},"b":"val#{i}","c":#{i * 10}})
        end
        |> Enum.join(",")

      json = "[#{objects}]"
      assert byte_size(json) >= 256
      {:ok, result} = RustyJson.decode(json)
      assert length(result) == 20
      assert hd(result) == %{"a" => 1, "b" => "val1", "c" => 10}
      assert List.last(result) == %{"a" => 20, "b" => "val20", "c" => 200}
    end

    test "correctly parses large objects with nested arrays" do
      # Object values containing arrays — commas inside arrays must not
      # confuse the parser.
      entries =
        for i <- 1..15 do
          ~s("key#{i}":[#{i},#{i + 1},#{i + 2},#{i + 3}])
        end
        |> Enum.join(",")

      json = "{#{entries}}"
      assert byte_size(json) >= 256
      {:ok, result} = RustyJson.decode(json)
      assert map_size(result) == 15
      assert result["key1"] == [1, 2, 3, 4]
      assert result["key15"] == [15, 16, 17, 18]
    end

    test "rejects incomplete array" do
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.decode("[1, 2")
    end

    test "rejects incomplete object" do
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.decode(~s({"a": 1))
    end

    test "rejects incomplete string" do
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.decode(~s("hello))
    end

    # === Nesting depth limit ===
    test "accepts 128 levels of array nesting" do
      json = String.duplicate("[", 128) <> "1" <> String.duplicate("]", 128)
      assert {:ok, _} = RustyJson.decode(json)
    end

    test "rejects 129 levels of array nesting" do
      json = String.duplicate("[", 129) <> "1" <> String.duplicate("]", 129)
      assert {:error, %RustyJson.DecodeError{message: msg}} = RustyJson.decode(json)
      assert msg =~ "Nesting depth"
    end

    test "accepts 128 levels of object nesting" do
      json = String.duplicate("{\"a\":", 128) <> "1" <> String.duplicate("}", 128)
      assert {:ok, _} = RustyJson.decode(json)
    end

    test "rejects 129 levels of object nesting" do
      json = String.duplicate("{\"a\":", 129) <> "1" <> String.duplicate("}", 129)
      assert {:error, %RustyJson.DecodeError{message: msg}} = RustyJson.decode(json)
      assert msg =~ "Nesting depth"
    end

    # === Round-trip encoding/decoding ===
    test "round-trip: complex structure" do
      data = %{
        "null" => nil,
        "bool" => true,
        "int" => 42,
        "float" => 3.14,
        "string" => "hello\nworld",
        "unicode" => "日本語 🎉",
        "array" => [1, 2, 3],
        "nested" => %{"a" => %{"b" => [1, 2]}}
      }

      assert RustyJson.decode!(RustyJson.encode!(data)) == data
    end
  end

  describe "decode with keys: :intern" do
    test "decodes array of objects correctly" do
      json = ~s([{"id":1,"name":"a"},{"id":2,"name":"b"}])

      assert RustyJson.decode!(json, keys: :intern) ==
               [%{"id" => 1, "name" => "a"}, %{"id" => 2, "name" => "b"}]
    end

    test "handles empty objects" do
      assert RustyJson.decode!("[{},{}]", keys: :intern) == [%{}, %{}]
    end

    test "handles nested objects" do
      json = ~s([{"user":{"id":1}},{"user":{"id":2}}])
      result = RustyJson.decode!(json, keys: :intern)
      assert result == [%{"user" => %{"id" => 1}}, %{"user" => %{"id" => 2}}]
    end

    test "handles escaped keys (not interned but still correct)" do
      json = ~s([{"key\\nwith\\nnewlines":1},{"key\\nwith\\nnewlines":2}])
      result = RustyJson.decode!(json, keys: :intern)
      assert result == [%{"key\nwith\nnewlines" => 1}, %{"key\nwith\nnewlines" => 2}]
    end

    test "handles unicode escaped keys" do
      json = ~s([{"\\u0069d":1},{"\\u0069d":2}])
      result = RustyJson.decode!(json, keys: :intern)
      assert result == [%{"id" => 1}, %{"id" => 2}]
    end

    test "interned keys share binary references across objects" do
      # keys: :intern caches key Terms in the NIF so repeated keys share
      # the same binary. Verify that the key binaries are reference-equal.
      json = ~s([{"id":1,"name":"a"},{"id":2,"name":"b"}])
      [obj1, obj2] = RustyJson.decode!(json, keys: :intern)

      # Extract the actual key binaries from each map
      [key1_id] = for {k, _} <- obj1, k == "id", do: k
      [key2_id] = for {k, _} <- obj2, k == "id", do: k

      # Interned keys should be the exact same binary reference.
      # :erts_debug.same/2 checks term identity (pointer equality).
      assert :erts_debug.same(key1_id, key2_id),
             "expected interned keys to be the same binary reference"
    end

    test "intern does not break on non-object input" do
      # Primitives and arrays have no object keys, but :intern must not crash
      assert RustyJson.decode!("123", keys: :intern) == 123
      assert RustyJson.decode!("true", keys: :intern) == true
      assert RustyJson.decode!(~s("hello"), keys: :intern) == "hello"
      assert RustyJson.decode!("[1,2,3]", keys: :intern) == [1, 2, 3]
    end

    test "handles large arrays of objects" do
      # Generate 100 objects with same keys
      objects = for i <- 1..100, do: %{"id" => i, "name" => "item#{i}", "active" => true}
      json = RustyJson.encode!(objects)
      result = RustyJson.decode!(json, keys: :intern)
      assert result == objects
    end

    test "handles duplicate keys (last wins)" do
      # Even with interning, duplicate keys should follow JSON semantics (last one wins)
      # Include unique keys alongside duplicates to catch key-collapse bugs
      # Use == (not =) because Elixir's = on maps is a subset match that ignores extra keys
      json = ~s([{"a": 1, "x": 99, "a": 2}, {"b": 3, "y": 88, "b": 4}])

      assert RustyJson.decode!(json, keys: :intern) ==
               [%{"a" => 2, "x" => 99}, %{"b" => 4, "y" => 88}]
    end

    test "handles empty keys" do
      json = ~s([{"": 1}, {"": 2}])
      assert RustyJson.decode!(json, keys: :intern) == [%{"" => 1}, %{"" => 2}]
    end

    test "handles repeated keys at different nesting levels" do
      # "id" appears at top level and nested level
      json = ~s([{"id": 1, "nested": {"id": 2}}])
      assert RustyJson.decode!(json, keys: :intern) == [%{"id" => 1, "nested" => %{"id" => 2}}]
    end
  end

  describe "decode with keys: custom_function (Gap 1)" do
    test "custom function applied to keys" do
      json = ~s({"name":"Alice","age":30})
      result = RustyJson.decode!(json, keys: &String.upcase/1)
      assert result == %{"NAME" => "Alice", "AGE" => 30}
    end

    test "custom function applied recursively" do
      json = ~s({"user":{"name":"Alice","role":"admin"}})
      result = RustyJson.decode!(json, keys: &String.upcase/1)
      assert result == %{"USER" => %{"NAME" => "Alice", "ROLE" => "admin"}}
    end

    test "custom function with arrays of objects" do
      json = ~s([{"id":1},{"id":2}])
      result = RustyJson.decode!(json, keys: fn k -> "key_#{k}" end)
      assert result == [%{"key_id" => 1}, %{"key_id" => 2}]
    end

    test "custom function does not affect non-string values" do
      json = ~s({"items":["a","b"]})
      result = RustyJson.decode!(json, keys: &String.upcase/1)
      assert result == %{"ITEMS" => ["a", "b"]}
    end
  end

  describe "decode with keys: :atoms (unsafe, creates atoms)" do
    test ":atoms creates new atoms via String.to_atom/1" do
      json = ~s({"brand_new_atoms_test_key": 1})
      result = RustyJson.decode!(json, keys: :atoms)
      assert result == %{brand_new_atoms_test_key: 1}
    end

    test ":atoms converts existing atoms" do
      json = ~s({"name": "Alice"})
      result = RustyJson.decode!(json, keys: :atoms)
      assert result == %{name: "Alice"}
    end

    test ":atoms works recursively" do
      json = ~s({"user": {"name": "Alice"}})
      result = RustyJson.decode!(json, keys: :atoms)
      assert result == %{user: %{name: "Alice"}}
    end
  end

  describe "decode with keys: :atoms! (strict, existing atoms only)" do
    test ":atoms! raises for non-existing atoms" do
      assert_raise ArgumentError, fn ->
        RustyJson.decode!(~s({"nonexistent_atom_zzzzzz_12345": 1}), keys: :atoms!)
      end
    end

    test ":atoms! converts existing atoms" do
      # :name already exists as an atom
      json = ~s({"name": "Alice"})
      result = RustyJson.decode!(json, keys: :atoms!)
      assert result == %{name: "Alice"}
    end

    test ":atoms! works recursively with existing atoms" do
      json = ~s({"user": {"name": "Alice"}})
      result = RustyJson.decode!(json, keys: :atoms!)
      assert result == %{user: %{name: "Alice"}}
    end
  end

  describe "decode with keys: :copy" do
    test "keys: :copy is accepted and decodes correctly" do
      # :copy is a Jason-compatible alias for :strings. Both produce string keys.
      # This test guards against the option being accidentally rejected.
      json = ~s({"name":"Alice","age":30})
      result = RustyJson.decode!(json, keys: :copy)
      assert result == %{"name" => "Alice", "age" => 30}
    end
  end

  describe "decode with strings: option (Gap 2)" do
    test "strings: :copy and :reference are both accepted and decode correctly" do
      # RustyJson always copies from the NIF, so both options behave identically.
      # This test guards against either option being accidentally rejected.
      json = ~s({"key":"value","nested":{"a":"b"}})
      copy = RustyJson.decode!(json, strings: :copy)
      ref = RustyJson.decode!(json, strings: :reference)
      assert copy == ref
      assert copy == %{"key" => "value", "nested" => %{"a" => "b"}}
    end

    test "invalid strings option raises" do
      assert_raise ArgumentError, fn ->
        RustyJson.decode!("1", strings: :invalid)
      end
    end
  end

  describe "decode with floats: :decimals (Gap 3)" do
    test "floats decoded as Decimal structs" do
      json = ~s({"price":19.99})
      result = RustyJson.decode!(json, floats: :decimals)
      assert %{"price" => %Decimal{}} = result
      assert Decimal.equal?(result["price"], Decimal.new("19.99"))
    end

    test "integer values remain as integers" do
      json = ~s({"count":42})
      result = RustyJson.decode!(json, floats: :decimals)
      assert result == %{"count" => 42}
    end

    test "negative float as decimal" do
      json = ~s(-3.14)
      result = RustyJson.decode!(json, floats: :decimals)
      assert %Decimal{} = result
      assert Decimal.equal?(result, Decimal.new("-3.14"))
    end

    test "float with exponent as decimal" do
      json = ~s(1.5e2)
      result = RustyJson.decode!(json, floats: :decimals)
      assert %Decimal{} = result
      assert Decimal.equal?(result, Decimal.new("150"))
    end

    test "zero float as decimal" do
      json = ~s(0.0)
      result = RustyJson.decode!(json, floats: :decimals)
      assert %Decimal{} = result
      assert Decimal.equal?(result, Decimal.new("0.0"))
    end

    test "invalid floats option raises" do
      assert_raise ArgumentError, fn ->
        RustyJson.decode!("1", floats: :invalid)
      end
    end
  end

  describe "DecodeError struct fields (Gap 8)" do
    test "DecodeError has position and data fields for start-of-input errors" do
      error =
        assert_raise RustyJson.DecodeError, fn ->
          RustyJson.decode!("invalid")
        end

      assert error.position == 0
      assert error.data == "invalid"
      assert is_binary(error.token)
    end

    test "DecodeError position for mid-input errors" do
      error =
        assert_raise RustyJson.DecodeError, fn ->
          RustyJson.decode!(~s({"a": invalid}))
        end

      assert is_integer(error.position)
      assert error.position > 0
      assert error.data == ~s({"a": invalid})
    end

    test "DecodeError has token field" do
      error =
        assert_raise RustyJson.DecodeError, fn ->
          RustyJson.decode!(~s([1, 2, invalid]))
        end

      assert is_binary(error.token)
    end

    test "decode/2 returns DecodeError struct with message" do
      assert {:error, %RustyJson.DecodeError{} = error} = RustyJson.decode("invalid")
      assert is_binary(error.message)
      assert is_integer(error.position)
    end
  end

  describe "large integer precision" do
    test "20-digit integer preserves precision" do
      big = String.duplicate("9", 20)
      result = RustyJson.decode!(big)
      assert is_integer(result)
      assert result == String.to_integer(big)
    end

    test "40-digit integer preserves precision" do
      big = String.duplicate("1", 40)
      result = RustyJson.decode!(big)
      assert is_integer(result)
      assert result == String.to_integer(big)
    end

    test "negative large integer preserves precision" do
      big = "-" <> String.duplicate("9", 25)
      result = RustyJson.decode!(big)
      assert is_integer(result)
      assert result == String.to_integer(big)
    end

    test "round-trip large integer" do
      big = String.to_integer(String.duplicate("9", 30))
      json = RustyJson.encode!(big)
      assert RustyJson.decode!(json) == big
    end
  end

  describe "decode with decoding_integer_digit_limit (Gap 9)" do
    test "default limit of 1024 digits" do
      # Exactly 1024 digits should succeed
      at_limit = String.duplicate("1", 1024)
      assert {:ok, _} = RustyJson.decode(at_limit)

      # 1025 digits should fail
      over_limit = String.duplicate("1", 1025)
      assert {:error, %RustyJson.DecodeError{message: msg}} = RustyJson.decode(over_limit)
      assert msg =~ "digit limit"
    end

    test "rejects integers exceeding digit limit" do
      # Create a number with more than 10 digits
      big_num = String.duplicate("1", 11)
      json = ~s({"n":#{big_num}})

      assert {:error, %RustyJson.DecodeError{message: msg}} =
               RustyJson.decode(json, decoding_integer_digit_limit: 10)

      assert msg =~ "digit limit"
    end

    test "custom digit limit" do
      # 5 digit limit
      json = ~s(12345)
      assert {:ok, 12_345} = RustyJson.decode(json, decoding_integer_digit_limit: 5)

      json = ~s(123456)

      assert {:error, %RustyJson.DecodeError{}} =
               RustyJson.decode(json, decoding_integer_digit_limit: 5)
    end

    test "digit limit of 0 disables the check" do
      # Use a number exceeding the default 1024-digit limit
      # to verify that limit=0 truly disables the check
      big_num = String.duplicate("9", 2000)
      json = big_num
      # First verify it would fail with the default limit
      assert {:error, %RustyJson.DecodeError{}} =
               RustyJson.decode(json, decoding_integer_digit_limit: 1024)

      # Now verify limit=0 allows it
      assert {:ok, result} = RustyJson.decode(json, decoding_integer_digit_limit: 0)
      assert result == String.to_integer(big_num)
    end

    test "floats are not affected by digit limit" do
      json = ~s(1.23456789012345)
      assert {:ok, _} = RustyJson.decode(json, decoding_integer_digit_limit: 5)
    end
  end

  # -- Test helpers --

  # Build a valid JSON object >= 256 bytes with a known marker key/value at the front
  # (followed by a comma), so garbage can be injected at an unambiguous location.
  defp large_object(marker_key, marker_value) do
    padding =
      for i <- 1..10 do
        val = String.duplicate("v", 20)
        ~s("padding_key_#{i}":"#{val}")
      end
      |> Enum.join(",")

    ~s({"#{marker_key}":#{marker_value},#{padding}})
  end

  # Build a valid JSON array >= 256 bytes with padding strings followed by the given values.
  defp large_array(values) do
    padding = Enum.map(1..10, fn i -> ~s("padding_#{String.duplicate("x", 20)}_#{i}") end)
    all = padding ++ Enum.map(values, &to_string/1)
    "[#{Enum.join(all, ",")}]"
  end
end
