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
  | `RustyJson.Fragment` | Pre-encoded JSON injection |
  | `RustyJson.Formatter` | JSON pretty-printing utilities |
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
  | `MapSet` | array | `MapSet.new([1, 2])` → `[1,2]` |
  | `Range` | object | `1..10` → `{"first":1,"last":10,"step":1}` |
  | structs | object | `%User{name: "Alice"}` → `{"name":"Alice"}` |

  ## Escape Modes

  RustyJson supports multiple escape modes for different security contexts:

  | Mode | Description | Use Case |
  |------|-------------|----------|
  | `:json` | Standard JSON escaping (default) | General use |
  | `:html_safe` | Escapes `<`, `>`, `&` as `\\uXXXX` | HTML embedding |
  | `:javascript_safe` | Escapes line/paragraph separators | JavaScript strings |
  | `:unicode_safe` | Escapes all non-ASCII as `\\uXXXX` | ASCII-only output |

  ## Performance Tips

  1. **Skip the protocol** (default): For maximum speed, don't use `protocol: true`
     unless you have custom `RustyJson.Encoder` implementations.

  2. **Use lean mode**: If you don't have DateTime/Decimal types, use `lean: true`
     to skip struct type detection in Rust.

  3. **Use compression**: For large payloads over the network, `compress: :gzip`
     reduces output size 5-10x.

  4. **Avoid atom keys in decode**: Using `keys: :atoms!` creates atoms from
     untrusted input, which can exhaust the atom table.

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
  - `:atoms` - Convert to atoms only if they already exist (safe)
  - `:atoms!` - Always convert to atoms, creating new ones (unsafe with untrusted input)
  - `:intern` - Cache repeated keys during parsing (~30% faster for arrays of objects)
  """
  @type keys :: :strings | :atoms | :atoms! | :intern

  @typedoc """
  Escape mode for JSON string encoding.

  - `:json` - Standard JSON escaping (default)
  - `:html_safe` - Also escape `<`, `>`, `&` for safe HTML embedding
  - `:javascript_safe` - Also escape line/paragraph separators (U+2028, U+2029)
  - `:unicode_safe` - Escape all non-ASCII characters as `\\uXXXX`
  """
  @type escape_mode :: :json | :html_safe | :javascript_safe | :unicode_safe

  @typedoc """
  Options for `encode/2` and `encode!/2`.

  - `:pretty` - Pretty print with indentation. `true` for 2 spaces, or an integer for custom.
  - `:escape` - Escape mode (see `t:escape_mode/0`). Default: `:json`
  - `:compress` - Compression (see `t:compression_option/0`). Default: `:none`
  - `:protocol` - Use `RustyJson.Encoder` protocol. Default: `false`
  - `:lean` - Skip special struct handling. Default: `false`
  """
  @type encode_opt ::
          {:pretty, boolean() | pos_integer()}
          | {:escape, escape_mode()}
          | {:compress, compression_option()}
          | {:protocol, boolean()}
          | {:lean, boolean()}

  @typedoc """
  Options for `decode/2` and `decode!/2`.

  - `:keys` - How to handle object keys (see `t:keys/0`). Default: `:strings`
  """
  @type decode_opt :: {:keys, keys()}

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
  @spec nif_encode_direct(
          term(),
          non_neg_integer() | nil,
          compression_options(),
          boolean(),
          atom() | nil
        ) :: String.t()
  defp nif_encode_direct(_input, _indent, _compression, _lean, _escape),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec nif_decode(String.t(), boolean()) :: term()
  defp nif_decode(_input, _intern_keys), do: :erlang.nif_error(:nif_not_loaded)

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

  * `:protocol` - Enable `RustyJson.Encoder` protocol for custom types. Default: `false`

  * `:lean` - Skip struct type detection (DateTime, Decimal, etc. encoded as raw
    maps). Default: `false`

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
  @spec encode(term(), [encode_opt()]) :: {:ok, String.t()} | {:error, String.t()}
  def encode(input, opts \\ []) do
    {:ok, encode!(input, opts)}
  rescue
    e in [RustyJson.EncodeError, ErlangError, ArgumentError] ->
      {:error, error_message(e)}
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

  For custom types, implement `RustyJson.Encoder` and use `protocol: true`:

      defmodule Money do
        defstruct [:amount, :currency]
      end

      defimpl RustyJson.Encoder, for: Money do
        def encode(%Money{amount: amount, currency: currency}) do
          %{amount: Decimal.to_string(amount), currency: currency}
        end
      end

      iex> money = %Money{amount: Decimal.new("99.99"), currency: "USD"}
      iex> RustyJson.encode!(money, protocol: true)
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
    {use_protocol, opts} = Keyword.pop(opts, :protocol, false)
    {lean, _opts} = Keyword.pop(opts, :lean, false)

    indent = normalize_indent(indent)
    escape = validate_escape!(escape)
    compression = validate_compression!(compression)

    # With protocol: true, preprocess with Elixir Encoder protocol
    # Otherwise, send directly to Rust for maximum performance
    processed = if use_protocol, do: RustyJson.Encoder.encode(input), else: input

    nif_encode_direct(processed, indent, compression, lean == true, escape)
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
    * `:atoms` - Convert to existing atoms only (safe)
    * `:atoms!` - Convert to atoms, creating new ones (unsafe with untrusted input)
    * `:intern` - Cache repeated keys during parsing. **~30% faster** for arrays of
      objects with the same schema (REST APIs, GraphQL, database results, webhooks).
      **Caution**: 2-3x slower for single objects or varied schemas—only use for
      homogeneous arrays of 10+ objects.

  ## Examples

      iex> RustyJson.decode(~s({"name":"Alice","age":30}))
      {:ok, %{"age" => 30, "name" => "Alice"}}

      iex> RustyJson.decode(~s([1, 2, 3]))
      {:ok, [1, 2, 3]}

      iex> RustyJson.decode("invalid")
      {:error, "expected value at position 0"}

  ## Security Considerations

  **Avoid `keys: :atoms!` with untrusted input.** Atoms are not garbage collected,
  so an attacker could exhaust your atom table by sending JSON with many unique keys.

  Use `keys: :atoms` instead, which only converts keys that already exist as atoms.

  See `decode!/2` for a version that raises on error.
  """
  @spec decode(iodata(), [decode_opt()]) :: {:ok, term()} | {:error, String.t()}
  def decode(input, opts \\ []) do
    {:ok, decode!(input, opts)}
  rescue
    e in [RustyJson.DecodeError, ErlangError, ArgumentError] ->
      {:error, error_message(e)}
  end

  @doc """
  Decodes a JSON string to an Elixir term, raising on error.

  Same as `decode/2` but raises `RustyJson.DecodeError` on failure.

  ## Options

  See `decode/2` for available options.

  ## Examples

      iex> RustyJson.decode!(~s({"x": [1, 2, 3]}))
      %{"x" => [1, 2, 3]}

      iex> RustyJson.decode!(~s({"x": 1}), keys: :atoms)
      %{x: 1}

      iex> RustyJson.decode!("null")
      nil

      iex> RustyJson.decode!("true")
      true

  ## JSON Types to Elixir

  | JSON | Elixir |
  |------|--------|
  | object | map |
  | array | list |
  | string | binary |
  | number (int) | integer |
  | number (float) | float |
  | true | `true` |
  | false | `false` |
  | null | `nil` |

  ## Error Cases

      iex> RustyJson.decode!("invalid")
      ** (RustyJson.DecodeError) expected value at position 0

      iex> RustyJson.decode!("{trailing: comma,}")
      ** (RustyJson.DecodeError) expected string at position 1

  """
  @spec decode!(iodata(), [decode_opt()]) :: term()
  def decode!(input, opts \\ []) do
    {keys, _opts} = Keyword.pop(opts, :keys, :strings)
    validate_keys!(keys)

    result =
      input
      |> IO.iodata_to_binary()
      |> nif_decode(keys == :intern)

    case keys do
      :intern -> result
      :strings -> result
      atoms_mode -> transform_keys(result, atoms_mode)
    end
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
  @spec encode_to_iodata(term(), [encode_opt()]) :: {:ok, iodata()} | {:error, String.t()}
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
  defp normalize_indent(indent) do
    cond do
      indent == true -> 2
      is_integer(indent) and indent > 0 -> indent
      true -> nil
    end
  end

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
  defp validate_keys!(keys) when keys in [:strings, :atoms, :atoms!, :intern], do: :ok

  defp validate_keys!(other) do
    raise ArgumentError,
          "invalid :keys option #{inspect(other)}, expected one of: :strings, :atoms, :atoms!, :intern"
  end

  @doc false
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
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp string_to_atom(key, :atoms!) when is_binary(key) do
    String.to_atom(key)
  end

  defp string_to_atom(key, _), do: key

  @doc false
  defp error_message(%ErlangError{original: err}), do: error_message(err)
  defp error_message(%{message: message}), do: message
  defp error_message(err) when is_exception(err), do: Exception.message(err)
  defp error_message(err) when is_binary(err), do: err
  defp error_message(err), do: inspect(err)
end
