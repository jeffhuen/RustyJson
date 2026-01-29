defmodule SafetyTest do
  use ExUnit.Case

  describe "deep nesting" do
    test "encoder rejects nesting beyond 128 levels" do
      deep_list = Enum.reduce(1..200, 1, fn _, acc -> [acc] end)
      assert {:error, %RustyJson.EncodeError{message: msg}} = RustyJson.encode(deep_list)
      assert msg =~ "Nesting depth"
    end

    test "encoder accepts 128 levels of nesting" do
      deep_list = Enum.reduce(1..128, 1, fn _, acc -> [acc] end)
      assert {:ok, _} = RustyJson.encode(deep_list)
    end
  end

  describe "large integers" do
    test "encodes integers larger than 64 bits" do
      large_int = Integer.pow(2, 64) + 1
      assert RustyJson.encode!(large_int) == Integer.to_string(large_int)
    end

    test "encodes integers larger than 128 bits" do
      large_int = Integer.pow(2, 129)
      assert RustyJson.encode!(large_int) == Integer.to_string(large_int)
    end

    test "encodes negative large integers" do
      large_int = -Integer.pow(2, 129)
      assert RustyJson.encode!(large_int) == Integer.to_string(large_int)
    end
  end

  describe "special types with protocol mode" do
    test "MapSet raises UndefinedError" do
      set = MapSet.new([1, 2, 3])

      assert_raise Protocol.UndefinedError, fn ->
        RustyJson.encode!(set)
      end
    end

    test "Range raises UndefinedError" do
      range = 1..10

      assert_raise Protocol.UndefinedError, fn ->
        RustyJson.encode!(range)
      end
    end
  end
end
