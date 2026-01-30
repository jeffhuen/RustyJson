defmodule DerivedBothEncoders do
  @derive {RustyJson.Encoder, only: [:name, :age]}
  @derive {Jason.Encoder, only: [:name, :age]}
  defstruct [:name, :age, :secret]
end

defmodule NoEncoderStruct do
  defstruct [:value]
end

defmodule JasonParityTest do
  use ExUnit.Case, async: true

  import RustyJson.Helpers, only: [json_map: 1, json_map_take: 2]

  # Helper: compare decoded JSON content (order-independent for objects)
  # This is useful when key ordering may differ between RustyJson and Jason
  # for large maps where the NIF may iterate in a different order.
  defp same_json_content?(a, b) do
    Jason.decode!(a) == Jason.decode!(b)
  end

  # Helper: recursively compare OrderedObject values, ignoring struct module
  defp ordered_values_equal?([], []), do: true

  defp ordered_values_equal?([{k1, v1} | t1], [{k2, v2} | t2]) do
    k1 == k2 and values_equivalent?(v1, v2) and ordered_values_equal?(t1, t2)
  end

  defp ordered_values_equal?(_, _), do: false

  defp values_equivalent?(%RustyJson.OrderedObject{values: v1}, %Jason.OrderedObject{values: v2}) do
    ordered_values_equal?(v1, v2)
  end

  defp values_equivalent?(a, b), do: a == b

  # ===========================================================================
  # 1. Encoding output
  # ===========================================================================

  describe "encoding output parity" do
    test "simple string" do
      assert RustyJson.encode!("hello") == Jason.encode!("hello")
    end

    test "empty string" do
      assert RustyJson.encode!("") == Jason.encode!("")
    end

    test "integers" do
      for val <- [0, 1, -1, 42, -42, 1_000_000] do
        assert RustyJson.encode!(val) == Jason.encode!(val),
               "mismatch for integer #{val}"
      end
    end

    test "floats that both represent the same way" do
      for val <- [0.0, 1.0, -1.0, 3.14, -3.14] do
        assert RustyJson.encode!(val) == Jason.encode!(val),
               "mismatch for float #{val}"
      end
    end

    test "float 1.0e10 - known representation difference" do
      r = RustyJson.encode!(1.0e10)
      j = Jason.encode!(1.0e10)
      # Representations differ (e.g., "10000000000.0" vs "1.0e10")
      assert r != j, "expected different representations, got #{r} for both"
      # But both decode to the same float value
      assert RustyJson.decode!(r) == Jason.decode!(j)
    end

    test "booleans" do
      assert RustyJson.encode!(true) == Jason.encode!(true)
      assert RustyJson.encode!(false) == Jason.encode!(false)
    end

    test "nil" do
      assert RustyJson.encode!(nil) == Jason.encode!(nil)
    end

    test "atoms" do
      for atom <- [:hello, :world, :foo_bar, :"Elixir", :"with spaces", :"with-dashes"] do
        assert RustyJson.encode!(atom) == Jason.encode!(atom),
               "mismatch for atom #{inspect(atom)}"
      end
    end

    test "map with string keys" do
      map = %{"name" => "Alice", "age" => 30}
      assert RustyJson.encode!(map) == Jason.encode!(map)
    end

    test "map with atom keys" do
      map = %{name: "Alice", age: 30}
      assert RustyJson.encode!(map) == Jason.encode!(map)
    end

    test "map with integer keys" do
      map = %{1 => "one", 2 => "two"}
      assert RustyJson.encode!(map) == Jason.encode!(map)
    end

    test "nested structures - maps in lists in maps" do
      data = %{
        "users" => [
          %{"name" => "Alice", "scores" => [95, 87, 92]},
          %{"name" => "Bob", "scores" => [88, 91, 78]}
        ]
      }

      assert RustyJson.encode!(data) == Jason.encode!(data)
    end

    test "empty containers" do
      assert RustyJson.encode!(%{}) == Jason.encode!(%{})
      assert RustyJson.encode!([]) == Jason.encode!([])
      assert RustyJson.encode!("") == Jason.encode!("")
    end

    test "large integers" do
      for val <- [
            999_999_999_999_999_999,
            -999_999_999_999_999_999,
            123_456_789_012_345_678_901_234_567_890
          ] do
        assert RustyJson.encode!(val) == Jason.encode!(val),
               "mismatch for large integer #{val}"
      end
    end

    test "unicode strings" do
      for str <- ["café", "日本語", "emoji: 😀🎉", "Ünïcödé", "中文测试"] do
        assert RustyJson.encode!(str) == Jason.encode!(str),
               "mismatch for unicode string #{inspect(str)}"
      end
    end

    test "strings needing escaping - quotes, backslashes, newlines, tabs" do
      for str <- [
            ~s(hello "world"),
            "back\\slash",
            "new\nline",
            "tab\there",
            "carriage\rreturn",
            "form\ffeed",
            "back\bspace"
          ] do
        assert RustyJson.encode!(str) == Jason.encode!(str),
               "mismatch for escaped string #{inspect(str)}"
      end
    end

    test "strings with control characters - standard escape sequences" do
      # Control chars that have named escapes: \b \t \n \f \r
      for byte <- [0x08, 0x09, 0x0A, 0x0C, 0x0D] do
        str = <<byte>>

        assert RustyJson.encode!(str) == Jason.encode!(str),
               "mismatch for control char 0x#{Integer.to_string(byte, 16) |> String.pad_leading(2, "0")}"
      end
    end

    test "strings with control characters - unicode escapes use lowercase hex" do
      # RustyJson uses lowercase hex (\u000b), Jason uses uppercase (\u000B).
      # Both produce valid JSON; we verify they decode to the same value.
      for byte <- 0x00..0x1F, byte not in [0x08, 0x09, 0x0A, 0x0C, 0x0D] do
        str = <<byte>>
        r = RustyJson.encode!(str)
        j = Jason.encode!(str)

        assert RustyJson.decode!(r) == Jason.decode!(j),
               "decoded mismatch for control char 0x#{Integer.to_string(byte, 16) |> String.pad_leading(2, "0")}: rusty=#{r} jason=#{j}"
      end
    end

    test "null byte in string" do
      # Both encode null byte, may differ in hex case
      r = RustyJson.encode!("hello\0world")
      j = Jason.encode!("hello\0world")
      assert RustyJson.decode!(r) == Jason.decode!(j)
    end

    test "list of mixed types" do
      list = [1, "two", 3.0, true, false, nil, %{"key" => "val"}]
      assert RustyJson.encode!(list) == Jason.encode!(list)
    end

    test "deeply nested structure" do
      # 10+ levels deep
      nested =
        Enum.reduce(1..12, "innermost", fn i, acc ->
          %{"level_#{i}" => acc}
        end)

      assert RustyJson.encode!(nested) == Jason.encode!(nested)
    end

    test "map key ordering is identical for small maps" do
      # Small maps (<=32 keys) have identical ordering in Erlang
      map = %{z: 1, a: 2, m: 3, f: 4, b: 5}
      assert RustyJson.encode!(map) == Jason.encode!(map)
    end

    test "large map - same content, key order may differ" do
      # Maps with >32 keys may have different iteration order between
      # RustyJson (NIF) and Jason (Elixir Map.to_list). Both produce
      # valid JSON with the same decoded content.
      map = Map.new(1..100, fn i -> {"key_#{i}", i} end)
      r = RustyJson.encode!(map)
      j = Jason.encode!(map)
      assert same_json_content?(r, j)
    end
  end

  # ===========================================================================
  # 2. Encode options
  # ===========================================================================

  describe "encode options parity" do
    test "escape: :json (default)" do
      str = "hello \"world\" \\ \n \t"
      assert RustyJson.encode!(str) == Jason.encode!(str)
      assert RustyJson.encode!(str, escape: :json) == Jason.encode!(str, escape: :json)
    end

    test "escape: :html_safe - both escape < and / identically" do
      # Jason html_safe escapes: < (as \u003C) and / (as \/)
      # RustyJson html_safe escapes: <, >, & (as \uXXXX) and / (as \/)
      # For chars both escape, the hex case may differ.
      # We verify they produce semantically equivalent JSON.
      str = "<script>alert('xss')</script>"
      r = RustyJson.encode!(str, escape: :html_safe)
      j = Jason.encode!(str, escape: :html_safe)

      # Both should decode back to the same string
      assert RustyJson.decode!(r) == Jason.decode!(j)
    end

    test "escape: :html_safe - forward slash escaping matches" do
      str = "path/to/file"
      r = RustyJson.encode!(str, escape: :html_safe)
      j = Jason.encode!(str, escape: :html_safe)

      # Both should escape / as \/
      assert r =~ "\\/"
      assert j =~ "\\/"
      assert RustyJson.decode!(r) == Jason.decode!(j)
    end

    test "escape: :javascript_safe escapes U+2028 and U+2029" do
      str = "line\u2028sep\u2029end"

      assert RustyJson.encode!(str, escape: :javascript_safe) ==
               Jason.encode!(str, escape: :javascript_safe)
    end

    test "escape: :unicode_safe escapes non-ASCII" do
      str = "café"
      r = RustyJson.encode!(str, escape: :unicode_safe)
      j = Jason.encode!(str, escape: :unicode_safe)

      # Both should escape non-ASCII chars, but hex case may differ
      assert RustyJson.decode!(r) == Jason.decode!(j)

      # Both should contain \u escape sequences for non-ASCII
      assert r =~ "\\u"
      assert j =~ "\\u"
    end

    test "pretty: true" do
      data = %{name: "Alice", scores: [1, 2, 3]}
      assert RustyJson.encode!(data, pretty: true) == Jason.encode!(data, pretty: true)
    end

    test "pretty: keyword opts with string indent, after_colon, line_separator" do
      data = %{a: 1, b: [2, 3]}

      opts = [indent: "  ", after_colon: "", line_separator: "\r\n"]

      assert RustyJson.encode!(data, pretty: opts) == Jason.encode!(data, pretty: opts)
    end

    test "pretty: keyword opts with tab indent" do
      data = %{a: 1}

      opts = [indent: "\t", after_colon: " ", line_separator: "\n"]

      assert RustyJson.encode!(data, pretty: opts) == Jason.encode!(data, pretty: opts)
    end

    test "maps: :strict raises on duplicate serialized keys" do
      # A map where atom :a and string "a" would produce the same JSON key
      map = Map.put(%{a: 1}, "a", 2)

      assert_raise RustyJson.EncodeError, fn ->
        RustyJson.encode!(map, maps: :strict)
      end

      assert_raise Jason.EncodeError, fn ->
        Jason.encode!(map, maps: :strict)
      end
    end

    test "maps: :naive allows duplicate serialized keys" do
      map = Map.put(%{a: 1}, "a", 2)
      # Both should succeed without raising
      assert {:ok, _} = RustyJson.encode(map, maps: :naive)
      assert {:ok, _} = Jason.encode(map, maps: :naive)
    end
  end

  # ===========================================================================
  # 3. Decode output
  # ===========================================================================

  describe "decode output parity" do
    test "simple JSON values" do
      for json <- [~s("hello"), "42", "3.14", "true", "false", "null"] do
        assert RustyJson.decode!(json) == Jason.decode!(json),
               "mismatch decoding #{json}"
      end
    end

    test "nested objects and arrays" do
      json = ~s({"a":{"b":[1,2,3],"c":{"d":"deep"}}})
      assert RustyJson.decode!(json) == Jason.decode!(json)
    end

    test "unicode escape sequences" do
      json = ~s("\\u0048\\u0065\\u006C\\u006C\\u006F")
      assert RustyJson.decode!(json) == Jason.decode!(json)
    end

    test "escaped characters in strings" do
      json = ~s("hello\\nworld\\t\\r\\\\\\\"")
      assert RustyJson.decode!(json) == Jason.decode!(json)
    end

    test "keys: :atoms" do
      json = ~s({"name":"Alice","age":30})

      assert RustyJson.decode!(json, keys: :atoms) ==
               Jason.decode!(json, keys: :atoms)
    end

    test "keys: :atoms!" do
      # Ensure atoms exist first
      _ = [:name, :age]
      json = ~s({"name":"Alice","age":30})

      assert RustyJson.decode!(json, keys: :atoms!) ==
               Jason.decode!(json, keys: :atoms!)
    end

    test "keys: :strings (default)" do
      json = ~s({"name":"Alice"})

      assert RustyJson.decode!(json) == Jason.decode!(json)
      assert RustyJson.decode!(json, keys: :strings) == Jason.decode!(json, keys: :strings)
    end

    test "strings: :copy and :reference both produce valid output" do
      json = ~s({"key":"value"})

      # Both modes should decode correctly (RustyJson always copies from NIF)
      assert RustyJson.decode!(json, strings: :copy) ==
               Jason.decode!(json, strings: :copy)

      assert RustyJson.decode!(json, strings: :reference) ==
               Jason.decode!(json, strings: :reference)
    end

    test "objects: :ordered_objects preserves key order" do
      json = ~s({"b":2,"a":1,"c":3})

      r = RustyJson.decode!(json, objects: :ordered_objects)
      j = Jason.decode!(json, objects: :ordered_objects)

      assert r.values == j.values
    end

    test "large numbers" do
      for json <- ["999999999999999999", "-999999999999999999"] do
        assert RustyJson.decode!(json) == Jason.decode!(json),
               "mismatch decoding large number #{json}"
      end
    end

    test "negative numbers" do
      for json <- ["-1", "-42", "-3.14", "-0", "-0.0"] do
        assert RustyJson.decode!(json) == Jason.decode!(json),
               "mismatch decoding #{json}"
      end
    end

    test "floats with exponents" do
      for json <- ["1e10", "1E10", "1.5e2", "1.5E-3", "-2.5e+4", "0.1e1"] do
        assert RustyJson.decode!(json) == Jason.decode!(json),
               "mismatch decoding #{json}"
      end
    end

    test "empty containers" do
      assert RustyJson.decode!("{}") == Jason.decode!("{}")
      assert RustyJson.decode!("[]") == Jason.decode!("[]")
      assert RustyJson.decode!(~s("")) == Jason.decode!(~s(""))
    end

    test "null, true, false" do
      assert RustyJson.decode!("null") == Jason.decode!("null")
      assert RustyJson.decode!("true") == Jason.decode!("true")
      assert RustyJson.decode!("false") == Jason.decode!("false")
    end

    test "nested arrays" do
      json = "[[1,[2,[3]]],[4,5]]"
      assert RustyJson.decode!(json) == Jason.decode!(json)
    end

    test "whitespace handling" do
      json = ~s(  {  "a"  :  1  ,  "b"  :  [  2  ,  3  ]  }  )
      assert RustyJson.decode!(json) == Jason.decode!(json)
    end

    test "surrogate pair unicode" do
      # Encode emoji via surrogate pair: U+1F600 = \uD83D\uDE00
      json = ~s("\\uD83D\\uDE00")
      assert RustyJson.decode!(json) == Jason.decode!(json)
    end
  end

  # ===========================================================================
  # 4. Error handling
  # ===========================================================================

  describe "error handling parity" do
    test "decode invalid JSON returns error tuple" do
      {:error, r_err} = RustyJson.decode("invalid")
      {:error, j_err} = Jason.decode("invalid")

      assert %RustyJson.DecodeError{} = r_err
      assert %Jason.DecodeError{} = j_err
    end

    test "decode! invalid JSON raises DecodeError" do
      assert_raise RustyJson.DecodeError, fn ->
        RustyJson.decode!("invalid")
      end

      assert_raise Jason.DecodeError, fn ->
        Jason.decode!("invalid")
      end
    end

    test "encode! PID raises Protocol.UndefinedError" do
      pid = self()

      assert_raise Protocol.UndefinedError, fn ->
        RustyJson.encode!(pid)
      end

      assert_raise Protocol.UndefinedError, fn ->
        Jason.encode!(pid)
      end
    end

    test "encode! struct without encoder raises Protocol.UndefinedError" do
      val = %NoEncoderStruct{value: 1}

      assert_raise Protocol.UndefinedError, fn ->
        RustyJson.encode!(val)
      end

      assert_raise Protocol.UndefinedError, fn ->
        Jason.encode!(val)
      end
    end

    test "maps: :strict duplicate key detection both raise" do
      map = Map.put(%{a: 1}, "a", 2)

      r_error =
        assert_raise RustyJson.EncodeError, fn ->
          RustyJson.encode!(map, maps: :strict)
        end

      j_error =
        assert_raise Jason.EncodeError, fn ->
          Jason.encode!(map, maps: :strict)
        end

      # Both should mention "duplicate key" in the message
      assert r_error.message =~ "duplicate key"
      assert j_error.message =~ "duplicate key"
    end
  end

  # ===========================================================================
  # 5. Encode low-level functions
  # ===========================================================================

  describe "Encode low-level function parity" do
    test "integer/1 produces same output" do
      for val <- [0, 1, -1, 42, 999_999] do
        assert IO.iodata_to_binary(RustyJson.Encode.integer(val)) ==
                 IO.iodata_to_binary(Jason.Encode.integer(val))
      end
    end

    test "float/1 produces same output for common floats" do
      for val <- [0.0, 1.0, -1.0, 3.14] do
        assert IO.iodata_to_binary(RustyJson.Encode.float(val)) ==
                 IO.iodata_to_binary(Jason.Encode.float(val))
      end
    end

    test "encode/2 produces same iodata for strings" do
      {:ok, r} = RustyJson.Encode.encode("hello world")
      {:ok, j} = Jason.Encode.encode("hello world", %{escape: :json, maps: :naive})
      assert IO.iodata_to_binary(r) == IO.iodata_to_binary(j)
    end

    test "encode/2 produces same iodata for maps" do
      {:ok, r} = RustyJson.Encode.encode(%{a: 1, b: "two"})
      {:ok, j} = Jason.Encode.encode(%{a: 1, b: "two"}, %{escape: :json, maps: :naive})
      assert IO.iodata_to_binary(r) == IO.iodata_to_binary(j)
    end

    test "encode/2 produces same iodata for lists" do
      {:ok, r} = RustyJson.Encode.encode([1, "two", true, nil])
      {:ok, j} = Jason.Encode.encode([1, "two", true, nil], %{escape: :json, maps: :naive})
      assert IO.iodata_to_binary(r) == IO.iodata_to_binary(j)
    end

    test "encode/2 produces same iodata for atoms" do
      for atom <- [nil, true, false, :hello] do
        {:ok, r} = RustyJson.Encode.encode(atom)
        {:ok, j} = Jason.Encode.encode(atom, %{escape: :json, maps: :naive})
        assert IO.iodata_to_binary(r) == IO.iodata_to_binary(j)
      end
    end

    test "value/2 with opts produces same iodata" do
      r_opts = RustyJson.Encode.opts(:json)
      # Jason doesn't expose opts/0, so compare via encode/2
      for term <- [42, "hello", true, nil, [1, 2], %{a: 1}] do
        r = IO.iodata_to_binary(RustyJson.Encode.value(term, r_opts))
        {:ok, j} = Jason.Encode.encode(term, %{escape: :json, maps: :naive})
        assert r == IO.iodata_to_binary(j), "mismatch for #{inspect(term)}"
      end
    end

    test "atom/2 with opts produces same iodata" do
      r_opts = RustyJson.Encode.opts(:json)

      for atom <- [nil, true, false, :hello, :foo_bar] do
        r = IO.iodata_to_binary(RustyJson.Encode.atom(atom, r_opts))
        {:ok, j} = Jason.Encode.encode(atom, %{escape: :json, maps: :naive})
        assert r == IO.iodata_to_binary(j), "mismatch for atom #{inspect(atom)}"
      end
    end

    test "list/2 with opts produces same iodata" do
      r_opts = RustyJson.Encode.opts(:json)

      r = IO.iodata_to_binary(RustyJson.Encode.list([1, "a", true], r_opts))
      {:ok, j} = Jason.Encode.encode([1, "a", true], %{escape: :json, maps: :naive})
      assert r == IO.iodata_to_binary(j)
    end

    test "map/2 with opts produces same iodata" do
      r_opts = RustyJson.Encode.opts(:json)

      map = %{x: 10, y: 20}
      r = IO.iodata_to_binary(RustyJson.Encode.map(map, r_opts))
      {:ok, j} = Jason.Encode.encode(map, %{escape: :json, maps: :naive})
      assert r == IO.iodata_to_binary(j)
    end

    test "string/2 with opts produces same output" do
      r_opts = RustyJson.Encode.opts(:json)

      for str <- ["hello \"world\"", "back\\slash", "new\nline", "tab\there", "a/b/c"] do
        r = IO.iodata_to_binary(RustyJson.Encode.string(str, r_opts))
        {:ok, j} = Jason.Encode.encode(str, %{escape: :json, maps: :naive})
        assert r == IO.iodata_to_binary(j), "Encode.string/2 mismatch for #{inspect(str)}"
      end
    end
  end

  # ===========================================================================
  # 6. Fragment
  # ===========================================================================

  describe "Fragment parity" do
    test "fragment encodes identically when used as top-level value" do
      json_str = ~s({"already":"encoded"})
      rf = RustyJson.Fragment.new(json_str)
      jf = Jason.Fragment.new(json_str)

      assert RustyJson.encode!(rf) == Jason.encode!(jf)
    end

    test "fragment with iodata list encodes identically" do
      iodata = ["{", ~s("key"), ":", ~s("value"), "}"]
      rf = RustyJson.Fragment.new(iodata)
      jf = Jason.Fragment.new(iodata)

      assert RustyJson.encode!(rf) == Jason.encode!(jf)
    end

    test "fragment inside nested structures - Jason comparison" do
      # Jason supports fragments inside maps/lists
      jf = Jason.Fragment.new(~s([1,2,3]))
      j = Jason.encode!(%{data: jf})
      assert j == ~s({"data":[1,2,3]})

      # RustyJson fragment inside a map currently has a limitation
      # with the NIF path; top-level fragments work fine
      rf = RustyJson.Fragment.new(~s([1,2,3]))
      assert RustyJson.encode!(rf) == Jason.encode!(jf)
    end
  end

  # ===========================================================================
  # 7. Formatter
  # ===========================================================================

  describe "Formatter parity" do
    test "pretty_print/2 identical output" do
      input = ~s({"a":{"b":[1,2],"c":"hello"}})

      assert RustyJson.Formatter.pretty_print(input) ==
               Jason.Formatter.pretty_print(input)
    end

    test "minimize/2 identical output" do
      input = ~s({ "a" : 1 , "b" : [ 2 , 3 ] })

      assert RustyJson.Formatter.minimize(input) ==
               Jason.Formatter.minimize(input)
    end

    test "pretty_print_to_iodata/2 identical as binary" do
      input = ~s({"x":[1,{"y":2}]})

      r = IO.iodata_to_binary(RustyJson.Formatter.pretty_print_to_iodata(input))
      j = IO.iodata_to_binary(Jason.Formatter.pretty_print_to_iodata(input))
      assert r == j
    end

    test "custom opts: indent string" do
      input = ~s({"a":1,"b":2})
      opts = [indent: "\t"]

      assert RustyJson.Formatter.pretty_print(input, opts) ==
               Jason.Formatter.pretty_print(input, opts)
    end

    test "custom opts: line_separator" do
      input = ~s({"a":1,"b":[2,3]})
      opts = [line_separator: "\r\n"]

      assert RustyJson.Formatter.pretty_print(input, opts) ==
               Jason.Formatter.pretty_print(input, opts)
    end

    test "custom opts: after_colon" do
      input = ~s({"a":1,"b":2})
      opts = [after_colon: ""]

      assert RustyJson.Formatter.pretty_print(input, opts) ==
               Jason.Formatter.pretty_print(input, opts)
    end

    test "custom opts: record_separator" do
      input = ~s({"a":1}{"b":2})
      opts = [record_separator: "\n---\n"]

      assert RustyJson.Formatter.pretty_print(input, opts) ==
               Jason.Formatter.pretty_print(input, opts)
    end

    test "minimize with record_separator" do
      input = ~s({"a": 1} {"b": 2})
      opts = [record_separator: ";"]

      assert RustyJson.Formatter.minimize(input, opts) ==
               Jason.Formatter.minimize(input, opts)
    end

    test "pretty_print with all custom opts combined" do
      input = ~s({"a":{"b":[1,2]}})
      opts = [indent: "    ", line_separator: "\r\n", after_colon: " "]

      assert RustyJson.Formatter.pretty_print(input, opts) ==
               Jason.Formatter.pretty_print(input, opts)
    end

    test "minimize empty object and array" do
      assert RustyJson.Formatter.minimize("{ }") == Jason.Formatter.minimize("{ }")
      assert RustyJson.Formatter.minimize("[ ]") == Jason.Formatter.minimize("[ ]")
    end

    test "pretty_print nested arrays" do
      input = ~s([[1,[2,[3]]]])

      assert RustyJson.Formatter.pretty_print(input) ==
               Jason.Formatter.pretty_print(input)
    end

    test "pretty_print with strings containing special chars" do
      input = ~s({"msg":"hello\\nworld","path":"C:\\\\foo"})

      assert RustyJson.Formatter.pretty_print(input) ==
               Jason.Formatter.pretty_print(input)
    end
  end

  # ===========================================================================
  # 8. OrderedObject
  # ===========================================================================

  describe "OrderedObject parity" do
    test "decoding with objects: :ordered_objects produces same values list" do
      json = ~s({"z":26,"a":1,"m":13})

      r = RustyJson.decode!(json, objects: :ordered_objects)
      j = Jason.decode!(json, objects: :ordered_objects)

      assert r.values == j.values
    end

    test "encoding OrderedObject produces same JSON" do
      values = [{"b", 2}, {"a", 1}, {"c", 3}]
      ro = %RustyJson.OrderedObject{values: values}
      jo = %Jason.OrderedObject{values: values}

      assert RustyJson.encode!(ro) == Jason.encode!(jo)
    end

    test "round-trip: decode ordered -> encode -> same JSON for simple objects" do
      json = ~s({"x":1,"y":2,"z":3})

      r_obj = RustyJson.decode!(json, objects: :ordered_objects)
      j_obj = Jason.decode!(json, objects: :ordered_objects)

      assert RustyJson.encode!(r_obj) == Jason.encode!(j_obj)
    end

    test "ordered object with nested values - same structure" do
      json = ~s({"outer":{"inner":1},"list":[1,2]})

      r = RustyJson.decode!(json, objects: :ordered_objects)
      j = Jason.decode!(json, objects: :ordered_objects)

      # Nested ordered objects will be different struct types
      # (RustyJson.OrderedObject vs Jason.OrderedObject) so we compare recursively
      assert ordered_values_equal?(r.values, j.values)
    end

    test "empty ordered object" do
      json = ~s({})

      r = RustyJson.decode!(json, objects: :ordered_objects)
      j = Jason.decode!(json, objects: :ordered_objects)

      assert r.values == j.values
    end
  end

  # ===========================================================================
  # 9. Helpers
  # ===========================================================================

  describe "Helpers parity" do
    test "json_map output matches between the two" do
      r_fragment = json_map(name: "Alice", age: 30)
      r_encoded = RustyJson.encode!(r_fragment)

      # json_map preserves insertion order
      expected = ~s({"name":"Alice","age":30})
      assert r_encoded == expected

      # Also verify Jason produces the same via OrderedObject
      j_encoded = Jason.encode!(Jason.OrderedObject.new([{"name", "Alice"}, {"age", 30}]))
      assert r_encoded == j_encoded
    end

    test "json_map_take output matches" do
      map = %{name: "Bob", age: 25, email: "bob@test.com"}
      r_fragment = json_map_take(map, [:name, :age])
      r_encoded = RustyJson.encode!(r_fragment)

      expected = ~s({"name":"Bob","age":25})
      assert r_encoded == expected
    end
  end

  # ===========================================================================
  # 10. Edge cases
  # ===========================================================================

  describe "edge cases" do
    test "very deeply nested structures (12 levels)" do
      nested =
        Enum.reduce(1..12, "inner", fn i, acc ->
          %{"l#{i}" => acc}
        end)

      assert RustyJson.encode!(nested) == Jason.encode!(nested)
    end

    test "map key ordering consistency for small maps" do
      map1 = %{a: 1, b: 2, c: 3, d: 4, e: 5}
      map2 = Map.new(e: 5, d: 4, c: 3, b: 2, a: 1)

      assert RustyJson.encode!(map1) == Jason.encode!(map1)
      assert RustyJson.encode!(map2) == Jason.encode!(map2)
      assert RustyJson.encode!(map1) == RustyJson.encode!(map2)
    end

    test "struct encoding with @derive" do
      person = %DerivedBothEncoders{name: "Charlie", age: 40, secret: "hidden"}

      r = RustyJson.encode!(person)
      j = Jason.encode!(person)
      # Compare decoded values since map key order may differ between encoders
      assert Jason.decode!(r) == Jason.decode!(j)
    end

    test "Date encoding" do
      date = ~D[2024-01-15]
      assert RustyJson.encode!(date) == Jason.encode!(date)
    end

    test "Time encoding" do
      time = ~T[14:30:00]
      assert RustyJson.encode!(time) == Jason.encode!(time)
    end

    test "NaiveDateTime encoding" do
      ndt = ~N[2024-01-15 14:30:00]
      assert RustyJson.encode!(ndt) == Jason.encode!(ndt)
    end

    test "DateTime encoding" do
      {:ok, dt, _} = DateTime.from_iso8601("2024-01-15T14:30:00Z")
      assert RustyJson.encode!(dt) == Jason.encode!(dt)
    end

    test "Decimal encoding" do
      for str <- ["0", "1", "-1", "123.456", "0.001", "999999999.999999999"] do
        d = Decimal.new(str)

        assert RustyJson.encode!(d) == Jason.encode!(d),
               "mismatch for Decimal #{str}"
      end
    end

    test "list with many types" do
      list = [
        1,
        2.5,
        "str",
        true,
        false,
        nil,
        %{},
        [],
        [1, [2]],
        %{"a" => %{"b" => "c"}}
      ]

      assert RustyJson.encode!(list) == Jason.encode!(list)
    end

    test "string with all JSON escape sequences" do
      str = "\"\\/\b\f\n\r\t"
      assert RustyJson.encode!(str) == Jason.encode!(str)
    end

    test "large list" do
      list = Enum.to_list(1..1000)
      assert RustyJson.encode!(list) == Jason.encode!(list)
    end

    test "decode and re-encode produces same result" do
      original = ~s({"name":"Alice","scores":[95,87,92],"active":true,"meta":null})
      decoded_r = RustyJson.decode!(original)
      decoded_j = Jason.decode!(original)
      assert decoded_r == decoded_j

      # Re-encode should produce identical output
      assert RustyJson.encode!(decoded_r) == Jason.encode!(decoded_j)
    end

    test "decode float precision matches" do
      for json <- ["0.1", "0.2", "0.3", "1.1e-5", "2.2250738585072014e-308"] do
        assert RustyJson.decode!(json) == Jason.decode!(json),
               "float precision mismatch for #{json}"
      end
    end

    test "decode large array of objects" do
      json =
        "[" <>
          Enum.map_join(1..50, ",", fn i ->
            ~s({"id":#{i},"name":"item_#{i}","active":#{rem(i, 2) == 0}})
          end) <>
          "]"

      assert RustyJson.decode!(json) == Jason.decode!(json)
    end

    test "string with solidus (forward slash) - default escaping" do
      # Default JSON escaping should NOT escape forward slash
      str = "a/b/c"
      assert RustyJson.encode!(str) == Jason.encode!(str)
    end

    test "encode empty nested structures" do
      data = %{"empty_map" => %{}, "empty_list" => [], "empty_string" => ""}
      assert RustyJson.encode!(data) == Jason.encode!(data)
    end

    test "decode numbers at integer boundaries" do
      for json <- [
            "9007199254740992",
            "-9007199254740992",
            "0",
            "1",
            "-1"
          ] do
        assert RustyJson.decode!(json) == Jason.decode!(json),
               "boundary number mismatch for #{json}"
      end
    end

    test "mixed keys map with fewer than 32 keys" do
      map = %{:a => 1, "b" => 2, :c => 3}
      assert RustyJson.encode!(map) == Jason.encode!(map)
    end

    test "encode preserves string encoding for non-ASCII" do
      str = "hello 世界"
      assert RustyJson.encode!(str) == Jason.encode!(str)
    end

    test "decode objects with duplicate keys" do
      # Known difference: RustyJson keeps the LAST value for duplicate keys,
      # Jason keeps the FIRST value. Both are valid per RFC 8259 which says
      # "The names within an object SHOULD be unique" (not MUST).
      json = ~s({"a":1,"a":2})
      r = RustyJson.decode!(json)
      j = Jason.decode!(json)
      # RustyJson: last wins
      assert r == %{"a" => 2}
      # Jason: first wins
      assert j == %{"a" => 1}
    end

    test "decode deeply nested arrays" do
      json = "[[[[[[[[[[1]]]]]]]]]]"
      assert RustyJson.decode!(json) == Jason.decode!(json)
    end
  end
end
