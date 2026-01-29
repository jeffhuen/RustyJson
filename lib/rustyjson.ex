defmodule RustyJson do
  @moduledoc """
  A high-performance JSON library for Elixir powered by Rust NIFs.

  RustyJson is designed as a **drop-in replacement for Jason** with significantly
  better performance characteristics:

  - **3-6x faster encoding** for medium/large payloads
  - **10-20x lower memory usage** during encoding
  - **Full JSON spec compliance** (RFC 8259)
  - **Native type support** for DateTime, Decimal, URI, and more

  ## Quick Start

      # Encoding
      iex> RustyJson.encode!(%{name: "Alice", age: 30})
      ~s({"age":30,"name":"Alice"})

      # Decoding
      iex> RustyJson.decode!(~s({"name":"Alice","age":30}))
      %{"age" => 30, "name" => "Alice"}

      # Pretty printing
      iex> RustyJson.encode!(%{items: [1, 2, 3]}, pretty: true)
      \"""
      {
        "items": [
          1,
          2,
          3
        ]
      }
      \"""

  ## Phoenix Integration

  Configure Phoenix to use RustyJson as the JSON library:

      # config/config.exs
      config :phoenix, :json_library, RustyJson

  ## Why RustyJson?

  Traditional JSON libraries in Elixir create many intermediate binary allocations
  during encoding, which pressures the garbage collector. RustyJson eliminates this
  by walking the Erlang term tree directly in Rust and writing to a single buffer.

  For a detailed comparison, see the [README](readme.html).

  ## Module Overview

  | Module | Description |
  |--------|-------------|
  | `RustyJson` | Main encoding/decoding API |
  | `RustyJson.Encoder` | Protocol for custom type encoding |
  | `RustyJson.Encode` | Low-level encoding functions |
  | `RustyJson.Fragment` | Pre-encoded JSON injection |
  | `RustyJson.Formatter` | JSON pretty-printing utilities |
  | `RustyJson.Helpers` | Compile-time JSON macros (`json_map`, `json_map_take`) |
  | `RustyJson.Sigil` | `~j`/`~J` sigils for JSON literals |
  | `RustyJson.OrderedObject` | Order-preserving JSON object (for `objects: :ordered_objects`) |
  | `RustyJson.Decoder` | JSON decoding module (Jason.Decoder compatible) |
  | `RustyJson.DecodeError` | Decoding error exception |
  | `RustyJson.EncodeError` | Encoding error exception |

  ## Built-in Type Support

  RustyJson natively handles these Elixir types without protocol overhead:

  | Elixir Type | JSON Output | Example |
  |-------------|-------------|---------|
  | `map` | object | `%{a: 1}` → `{"a":1}` |
  | `list` | array | `[1, 2]` → `[1,2]` |
  | `tuple` | array | `{1, 2}` → `[1,2]` |
  | `binary` | string | `"hello"` → `"hello"` |
  | `integer` | number | `42` → `42` |
  | `float` | number | `3.14` → `3.14` |
  | `true/false` | boolean | `true` → `true` |
  | `nil` | null | `nil` → `null` |
  | `atom` | string | `:hello` → `"hello"` |
  | `DateTime` | ISO8601 string | `~U[2024-01-15 14:30:00Z]` → `"2024-01-15T14:30:00Z"` |
  | `NaiveDateTime` | ISO8601 string | `~N[2024-01-15 14:30:00]` → `"2024-01-15T14:30:00"` |
  | `Date` | ISO8601 string | `~D[2024-01-15]` → `"2024-01-15"` |
  | `Time` | ISO8601 string | `~T[14:30:00]` → `"14:30:00"` |
  | `Decimal` | string | `Decimal.new("123.45")` → `"123.45"` |
  | `URI` | string | `URI.parse("https://example.com")` → `"https://example.com"` |
  | structs | object | `%User{name: "Alice"}` → `{"name":"Alice"}` (requires `@derive RustyJson.Encoder` or explicit `defimpl`) |

  > **Note:** `MapSet` and `Range` are **not** natively encoded. They require an explicit
  > `RustyJson.Encoder` implementation or `protocol: false` to encode via the Rust NIF directly.
  > This matches Jason's behavior.

  ## Escape Modes

  RustyJson supports multiple escape modes for different security contexts:

  | Mode | Description | Use Case |
  |------|-------------|----------|
  | `:json` | Standard JSON escaping (default) | General use |
  | `:html_safe` | Escapes `<`, `>`, `&` as `\\uXXXX` and `/` as `\\/` | HTML embedding |
  | `:javascript_safe` | Escapes line/paragraph separators | JavaScript strings |
  | `:unicode_safe` | Escapes all non-ASCII as `\\uXXXX` | ASCII-only output |

  ## Performance Tips

  1. **Bypass the protocol**: The protocol is enabled by default for Jason
     compatibility. If you have no custom `RustyJson.Encoder` implementations,
     use `protocol: false` to bypass protocol dispatch for maximum speed.

  2. **Use lean mode**: If you don't have DateTime/Decimal types, use `lean: true`
     to skip struct type detection in Rust.

  3. **Use compression**: For large payloads over the network, `compress: :gzip`
     reduces output size 5-10x.

  4. **Avoid `keys: :atoms` with untrusted input**: `keys: :atoms` uses
     `String.to_atom/1`, which can exhaust the atom table. Use `keys: :atoms!`
     (which uses `String.to_existing_atom/1`) or `keys: :strings` (default) instead.

  5. **Use key interning for bulk data**: When decoding arrays of objects with
     the same schema (API responses, database results, webhooks), use `keys: :intern`
     for ~30% faster parsing:

         RustyJson.decode!(json, keys: :intern)

     **Caution**: Don't use for single objects or varied schemas—cache overhead
     makes it 2-3x *slower* when keys aren't reused.

  ## Error Handling

  RustyJson provides clear, actionable error messages. `encode/1` and `decode/1`
  consistently return `{:error, reason}` tuples for invalid input.

      # Error messages describe the problem
      RustyJson.decode(~s({"key": "value\\\\'s"}))
      # => {:error, "Invalid escape sequence: \\\\'"}

      # Unencodable values return error tuples
      RustyJson.encode(%{{:tuple, :key} => 1})
      # => {:error, "Map key must be atom, string, or integer"}

      # Strict UTF-16 surrogate validation per RFC 7493
      RustyJson.decode(~s("\\\\uD800"))
      # => {:error, "Lone surrogate in string"}

  This makes error handling predictable—pattern match on results without needing
  `try/rescue` blocks.
  """

  @typedoc """
  Supported compression algorithms for encoding.

  - `:gzip` - Standard gzip compression
  - `:none` - No compression (default)
  """
  @type compression_algorithm :: :gzip | :none

  @typedoc """
  Compression level from 0 (fastest, least compression) to 9 (slowest, best compression).
  """
  @type compression_level :: 0..9

  @typedoc """
  Compression options tuple.

  Can be specified as:
  - `:gzip` - Use default compression level
  - `{:gzip, level}` - Use specific compression level (0-9)
  - `:none` - No compression
  """
  @type compression_option :: :gzip | {:gzip, compression_level()} | :none

  @typedoc """
  Internal compression options format passed to NIF.
  """
  @type compression_options :: {compression_algorithm(), compression_level() | nil}

  @typedoc """
  Options for decoding JSON object keys.

  - `:strings` - Keep keys as strings (default, safe)
  - `:atoms` - Convert to atoms using `String.to_atom/1` (unsafe with untrusted input)
  - `:atoms!` - Convert to existing atoms using `String.to_existing_atom/1` (safe, raises if missing)
  - `:copy` - Copy key binaries (same as `:strings` in RustyJson since NIFs always copy)
  - `:intern` - Cache repeated keys during parsing (~30% faster for arrays of objects)
  - A function of arity 1 - Applied to each key string recursively
  """
  @type keys :: :strings | :atoms | :atoms! | :copy | :intern | (String.t() -> term())

  @typedoc """
  Escape mode for JSON string encoding.

  - `:json` - Standard JSON escaping (default)
  - `:html_safe` - Also escape `<`, `>`, `&`, `/` for safe HTML embedding
  - `:javascript_safe` - Also escape line/paragraph separators (U+2028, U+2029)
  - `:unicode_safe` - Escape all non-ASCII characters as `\\uXXXX`
  """
  @type escape_mode :: :json | :html_safe | :javascript_safe | :unicode_safe

  @typedoc """
  Options for `encode/2` and `encode!/2`.

  - `:pretty` - Pretty print with indentation. `true` for 2 spaces, an integer for custom
    spacing, a string/iodata for custom indent (e.g. `"\\t"` for tabs), or a keyword list
    with `:indent`, `:line_separator`, and `:after_colon` keys.
  - `:escape` - Escape mode (see `t:escape_mode/0`). Default: `:json`
  - `:compress` - Compression (see `t:compression_option/0`). Default: `:none`
  - `:protocol` - Use `RustyJson.Encoder` protocol. Default: `true`
  - `:lean` - Skip special struct handling. Default: `false`
  - `:maps` - Key uniqueness mode. `:naive` (default) allows duplicate serialized keys,
    `:strict` raises on duplicate keys (e.g. atom `:a` and string `"a"` in the same map).
  """
  @type encode_opt ::
          {:pretty, boolean() | pos_integer() | keyword()}
          | {:escape, escape_mode()}
          | {:compress, compression_option()}
          | {:protocol, boolean()}
          | {:lean, boolean()}
          | {:maps, :naive | :strict}

  @typedoc """
  Options for `decode/2` and `decode!/2`.

  - `:keys` - How to handle object keys (see `t:keys/0`). Default: `:strings`
  - `:strings` - How to handle decoded strings. `:copy` or `:reference`. Both produce copies (RustyJson always copies). Default: `:reference`
  - `:objects` - How to decode JSON objects. `:maps` (default) or `:ordered_objects`
  - `:floats` - How to decode JSON floats. `:native` (default) or `:decimals`
  - `:decoding_integer_digit_limit` - Maximum digits in integer part. 0 disables.
    Default: 1024, or the value of `Application.compile_env(:rustyjson, :decoding_integer_digit_limit)`
  """
  @type decode_opt ::
          {:keys, keys()}
          | {:strings, :copy | :reference}
          | {:objects, :maps | :ordered_objects}
          | {:floats, :native | :decimals}
          | {:decoding_integer_digit_limit, non_neg_integer()}

  @default_integer_digit_limit Application.compile_env(
                                 :rustyjson,
                                 :decoding_integer_digit_limit,
                                 1024
                               )

  source_url = Mix.Project.config()[:source_url]
  version = Mix.Project.config()[:version]

  # Check env var or application config for force_build
  force_build? =
    System.get_env("FORCE_RUSTYJSON_BUILD") in ["1", "true"] or
      Application.compile_env(:rustler_precompiled, :force_build, [])[:rustyjson] == true

  use RustlerPrecompiled,
    otp_app: :rustyjson,
    base_url: "#{source_url}/releases/download/v#{version}",
    force_build: force_build?,
    nif_versions: ["2.15", "2.16", "2.17"],
    targets: RustlerPrecompiled.Config.default_targets(),
    version: version

  # NIF stubs - these are replaced by Rustler at runtime
  @doc false
  @spec nif_encode_direct(term(), map()) :: String.t()
  defp nif_encode_direct(_input, _opts_map),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec nif_decode(String.t(), map()) :: term()
  defp nif_decode(_input, _opts_map), do: :erlang.nif_error(:nif_not_loaded)

  # ============================================================================
  # Encoding API
  # ============================================================================

  @doc """
  Encodes an Elixir term to a JSON string.

  Returns `{:ok, json}` on success or `{:error, reason}` on failure.

  ## Options

  * `:pretty` - Pretty print with indentation. `true` uses 2 spaces, or pass an
    integer for custom spacing. Default: `false`

  * `:escape` - Escape mode for special characters. One of `:json` (default),
    `:html_safe`, `:javascript_safe`, or `:unicode_safe`. See `t:escape_mode/0`.

  * `:compress` - Compression algorithm. `:gzip` or `{:gzip, 0..9}` for specific
    level. Default: `:none`

  * `:protocol` - Enable `RustyJson.Encoder` protocol for custom types. Default: `true`

  * `:lean` - Skip struct type detection (DateTime, Decimal, etc. encoded as raw
    maps). Default: `false`

  * `:maps` - Key uniqueness mode. `:naive` (default) allows duplicate serialized
    keys, `:strict` errors on duplicate keys (e.g. atom `:a` and string `"a"`).

  ## Examples

      iex> RustyJson.encode(%{name: "Alice", scores: [95, 87, 92]})
      {:ok, ~s({"name":"Alice","scores":[95,87,92]})}

      iex> RustyJson.encode(%{valid: true}, pretty: true)
      {:ok, \"{\\n  \\\"valid\\\": true\\n}\"}

      iex> RustyJson.encode("invalid UTF-8: " <> <<0xFF>>)
      {:error, "Failed to decode binary as UTF-8"}

  ## Error Handling

  Common error cases:
  - Invalid UTF-8 binary
  - Non-finite float (NaN, Infinity)
  - Circular references (will cause stack overflow)

  See `encode!/2` for a version that raises on error.
  """
  @spec encode(term(), [encode_opt()]) ::
          {:ok, String.t()} | {:error, RustyJson.EncodeError.t() | Exception.t()}
  def encode(input, opts \\ []) do
    {:ok, encode!(input, opts)}
  rescue
    e in [RustyJson.EncodeError] -> {:error, e}
    e in [ArgumentError] -> {:error, e}
    e in [ErlangError] -> {:error, %RustyJson.EncodeError{message: error_message(e)}}
  end

  @doc """
  Encodes an Elixir term to a JSON string, raising on error.

  Same as `encode/2` but raises `RustyJson.EncodeError` on failure.

  ## Options

  See `encode/2` for available options.

  ## Examples

      iex> RustyJson.encode!(%{hello: "world"})
      ~s({"hello":"world"})

      iex> RustyJson.encode!([1, 2, 3], pretty: 4)
      \"""
      [
          1,
          2,
          3
      ]
      \"""

      iex> RustyJson.encode!(~D[2024-01-15])
      ~s("2024-01-15")

      iex> RustyJson.encode!(%{html: "<script>"}, escape: :html_safe)
      ~s({"html":"\\u003cscript\\u003e"})

  ## Custom Encoding

  For custom types, implement `RustyJson.Encoder`. The protocol is used by
  default (`protocol: true`):

      defmodule Money do
        defstruct [:amount, :currency]
      end

      defimpl RustyJson.Encoder, for: Money do
        def encode(%Money{amount: amount, currency: currency}, _opts) do
          %{amount: Decimal.to_string(amount), currency: currency}
        end
      end

      iex> money = %Money{amount: Decimal.new("99.99"), currency: "USD"}
      iex> RustyJson.encode!(money)
      ~s({"amount":"99.99","currency":"USD"})

  ## Compression

      iex> json = RustyJson.encode!(%{data: String.duplicate("x", 1000)}, compress: :gzip)
      iex> :zlib.gunzip(json)
      ~s({"data":"#{String.duplicate("x", 1000)}"})

  """
  @spec encode!(term(), [encode_opt()]) :: String.t()
  def encode!(input, opts \\ []) do
    {indent, opts} = Keyword.pop(opts, :pretty, nil)
    {compression, opts} = Keyword.pop(opts, :compress, :none)
    {escape, opts} = Keyword.pop(opts, :escape, :json)
    {use_protocol, opts} = Keyword.pop(opts, :protocol, true)
    {lean, opts} = Keyword.pop(opts, :lean, false)
    {maps_mode, opts} = Keyword.pop(opts, :maps, :naive)
    validate_option!(maps_mode, [:naive, :strict], :maps)

    # Extract pretty print separator opts
    {pretty_opts, indent} = normalize_pretty_opts(indent)

    escape = validate_escape!(escape)
    compression = validate_compression!(compression)
    strict_keys = maps_mode == :strict

    _ = opts

    # Build opaque encoder opts matching Jason.Encode.opts() format.
    # This is a {escape_fn, encode_map_fn} tuple that flows through the
    # Encoder protocol and into Encode functions for full Jason compatibility.
    encoder_opts = RustyJson.Encode.build_opts(escape, maps_mode)

    # With protocol: true, preprocess with Elixir Encoder protocol
    # Otherwise, send directly to Rust for maximum performance
    processed = if use_protocol, do: RustyJson.Encoder.encode(input, encoder_opts), else: input

    # Resolve function-based Fragments so the NIF receives iodata
    processed = resolve_fragment_functions(processed, encoder_opts)

    nif_opts = %{
      indent: indent,
      compression: compression,
      lean: lean == true,
      escape: escape,
      strict_keys: strict_keys,
      pretty_opts: pretty_opts
    }

    nif_encode_direct(processed, nif_opts)
  rescue
    e in [ErlangError] ->
      raise_encode_error(e)
  end

  # ============================================================================
  # Decoding API
  # ============================================================================

  @doc """
  Decodes a JSON string to an Elixir term.

  Returns `{:ok, term}` on success or `{:error, reason}` on failure.

  ## Options

  * `:keys` - How to decode object keys. One of:
    * `:strings` - Keep as strings (default, safe)
    * `:atoms` - Convert to atoms (unsafe with untrusted input)
    * `:atoms!` - Convert to existing atoms only (safe, raises if atom missing)
    * `:copy` - Copy key binaries (equivalent to `:strings` in RustyJson)
    * `:intern` - Cache repeated keys during parsing. **~30% faster** for arrays of
      objects with the same schema (REST APIs, GraphQL, database results, webhooks).
      **Caution**: 2-3x slower for single objects or varied schemas—only use for
      homogeneous arrays of 10+ objects.
    * A function of arity 1 - Applied recursively to each key string.
      Example: `keys: &String.upcase/1`

  * `:strings` - How to handle decoded strings. `:reference` (default) or `:copy`.
    Both produce copies in RustyJson (Rust NIFs always copy into BEAM binaries),
    so this option exists for Jason API compatibility.

  * `:objects` - How to decode JSON objects. `:maps` (default) or `:ordered_objects`.
    When `:ordered_objects`, returns `%RustyJson.OrderedObject{}` structs that
    preserve key insertion order.

  * `:floats` - How to decode JSON floats. `:native` (default) returns Elixir floats,
    `:decimals` returns `%Decimal{}` structs for exact decimal representation.

  * `:decoding_integer_digit_limit` - Maximum number of digits allowed in the integer
    part of a JSON number. Integers exceeding this limit cause a decode error.
    Default: `1024`, or the value of
    `Application.compile_env(:rustyjson, :decoding_integer_digit_limit)`.
    Set to `0` to disable the limit.

  ## Examples

      iex> RustyJson.decode(~s({"name":"Alice","age":30}))
      {:ok, %{"age" => 30, "name" => "Alice"}}

      iex> RustyJson.decode(~s([1, 2, 3]))
      {:ok, [1, 2, 3]}

      iex> RustyJson.decode("invalid")
      {:error, "Unexpected character at position 0"}

  ## Security Considerations

  **Avoid `keys: :atoms` with untrusted input.** Atoms are not garbage collected,
  so an attacker could exhaust your atom table by sending JSON with many unique keys.

  Use `keys: :atoms!` if you expect specific keys to exist, or `keys: :strings` (default).

  See `decode!/2` for a version that raises on error.
  """
  @spec decode(iodata(), [decode_opt()]) :: {:ok, term()} | {:error, RustyJson.DecodeError.t()}
  def decode(input, opts \\ []) do
    {:ok, decode!(input, opts)}
  rescue
    e in [RustyJson.DecodeError] -> {:error, e}
    e in [ArgumentError] -> {:error, %RustyJson.DecodeError{message: Exception.message(e)}}
    e in [ErlangError] -> {:error, %RustyJson.DecodeError{message: error_message(e)}}
  end

  @doc """
  Decodes a JSON string to an Elixir term, raising on error.

  Same as `decode/2` but raises `RustyJson.DecodeError` on failure.
  The raised exception includes `:data`, `:position`, and `:token` fields
  for detailed error diagnostics.

  ## Options

  See `decode/2` for available options.

  ## Examples

      iex> RustyJson.decode!(~s({"x": [1, 2, 3]}))
      %{"x" => [1, 2, 3]}

      iex> RustyJson.decode!(~s({"x": 1}), keys: :atoms)
      %{x: 1}

      iex> RustyJson.decode!(~s({"x": 1}), keys: &String.upcase/1)
      %{"X" => 1}

      iex> RustyJson.decode!("null")
      nil

      iex> RustyJson.decode!("true")
      true

      iex> RustyJson.decode!(~s({"price":19.99}), floats: :decimals)
      %{"price" => Decimal.new("19.99")}

  ## JSON Types to Elixir

  | JSON | Elixir |
  |------|--------|
  | object | map (or `RustyJson.OrderedObject` with `objects: :ordered_objects`) |
  | array | list |
  | string | binary |
  | number (int) | integer |
  | number (float) | float (or `Decimal` with `floats: :decimals`) |
  | true | `true` |
  | false | `false` |
  | null | `nil` |

  ## Error Cases

      iex> RustyJson.decode!("invalid")
      ** (RustyJson.DecodeError) Unexpected character at position 0

      iex> RustyJson.decode!("{trailing: comma,}")
      ** (RustyJson.DecodeError) Expected string key at position 1

  """
  @spec decode!(iodata(), [decode_opt()]) :: term()
  def decode!(input, opts \\ []) do
    {keys, nif_opts, validated_opts} = parse_decode_opts(opts)
    input_binary = IO.iodata_to_binary(input)

    result = nif_decode_with_error_handling(input_binary, nif_opts)
    maybe_transform_keys(result, keys, validated_opts)
  end

  # ============================================================================
  # Phoenix Interface
  # ============================================================================

  @doc """
  Encodes a term to iodata (for Phoenix compatibility).

  This function exists to implement the Phoenix JSON library interface.
  Returns `{:ok, binary}` on success or `{:error, reason}` on failure.

  ## A Note on iodata

  RustyJson returns a **single binary**, not an iolist. This is intentional
  and provides excellent performance for payloads up to ~100MB.

  The memory efficiency comes from the encoding process (no intermediate
  allocations), not from chunked output. A 10MB payload uses ~15MB peak memory.

  For truly massive payloads (100MB+), consider:
  - Streaming the data structure itself (encode in chunks)
  - Using compression (`compress: :gzip` reduces output 5-10x)
  - Pagination or chunked API design

  ## Examples

      iex> RustyJson.encode_to_iodata(%{status: "ok"})
      {:ok, ~s({"status":"ok"})}

  """
  @spec encode_to_iodata(term(), [encode_opt()]) ::
          {:ok, iodata()} | {:error, RustyJson.EncodeError.t() | Exception.t()}
  def encode_to_iodata(input, opts \\ []), do: encode(input, opts)

  @doc """
  Encodes a term to iodata, raising on error (for Phoenix compatibility).

  This function exists to implement the Phoenix JSON library interface.
  Raises `RustyJson.EncodeError` on failure.

  See `encode_to_iodata/2` for notes on iodata behavior.

  ## Examples

      iex> RustyJson.encode_to_iodata!(%{status: "ok"})
      ~s({"status":"ok"})

  """
  @spec encode_to_iodata!(term(), [encode_opt()]) :: iodata()
  def encode_to_iodata!(input, opts \\ []), do: encode!(input, opts)

  # ============================================================================
  # Private Functions
  # ============================================================================

  @doc false
  defp normalize_pretty_opts(indent) when is_list(indent) do
    # Pretty print with custom separator options
    raw_indent = Keyword.get(indent, :indent, 2)

    pretty_opts = %{}

    pretty_opts =
      case Keyword.fetch(indent, :line_separator) do
        {:ok, sep} -> Map.put(pretty_opts, :line_separator, IO.iodata_to_binary(sep))
        :error -> pretty_opts
      end

    pretty_opts =
      case Keyword.fetch(indent, :after_colon) do
        {:ok, sep} -> Map.put(pretty_opts, :after_colon, IO.iodata_to_binary(sep))
        :error -> pretty_opts
      end

    # Handle iodata indent (e.g. "\t") — pass as binary in pretty_opts
    {pretty_opts, indent_val} = normalize_indent_value(raw_indent, pretty_opts)

    {if(map_size(pretty_opts) > 0, do: pretty_opts, else: nil), indent_val}
  end

  defp normalize_pretty_opts(indent) do
    {pretty_opts, indent_val} = normalize_indent_value(indent, %{})
    {if(map_size(pretty_opts) > 0, do: pretty_opts, else: nil), indent_val}
  end

  # Convert indent value to {pretty_opts_map, integer_indent_for_nif}
  # For string/iodata indent, we pass the binary through pretty_opts and use
  # indent=1 as a sentinel to enable pretty mode in the NIF.
  @doc false
  defp normalize_indent_value(indent, pretty_opts) do
    cond do
      indent == true ->
        {pretty_opts, 2}

      is_integer(indent) and indent > 0 ->
        {pretty_opts, indent}

      is_binary(indent) ->
        {Map.put(pretty_opts, :indent, indent), 1}

      is_list(indent) ->
        # iodata list
        {Map.put(pretty_opts, :indent, IO.iodata_to_binary(indent)), 1}

      true ->
        {pretty_opts, nil}
    end
  end

  @doc false
  defp extract_token(data, position) when is_binary(data) and is_integer(position) do
    if position >= 0 and position < byte_size(data) do
      # Extract a short token around the error position
      len = min(byte_size(data) - position, 10)
      binary_part(data, position, len)
    else
      nil
    end
  end

  defp extract_token(_, _), do: nil

  @doc false
  defp validate_escape!(:json), do: :json
  defp validate_escape!(:html_safe), do: :html_safe
  defp validate_escape!(:unicode_safe), do: :unicode_safe
  defp validate_escape!(:javascript_safe), do: :javascript_safe
  defp validate_escape!(nil), do: :json

  defp validate_escape!(other) do
    raise ArgumentError,
          "invalid :escape option #{inspect(other)}, expected one of: :json, :html_safe, :javascript_safe, :unicode_safe"
  end

  @doc false
  defp validate_compression!(nil), do: {:none, nil}
  defp validate_compression!(false), do: {:none, nil}
  defp validate_compression!(:none), do: {:none, nil}
  defp validate_compression!(:gzip), do: {:gzip, nil}

  defp validate_compression!({:gzip, level}) when is_integer(level) and level in 0..9 do
    {:gzip, level}
  end

  defp validate_compression!({:gzip, level}) when is_integer(level) do
    raise ArgumentError, "invalid gzip compression level #{level}, expected 0-9"
  end

  defp validate_compression!(other) do
    raise ArgumentError,
          "invalid :compress option #{inspect(other)}, expected :gzip, {:gzip, 0..9}, or :none"
  end

  @doc false
  defp validate_keys!(keys) when keys in [:strings, :atoms, :atoms!, :copy, :intern], do: :ok
  defp validate_keys!(keys) when is_function(keys, 1), do: :ok

  defp validate_keys!(other) do
    raise ArgumentError,
          "invalid :keys option #{inspect(other)}, expected one of: :strings, :atoms, :atoms!, :copy, :intern, or a function/1"
  end

  # Raises an EncodeError from a NIF ErlangError.
  # Extracted to avoid `raise` inside `rescue` (Credo W: reraise).
  @spec raise_encode_error(Exception.t()) :: no_return()
  defp raise_encode_error(e) do
    raise %RustyJson.EncodeError{message: error_message(e)}
  end

  # Parse and validate all decode options, returning {keys, nif_opts, validated_opts}.
  defp parse_decode_opts(opts) do
    {keys, opts} = Keyword.pop(opts, :keys, :strings)
    {strings_mode, opts} = Keyword.pop(opts, :strings, :reference)
    {objects_mode, opts} = Keyword.pop(opts, :objects, :maps)
    {floats_mode, opts} = Keyword.pop(opts, :floats, :native)

    {digit_limit, _opts} =
      Keyword.pop(opts, :decoding_integer_digit_limit, @default_integer_digit_limit)

    validate_keys!(keys)
    validate_option!(strings_mode, [:copy, :reference], :strings)
    validate_option!(objects_mode, [:maps, :ordered_objects], :objects)
    validate_option!(floats_mode, [:native, :decimals], :floats)

    {intern_keys, keys_fn} =
      case keys do
        :intern -> {true, nil}
        f when is_function(f, 1) -> {false, f}
        _ -> {false, nil}
      end

    nif_opts = %{
      intern_keys: intern_keys,
      floats_decimals: floats_mode == :decimals,
      ordered_objects: objects_mode == :ordered_objects,
      integer_digit_limit: digit_limit
    }

    {keys, nif_opts, %{keys_fn: keys_fn}}
  end

  # Call the NIF decoder, converting ErlangError to DecodeError.
  # Extracted to avoid `raise` inside `rescue` (Credo W: reraise).
  defp nif_decode_with_error_handling(input_binary, nif_opts) do
    nif_decode(input_binary, nif_opts)
  rescue
    e in [ErlangError] ->
      raise_decode_error(e, input_binary)
  end

  @spec raise_decode_error(Exception.t(), binary()) :: no_return()
  defp raise_decode_error(
         %ErlangError{original: {msg, pos}},
         input_binary
       )
       when is_binary(msg) and is_integer(pos) do
    raise %RustyJson.DecodeError{
      message: "#{msg} at position #{pos}",
      data: input_binary,
      position: pos,
      token: extract_token(input_binary, pos)
    }
  end

  defp raise_decode_error(e, _input_binary) do
    raise e
  end

  # Apply key transformations to decoded result.
  defp maybe_transform_keys(result, keys, %{keys_fn: keys_fn}) do
    cond do
      keys_fn != nil -> transform_keys(result, keys_fn)
      keys in [:atoms, :atoms!] -> transform_keys(result, keys)
      true -> result
    end
  end

  # Resolve function-based Fragment encode fields to iodata before sending to NIF.
  # This handles both protocol: true (where the Fragment encoder may have already
  # resolved it) and protocol: false (where function fragments would crash the NIF).
  defp resolve_fragment_functions(%RustyJson.Fragment{encode: encode} = frag, opts)
       when is_function(encode, 1) do
    %{frag | encode: encode.(opts)}
  end

  defp resolve_fragment_functions(value, _opts), do: value

  @doc false
  defp validate_option!(value, valid_values, option_name) do
    unless value in valid_values do
      valid_str = valid_values |> Enum.map_join(", ", &inspect/1)

      raise ArgumentError,
            "invalid :#{option_name} option #{inspect(value)}, expected #{valid_str}"
    end
  end

  @doc false
  # Handle OrderedObject: transform keys within the values list, preserving order
  defp transform_keys(%RustyJson.OrderedObject{values: values} = obj, keys_mode) do
    transformed =
      Enum.map(values, fn {k, v} ->
        new_key =
          cond do
            is_function(keys_mode, 1) and is_binary(k) -> keys_mode.(k)
            is_function(keys_mode, 1) -> k
            true -> string_to_atom(k, keys_mode)
          end

        {new_key, transform_keys(v, keys_mode)}
      end)

    %{obj | values: transformed}
  end

  defp transform_keys(value, fun) when is_map(value) and is_function(fun, 1) do
    Map.new(value, fn {k, v} ->
      {if(is_binary(k), do: fun.(k), else: k), transform_keys(v, fun)}
    end)
  end

  defp transform_keys(value, keys_mode) when is_map(value) do
    Map.new(value, fn {k, v} ->
      {string_to_atom(k, keys_mode), transform_keys(v, keys_mode)}
    end)
  end

  defp transform_keys(value, keys_mode) when is_list(value) do
    Enum.map(value, &transform_keys(&1, keys_mode))
  end

  defp transform_keys(value, _keys_mode), do: value

  @doc false
  defp string_to_atom(key, :atoms) when is_binary(key) do
    String.to_atom(key)
  end

  defp string_to_atom(key, :atoms!) when is_binary(key) do
    String.to_existing_atom(key)
  end

  defp string_to_atom(key, _), do: key

  @doc false
  defp error_message(%ErlangError{original: {msg, pos}})
       when is_binary(msg) and is_integer(pos) do
    "#{msg} at position #{pos}"
  end

  defp error_message(%ErlangError{original: err}), do: error_message(err)
  defp error_message(%{message: message}), do: message
  defp error_message(err) when is_exception(err), do: Exception.message(err)
  defp error_message(err) when is_binary(err), do: err
  defp error_message(err), do: inspect(err)
end
