defmodule EncodeTest do
  use ExUnit.Case

  describe "RustyJson.Encode" do
    test "opts/1 builds opaque encoding options" do
      opts = RustyJson.Encode.opts(:json)
      # opts is opaque - verify it works by encoding with it
      assert IO.iodata_to_binary(RustyJson.Encode.value("test", opts)) == ~s("test")
    end

    test "opts/0 defaults to :json" do
      opts = RustyJson.Encode.opts()
      assert IO.iodata_to_binary(RustyJson.Encode.value("test", opts)) == ~s("test")
    end

    test "encode/2 returns ok tuple" do
      assert {:ok, iodata} = RustyJson.Encode.encode(%{a: 1})
      assert IO.iodata_to_binary(iodata) == ~s({"a":1})
    end

    test "encode/2 returns error on failure" do
      assert {:error, _} = RustyJson.Encode.encode(self())
    end

    test "value/2 encodes any term" do
      opts = RustyJson.Encode.opts()
      assert IO.iodata_to_binary(RustyJson.Encode.value("hello", opts)) == ~s("hello")
      assert IO.iodata_to_binary(RustyJson.Encode.value(42, opts)) == "42"
      assert IO.iodata_to_binary(RustyJson.Encode.value(true, opts)) == "true"
    end

    test "atom/2 encodes atoms" do
      opts = RustyJson.Encode.opts()
      assert IO.iodata_to_binary(RustyJson.Encode.atom(:hello, opts)) == ~s("hello")
      assert IO.iodata_to_binary(RustyJson.Encode.atom(nil, opts)) == "null"
      assert IO.iodata_to_binary(RustyJson.Encode.atom(true, opts)) == "true"
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
      assert IO.iodata_to_binary(RustyJson.Encode.list([1, 2, 3], opts)) == "[1,2,3]"
    end

    test "keyword/2 encodes keyword list as object" do
      opts = RustyJson.Encode.opts()
      result = IO.iodata_to_binary(RustyJson.Encode.keyword([a: 1, b: 2], opts))
      decoded = RustyJson.decode!(result)
      assert decoded == %{"a" => 1, "b" => 2}
    end

    test "map/2 encodes maps" do
      opts = RustyJson.Encode.opts()
      result = IO.iodata_to_binary(RustyJson.Encode.map(%{x: 1}, opts))
      assert result == ~s({"x":1})
    end

    test "string/2 encodes strings" do
      opts = RustyJson.Encode.opts()
      assert IO.iodata_to_binary(RustyJson.Encode.string("hello", opts)) == ~s("hello")
    end

    test "string/2 with html_safe escape" do
      opts = RustyJson.Encode.opts(:html_safe)
      result = IO.iodata_to_binary(RustyJson.Encode.string("<script>", opts))
      assert result =~ "\\u003C"
    end

    test "struct/2 encodes structs" do
      opts = RustyJson.Encode.opts()
      result = IO.iodata_to_binary(RustyJson.Encode.struct(~D[2024-01-15], opts))
      assert result == ~s("2024-01-15")
    end
  end

  describe "key/2" do
    test "encodes string key" do
      {escape, _} = RustyJson.Encode.opts()
      result = IO.iodata_to_binary(RustyJson.Encode.key("name", escape))
      assert result == "name"
    end

    test "encodes atom key" do
      {escape, _} = RustyJson.Encode.opts()
      result = IO.iodata_to_binary(RustyJson.Encode.key(:status, escape))
      assert result == "status"
    end

    test "encodes integer key via String.Chars" do
      {escape, _} = RustyJson.Encode.opts()
      result = IO.iodata_to_binary(RustyJson.Encode.key(42, escape))
      assert result == "42"
    end

    test "respects html_safe escape" do
      {escape, _} = RustyJson.Encode.opts(:html_safe)
      result = IO.iodata_to_binary(RustyJson.Encode.key("<key>", escape))
      assert result =~ "\\u003C"
    end
  end

  describe "keyword/2 preserves order" do
    test "maintains insertion order" do
      opts = RustyJson.Encode.opts()
      result = IO.iodata_to_binary(RustyJson.Encode.keyword([z: 1, a: 2, m: 3], opts))
      assert result == ~s({"z":1,"a":2,"m":3})
    end

    test "handles empty keyword list" do
      opts = RustyJson.Encode.opts()
      result = IO.iodata_to_binary(RustyJson.Encode.keyword([], opts))
      assert result == "{}"
    end

    test "handles single entry" do
      opts = RustyJson.Encode.opts()
      result = IO.iodata_to_binary(RustyJson.Encode.keyword([only: true], opts))
      assert result == ~s({"only":true})
    end
  end
end
