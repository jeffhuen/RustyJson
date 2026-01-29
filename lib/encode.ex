defmodule RustyJson.Encode do
  @moduledoc """
  Low-level encoding functions, compatible with Jason's `Encode` module.

  These functions encode individual Elixir terms to JSON iodata.
  They are designed for use inside custom `RustyJson.Encoder` protocol
  implementations, providing the same API as Jason's `Encode` module.

  ## Opts

  Functions that accept `opts` use an opaque type matching Jason's `Encode.opts()`.
  The opts value is passed to `RustyJson.Encoder.encode/2` implementations and
  should be forwarded to `Encode` functions as-is.

  ## Examples

      defimpl RustyJson.Encoder, for: Money do
        def encode(%{amount: a, currency: c}, opts) do
          RustyJson.Encode.map(%{amount: a, currency: to_string(c)}, opts)
        end
      end
  """

  @typep escape :: (String.t(), String.t(), integer() -> iodata())
  @typep encode_map :: (map(), escape(), encode_map() -> iodata())

  @typedoc """
  Opaque encoding options.

  Passed to `RustyJson.Encoder.encode/2` implementations.
  Forward to `Encode` functions as-is.
  """
  @opaque opts :: {escape, encode_map}

  @doc """
  Builds encoding options from an escape mode.

  Returns an opaque opts value that can be passed to `value/2`, `map/2`,
  `string/2`, and other encoding functions.

  ## Examples

      opts = RustyJson.Encode.opts(:json)
      RustyJson.Encode.string("hello", opts)
  """
  @spec opts(atom()) :: opts()
  def opts(escape \\ :json) do
    build_opts(escape, :naive)
  end

  @doc false
  @spec build_opts(atom(), atom()) :: opts()
  def build_opts(escape_mode, maps_mode) do
    {escape_function(%{escape: escape_mode}), encode_map_function(%{maps: maps_mode})}
  end

  @doc false
  @spec encode(term(), map()) ::
          {:ok, iodata()} | {:error, RustyJson.EncodeError.t() | Exception.t()}
  def encode(value, user_opts \\ %{escape: :json, maps: :naive}) do
    escape = escape_function(user_opts)
    encode_map = encode_map_function(user_opts)

    try do
      {:ok, value(value, escape, encode_map)}
    catch
      :throw, %RustyJson.EncodeError{} = e ->
        {:error, e}

      :error, %Protocol.UndefinedError{protocol: RustyJson.Encoder} = e ->
        {:error, e}
    end
  end

  @doc """
  Encodes any term to JSON iodata.

  Dispatches based on type, matching Jason's `Encode.value/2`.
  """
  @spec value(term(), opts()) :: iodata()
  def value(value, {escape, encode_map}) do
    value(value, escape, encode_map)
  end

  @doc false
  def value(value, escape, _encode_map) when is_atom(value) do
    encode_atom(value, escape)
  end

  def value(value, escape, _encode_map) when is_binary(value) do
    encode_string(value, escape)
  end

  def value(value, _escape, _encode_map) when is_integer(value) do
    integer(value)
  end

  def value(value, _escape, _encode_map) when is_float(value) do
    float(value)
  end

  def value(value, escape, encode_map) when is_list(value) do
    list(value, escape, encode_map)
  end

  def value(%{__struct__: module} = value, escape, encode_map) do
    struct(value, escape, encode_map, module)
  end

  def value(value, escape, encode_map) when is_map(value) do
    case Map.to_list(value) do
      [] -> "{}"
      kv -> encode_map.(kv, escape, encode_map)
    end
  end

  def value(value, escape, encode_map) do
    RustyJson.Encoder.encode(value, {escape, encode_map})
  end

  @doc """
  Encodes an atom to a JSON string or literal.
  """
  @spec atom(atom(), opts()) :: iodata()
  def atom(atom, {escape, _encode_map}) do
    encode_atom(atom, escape)
  end

  defp encode_atom(nil, _escape), do: "null"
  defp encode_atom(true, _escape), do: "true"
  defp encode_atom(false, _escape), do: "false"

  defp encode_atom(atom, escape),
    do: encode_string(Atom.to_string(atom), escape)

  @doc """
  Encodes an integer to a JSON number.
  """
  @spec integer(integer()) :: iodata()
  def integer(integer) do
    Integer.to_string(integer)
  end

  @doc """
  Encodes a float to a JSON number.
  """
  @spec float(float()) :: iodata()
  def float(float) do
    :erlang.float_to_binary(float, [:short])
  end

  @doc """
  Encodes a list to a JSON array.
  """
  @spec list(list(), opts()) :: iodata()
  def list(list, {escape, encode_map}) do
    list(list, escape, encode_map)
  end

  defp list([], _escape, _encode_map) do
    "[]"
  end

  defp list([head | tail], escape, encode_map) do
    [?[, value(head, escape, encode_map) | list_loop(tail, escape, encode_map)]
  end

  defp list_loop([], _escape, _encode_map) do
    ~c']'
  end

  defp list_loop([head | tail], escape, encode_map) do
    [?,, value(head, escape, encode_map) | list_loop(tail, escape, encode_map)]
  end

  @doc """
  Encodes a keyword list as an ordered JSON object.

  Preserves key insertion order, matching Jason's `Encode.keyword/2`.
  """
  @spec keyword(keyword(), opts()) :: iodata()
  def keyword(list, _) when list == [], do: "{}"

  def keyword(list, {escape, encode_map}) when is_list(list) do
    encode_map.(list, escape, encode_map)
  end

  @doc """
  Encodes a map to a JSON object.
  """
  @spec map(map(), opts()) :: iodata()
  def map(value, {escape, encode_map}) do
    case Map.to_list(value) do
      [] -> "{}"
      kv -> encode_map.(kv, escape, encode_map)
    end
  end

  @doc """
  Encodes a struct to JSON.
  """
  @spec struct(struct(), opts()) :: iodata()
  def struct(%module{} = value, {escape, encode_map}) do
    struct(value, escape, encode_map, module)
  end

  for module <- [Date, Time, NaiveDateTime, DateTime] do
    defp struct(value, _escape, _encode_map, unquote(module)) do
      [?", unquote(module).to_iso8601(value), ?"]
    end
  end

  if Code.ensure_loaded?(Decimal) do
    defp struct(value, _escape, _encode_map, Decimal) do
      [?", Decimal.to_string(value, :normal), ?"]
    end
  end

  defp struct(value, escape, encode_map, RustyJson.Fragment) do
    %{encode: encode} = value
    encode.({escape, encode_map})
  end

  defp struct(value, escape, encode_map, RustyJson.OrderedObject) do
    case value do
      %{values: []} -> "{}"
      %{values: values} -> encode_map.(values, escape, encode_map)
    end
  end

  defp struct(value, escape, encode_map, _module) do
    RustyJson.Encoder.encode(value, {escape, encode_map})
  end

  @doc false
  def key(string, escape) when is_binary(string) do
    escape.(string, string, 0)
  end

  def key(atom, escape) when is_atom(atom) do
    string = Atom.to_string(atom)
    escape.(string, string, 0)
  end

  def key(other, escape) do
    string = String.Chars.to_string(other)
    escape.(string, string, 0)
  end

  @doc """
  Encodes a string to a JSON string.
  """
  @spec string(String.t(), opts()) :: iodata()
  def string(string, {escape, _encode_map}) do
    encode_string(string, escape)
  end

  defp encode_string(string, escape) do
    [?", escape.(string, string, 0), ?"]
  end

  # Escape functions matching Jason's implementations

  defp escape_function(%{escape: escape}) do
    case escape do
      :json -> &escape_json/3
      :html_safe -> &escape_html/3
      :unicode_safe -> &escape_unicode/3
      :javascript_safe -> &escape_javascript/3
    end
  end

  defp encode_map_function(%{maps: maps}) do
    case maps do
      :naive -> &map_naive/3
      :strict -> &map_strict/3
    end
  end

  # Map encoding

  defp map_naive([{key, value} | tail], escape, encode_map) do
    [
      "{\"",
      key(key, escape),
      "\":",
      value(value, escape, encode_map)
      | map_naive_loop(tail, escape, encode_map)
    ]
  end

  defp map_naive_loop([], _escape, _encode_map) do
    ~c'}'
  end

  defp map_naive_loop([{key, value} | tail], escape, encode_map) do
    [
      ",\"",
      key(key, escape),
      "\":",
      value(value, escape, encode_map)
      | map_naive_loop(tail, escape, encode_map)
    ]
  end

  defp map_strict([{key, value} | tail], escape, encode_map) do
    key = IO.iodata_to_binary(key(key, escape))
    visited = %{key => []}

    [
      "{\"",
      key,
      "\":",
      value(value, escape, encode_map)
      | map_strict_loop(tail, escape, encode_map, visited)
    ]
  end

  defp map_strict_loop([], _escape, _encode_map, _visited) do
    ~c'}'
  end

  defp map_strict_loop([{key, value} | tail], escape, encode_map, visited) do
    key = IO.iodata_to_binary(key(key, escape))

    case visited do
      %{^key => _} ->
        throw(RustyJson.EncodeError.new({:duplicate_key, key}))

      _ ->
        visited = Map.put(visited, key, [])

        [
          ",\"",
          key,
          "\":",
          value(value, escape, encode_map)
          | map_strict_loop(tail, escape, encode_map, visited)
        ]
    end
  end

  # String escaping using Jason's 5-parameter algorithm:
  # escape_*(data, original, skip, len, acc)
  #   data     - remaining bytes to scan
  #   original - the full original string (never mutated)
  #   skip     - byte offset of the start of current unescaped segment
  #   len      - length of current unescaped segment
  #   acc      - accumulated iodata output
  #
  # When a byte needs escaping:
  #   1. Emit binary_part(original, skip, len) — the segment before this byte
  #   2. Emit the escape sequence
  #   3. Continue with skip = skip + len + 1, len = 0
  #
  # When a byte does NOT need escaping:
  #   1. Continue with len + 1
  #
  # When done (empty binary):
  #   1. If acc is empty, nothing was escaped — return original unchanged
  #   2. Otherwise emit the final unescaped segment and return acc

  @slash_escapes Enum.zip(~c'\b\t\n\f\r\"\\', ~c'btnfr"\\')

  # JSON mode (RFC 8259) — escapes control characters (0x00-0x1F), backslash, double quote

  defp escape_json(data, original, skip) do
    escape_json(data, original, skip, 0, [])
  end

  for {byte, escape_char} <- @slash_escapes do
    defp escape_json(<<unquote(byte), rest::bits>>, original, skip, len, acc) do
      part = binary_part(original, skip, len)
      acc = [acc, part, ?\\, unquote(escape_char)]
      escape_json(rest, original, skip + len + 1, 0, acc)
    end
  end

  for byte <- 0x00..0x1F, byte not in Enum.map(@slash_escapes, &elem(&1, 0)) do
    defp escape_json(<<unquote(byte), rest::bits>>, original, skip, len, acc) do
      part = binary_part(original, skip, len)
      acc = [acc, part, escape_unicode_char(unquote(byte))]
      escape_json(rest, original, skip + len + 1, 0, acc)
    end
  end

  defp escape_json(<<_byte, rest::bits>>, original, skip, len, acc) do
    escape_json(rest, original, skip, len + 1, acc)
  end

  defp escape_json(<<>>, original, _skip, _len, []) do
    original
  end

  defp escape_json(<<>>, original, skip, len, acc) do
    [acc | binary_part(original, skip, len)]
  end

  # HTML-safe mode — additionally escapes <, >, &, /

  defp escape_html(data, original, skip) do
    escape_html(data, original, skip, 0, [])
  end

  for {byte, escape_char} <- @slash_escapes do
    defp escape_html(<<unquote(byte), rest::bits>>, original, skip, len, acc) do
      part = binary_part(original, skip, len)
      acc = [acc, part, ?\\, unquote(escape_char)]
      escape_html(rest, original, skip + len + 1, 0, acc)
    end
  end

  for byte <- [?<, ?>, ?&] do
    defp escape_html(<<unquote(byte), rest::bits>>, original, skip, len, acc) do
      part = binary_part(original, skip, len)
      acc = [acc, part, escape_unicode_char(unquote(byte))]
      escape_html(rest, original, skip + len + 1, 0, acc)
    end
  end

  defp escape_html(<<?/, rest::bits>>, original, skip, len, acc) do
    part = binary_part(original, skip, len)
    acc = [acc, part, ?\\, ?/]
    escape_html(rest, original, skip + len + 1, 0, acc)
  end

  for byte <- 0x00..0x1F, byte not in Enum.map(@slash_escapes, &elem(&1, 0)) do
    defp escape_html(<<unquote(byte), rest::bits>>, original, skip, len, acc) do
      part = binary_part(original, skip, len)
      acc = [acc, part, escape_unicode_char(unquote(byte))]
      escape_html(rest, original, skip + len + 1, 0, acc)
    end
  end

  defp escape_html(<<_byte, rest::bits>>, original, skip, len, acc) do
    escape_html(rest, original, skip, len + 1, acc)
  end

  defp escape_html(<<>>, original, _skip, _len, []) do
    original
  end

  defp escape_html(<<>>, original, skip, len, acc) do
    [acc | binary_part(original, skip, len)]
  end

  # Unicode-safe mode — escapes all non-ASCII codepoints

  defp escape_unicode(data, original, skip) do
    escape_unicode(data, original, skip, 0, [])
  end

  for {byte, escape_char} <- @slash_escapes do
    defp escape_unicode(<<unquote(byte), rest::bits>>, original, skip, len, acc) do
      part = binary_part(original, skip, len)
      acc = [acc, part, ?\\, unquote(escape_char)]
      escape_unicode(rest, original, skip + len + 1, 0, acc)
    end
  end

  for byte <- 0x00..0x1F, byte not in Enum.map(@slash_escapes, &elem(&1, 0)) do
    defp escape_unicode(<<unquote(byte), rest::bits>>, original, skip, len, acc) do
      part = binary_part(original, skip, len)
      acc = [acc, part, escape_unicode_char(unquote(byte))]
      escape_unicode(rest, original, skip + len + 1, 0, acc)
    end
  end

  defp escape_unicode(<<codepoint::utf8, rest::bits>>, original, skip, len, acc)
       when codepoint > 0x7F do
    part = binary_part(original, skip, len)
    escaped = escape_unicode_codepoint(codepoint)
    acc = [acc, part, escaped]
    escape_unicode(rest, original, skip + len + byte_size(<<codepoint::utf8>>), 0, acc)
  end

  defp escape_unicode(<<_byte, rest::bits>>, original, skip, len, acc) do
    escape_unicode(rest, original, skip, len + 1, acc)
  end

  defp escape_unicode(<<>>, original, _skip, _len, []) do
    original
  end

  defp escape_unicode(<<>>, original, skip, len, acc) do
    [acc | binary_part(original, skip, len)]
  end

  # JavaScript-safe mode — escapes U+2028 and U+2029 (line/paragraph separators)

  defp escape_javascript(data, original, skip) do
    escape_javascript(data, original, skip, 0, [])
  end

  for {byte, escape_char} <- @slash_escapes do
    defp escape_javascript(<<unquote(byte), rest::bits>>, original, skip, len, acc) do
      part = binary_part(original, skip, len)
      acc = [acc, part, ?\\, unquote(escape_char)]
      escape_javascript(rest, original, skip + len + 1, 0, acc)
    end
  end

  for byte <- 0x00..0x1F, byte not in Enum.map(@slash_escapes, &elem(&1, 0)) do
    defp escape_javascript(<<unquote(byte), rest::bits>>, original, skip, len, acc) do
      part = binary_part(original, skip, len)
      acc = [acc, part, escape_unicode_char(unquote(byte))]
      escape_javascript(rest, original, skip + len + 1, 0, acc)
    end
  end

  for {codepoint, escaped} <- [{0x2028, "\\u2028"}, {0x2029, "\\u2029"}] do
    defp escape_javascript(<<unquote(codepoint)::utf8, rest::bits>>, original, skip, len, acc) do
      part = binary_part(original, skip, len)
      acc = [acc, part, unquote(escaped)]

      escape_javascript(
        rest,
        original,
        skip + len + byte_size(<<unquote(codepoint)::utf8>>),
        0,
        acc
      )
    end
  end

  defp escape_javascript(<<_byte, rest::bits>>, original, skip, len, acc) do
    escape_javascript(rest, original, skip, len + 1, acc)
  end

  defp escape_javascript(<<>>, original, _skip, _len, []) do
    original
  end

  defp escape_javascript(<<>>, original, skip, len, acc) do
    [acc | binary_part(original, skip, len)]
  end

  # Helpers

  defp escape_unicode_char(byte) do
    hex = Integer.to_string(byte, 16)
    "\\u" <> String.pad_leading(hex, 4, "0")
  end

  defp escape_unicode_codepoint(codepoint) when codepoint <= 0xFFFF do
    escape_unicode_char(codepoint)
  end

  defp escape_unicode_codepoint(codepoint) do
    # Encode as surrogate pair
    high = div(codepoint - 0x10000, 0x400) + 0xD800
    low = rem(codepoint - 0x10000, 0x400) + 0xDC00
    [escape_unicode_char(high), escape_unicode_char(low)]
  end
end
