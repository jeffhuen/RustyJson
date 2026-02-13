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

  describe "key interning" do
    # Basic interning correctness is tested in decoder_test.exs "decode with keys: :intern"

    test "interning works correctly with many unique keys (exceeds internal cache cap)" do
      # The intern cache is capped at 4096 unique keys. Beyond that, keys are
      # allocated normally. This test verifies correctness is preserved regardless
      # of whether keys come from cache or fresh allocation.
      keys = for i <- 1..5000, do: ~s("key_#{i}":#{i})
      json = "{" <> Enum.join(keys, ",") <> "}"
      result = RustyJson.decode!(json, keys: :intern)

      # Verify all 5000 keys are present and correct
      assert map_size(result) == 5000
      assert result["key_1"] == 1
      assert result["key_5000"] == 5000
    end
  end

  describe "max_bytes limit" do
    test "rejects input exceeding max_bytes" do
      json = ~s("#{String.duplicate("x", 1000)}")

      assert {:error, %RustyJson.DecodeError{message: msg}} =
               RustyJson.decode(json, max_bytes: 100)

      assert msg =~ "max_bytes"
    end

    test "accepts input within max_bytes" do
      assert {:ok, "hello"} = RustyJson.decode(~s("hello"), max_bytes: 100)
    end

    test "max_bytes 0 means unlimited (default)" do
      large = ~s("#{String.duplicate("a", 10_000)}")
      assert {:ok, _} = RustyJson.decode(large)
      assert {:ok, _} = RustyJson.decode(large, max_bytes: 0)
    end

    test "max_bytes check works with iodata input" do
      iodata = [~s("), String.duplicate("x", 500), ~s(")]
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.decode(iodata, max_bytes: 100)
    end

    test "max_bytes at exact boundary" do
      # 7 bytes: quote + hello + quote
      assert {:ok, "hello"} = RustyJson.decode(~s("hello"), max_bytes: 7)
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.decode(~s("hello"), max_bytes: 6)
    end
  end

  describe "duplicate key handling" do
    # "default allows duplicates (last wins)" is tested in decoder_test.exs

    test "duplicate_keys: :error rejects duplicates" do
      assert {:error, %RustyJson.DecodeError{message: msg}} =
               RustyJson.decode(~s({"a":1,"a":2}), duplicate_keys: :error)

      assert msg =~ "Duplicate key"
    end

    test "duplicate_keys: :error accepts unique keys" do
      assert RustyJson.decode(~s({"a":1,"b":2}), duplicate_keys: :error) ==
               {:ok, %{"a" => 1, "b" => 2}}
    end

    test "duplicate_keys: :error catches nested duplicates" do
      assert {:error, %RustyJson.DecodeError{}} =
               RustyJson.decode(~s({"a":{"b":1,"b":2}}), duplicate_keys: :error)
    end

    test "duplicate_keys: :error catches duplicates in array of objects" do
      assert {:error, %RustyJson.DecodeError{}} =
               RustyJson.decode(~s([{"a":1,"a":2}]), duplicate_keys: :error)
    end

    test "duplicate_keys: :error allows same key in different objects" do
      assert RustyJson.decode(~s([{"a":1},{"a":2}]), duplicate_keys: :error) ==
               {:ok, [%{"a" => 1}, %{"a" => 2}]}
    end
  end

  describe "UTF-8 string validation" do
    test "invalid UTF-8 rejected by default" do
      input = <<34, 0xFF, 34>>

      assert {:error, %RustyJson.DecodeError{message: msg}} =
               RustyJson.decode(input)

      assert msg =~ "Invalid UTF-8"
    end

    test "invalid UTF-8 accepted with validate_strings: false" do
      input = <<34, 0xFF, 34>>
      assert {:ok, _} = RustyJson.decode(input, validate_strings: false)
    end

    test "invalid UTF-8 rejected with validate_strings: true" do
      input = <<34, 0xFF, 34>>

      assert {:error, %RustyJson.DecodeError{message: msg}} =
               RustyJson.decode(input, validate_strings: true)

      assert msg =~ "Invalid UTF-8"
    end

    test "valid UTF-8 passes validation" do
      assert {:ok, "hello"} = RustyJson.decode(~s("hello"), validate_strings: true)
    end

    test "valid multi-byte UTF-8 passes validation" do
      assert {:ok, "café"} = RustyJson.decode(~s("café"), validate_strings: true)
    end

    test "partially valid UTF-8 rejected (valid prefix then invalid byte)" do
      # "hello" followed by 0xFF then closing quote
      input = <<34, "hello", 0xFF, 34>>

      assert {:error, %RustyJson.DecodeError{message: msg}} =
               RustyJson.decode(input, validate_strings: true)

      assert msg =~ "Invalid UTF-8"
    end

    test "invalid UTF-8 in key rejected with validate_strings: true" do
      # {"<0xFF>": 1}
      input = <<123, 34, 0xFF, 34, 58, 49, 125>>

      assert {:error, %RustyJson.DecodeError{message: msg}} =
               RustyJson.decode(input, validate_strings: true)

      assert msg =~ "Invalid UTF-8"
    end
  end

  describe "scheduler dispatch" do
    # Functional correctness only — no timing/scheduler assertions.
    # These verify the dirty NIF stubs load and produce correct results.

    test "decode works with dirty_threshold forcing dirty NIF" do
      assert {:ok, %{"a" => 1}} = RustyJson.decode(~s({"a":1}), dirty_threshold: 1)
    end

    test "decode works with dirty_threshold: 0 (disabled)" do
      assert {:ok, %{"a" => 1}} = RustyJson.decode(~s({"a":1}), dirty_threshold: 0)
    end

    test "encode works with scheduler: :dirty" do
      assert {:ok, _} = RustyJson.encode(%{a: 1}, scheduler: :dirty)
    end

    test "encode works with scheduler: :normal" do
      assert {:ok, _} = RustyJson.encode(%{a: 1}, scheduler: :normal)
    end

    test "encode with compression auto-promotes to dirty scheduler" do
      # scheduler: :auto with compression should use dirty NIF.
      # Verify correctness: the result must be valid gzip regardless of scheduler.
      {:ok, result} = RustyJson.encode(%{a: 1}, compress: :gzip)
      assert :zlib.gunzip(result) == ~s({"a":1})
    end

    test "all scheduler modes produce identical output" do
      data = %{name: "test", values: [1, 2, 3]}
      {:ok, normal} = RustyJson.encode(data, scheduler: :normal)
      {:ok, dirty} = RustyJson.encode(data, scheduler: :dirty)
      {:ok, auto} = RustyJson.encode(data, scheduler: :auto)
      assert normal == dirty
      assert normal == auto
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
