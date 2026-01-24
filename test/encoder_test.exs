defmodule EncoderTest do
  use ExUnit.Case

  defmodule Container do
    defstruct [:payload]
  end

  describe "Basic Encoding" do
    test "simple map" do
      assert RustyJson.encode!(%{"foo" => 5}) == ~s({"foo":5})
      assert RustyJson.encode!({:ok, :error}) == ~s(["ok","error"])
    end

    test "complicated term" do
      assert RustyJson.encode!(%{
               map: %{
                 1 => "foo",
                 "list" => [:ok, 42, -42, 42.0, 42.01, :error],
                 tuple: {:ok, []},
                 atom: :atom
               }
             }) ==
               ~s({"map":{"1":"foo","atom":"atom","tuple":["ok",[]],"list":["ok",42,-42,42.0,42.01,"error"]}})
    end
  end

  describe "Native Types & Fallbacks" do
    test "struct using fallback protocol (derived or default)" do
      # Note: Without explicit protocol implementation, structs encode as maps
      assert RustyJson.encode!(%Container{payload: ~T[12:00:00]}) == ~s({"payload":"12:00:00"})
    end

    test "nested types (URI, Time)" do
      assert RustyJson.encode!(%{a: [3, {URI.parse("http://foo.bar"), ~T[12:00:00]}]}) ==
               ~s({"a":[3,["http://foo.bar","12:00:00"]]})
    end

    test "lean mode (skips native type handling)" do
      # In lean mode, Time struct is encoded as a raw map of its fields
      # Note: __struct__ is always stripped by the encoder, even in lean mode
      encoded = RustyJson.encode!(~T[12:00:00], lean: true)
      decoded = RustyJson.decode!(encoded)

      assert %{"hour" => 12, "minute" => 0, "second" => 0} = decoded
      assert decoded["__struct__"] == nil
    end
  end

  describe "Formatting" do
    test "pretty print" do
      assert RustyJson.encode!([1], pretty: 2) == "[
  1
]"
    end
  end

  describe "Compression" do
    test "gzip compression" do
      assert zipped = RustyJson.encode!(%{"foo" => 5}, compress: :gzip)
      assert :zlib.gunzip(zipped) == ~s({"foo":5})
    end

    test "gzip with level" do
      for level <- 0..9 do
        assert zipped = RustyJson.encode!(%{"Leslie" => "Pawnee"}, compress: {:gzip, level})
        assert :zlib.gunzip(zipped) == ~s({"Leslie":"Pawnee"})
      end
    end

    test "gzip and pretty" do
      assert zipped = RustyJson.encode!([1], compress: :gzip, pretty: 2)
      assert :zlib.gunzip(zipped) == "[
  1
]"
    end

    test "disabled compression" do
      assert RustyJson.encode!(%{ron: "swanson"}, compress: false) == ~S({"ron":"swanson"})
      assert RustyJson.encode!(%{ron: "swanson"}, compress: nil) == ~S({"ron":"swanson"})
    end

    test "invalid compression options" do
      assert_raise ArgumentError, fn ->
        RustyJson.encode!(%{foo: "bar"}, compress: :zlib)
      end

      assert_raise ArgumentError, fn ->
        RustyJson.encode!(%{foo: "bar"}, compress: {:gzip, "foo"})
      end
    end
  end
end
