defmodule SigilTest do
  use ExUnit.Case
  import RustyJson.Sigil

  describe "~j sigil" do
    test "decodes JSON string" do
      result = ~j({"name": "Alice", "age": 30})
      assert result == %{"name" => "Alice", "age" => 30}
    end

    test "decodes array" do
      assert ~j([1, 2, 3]) == [1, 2, 3]
    end

    test "decodes primitives" do
      assert ~j(null) == nil
      assert ~j(true) == true
      assert ~j(42) == 42
    end

    test "with atoms modifier" do
      result = ~j({"x": 1})a
      assert result == %{x: 1}
    end

    test "with atoms! modifier" do
      result = ~j({"some_unique_sigil_key": 1})A
      assert result == %{some_unique_sigil_key: 1}
    end

    test "with interpolation" do
      value = ~s({"key": "value"})
      result = ~j(#{value})
      assert result == %{"key" => "value"}
    end
  end

  describe "~j sigil modifiers" do
    test "unknown modifier raises ArgumentError" do
      assert_raise ArgumentError, ~r/unknown sigil modifier/, fn ->
        Code.eval_string("""
        import RustyJson.Sigil
        ~j({"a":1})z
        """)
      end
    end
  end

  describe "~j sigil with multiple modifiers" do
    test "atoms + copy modifiers" do
      result = ~j({"x": 1})ac
      assert result == %{x: 1}
    end

    test "atoms! + reference modifiers" do
      result = ~j({"x": 1})Ar
      assert result == %{x: 1}
    end
  end

  describe "~J sigil" do
    test "decodes JSON at compile time" do
      result = ~J({"name": "Alice"})
      assert result == %{"name" => "Alice"}
    end

    test "with atoms modifier" do
      result = ~J({"y": 2})a
      assert result == %{y: 2}
    end

    test "with atoms! modifier" do
      result = ~J({"y": 2})A
      assert result == %{y: 2}
    end

    test "with reference modifier" do
      result = ~J({"y": 2})r
      assert result == %{"y" => 2}
    end

    test "with copy modifier" do
      result = ~J({"y": 2})c
      assert result == %{"y" => 2}
    end

    test "unknown modifier raises ArgumentError" do
      assert_raise ArgumentError, ~r/unknown sigil modifier/, fn ->
        Code.eval_string("""
        import RustyJson.Sigil
        ~J({"a":1})z
        """)
      end
    end
  end
end
