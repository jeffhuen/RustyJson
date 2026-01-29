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
    test "struct without explicit protocol raises" do
      assert_raise Protocol.UndefinedError,
                   ~r/RustyJson\.Encoder protocol must always be explicitly implemented/,
                   fn ->
                     RustyJson.encode!(%Container{payload: ~T[12:00:00]})
                   end
    end

    test "struct with protocol: false uses NIF fallback" do
      assert RustyJson.encode!(%Container{payload: ~T[12:00:00]}, protocol: false) ==
               ~s({"payload":"12:00:00"})
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

  describe "html_safe escaping" do
    test "escapes forward slash" do
      assert RustyJson.encode!("a/b", escape: :html_safe) == ~s("a\\/b")
    end

    test "escapes < > & and /" do
      result = RustyJson.encode!("</script>&", escape: :html_safe)
      assert result =~ "\\u003c"
      assert result =~ "\\u003e"
      assert result =~ "\\u0026"
      assert result =~ "\\/"
    end

    test "json mode does not escape /" do
      assert RustyJson.encode!("a/b", escape: :json) == ~s("a/b")
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

  describe "maps: :strict (Gap 5)" do
    test "strict mode allows unique keys" do
      assert {:ok, _} = RustyJson.encode(%{a: 1, b: 2}, maps: :strict)
    end

    test "strict mode detects duplicate atom and string keys" do
      # Map with both atom :a and string "a" key - both serialize to "a"
      map = %{:a => 1, "a" => 2}
      assert {:error, %RustyJson.EncodeError{message: msg}} = RustyJson.encode(map, maps: :strict)
      assert msg =~ "duplicate key"
    end

    test "naive mode (default) allows duplicates" do
      map = %{:a => 1, "a" => 2}
      assert {:ok, _} = RustyJson.encode(map, maps: :naive)
    end

    test "invalid maps option raises" do
      assert_raise ArgumentError, fn ->
        RustyJson.encode!(%{a: 1}, maps: :invalid)
      end
    end
  end

  describe "pretty print opts (Gap 6)" do
    test "custom after_colon separator" do
      result = RustyJson.encode!(%{a: 1}, pretty: [indent: 2, after_colon: ""])
      assert result == "{\n  \"a\":1\n}"
    end

    test "custom line_separator" do
      result = RustyJson.encode!(%{a: 1}, pretty: [indent: 2, line_separator: "\r\n"])
      assert result == "{\r\n  \"a\": 1\r\n}"
    end

    test "pretty with keyword list uses specified indent" do
      assert RustyJson.encode!([1, 2], pretty: [indent: 4]) == "[\n    1,\n    2\n]"
    end

    test "pretty with integer indent" do
      assert RustyJson.encode!([1], pretty: 4) == "[\n    1\n]"
    end
  end

  describe "EncodeError.new/1" do
    test "duplicate_key produces correct message" do
      error = RustyJson.EncodeError.new({:duplicate_key, "name"})
      assert %RustyJson.EncodeError{message: "duplicate key: name"} = error
    end

    test "duplicate_key with atom key" do
      error = RustyJson.EncodeError.new({:duplicate_key, :id})
      assert error.message == "duplicate key: id"
    end

    test "invalid_byte produces correct message" do
      error = RustyJson.EncodeError.new({:invalid_byte, 0x0A, "hello\nworld"})
      assert error.message =~ "invalid byte 0x0A"
      assert error.message =~ "hello"
    end

    test "invalid_byte with low byte" do
      error = RustyJson.EncodeError.new({:invalid_byte, 0x01, "bad"})
      assert error.message =~ "0x01"
    end
  end

  describe "Encoder Any fallback" do
    test "non-derived struct raises Protocol.UndefinedError" do
      assert_raise Protocol.UndefinedError, fn ->
        RustyJson.encode!(%Container{payload: "test"})
      end
    end

    test "non-struct unknown types raise with protocol: true" do
      # PID cannot be encoded via protocol
      assert_raise Protocol.UndefinedError, fn ->
        RustyJson.Encoder.encode(self())
      end
    end
  end

  describe "Fragment function encoding" do
    test "function-based fragment receives encoder opts" do
      fragment = %RustyJson.Fragment{
        encode: fn opts ->
          # opts should be a keyword list with escape and maps keys
          escape = Keyword.get(opts, :escape, :json)

          if escape == :html_safe do
            ~s({"url":"a\\/b"})
          else
            ~s({"url":"a/b"})
          end
        end
      }

      # With html_safe, the fragment function should receive the escape opt
      assert RustyJson.encode!(fragment, escape: :html_safe) == ~s({"url":"a\\/b"})
      assert RustyJson.encode!(fragment, escape: :json) == ~s({"url":"a/b"})
    end

    test "function-based fragment works with protocol: false" do
      fragment = %RustyJson.Fragment{
        encode: fn _opts -> ~s({"pre":"encoded"}) end
      }

      assert RustyJson.encode!(fragment, protocol: false) == ~s({"pre":"encoded"})
    end

    test "iodata-based fragment passes through unchanged" do
      fragment = RustyJson.Fragment.new(~s({"static":"json"}))
      assert RustyJson.encode!(fragment) == ~s({"static":"json"})
    end
  end

  describe "protocol default" do
    test "protocol: true is the default" do
      # Built-in types still work with protocol: true (default)
      assert RustyJson.encode!(%{a: 1}) == ~s({"a":1})
      assert RustyJson.encode!([1, 2]) == "[1,2]"
      assert RustyJson.encode!("hello") == ~s("hello")
      assert RustyJson.encode!(42) == "42"
      assert RustyJson.encode!(true) == "true"
      assert RustyJson.encode!(nil) == "null"
    end

    test "protocol: false bypasses encoder protocol" do
      # Structs without protocol impl work in non-protocol mode
      assert RustyJson.encode!(%Container{payload: "test"}, protocol: false) ==
               ~s({"payload":"test"})
    end
  end
end
