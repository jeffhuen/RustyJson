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

# NIF-path test struct: >= 5 fields with binaries (triggers NIF encode_fields path)
defmodule EncoderTest.NifPerson do
  @derive RustyJson.Encoder
  defstruct [:name, :email, :city, :country, :bio, :age, :active]
end

# Small struct: < 5 fields (always iodata fallback path)
defmodule EncoderTest.SmallStruct do
  @derive RustyJson.Encoder
  defstruct [:a, :b, :c]
end

# >= 5 fields but no binaries (iodata fallback path — NIF encode_fields
# only fires when there are binary values to benefit from)
defmodule EncoderTest.IntsOnly do
  @derive RustyJson.Encoder
  defstruct [:a, :b, :c, :d, :e]
end

# Nested struct container (>= 5 fields)
defmodule EncoderTest.NifNested do
  @derive RustyJson.Encoder
  defstruct [:name, :email, :score, :tags, :metadata, :inner]
end

# Inner derived struct for nesting tests
defmodule EncoderTest.InnerDerived do
  @derive RustyJson.Encoder
  defstruct [:label, :value]
end

defmodule EncoderTest do
  use ExUnit.Case

  alias EncoderTest.{
    DerivedAll,
    DerivedExcept,
    DerivedOnly,
    InnerDerived,
    IntsOnly,
    Money,
    NifNested,
    NifPerson,
    SmallStruct
  }

  defmodule Container do
    defstruct [:payload]
  end

  # Shared fixture for NIF-path struct tests
  @nif_person %NifPerson{
    name: "Alice",
    email: "alice@example.com",
    city: "Portland",
    country: "US",
    bio: "Hello world",
    age: 30,
    active: true
  }

  # =====================================================================
  # Basic encoding
  # =====================================================================

  describe "basic encoding" do
    test "single-key map" do
      assert RustyJson.encode!(%{"foo" => 5}) == ~s({"foo":5})
    end

    test "tuple encodes as JSON array" do
      assert RustyJson.encode!({:ok, :error}) == ~s(["ok","error"])
    end

    test "nested term round-trips correctly" do
      input = %{
        map: %{
          1 => "foo",
          "list" => [:ok, 42, -42, 42.0, 42.01, :error],
          tuple: {:ok, []},
          atom: :atom
        }
      }

      decoded = RustyJson.decode!(RustyJson.encode!(input))
      inner = decoded["map"]
      assert inner["1"] == "foo"
      assert inner["atom"] == "atom"
      assert inner["tuple"] == ["ok", []]
      assert inner["list"] == ["ok", 42, -42, 42.0, 42.01, "error"]
    end

    test "rejects invalid UTF-8 binary" do
      assert {:error, %RustyJson.EncodeError{}} = RustyJson.encode(<<0xFF, 0xFE, 0xFD>>)
    end

    test "built-in primitives encode correctly" do
      assert RustyJson.encode!(%{a: 1}) == ~s({"a":1})
      assert RustyJson.encode!([1, 2]) == "[1,2]"
      assert RustyJson.encode!("hello") == ~s("hello")
      assert RustyJson.encode!(42) == "42"
      assert RustyJson.encode!(true) == "true"
      assert RustyJson.encode!(nil) == "null"
    end
  end

  # =====================================================================
  # sort_keys option
  # =====================================================================

  describe "sort_keys option" do
    test "sorts atom keys lexicographically" do
      assert RustyJson.encode!(%{c: 3, a: 1, b: 2}, sort_keys: true) ==
               ~s({"a":1,"b":2,"c":3})
    end

    test "sorts string keys lexicographically" do
      assert RustyJson.encode!(%{"z" => 1, "a" => 2, "m" => 3}, sort_keys: true) ==
               ~s({"a":2,"m":3,"z":1})
    end

    test "sorts mixed key types (atom, string, integer)" do
      result = RustyJson.encode!(%{:b => 2, "a" => 1, 3 => "three"}, sort_keys: true)
      # All keys are stringified; lexicographic order: "3" < "a" < "b"
      assert result == ~s({"3":"three","a":1,"b":2})
    end

    test "sorts nested maps recursively" do
      nested = %{z: %{b: 2, a: 1}, a: %{d: 4, c: 3}}
      result = RustyJson.encode!(nested, sort_keys: true)
      assert result == ~s({"a":{"c":3,"d":4},"z":{"a":1,"b":2}})
    end

    test "works with pretty printing" do
      result = RustyJson.encode!(%{b: 2, a: 1}, sort_keys: true, pretty: 2)

      assert result == """
             {
               "a": 1,
               "b": 2
             }\
             """
    end

    test "works with protocol: false" do
      assert RustyJson.encode!(%{c: 3, a: 1, b: 2}, sort_keys: true, protocol: false) ==
               ~s({"a":1,"b":2,"c":3})
    end
  end

  # =====================================================================
  # Large payloads
  # =====================================================================

  describe "large payloads" do
    test "1 MB string" do
      large_str = String.duplicate("a", 1_000_000)
      result = RustyJson.encode!(large_str)
      # +2 for surrounding quotes
      assert byte_size(result) == 1_000_002
      assert String.starts_with?(result, "\"")
      assert String.ends_with?(result, "\"")
    end

    test "100k-element integer array" do
      large_list = Enum.to_list(1..100_000)
      result = RustyJson.encode!(large_list)
      assert String.starts_with?(result, "[")
      assert String.ends_with?(result, "]")
      assert length(RustyJson.decode!(result)) == 100_000
    end
  end

  # =====================================================================
  # Escape modes
  # =====================================================================

  describe "escape modes" do
    test "html_safe escapes < > & and /" do
      result = RustyJson.encode!("</script>&", escape: :html_safe)
      assert result =~ "\\u003c"
      assert result =~ "\\u003e"
      assert result =~ "\\u0026"
      assert result =~ "\\/"
    end

    test "json mode does not escape /" do
      assert RustyJson.encode!("a/b", escape: :json) == ~s("a/b")
    end

    test "html_safe escapes forward slash in isolation" do
      assert RustyJson.encode!("a/b", escape: :html_safe) == ~s("a\\/b")
    end
  end

  # =====================================================================
  # Pretty printing
  # =====================================================================

  describe "pretty printing" do
    test "pretty: true uses 2-space indent" do
      result = RustyJson.encode!(%{a: 1}, pretty: true)
      assert result == "{\n  \"a\": 1\n}"
    end

    test "pretty: <integer> uses N-space indent" do
      assert RustyJson.encode!([1], pretty: 4) == "[\n    1\n]"
    end

    test "pretty: keyword with custom indent" do
      assert RustyJson.encode!([1, 2], pretty: [indent: 4]) == "[\n    1,\n    2\n]"
    end

    test "custom after_colon separator" do
      result = RustyJson.encode!(%{a: 1}, pretty: [indent: 2, after_colon: ""])
      assert result == "{\n  \"a\":1\n}"
    end

    test "custom line_separator" do
      result = RustyJson.encode!(%{a: 1}, pretty: [indent: 2, line_separator: "\r\n"])
      assert result == "{\r\n  \"a\": 1\r\n}"
    end
  end

  # =====================================================================
  # Compression
  # =====================================================================

  describe "compression" do
    test "gzip round-trips correctly" do
      zipped = RustyJson.encode!(%{"foo" => 5}, compress: :gzip)
      assert :zlib.gunzip(zipped) == ~s({"foo":5})
    end

    test "gzip with all compression levels" do
      for level <- 0..9 do
        zipped = RustyJson.encode!(%{"Leslie" => "Pawnee"}, compress: {:gzip, level})
        assert :zlib.gunzip(zipped) == ~s({"Leslie":"Pawnee"})
      end
    end

    test "gzip combined with pretty printing" do
      zipped = RustyJson.encode!([1], compress: :gzip, pretty: 2)
      assert :zlib.gunzip(zipped) == "[\n  1\n]"
    end

    test "disabled compression (false and nil)" do
      assert RustyJson.encode!(%{ron: "swanson"}, compress: false) == ~S({"ron":"swanson"})
      assert RustyJson.encode!(%{ron: "swanson"}, compress: nil) == ~S({"ron":"swanson"})
    end

    test "invalid algorithm raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        RustyJson.encode!(%{foo: "bar"}, compress: :zlib)
      end
    end

    test "invalid level type raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        RustyJson.encode!(%{foo: "bar"}, compress: {:gzip, "foo"})
      end
    end

    test "out-of-range gzip level raises ArgumentError" do
      assert_raise ArgumentError, fn -> RustyJson.encode!(%{a: 1}, compress: {:gzip, -1}) end
      assert_raise ArgumentError, fn -> RustyJson.encode!(%{a: 1}, compress: {:gzip, 10}) end
    end
  end

  # =====================================================================
  # maps: :strict
  # =====================================================================

  describe "maps: :strict" do
    test "unique keys pass" do
      assert {:ok, _} = RustyJson.encode(%{a: 1, b: 2}, maps: :strict)
    end

    test "duplicate serialized keys error" do
      # Atom :a and string "a" both serialize to JSON key "a"
      assert {:error, %RustyJson.EncodeError{message: msg}} =
               RustyJson.encode(%{:a => 1, "a" => 2}, maps: :strict)

      assert msg =~ "duplicate key"
      assert msg =~ "a"
    end

    test "naive mode (default) allows duplicate serialized keys" do
      assert {:ok, _} = RustyJson.encode(%{:a => 1, "a" => 2}, maps: :naive)
    end

    test "strict mode works with derived structs" do
      # Struct keys are unique by definition
      assert {:ok, _} = RustyJson.encode(@nif_person, maps: :strict)
    end

    test "invalid maps option raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        RustyJson.encode!(%{a: 1}, maps: :invalid)
      end
    end
  end

  # =====================================================================
  # Protocol dispatch
  # =====================================================================

  describe "protocol dispatch" do
    test "struct without @derive or defimpl raises Protocol.UndefinedError" do
      assert_raise Protocol.UndefinedError,
                   ~r/RustyJson\.Encoder protocol must always be explicitly implemented/,
                   fn -> RustyJson.encode!(%Container{payload: "test"}) end
    end

    test "protocol: false bypasses protocol, encodes raw struct fields" do
      assert RustyJson.encode!(%Container{payload: ~T[12:00:00]}, protocol: false) ==
               ~s({"payload":"12:00:00"})
    end

    test "unencodable types raise Protocol.UndefinedError" do
      assert_raise Protocol.UndefinedError, fn -> RustyJson.encode!(self()) end
      assert_raise Protocol.UndefinedError, fn -> RustyJson.encode!(make_ref()) end
      assert_raise Protocol.UndefinedError, fn -> RustyJson.encode!(fn -> :ok end) end

      port = Port.open({:spawn, "cat"}, [:binary])

      try do
        assert_raise Protocol.UndefinedError, fn -> RustyJson.encode!(port) end
      after
        Port.close(port)
      end
    end
  end

  # =====================================================================
  # @derive RustyJson.Encoder
  # =====================================================================

  describe "@derive RustyJson.Encoder" do
    test "derive all fields" do
      val = %DerivedAll{name: "Alice", age: 30, secret: "hidden"}
      decoded = RustyJson.decode!(RustyJson.encode!(val))
      assert decoded == %{"name" => "Alice", "age" => 30, "secret" => "hidden"}
    end

    test "derive with :only excludes unspecified fields" do
      val = %DerivedOnly{name: "Alice", age: 30, secret: "hidden"}
      decoded = RustyJson.decode!(RustyJson.encode!(val))
      assert decoded == %{"name" => "Alice", "age" => 30}
    end

    test "derive with :except excludes specified fields" do
      val = %DerivedExcept{name: "Alice", age: 30, secret: "hidden"}
      decoded = RustyJson.decode!(RustyJson.encode!(val))
      assert decoded == %{"name" => "Alice", "age" => 30}
    end
  end

  # =====================================================================
  # Custom Encoder implementation
  # =====================================================================

  describe "custom Encoder implementation" do
    test "custom defimpl transforms output" do
      money = %Money{amount: 42, currency: :USD}
      decoded = RustyJson.decode!(RustyJson.encode!(money))
      assert decoded == %{"amount" => 42, "currency" => "USD"}
    end

    test "html_safe escaping flows through custom impl" do
      money = %Money{amount: 42, currency: :"<b>"}
      json = RustyJson.encode!(money, escape: :html_safe)
      assert json =~ "\\u003c"
    end
  end

  # =====================================================================
  # Fragment encoding
  # =====================================================================

  describe "Fragment encoding" do
    test "function-based fragment receives encoder opts (escape mode flows through)" do
      fragment = %RustyJson.Fragment{
        encode: fn opts ->
          ["{\"url\":", RustyJson.Encode.string("a/b", opts), "}"]
        end
      }

      # html_safe should escape /
      assert RustyJson.encode!(fragment, escape: :html_safe) =~ "\\/"
      # json mode should not
      refute RustyJson.encode!(fragment, escape: :json) =~ "\\/"
    end

    test "function-based fragment works with protocol: false" do
      fragment = %RustyJson.Fragment{
        encode: fn _opts -> ~s({"pre":"encoded"}) end
      }

      assert RustyJson.encode!(fragment, protocol: false) == ~s({"pre":"encoded"})
    end

    test "Fragment.new/1 with binary wraps in function and round-trips" do
      fragment = RustyJson.Fragment.new(~s({"a":1}))
      assert is_function(fragment.encode, 1)
      assert fragment.encode.([]) == ~s({"a":1})
      assert RustyJson.encode!(fragment) == ~s({"a":1})
    end

    test "Fragment.new/1 with iolist wraps in function" do
      fragment = RustyJson.Fragment.new(["{", "}", []])
      assert is_function(fragment.encode, 1)
      assert fragment.encode.([]) == ["{", "}", []]
    end

    test "Fragment.new/1 with function stores it directly" do
      fun = fn _opts -> ~s({"b":2}) end
      fragment = RustyJson.Fragment.new(fun)
      assert fragment.encode == fun
    end

    test "Fragment.new!/1 validates JSON and wraps in function" do
      fragment = RustyJson.Fragment.new!(~s({"valid":true}))
      assert is_function(fragment.encode, 1)
      assert fragment.encode.([]) == ~s({"valid":true})
    end

    test "Fragment.new!/1 raises on invalid JSON" do
      assert_raise RustyJson.DecodeError, fn ->
        RustyJson.Fragment.new!("not valid json")
      end
    end
  end

  # =====================================================================
  # NIF vs fallback parity (encode_fields path)
  # =====================================================================

  describe "NIF vs fallback parity" do
    # These tests verify that the NIF encode path and the Encoder protocol
    # fallback path produce JSON that decodes to the same content.
    #
    # NOTE: This is a consistency check (both paths agree), not an
    # absolute correctness check — we use decode! to compare, which is
    # circular. Absolute correctness of escape modes is verified in
    # jason_parity_test.exs by comparing against Jason's output.

    test "NIF and fallback decode to same content for :json escape" do
      nif_result = RustyJson.encode!(@nif_person, escape: :json)

      fallback_result =
        IO.iodata_to_binary(RustyJson.Encoder.encode(@nif_person, RustyJson.Encode.opts(:json)))

      assert RustyJson.decode!(nif_result) == RustyJson.decode!(fallback_result)
    end

    test "NIF and fallback decode to same content for :html_safe escape" do
      person = %NifPerson{@nif_person | name: "<script>alert('xss')</script>", bio: "a/b & c > d"}
      nif_result = RustyJson.encode!(person, escape: :html_safe)

      fallback_result =
        IO.iodata_to_binary(RustyJson.Encoder.encode(person, RustyJson.Encode.opts(:html_safe)))

      assert RustyJson.decode!(nif_result) == RustyJson.decode!(fallback_result)
    end

    test "NIF and fallback decode to same content for :javascript_safe escape" do
      person = %NifPerson{@nif_person | bio: "line\u2028separator\u2029end"}
      nif_result = RustyJson.encode!(person, escape: :javascript_safe)

      fallback_result =
        IO.iodata_to_binary(
          RustyJson.Encoder.encode(person, RustyJson.Encode.opts(:javascript_safe))
        )

      assert RustyJson.decode!(nif_result) == RustyJson.decode!(fallback_result)
    end

    test "NIF and fallback decode to same content for :unicode_safe escape" do
      person = %NifPerson{@nif_person | name: "Ünïcödé", bio: "日本語テスト"}
      nif_result = RustyJson.encode!(person, escape: :unicode_safe)

      fallback_result =
        IO.iodata_to_binary(
          RustyJson.Encoder.encode(person, RustyJson.Encode.opts(:unicode_safe))
        )

      assert RustyJson.decode!(nif_result) == RustyJson.decode!(fallback_result)
    end
  end

  # =====================================================================
  # Derived struct encoding (field types, nesting, struct shapes)
  # =====================================================================

  describe "derived struct encoding" do
    test "all field types round-trip correctly" do
      decoded = RustyJson.decode!(RustyJson.encode!(@nif_person))

      assert decoded == %{
               "name" => "Alice",
               "email" => "alice@example.com",
               "city" => "Portland",
               "country" => "US",
               "bio" => "Hello world",
               "age" => 30,
               "active" => true
             }
    end

    test "strings with special characters round-trip correctly" do
      person = %NifPerson{
        @nif_person
        | name: "line1\nline2\ttab",
          email: "quote\"backslash\\end",
          bio: "control\x01\x02chars"
      }

      decoded = RustyJson.decode!(RustyJson.encode!(person))
      assert decoded["name"] == "line1\nline2\ttab"
      assert decoded["email"] == "quote\"backslash\\end"
    end

    test "nil field encodes as JSON null (key is present)" do
      person = %NifPerson{@nif_person | bio: nil}
      decoded = RustyJson.decode!(RustyJson.encode!(person))

      assert decoded == %{
               "name" => "Alice",
               "email" => "alice@example.com",
               "city" => "Portland",
               "country" => "US",
               "bio" => nil,
               "age" => 30,
               "active" => true
             }
    end

    test "boolean false encodes as JSON false (not absent)" do
      person = %NifPerson{@nif_person | active: false}
      decoded = RustyJson.decode!(RustyJson.encode!(person))

      assert decoded == %{
               "name" => "Alice",
               "email" => "alice@example.com",
               "city" => "Portland",
               "country" => "US",
               "bio" => "Hello world",
               "age" => 30,
               "active" => false
             }
    end

    test "float fields round-trip correctly" do
      person = %NifPerson{@nif_person | age: 30.5}
      decoded = RustyJson.decode!(RustyJson.encode!(person))
      assert decoded["age"] == 30.5
      assert map_size(decoded) == 7

      person = %NifPerson{@nif_person | age: 0.1}
      decoded = RustyJson.decode!(RustyJson.encode!(person))
      assert decoded["age"] == 0.1
      assert map_size(decoded) == 7
    end

    test "non-boolean atom values encode as strings" do
      nested = %NifNested{
        name: "test",
        email: "a@b.com",
        score: 10,
        tags: [:ok, :error],
        metadata: %{status: :active},
        inner: nil
      }

      decoded = RustyJson.decode!(RustyJson.encode!(nested))

      assert decoded == %{
               "name" => "test",
               "email" => "a@b.com",
               "score" => 10,
               "tags" => ["ok", "error"],
               "metadata" => %{"status" => "active"},
               "inner" => nil
             }
    end

    test "nested derived struct" do
      nested = %NifNested{
        name: "outer",
        email: "o@o.com",
        score: 42,
        tags: ["a", "b"],
        metadata: %{x: 1},
        inner: %InnerDerived{label: "inner", value: 99}
      }

      decoded = RustyJson.decode!(RustyJson.encode!(nested))

      assert decoded == %{
               "name" => "outer",
               "email" => "o@o.com",
               "score" => 42,
               "tags" => ["a", "b"],
               "metadata" => %{"x" => 1},
               "inner" => %{"label" => "inner", "value" => 99}
             }
    end

    test "nested custom defimpl struct" do
      nested = %NifNested{
        name: "test",
        email: "t@t.com",
        score: 1,
        tags: [],
        metadata: %{},
        inner: %Money{amount: 42, currency: :USD}
      }

      decoded = RustyJson.decode!(RustyJson.encode!(nested))
      assert decoded["inner"] == %{"amount" => 42, "currency" => "USD"}
    end

    test "nested Fragment" do
      nested = %NifNested{
        name: "test",
        email: "t@t.com",
        score: 1,
        tags: [],
        metadata: %{},
        inner: %RustyJson.Fragment{encode: ~s({"pre":"encoded"})}
      }

      decoded = RustyJson.decode!(RustyJson.encode!(nested))

      assert decoded == %{
               "name" => "test",
               "email" => "t@t.com",
               "score" => 1,
               "tags" => [],
               "metadata" => %{},
               "inner" => %{"pre" => "encoded"}
             }
    end

    test "list and map fields with mixed primitives" do
      nested = %NifNested{
        name: "test",
        email: "t@t.com",
        score: 1,
        tags: ["hello", 42, true, nil],
        metadata: %{a: 1, b: "two"},
        inner: nil
      }

      decoded = RustyJson.decode!(RustyJson.encode!(nested))

      assert decoded == %{
               "name" => "test",
               "email" => "t@t.com",
               "score" => 1,
               "tags" => ["hello", 42, true, nil],
               "metadata" => %{"a" => 1, "b" => "two"},
               "inner" => nil
             }
    end
  end

  # =====================================================================
  # Struct shape variations
  # =====================================================================

  describe "struct shape variations" do
    test "small struct (< 5 fields)" do
      small = %SmallStruct{a: "hello", b: 42, c: true}
      decoded = RustyJson.decode!(RustyJson.encode!(small))
      assert decoded == %{"a" => "hello", "b" => 42, "c" => true}
    end

    test "integer-only struct (>= 5 fields, no binaries)" do
      ints = %IntsOnly{a: 1, b: 2, c: 3, d: 4, e: 5}
      decoded = RustyJson.decode!(RustyJson.encode!(ints))
      assert decoded == %{"a" => 1, "b" => 2, "c" => 3, "d" => 4, "e" => 5}
    end
  end

  # =====================================================================
  # Lean mode
  # =====================================================================

  describe "lean mode" do
    test "Time encodes as raw map instead of ISO8601 string" do
      normal = RustyJson.encode!(~T[12:00:00])
      assert normal == ~s("12:00:00")

      lean = RustyJson.encode!(~T[12:00:00], lean: true)
      decoded = RustyJson.decode!(lean)
      # Lean mode should produce a map with struct fields, not an ISO8601 string
      assert is_map(decoded)
      assert decoded["hour"] == 12
      assert decoded["minute"] == 0
      assert decoded["second"] == 0
      assert map_size(decoded) == map_size(Map.from_struct(~T[12:00:00]))
    end

    test "DateTime encodes as raw map" do
      {:ok, dt, _} = DateTime.from_iso8601("2024-01-15T14:30:00Z")
      decoded = RustyJson.decode!(RustyJson.encode!(dt, lean: true))
      assert decoded["year"] == 2024
      # __struct__ is always stripped by the NIF
      refute Map.has_key?(decoded, "__struct__")
      assert map_size(decoded) == map_size(Map.from_struct(dt))
    end

    test "Date encodes as raw map" do
      decoded = RustyJson.decode!(RustyJson.encode!(~D[2024-01-15], lean: true))
      assert decoded["year"] == 2024
      assert decoded["month"] == 1
      assert decoded["day"] == 15
      refute Map.has_key?(decoded, "__struct__")
      assert map_size(decoded) == map_size(Map.from_struct(~D[2024-01-15]))
    end

    test "NaiveDateTime encodes as raw map" do
      decoded = RustyJson.decode!(RustyJson.encode!(~N[2024-01-15 14:30:00], lean: true))
      assert decoded["year"] == 2024
      assert decoded["hour"] == 14
      assert map_size(decoded) == map_size(Map.from_struct(~N[2024-01-15 14:30:00]))
    end

    test "URI encodes as raw map" do
      uri = URI.parse("http://example.com/path")
      decoded = RustyJson.decode!(RustyJson.encode!(uri, lean: true))
      assert decoded["host"] == "example.com"
      assert decoded["scheme"] == "http"
      assert map_size(decoded) == map_size(Map.from_struct(uri))
    end
  end

  # =====================================================================
  # Native type encoding (non-lean)
  # =====================================================================

  describe "native type encoding" do
    test "nested URI and Time encode as ISO8601 strings" do
      result = RustyJson.encode!(%{a: [3, {URI.parse("http://foo.bar"), ~T[12:00:00]}]})
      assert result == ~s({"a":[3,["http://foo.bar","12:00:00"]]})
    end
  end

  # =====================================================================
  # Re-entrancy
  # =====================================================================

  describe "re-entrancy" do
    test "Fragment function calling Encode.value recursively" do
      inner = %NifPerson{
        name: "inner",
        email: "i@i.com",
        city: "A",
        country: "B",
        bio: "C",
        age: 1,
        active: true
      }

      fragment = %RustyJson.Fragment{
        encode: fn opts ->
          inner_json = RustyJson.Encode.value(inner, opts)
          [~s({"wrapper":), inner_json, ~s(})]
        end
      }

      decoded = RustyJson.decode!(RustyJson.encode!(fragment))
      assert decoded["wrapper"]["name"] == "inner"
    end

    test "html_safe escaping propagates into nested struct encoding" do
      inner = %NifPerson{
        name: "<b>bold</b>",
        email: "a@b.com",
        city: "A",
        country: "B",
        bio: "C",
        age: 1,
        active: true
      }

      json = RustyJson.encode!(%{data: inner}, escape: :html_safe)
      assert json =~ "\\u003cb\\u003e"
    end
  end

  # =====================================================================
  # encode_to_iodata (Phoenix interface)
  #
  # These functions delegate to encode/encode!, so these tests guard
  # against the delegation being accidentally broken.
  # =====================================================================

  describe "encode_to_iodata" do
    test "returns {:ok, iodata} on success" do
      assert {:ok, result} = RustyJson.encode_to_iodata(%{a: 1})
      assert IO.iodata_to_binary(result) == ~s({"a":1})
    end

    test "returns {:error, _} for unencodable types" do
      assert {:error, %Protocol.UndefinedError{}} = RustyJson.encode_to_iodata(self())
    end

    test "passes options through to encode" do
      assert {:ok, result} = RustyJson.encode_to_iodata(%{a: 1}, pretty: true)
      binary = IO.iodata_to_binary(result)
      assert binary == "{\n  \"a\": 1\n}"
    end

    test "bang variant returns iodata on success" do
      assert IO.iodata_to_binary(RustyJson.encode_to_iodata!(%{a: 1})) == ~s({"a":1})
    end

    test "bang variant raises for unencodable types" do
      assert_raise Protocol.UndefinedError, fn ->
        RustyJson.encode_to_iodata!(self())
      end
    end
  end

  # =====================================================================
  # EncodeError.new/1
  # =====================================================================

  describe "EncodeError.new/1" do
    test "duplicate_key with string key" do
      error = RustyJson.EncodeError.new({:duplicate_key, "name"})
      assert error.message == "duplicate key: name"
    end

    test "duplicate_key with atom key" do
      error = RustyJson.EncodeError.new({:duplicate_key, :id})
      assert error.message == "duplicate key: id"
    end

    test "invalid_byte includes hex code and context" do
      error = RustyJson.EncodeError.new({:invalid_byte, 0x0A, "hello\nworld"})
      assert error.message =~ "invalid byte 0x0A"
      assert error.message =~ "hello"

      error = RustyJson.EncodeError.new({:invalid_byte, 0x01, "bad"})
      assert error.message =~ "0x01"
    end
  end

  # Jason parity for struct encoding is tested in jason_parity_test.exs
  # where Jason is guaranteed to be loaded.
end
