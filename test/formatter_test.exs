defmodule FormatterTest do
  use ExUnit.Case

  describe "pretty_print/2" do
    test "formats compact JSON" do
      input = ~s({"name":"Alice","age":30})
      {:ok, result} = RustyJson.Formatter.pretty_print(input)

      assert result =~ "\"name\":"
      assert result =~ "\n"
    end

    test "handles nested structures" do
      input = ~s({"a":{"b":{"c":1}}})
      {:ok, result} = RustyJson.Formatter.pretty_print(input)

      assert result =~ "  \"a\":"
      assert result =~ "    \"b\":"
    end
  end

  describe "minimize/1" do
    test "removes whitespace" do
      input = """
      {
        "name": "Alice",
        "age": 30
      }
      """

      {:ok, result} = RustyJson.Formatter.minimize(input)

      refute result =~ "\n"
      refute result =~ "  "
      assert result == ~s({"age":30,"name":"Alice"})
    end
  end

  describe "error handling" do
    test "pretty_print returns error for invalid JSON" do
      assert {:error, _} = RustyJson.Formatter.pretty_print("not json")
    end

    test "pretty_print! raises for invalid JSON" do
      assert_raise RustyJson.DecodeError, fn ->
        RustyJson.Formatter.pretty_print!("not json")
      end
    end
  end
end
