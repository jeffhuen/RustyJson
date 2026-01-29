defmodule EncoderTest.Money do
  defstruct [:amount, :currency]
end

defimpl RustyJson.Encoder, for: EncoderTest.Money do
  def encode(%{amount: amount, currency: currency}, _opts) do
    %{amount: amount, currency: to_string(currency)}
  end
end

defmodule EncoderTest.DerivedAll do
  @derive RustyJson.Encoder
  defstruct [:name, :age, :secret]
end

defmodule EncoderTest.DerivedOnly do
  @derive {RustyJson.Encoder, only: [:name, :age]}
  defstruct [:name, :age, :secret]
end

defmodule EncoderTest.DerivedExcept do
  @derive {RustyJson.Encoder, except: [:secret]}
  defstruct [:name, :age, :secret]
end

defmodule EncoderTest do
  use ExUnit.Case

  alias EncoderTest.{DerivedAll, DerivedExcept, DerivedOnly, Money}

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

    test "strict mode detects keys that serialize to the same JSON key" do
      # Atom :a and string "a" are different Elixir keys but both serialize to "a"
      map = %{:a => 1, "a" => 2}
      assert {:error, %RustyJson.EncodeError{message: msg}} = RustyJson.encode(map, maps: :strict)
      assert msg =~ "duplicate key"
      assert msg =~ "a"
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
        RustyJson.Encoder.encode(self(), RustyJson.Encode.opts())
      end
    end
  end

  describe "Fragment function encoding" do
    test "function-based fragment receives encoder opts" do
      fragment = %RustyJson.Fragment{
        encode: fn opts ->
          # opts is the opaque {escape_fn, encode_map_fn} tuple from RustyJson.Encode
          # Use Encode functions to test that escape context flows through
          ["{\"url\":", RustyJson.Encode.string("a/b", opts), "}"]
        end
      }

      # With html_safe, the Encode.string call should escape /
      result_html = RustyJson.encode!(fragment, escape: :html_safe)
      assert result_html =~ "\\/"

      # With json mode, / should not be escaped
      result_json = RustyJson.encode!(fragment, escape: :json)
      refute result_json =~ "\\/"
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

    test "new/1 with iodata wraps in function (matching Jason)" do
      fragment = RustyJson.Fragment.new(~s({"a":1}))
      assert is_function(fragment.encode, 1)
      assert fragment.encode.([]) == ~s({"a":1})
    end

    test "new/1 with iolist wraps in function" do
      fragment = RustyJson.Fragment.new(["{", "}", []])
      assert is_function(fragment.encode, 1)
      assert fragment.encode.([]) == ["{", "}", []]
    end

    test "new/1 with function stores function directly" do
      fun = fn _opts -> ~s({"b":2}) end
      fragment = RustyJson.Fragment.new(fun)
      assert fragment.encode == fun
    end

    test "new!/1 wraps validated iodata in function" do
      fragment = RustyJson.Fragment.new!(~s({"valid":true}))
      assert is_function(fragment.encode, 1)
      assert fragment.encode.([]) == ~s({"valid":true})
    end

    test "new!/1 raises on invalid JSON" do
      assert_raise RustyJson.DecodeError, fn ->
        RustyJson.Fragment.new!("not valid json")
      end
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

  describe "encode_to_iodata/2" do
    test "returns {:ok, iodata} on success" do
      assert {:ok, result} = RustyJson.encode_to_iodata(%{a: 1})
      assert IO.iodata_to_binary(result) == ~s({"a":1})
    end

    test "returns {:error, _} on failure" do
      assert {:error, _} = RustyJson.encode_to_iodata(self())
    end

    test "accepts encode options" do
      assert {:ok, result} = RustyJson.encode_to_iodata(%{a: 1}, pretty: true)
      assert IO.iodata_to_binary(result) =~ "\n"
    end

    test "matches encode/2 output" do
      for term <- [%{a: 1}, [1, 2], "hello", 42, true, nil] do
        {:ok, iodata} = RustyJson.encode_to_iodata(term)
        {:ok, binary} = RustyJson.encode(term)
        assert IO.iodata_to_binary(iodata) == binary
      end
    end
  end

  describe "encode_to_iodata!/2" do
    test "returns iodata on success" do
      result = RustyJson.encode_to_iodata!(%{a: 1})
      assert IO.iodata_to_binary(result) == ~s({"a":1})
    end

    test "raises on failure" do
      assert_raise Protocol.UndefinedError, fn ->
        RustyJson.encode_to_iodata!(self())
      end
    end

    test "matches encode!/2 output" do
      for term <- [%{a: 1}, [1, 2], "hello", 42, true, nil] do
        assert IO.iodata_to_binary(RustyJson.encode_to_iodata!(term)) ==
                 RustyJson.encode!(term)
      end
    end
  end

  describe "lean mode with all struct types" do
    test "lean mode with DateTime encodes as raw map" do
      {:ok, dt, _} = DateTime.from_iso8601("2024-01-15T14:30:00Z")
      encoded = RustyJson.encode!(dt, lean: true)
      decoded = RustyJson.decode!(encoded)
      assert is_map(decoded)
      assert decoded["year"] == 2024
      assert decoded["__struct__"] == nil
    end

    test "lean mode with Date encodes as raw map" do
      encoded = RustyJson.encode!(~D[2024-01-15], lean: true)
      decoded = RustyJson.decode!(encoded)
      assert is_map(decoded)
      assert decoded["year"] == 2024
      assert decoded["__struct__"] == nil
    end

    test "lean mode with NaiveDateTime encodes as raw map" do
      encoded = RustyJson.encode!(~N[2024-01-15 14:30:00], lean: true)
      decoded = RustyJson.decode!(encoded)
      assert is_map(decoded)
      assert decoded["year"] == 2024
    end

    test "lean mode with URI encodes as raw map" do
      uri = URI.parse("http://example.com/path")
      encoded = RustyJson.encode!(uri, lean: true)
      decoded = RustyJson.decode!(encoded)
      assert is_map(decoded)
      assert decoded["host"] == "example.com"
    end
  end

  describe "custom Encoder implementation" do
    test "custom defimpl encodes via protocol" do
      money = %Money{amount: 42, currency: :USD}
      json = RustyJson.encode!(money)
      decoded = RustyJson.decode!(json)
      assert decoded == %{"amount" => 42, "currency" => "USD"}
    end

    test "custom defimpl with protocol: false skips protocol" do
      money = %Money{amount: 42, currency: :USD}
      # protocol: false sends raw struct to NIF which encodes all fields
      json = RustyJson.encode!(money, protocol: false)
      decoded = RustyJson.decode!(json)
      assert decoded["amount"] == 42
      # NIF encodes atom currency as string atom name
      assert decoded["currency"] == "USD"
    end

    test "custom defimpl with html_safe escaping" do
      money = %Money{amount: 42, currency: :"<b>"}
      json = RustyJson.encode!(money, escape: :html_safe)
      # The currency "<b>" should be escaped in html_safe mode
      assert json =~ "\\u003c"
    end
  end

  describe "@derive RustyJson.Encoder" do
    test "derive all fields" do
      val = %DerivedAll{name: "Alice", age: 30, secret: "hidden"}
      json = RustyJson.encode!(val)
      decoded = RustyJson.decode!(json)
      assert decoded["name"] == "Alice"
      assert decoded["age"] == 30
      assert decoded["secret"] == "hidden"
    end

    test "derive with :only" do
      val = %DerivedOnly{name: "Alice", age: 30, secret: "hidden"}
      json = RustyJson.encode!(val)
      decoded = RustyJson.decode!(json)
      assert decoded["name"] == "Alice"
      assert decoded["age"] == 30
      refute Map.has_key?(decoded, "secret")
    end

    test "derive with :except" do
      val = %DerivedExcept{name: "Alice", age: 30, secret: "hidden"}
      json = RustyJson.encode!(val)
      decoded = RustyJson.decode!(json)
      assert decoded["name"] == "Alice"
      assert decoded["age"] == 30
      refute Map.has_key?(decoded, "secret")
    end
  end

  describe "special types raise Protocol.UndefinedError" do
    test "PID raises" do
      assert_raise Protocol.UndefinedError, fn ->
        RustyJson.encode!(self())
      end
    end

    test "Reference raises" do
      assert_raise Protocol.UndefinedError, fn ->
        RustyJson.encode!(make_ref())
      end
    end

    test "Port raises" do
      # Get a port from an open process
      port = Port.open({:spawn, "echo"}, [:binary])

      try do
        assert_raise Protocol.UndefinedError, fn ->
          RustyJson.encode!(port)
        end
      after
        Port.close(port)
      end
    end

    test "Function raises" do
      assert_raise Protocol.UndefinedError, fn ->
        RustyJson.encode!(fn -> :ok end)
      end
    end
  end
end
