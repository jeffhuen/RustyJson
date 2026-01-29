defmodule FormatterTest do
  use ExUnit.Case

  describe "pretty_print/2" do
    test "formats compact JSON with default 2-space indent" do
      input = ~s({"a":1})
      assert RustyJson.Formatter.pretty_print(input) == "{\n  \"a\": 1\n}"
    end

    test "handles nested structures" do
      input = ~s({"a":{"b":1}})
      assert RustyJson.Formatter.pretty_print(input) == "{\n  \"a\": {\n    \"b\": 1\n  }\n}"
    end

    test "custom integer indent" do
      input = ~s({"a":1})
      assert RustyJson.Formatter.pretty_print(input, indent: 4) == "{\n    \"a\": 1\n}"
    end
  end

  describe "minimize/2" do
    test "removes whitespace" do
      input = """
      {
        "name": "Alice",
        "age": 30
      }
      """

      result = RustyJson.Formatter.minimize(input)

      refute result =~ "\n"
      refute result =~ "  "
      # Jason preserves key order (does not sort)
      assert result == ~s({"name":"Alice","age":30})
    end
  end

  describe "iodata variants (Gap 7)" do
    test "pretty_print_to_iodata matches pretty_print" do
      input = ~s({"a":1,"b":2})
      str = RustyJson.Formatter.pretty_print(input)
      iodata = RustyJson.Formatter.pretty_print_to_iodata(input)
      assert IO.iodata_to_binary(iodata) == str
    end

    test "minimize_to_iodata matches minimize" do
      input = ~s({"a" : 1 , "b" : 2})
      str = RustyJson.Formatter.minimize(input)
      iodata = RustyJson.Formatter.minimize_to_iodata(input, [])
      assert IO.iodata_to_binary(iodata) == str
    end

    test "minimize with opts param accepted" do
      input = ~s({"a": 1})
      result = RustyJson.Formatter.minimize(input, [])
      assert is_binary(result)
    end
  end

  describe "iodata indent" do
    test "tab indentation via Formatter" do
      input = ~s({"a":1})
      assert RustyJson.Formatter.pretty_print(input, indent: "\t") == "{\n\t\"a\": 1\n}"
    end

    test "tab indentation nested" do
      input = ~s([{"a":1}])

      assert RustyJson.Formatter.pretty_print(input, indent: "\t") ==
               "[\n\t{\n\t\t\"a\": 1\n\t}\n]"
    end

    test "tab indentation via encode!" do
      assert RustyJson.encode!(%{a: 1}, pretty: "\t") == "{\n\t\"a\": 1\n}"
    end

    test "custom string indent via pretty keyword" do
      assert RustyJson.encode!(%{a: 1}, pretty: [indent: "-->"]) ==
               "{\n-->\"a\": 1\n}"
    end

    test "nested custom string indent" do
      assert RustyJson.encode!([1, 2], pretty: [indent: "-->"]) ==
               "[\n-->1,\n-->2\n]"
    end
  end

  describe "number and key order preservation" do
    test "minimize preserves number formatting (1.00 stays 1.00)" do
      assert RustyJson.Formatter.minimize(~s({"x": 1.00})) == ~s({"x":1.00})
    end

    test "minimize preserves exponent notation" do
      assert RustyJson.Formatter.minimize(~s({"x": 1e2})) == ~s({"x":1e2})
    end

    test "pretty_print preserves number formatting" do
      result = RustyJson.Formatter.pretty_print(~s({"x": 1.00}))
      assert result =~ "1.00"
    end

    test "pretty_print preserves exponent notation" do
      result = RustyJson.Formatter.pretty_print(~s({"x": 1.5e+10}))
      assert result =~ "1.5e+10"
    end

    test "preserves complex number formats" do
      for num <- ["1.000", "1e-5", "1.5e+10", "-0.0", "0.001"] do
        input = ~s({"x": #{num}})
        assert RustyJson.Formatter.minimize(input) == ~s({"x":#{num}})
      end
    end

    test "preserves key order in pretty_print" do
      input = ~s({"z":1,"a":2,"m":3})
      result = RustyJson.Formatter.pretty_print(input)
      assert result =~ ~r/"z".*"a".*"m"/s
    end
  end

  describe "record_separator" do
    test "pretty_print with record_separator does not prepend for single object" do
      input = ~s({"a":1})
      result = RustyJson.Formatter.pretty_print(input, record_separator: "\n")
      # Jason formatter does not prepend separator for the first object
      assert result == "{\n  \"a\": 1\n}"
    end

    test "minimize with record_separator does not prepend for single object" do
      input = ~s({"a" : 1})
      result = RustyJson.Formatter.minimize(input, record_separator: "\n")
      assert result == "{\"a\":1}"
    end

    test "pretty_print without record_separator has no prefix" do
      input = ~s({"a":1})
      result = RustyJson.Formatter.pretty_print(input)
      assert result == "{\n  \"a\": 1\n}"
    end

    test "record_separator with custom string" do
      input = ~s([1,2])
      result = RustyJson.Formatter.minimize(input, record_separator: "\x1E")
      # Jason behavior: no separator for single record
      assert result == "[1,2]"
    end
  end

  describe "non-JSON passthrough (matches Jason)" do
    test "pretty_print strips whitespace from non-JSON input" do
      # Both Jason and RustyJson formatters operate on raw bytes without
      # validating JSON structure. Non-JSON input has whitespace stripped.
      assert RustyJson.Formatter.pretty_print("not json") == "notjson"
    end

    test "minimize strips whitespace from non-JSON input" do
      assert RustyJson.Formatter.minimize("not json") == "notjson"
    end
  end
end
