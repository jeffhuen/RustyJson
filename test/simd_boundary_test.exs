defmodule RustyJson.SimdBoundaryTest do
  @moduledoc """
  Tests for handrolled SIMD boundary logic in the decoder.

  These target the custom code that could actually break — not the SIMD
  comparisons themselves (which are correct by construction), but:

  1. Partial-chunk `to_bitmask().trailing_zeros()` arithmetic in skip_ascii_digits
     and skip_whitespace (do we advance to the exact right byte?)
  2. The SIMD-to-scalar handoff (does the scalar tail pick up correctly?)
  3. The bulk copy optimization in decode_escaped_string (does find_escape_json
     return the right position? does the next > i guard work?)
  4. Digit-to-non-digit transitions at chunk boundaries (does the parser see
     the `.`, `e`, `,`, `]` correctly after SIMD skips digits?)
  """
  use ExUnit.Case, async: true

  # =========================================================================
  # skip_ascii_digits: partial-chunk bitmask + scalar handoff
  # =========================================================================

  describe "skip_ascii_digits" do
    # The SIMD path processes 16 bytes at a time. The first digit is consumed
    # by the parser before calling skip_ascii_digits, so N-digit number means
    # skip sees N-1 bytes. The partial-chunk path uses to_bitmask().trailing_zeros()
    # to find the exact first non-digit within a chunk.

    test "17-digit integer: one full SIMD chunk + scalar tail" do
      n = String.duplicate("3", 17)
      assert RustyJson.decode!(n) == String.to_integer(n)
    end

    test "33-digit integer: SIMD chunk + scalar tail (or AVX2 + tail)" do
      n = String.duplicate("6", 33)
      assert RustyJson.decode!(n) == String.to_integer(n)
    end

    test "negative 33-digit integer" do
      n = "-" <> String.duplicate("2", 33)
      assert RustyJson.decode!(n) == String.to_integer(n)
    end

    test "16 digits then dot: partial chunk stops at non-digit correctly" do
      json = String.duplicate("1", 16) <> ".5"
      result = RustyJson.decode!(json)
      assert is_float(result)
    end

    test "32 digits then e: partial chunk stops at exponent marker" do
      json = String.duplicate("1", 32) <> "e2"
      result = RustyJson.decode!(json)
      assert is_float(result)
    end

    test "16 digits then comma in array: transition to structural char" do
      n = String.duplicate("9", 16)
      json = "[#{n},1]"
      assert RustyJson.decode!(json) == [String.to_integer(n), 1]
    end

    test "32 digits then closing bracket: transition to structural char" do
      n = String.duplicate("8", 32)
      json = "[#{n}]"
      assert RustyJson.decode!(json) == [String.to_integer(n)]
    end

    test "float with 17-digit fractional part" do
      json = "1." <> String.duplicate("0", 16) <> "1"
      result = RustyJson.decode!(json)
      assert is_float(result)
    end

    test "float with 33-digit fractional part" do
      json = "1." <> String.duplicate("0", 32) <> "1"
      result = RustyJson.decode!(json)
      assert is_float(result)
    end

    test "array of boundary-sized integers (parse_number_fast path)" do
      nums = [
        String.duplicate("1", 17),
        String.duplicate("2", 33),
        String.duplicate("3", 16)
      ]

      json = "[" <> Enum.join(nums, ",") <> "]"
      assert RustyJson.decode!(json) == Enum.map(nums, &String.to_integer/1)
    end
  end

  # =========================================================================
  # decode_escaped_string: bulk copy + next > i guard
  # =========================================================================

  describe "decode_escaped_string bulk copy" do
    # The bulk copy calls find_escape_json to scan forward, then does
    # extend_from_slice for the safe region. The risks are:
    # - find_escape_json returns wrong position (off by one in bitmask math)
    # - The next > i guard fails to prevent infinite loops on control chars
    # - Slice boundaries are wrong (copies too much or too little)

    test "escape after 17 plain bytes: crosses one SIMD chunk" do
      prefix = String.duplicate("a", 17)
      json = ~s("#{prefix}\\nend")
      assert RustyJson.decode!(json) == prefix <> "\nend"
    end

    test "escape after 33 plain bytes: crosses two SIMD chunks (or one AVX2 + tail)" do
      prefix = String.duplicate("a", 33)
      json = ~s("#{prefix}\\nend")
      assert RustyJson.decode!(json) == prefix <> "\nend"
    end

    test "two long plain runs separated by escape" do
      a = String.duplicate("a", 33)
      b = String.duplicate("b", 33)
      json = ~s("#{a}\\n#{b}")
      assert RustyJson.decode!(json) == a <> "\n" <> b
    end

    test "multiple escapes with 17-byte gaps (repeating boundary crossing)" do
      segment = String.duplicate("m", 17) <> "\\n"
      content = String.duplicate(segment, 5)
      json = "\"" <> content <> "\""
      expected = String.duplicate(String.duplicate("m", 17) <> "\n", 5)
      assert RustyJson.decode!(json) == expected
    end

    test "consecutive escapes with no bulk copy opportunity" do
      json = ~s("\\n\\t\\r\\n\\t\\r\\n\\t\\r\\n")
      assert RustyJson.decode!(json) == "\n\t\r\n\t\r\n\t\r\n"
    end

    test "unicode escape after 17 plain bytes" do
      prefix = String.duplicate("a", 17)
      json = ~s("#{prefix}\\u0041rest")
      assert RustyJson.decode!(json) == prefix <> "Arest"
    end

    test "surrogate pair after 33 plain bytes" do
      prefix = String.duplicate("a", 33)
      json = ~s("#{prefix}\\uD83D\\uDE00rest")
      assert RustyJson.decode!(json) == prefix <> "😀rest"
    end

    test "varied ASCII content in bulk copy (not just repeated bytes)" do
      varied = "abcdefghijklmnopqrstuvwxyz0123456"
      assert byte_size(varied) == 33
      json = ~s("#{varied}\\nend")
      assert RustyJson.decode!(json) == varied <> "\nend"
    end

    test "1000+ byte string exercises sustained bulk copy" do
      segment = String.duplicate("z", 20) <> "\\n"
      content = String.duplicate(segment, 50)
      json = "\"" <> content <> "\""
      expected = String.duplicate(String.duplicate("z", 20) <> "\n", 50)
      assert RustyJson.decode!(json) == expected
    end
  end

  # =========================================================================
  # skip_whitespace: partial-chunk bitmask + scalar handoff
  # =========================================================================

  describe "skip_whitespace" do
    # Same partial-chunk bitmask logic as skip_ascii_digits.
    # The scalar tail in the decoder's skip_whitespace method handles remainder.

    test "17 spaces before value: one SIMD chunk + scalar tail" do
      json = String.duplicate(" ", 17) <> "42"
      assert RustyJson.decode!(json) == 42
    end

    test "33 spaces before value: two SIMD chunks + scalar tail (or AVX2 + tail)" do
      json = String.duplicate(" ", 33) <> "42"
      assert RustyJson.decode!(json) == 42
    end

    test "33 mixed whitespace bytes (all 4 types)" do
      ws = String.duplicate(" \t\n\r", 8) <> " "
      assert byte_size(ws) == 33
      json = ws <> "null"
      assert RustyJson.decode!(json) == nil
    end

    test "33 spaces between array elements" do
      ws = String.duplicate(" ", 33)
      json = "[1,#{ws}2]"
      assert RustyJson.decode!(json) == [1, 2]
    end

    test "33 spaces between object key, colon, and value" do
      ws = String.duplicate(" ", 33)
      json = ~s({"a"#{ws}:#{ws}1})
      assert RustyJson.decode!(json) == %{"a" => 1}
    end

    test "256 spaces: sustained SIMD iteration" do
      json = String.duplicate(" ", 256) <> "42"
      assert RustyJson.decode!(json) == 42
    end
  end

  # =========================================================================
  # Round-trip: encode then decode exercises both encoder and decoder SIMD
  # =========================================================================

  describe "round-trip at SIMD boundaries" do
    test "string with escape at position 17" do
      data = String.duplicate("a", 17) <> "\n" <> "end"
      assert RustyJson.decode!(RustyJson.encode!(data)) == data
    end

    test "33-digit integer" do
      data = String.to_integer(String.duplicate("9", 33))
      assert RustyJson.decode!(RustyJson.encode!(data)) == data
    end
  end
end
