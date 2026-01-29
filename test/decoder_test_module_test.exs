defmodule DecoderModuleTest do
  use ExUnit.Case

  describe "RustyJson.Decoder" do
    test "parse/1 delegates to RustyJson.decode/1" do
      assert {:ok, %{"name" => "Alice"}} = RustyJson.Decoder.parse(~s({"name":"Alice"}))
    end

    test "parse/1 returns error for invalid JSON" do
      assert {:error, %RustyJson.DecodeError{}} = RustyJson.Decoder.parse("invalid")
    end

    test "parse/2 passes options through" do
      assert {:ok, %{name: "Alice"}} = RustyJson.Decoder.parse(~s({"name":"Alice"}), keys: :atoms)
    end

    test "parse/2 with floats: :decimals" do
      assert {:ok, %{"price" => price}} =
               RustyJson.Decoder.parse(~s({"price":19.99}), floats: :decimals)

      assert Decimal.equal?(price, Decimal.new("19.99"))
    end
  end
end
