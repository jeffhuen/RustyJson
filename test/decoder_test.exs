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
      assert {:error, _} = RustyJson.decode("01")
      assert {:error, _} = RustyJson.decode("00")
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
      assert {:error, _} = RustyJson.decode(<<34, 0, 34>>)
      # literal newline
      assert {:error, _} = RustyJson.decode(<<34, 10, 34>>)
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
      assert result["a"] == 2
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
      assert {:error, _} = RustyJson.decode("[1,]")
    end

    test "rejects trailing comma in object" do
      assert {:error, _} = RustyJson.decode(~s({"a": 1,}))
    end

    test "rejects single quotes" do
      assert {:error, _} = RustyJson.decode("'hello'")
    end

    test "rejects unquoted keys" do
      assert {:error, _} = RustyJson.decode("{a: 1}")
    end

    test "rejects trailing content" do
      assert {:error, _} = RustyJson.decode("123abc")
      assert {:error, _} = RustyJson.decode("true false")
    end

    test "rejects incomplete array" do
      assert {:error, _} = RustyJson.decode("[1, 2")
    end

    test "rejects incomplete object" do
      assert {:error, _} = RustyJson.decode(~s({"a": 1))
    end

    test "rejects incomplete string" do
      assert {:error, _} = RustyJson.decode(~s("hello))
    end

    # === Nesting depth limit ===
    test "accepts 128 levels of array nesting" do
      json = String.duplicate("[", 128) <> "1" <> String.duplicate("]", 128)
      assert {:ok, _} = RustyJson.decode(json)
    end

    test "rejects 129 levels of array nesting" do
      json = String.duplicate("[", 129) <> "1" <> String.duplicate("]", 129)
      assert {:error, msg} = RustyJson.decode(json)
      assert msg =~ "Nesting depth"
    end

    test "accepts 128 levels of object nesting" do
      json = String.duplicate("{\"a\":", 128) <> "1" <> String.duplicate("}", 128)
      assert {:ok, _} = RustyJson.decode(json)
    end

    test "rejects 129 levels of object nesting" do
      json = String.duplicate("{\"a\":", 129) <> "1" <> String.duplicate("}", 129)
      assert {:error, msg} = RustyJson.decode(json)
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
end
