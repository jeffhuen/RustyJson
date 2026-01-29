defmodule EncodeTest do
  use ExUnit.Case

  describe "RustyJson.Encode" do
    test "opts/1 builds options map" do
      opts = RustyJson.Encode.opts(:json)
      assert %{escape: :json} = opts
    end

    test "opts/0 defaults to :json" do
      opts = RustyJson.Encode.opts()
      assert %{escape: :json} = opts
    end

    test "encode/2 returns ok tuple" do
      assert {:ok, iodata} = RustyJson.Encode.encode(%{a: 1})
      assert IO.iodata_to_binary(iodata) == ~s({"a":1})
    end

    test "encode/2 returns error on failure" do
      assert {:error, _} = RustyJson.Encode.encode(<<0xFF>>)
    end

    test "value/2 encodes any term" do
      opts = RustyJson.Encode.opts()
      assert RustyJson.Encode.value("hello", opts) == ~s("hello")
      assert RustyJson.Encode.value(42, opts) == "42"
      assert RustyJson.Encode.value(true, opts) == "true"
    end

    test "atom/2 encodes atoms" do
      opts = RustyJson.Encode.opts()
      assert RustyJson.Encode.atom(:hello, opts) == ~s("hello")
      assert RustyJson.Encode.atom(nil, opts) == "null"
      assert RustyJson.Encode.atom(true, opts) == "true"
    end

    test "integer/1 encodes integers" do
      assert RustyJson.Encode.integer(42) == "42"
      assert RustyJson.Encode.integer(-1) == "-1"
      assert RustyJson.Encode.integer(0) == "0"
    end

    test "float/1 encodes floats" do
      result = RustyJson.Encode.float(3.14)
      assert is_binary(result)
      assert String.contains?(result, "3.14")
    end

    test "list/2 encodes lists" do
      opts = RustyJson.Encode.opts()
      assert RustyJson.Encode.list([1, 2, 3], opts) == "[1,2,3]"
    end

    test "keyword/2 encodes keyword list as object" do
      opts = RustyJson.Encode.opts()
      result = RustyJson.Encode.keyword([a: 1, b: 2], opts)
      decoded = RustyJson.decode!(result)
      assert decoded == %{"a" => 1, "b" => 2}
    end

    test "map/2 encodes maps" do
      opts = RustyJson.Encode.opts()
      result = RustyJson.Encode.map(%{x: 1}, opts)
      assert result == ~s({"x":1})
    end

    test "string/2 encodes strings" do
      opts = RustyJson.Encode.opts()
      assert RustyJson.Encode.string("hello", opts) == ~s("hello")
    end

    test "string/2 with html_safe escape" do
      opts = RustyJson.Encode.opts(:html_safe)
      result = RustyJson.Encode.string("<script>", opts)
      assert result =~ "\\u003c"
    end

    test "struct/2 encodes structs" do
      opts = RustyJson.Encode.opts()
      result = RustyJson.Encode.struct(~D[2024-01-15], opts)
      assert result == ~s("2024-01-15")
    end
  end

  describe "key/2" do
    test "encodes string key" do
      opts = RustyJson.Encode.opts()
      assert RustyJson.Encode.key("name", opts) == ~s("name")
    end

    test "encodes atom key" do
      opts = RustyJson.Encode.opts()
      assert RustyJson.Encode.key(:status, opts) == ~s("status")
    end

    test "encodes integer key via String.Chars" do
      opts = RustyJson.Encode.opts()
      assert RustyJson.Encode.key(42, opts) == ~s("42")
    end

    test "respects html_safe escape" do
      opts = RustyJson.Encode.opts(:html_safe)
      assert RustyJson.Encode.key("<key>", opts) =~ "\\u003c"
    end
  end

  describe "keyword/2 preserves order" do
    test "maintains insertion order" do
      opts = RustyJson.Encode.opts()
      result = RustyJson.Encode.keyword([z: 1, a: 2, m: 3], opts)
      assert result == ~s({"z":1,"a":2,"m":3})
    end

    test "handles empty keyword list" do
      opts = RustyJson.Encode.opts()
      result = RustyJson.Encode.keyword([], opts)
      assert result == "{}"
    end

    test "handles single entry" do
      opts = RustyJson.Encode.opts()
      result = RustyJson.Encode.keyword([only: true], opts)
      assert result == ~s({"only":true})
    end
  end
end
