defmodule RustyJson.RegressionsTest do
  use ExUnit.Case, async: true

  # Structural index rejection tests are covered more thoroughly in
  # decoder_test.exs "rejects garbage between..." tests which exercise
  # both large-input (structural index) and small-input code paths.

  describe "unicode_safe escaping" do
    test "handles multi-byte char crossing SIMD chunk boundary" do
      # 15 "a"s + 1 "€" (3 bytes: E2 82 AC)
      # At index 15, we have E2. Index 16 is 82.
      # If the 16-byte SIMD scanner hits E2 at the end of a chunk,
      # it must handle the continuation correctly.
      input = String.duplicate("a", 15) <> "€" <> "bbb"
      # RustyJson outputs lowercase hex for unicode escapes
      expected = ~s(\"aaaaaaaaaaaaaaa\\u20acbbb\")

      assert {:ok, result} = RustyJson.encode(input, escape: :unicode_safe)
      assert result == expected
    end
  end

  describe "capacity estimation" do
    test "handles mixed nesting correctly" do
      # Validates that count_elements_until_close tracks both {} and [] depth.
      # Array of objects containing arrays: [{"a": [1,2]}, {"b": [3,4]}]
      # If it counted inner commas as top-level, it would over-allocate or fail.
      inner = "[1,2,3,4,5]"
      list = Enum.map(1..50, fn _ -> "{\"a\": #{inner}}" end)
      json = "[" <> Enum.join(list, ",") <> "]"

      assert {:ok, result} = RustyJson.decode(json)
      assert length(result) == 50
      assert List.first(result) == %{"a" => [1, 2, 3, 4, 5]}
    end
  end
end
