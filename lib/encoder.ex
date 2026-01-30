defprotocol RustyJson.Encoder do
  @moduledoc """
  Protocol controlling how a value is encoded to JSON.

  ## Deriving

  The protocol allows leveraging the Elixir's `@derive` feature
  to simplify protocol implementation in trivial cases. Accepted
  options are:

    * `:only` - encodes only values of specified keys.
    * `:except` - encodes all struct fields except specified keys.

  By default all keys except the `:__struct__` key are encoded.

  ## Example

  Let's assume a struct that represents a person:

      defmodule Person do
        @derive {RustyJson.Encoder, only: [:name, :age]}
        defstruct [:name, :age, :private_data]
      end

  The `@derive` generates an optimized implementation that pattern-matches
  struct fields and uses one of two fast paths:

  - **Small structs**: builds JSON iodata with compile-time collapsed keys
    (no runtime `Map.from_struct`, `Map.to_list`, or key escaping).
  - **Larger structs**: delegates to a NIF-accelerated path using pre-escaped
    keys, with an automatic fallback to the same iodata path when the NIF
    would not be beneficial.

  ## Explicit Implementation

  If you need full control, implement the protocol directly.
  Implementations should return iodata (matching Jason's contract)
  by calling `RustyJson.Encode` functions:

      defimpl RustyJson.Encoder, for: Money do
        def encode(%Money{amount: amount, currency: currency}, opts) do
          RustyJson.Encode.map(%{amount: amount, currency: to_string(currency)}, opts)
        end
      end

  For backwards compatibility, returning a plain map is also supported
  and will be re-encoded automatically:

      defimpl RustyJson.Encoder, for: Money do
        def encode(%Money{amount: amount, currency: currency}, _opts) do
          %{amount: amount, currency: to_string(currency)}
        end
      end

  ## Return Value Contract

  Implementations must return one of:

    * **iodata** (preferred) — built via `RustyJson.Encode` functions
      (`Encode.map/2`, `Encode.list/2`, `Encode.value/2`, etc.).
      This is the most efficient path and matches Jason's contract.
    * **a plain map** — re-encoded automatically as a JSON object.
      Supported for backwards compatibility with a small overhead.

  **Do not** return bare Elixir terms (atoms, integers, plain lists,
  `nil`, unquoted strings) from `encode/2`. These are not valid iodata
  and will produce silently invalid JSON or raise `ArgumentError`
  downstream.

  This is an intentional design choice shared with Jason: the protocol
  is a low-level iodata contract that does not validate return values.
  Validating every return would require runtime type inspection on every
  value in the tree — for a large payload with millions of values, that
  overhead is measurable. Instead, the contract trusts implementations
  to return valid iodata (which `@derive` guarantees automatically) and
  passes results through with zero checking. Correct implementations
  get maximum performance; incorrect implementations get silent
  corruption rather than a helpful error.

  Use `RustyJson.Encode` functions to produce correctly formatted JSON:

      # WRONG: bare string — produces unquoted JSON
      def encode(%Name{value: v}, _opts), do: v

      # RIGHT: properly quoted JSON string
      def encode(%Name{value: v}, opts), do: RustyJson.Encode.string(v, opts)

      # WRONG: plain list — treated as iodata bytes, not a JSON array
      def encode(%Ids{list: l}, _opts), do: l

      # RIGHT: JSON array
      def encode(%Ids{list: l}, opts), do: RustyJson.Encode.list(l, opts)

  ## Fallback Behavior

  Structs without an explicit `RustyJson.Encoder` implementation raise
  `Protocol.UndefinedError`. Custom types must explicitly opt in to encoding
  via `@derive RustyJson.Encoder` or `defimpl RustyJson.Encoder`.
  """

  @fallback_to_any true

  @typedoc """
  Encoder options passed from `RustyJson.encode!/2`.

  This is an opaque value matching `RustyJson.Encode.opts()`. Pass it as-is to
  `RustyJson.Encode` functions (`value/2`, `map/2`, `string/2`, etc.) inside
  custom encoder implementations. Do not inspect or destructure this value.
  """
  @type opts :: RustyJson.Encode.opts()

  @doc """
  Encodes `value` to JSON iodata or a plain map.

  Derived implementations return iodata directly (pre-serialized JSON).
  Custom implementations may return either iodata (preferred, via
  `RustyJson.Encode` functions) or a plain map which will be
  re-encoded automatically.

  Other return types (nil, atoms, bare strings, plain lists) are not
  supported and will produce invalid JSON or raise. See the "Return
  Value Contract" section in the moduledoc.

  The `opts` parameter carries encoding context (`:escape`, `:maps`) from
  `RustyJson.encode!/2`. Pass it to `RustyJson.Encode` functions as-is.
  """
  @spec encode(t, opts()) :: iodata() | term
  def encode(value, opts)
end

# Shared needs_encoding check logic injected into Map and List impls at
# compile time via __using__. This keeps the functions as local defp calls
# (direct jumps) while maintaining a single source of truth.
#
# Recursion characteristics: these functions are tail-recursive when
# iterating siblings (map entries, list elements) but use body recursion
# when descending into nested maps/lists (the `or` operator requires a
# stack frame for the left branch). This means nesting depth is bounded
# by the BEAM process stack. In practice this is not a concern: the Rust
# NIF enforces a 128-level nesting depth limit, and the BEAM default
# stack accommodates thousands of frames. Deeply nested data that could
# exhaust the stack here would also exhaust the Encode.value/list/map
# recursion and the NIF's nesting limit.
defmodule RustyJson.Encoder.NeedsEncoding do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      defp needs_encoding_iter?(:none), do: false
      defp needs_encoding_iter?({_k, %{__struct__: _}, _next}), do: true
      defp needs_encoding_iter?({_k, v, _next}) when is_tuple(v), do: true

      defp needs_encoding_iter?({_k, v, next}) when is_map(v) do
        needs_encoding_iter?(:maps.next(:maps.iterator(v))) or
          needs_encoding_iter?(:maps.next(next))
      end

      defp needs_encoding_iter?({_k, v, next}) when is_list(v) do
        needs_encoding_list?(v) or needs_encoding_iter?(:maps.next(next))
      end

      defp needs_encoding_iter?({_k, _v, next}), do: needs_encoding_iter?(:maps.next(next))

      defp needs_encoding_list?([]), do: false
      defp needs_encoding_list?([%{__struct__: _} | _]), do: true
      defp needs_encoding_list?([v | _]) when is_tuple(v), do: true

      defp needs_encoding_list?([v | rest]) when is_map(v) do
        needs_encoding_iter?(:maps.next(:maps.iterator(v))) or needs_encoding_list?(rest)
      end

      defp needs_encoding_list?([v | rest]) when is_list(v) do
        needs_encoding_list?(v) or needs_encoding_list?(rest)
      end

      defp needs_encoding_list?([_ | rest]), do: needs_encoding_list?(rest)
    end
  end
end

# For maps and lists, check if values contain structs or tuples that need
# protocol encoding. If so, produce a Fragment wrapping iodata from
# Encode.map/list (single-pass serialization). Otherwise, return the
# original term for the Rust NIF to handle natively.
defimpl RustyJson.Encoder, for: Map do
  use RustyJson.Encoder.NeedsEncoding

  def encode(map, opts) do
    if needs_encoding_iter?(:maps.next(:maps.iterator(map))) do
      %RustyJson.Fragment{encode: RustyJson.Encode.map(map, opts)}
    else
      map
    end
  end
end

defimpl RustyJson.Encoder, for: List do
  use RustyJson.Encoder.NeedsEncoding

  def encode([], _opts), do: []

  def encode(list, opts) do
    if needs_encoding_list?(list) do
      %RustyJson.Fragment{encode: RustyJson.Encode.list(list, opts)}
    else
      list
    end
  end
end

defimpl RustyJson.Encoder, for: Tuple do
  def encode(tuple, opts) do
    tuple |> Tuple.to_list() |> RustyJson.Encoder.encode(opts)
  end
end

# Primitive types pass through unchanged - Rust handles them natively.
defimpl RustyJson.Encoder, for: [BitString, Integer, Float, Atom] do
  def encode(value, _opts), do: value
end

# Built-in types are passed through to Rust which handles them natively.
# This avoids double-processing while maintaining protocol compatibility.
defimpl RustyJson.Encoder, for: [Date, Time, NaiveDateTime, DateTime] do
  def encode(value, _opts), do: value
end

defimpl RustyJson.Encoder, for: URI do
  def encode(uri, _opts), do: uri
end

if Code.ensure_loaded?(Decimal) do
  defimpl RustyJson.Encoder, for: Decimal do
    def encode(decimal, _opts), do: decimal
  end
end

# Helper module for NIF-accelerated derived struct encoding.
# Centralises all NIF-path logic so the generated defimpl stays minimal.
defmodule RustyJson.Encoder.DerivedNIF do
  @moduledoc false

  use RustyJson.Encoder.NeedsEncoding

  @typep pre_encoded :: {:__pre_encoded__, binary()}
  @typep nif_value :: binary() | integer() | boolean() | nil | pre_encoded()

  # -------------------------------------------------------------------
  # Public API called by generated encode/2
  # -------------------------------------------------------------------

  @doc false
  @spec encode([binary()], non_neg_integer(), list(term()), RustyJson.Encode.opts()) ::
          iodata() | RustyJson.Fragment.t()
  def encode(nif_keys, field_count, values, {escape, encode_map} = opts) do
    case Process.get(:rustyjson_encode_fields_ctx) do
      {escape_mode, strict_keys} when is_atom(escape_mode) ->
        if should_use_nif?(field_count, values) do
          nif_path(nif_keys, values, escape_mode, strict_keys, opts)
        else
          fallback_iodata(nif_keys, values, escape, encode_map)
        end

      _ ->
        # Direct protocol call outside encode! — no context available
        fallback_iodata(nif_keys, values, escape, encode_map)
    end
  end

  # -------------------------------------------------------------------
  # Size gate
  # -------------------------------------------------------------------

  @doc false
  @spec should_use_nif?(non_neg_integer(), list(term())) :: boolean()
  def should_use_nif?(field_count, values) when field_count >= 5 do
    {binary_count, binary_bytes} = count_binary_weight(values, 0, 0)
    binary_count >= 1 or binary_bytes >= 32
  end

  def should_use_nif?(_field_count, _values), do: false

  defp count_binary_weight([], count, bytes), do: {count, bytes}

  defp count_binary_weight([v | rest], count, bytes) when is_binary(v) do
    count_binary_weight(rest, count + 1, bytes + byte_size(v))
  end

  defp count_binary_weight([_ | rest], count, bytes) do
    count_binary_weight(rest, count, bytes)
  end

  # -------------------------------------------------------------------
  # NIF path — classify values, call Rust NIF
  # -------------------------------------------------------------------

  defp nif_path(nif_keys, values, escape_mode, strict_keys, opts) do
    nif_values = Enum.map(values, &nif_field(&1, escape_mode, opts))
    result = RustyJson.nif_encode_fields(nif_keys, nif_values, escape_mode, strict_keys)
    # Wrap in Fragment so encode! fast-path can bypass NIF re-encoding
    %RustyJson.Fragment{encode: result}
  end

  @doc false
  @spec nif_field(term(), RustyJson.escape_mode(), RustyJson.Encode.opts()) :: nif_value()
  def nif_field(value, _escape_mode, _opts) when is_binary(value), do: value
  def nif_field(value, _escape_mode, _opts) when is_integer(value), do: value
  def nif_field(nil, _escape_mode, _opts), do: nil
  def nif_field(true, _escape_mode, _opts), do: true
  def nif_field(false, _escape_mode, _opts), do: false

  # Everything else (floats, non-boolean atoms, structs, tuples, maps, lists) → pre-encode.
  # Maps and lists could theoretically be passed raw when they contain only safe primitives,
  # but the NIF contract is strict (only primitives + pre-encoded), so we pre-encode them.
  def nif_field(value, _escape_mode, opts) do
    pre_encode(value, opts)
  end

  @spec pre_encode(term(), RustyJson.Encode.opts()) :: pre_encoded()
  defp pre_encode(value, opts) do
    encoded = IO.iodata_to_binary(RustyJson.Encode.value(value, opts))
    {:__pre_encoded__, encoded}
  end

  # -------------------------------------------------------------------
  # Fallback iodata path (existing Encode.value + build_kv_iodata)
  # -------------------------------------------------------------------

  @doc false
  @spec fallback_iodata([binary()], list(term()), term(), term()) :: iodata()
  def fallback_iodata(nif_keys, values, escape, encode_map) do
    build_kv_iodata(nif_keys, values, escape, encode_map)
  end

  defp build_kv_iodata(keys, values, escape, encode_map) do
    [?{ | kv_loop(keys, values, true, escape, encode_map)]
  end

  defp kv_loop([], [], _first, _escape, _encode_map), do: ~c'}'

  defp kv_loop([key | keys], [val | vals], first, escape, encode_map) do
    prefix = if first, do: key, else: [?,, key]

    [
      prefix,
      RustyJson.Encode.value(val, escape, encode_map)
      | kv_loop(keys, vals, false, escape, encode_map)
    ]
  end
end

defimpl RustyJson.Encoder, for: Any do
  @moduledoc false
  @dialyzer {:nowarn_function, encode: 2}

  # Compile-time codegen for @derive RustyJson.Encoder.
  #
  # Two code shapes depending on field count:
  #
  # < 5 fields: inline iodata with compile-time collapsed static segments.
  #   Zero overhead — identical to the original codegen. No Process.get,
  #   no function-call indirection.
  #
  # >= 5 fields: delegates to DerivedNIF.encode/4 which decides at runtime
  #   whether to use the Rust NIF path (when binary-heavy) or the fallback
  #   iodata path. Pre-escaped "\"key\":" binaries are stored in @nif_keys.
  defmacro __deriving__(module, struct, opts) do
    fields = fields_to_encode(struct, opts)
    field_count = length(fields)
    kv = Enum.map(fields, &{&1, Macro.var(&1, __MODULE__)})

    if field_count >= 5 do
      # NIF-eligible path: delegate to DerivedNIF
      nif_keys =
        Enum.map(fields, fn field ->
          key_str = IO.iodata_to_binary(RustyJson.Encode.key(field, &escape_key/3))
          "\"" <> key_str <> "\":"
        end)

      values_ast = Enum.map(fields, &Macro.var(&1, __MODULE__))

      quote do
        defimpl RustyJson.Encoder, for: unquote(module) do
          @nif_keys unquote(nif_keys)
          @field_count unquote(field_count)

          def encode(%{unquote_splicing(kv)}, opts) do
            RustyJson.Encoder.DerivedNIF.encode(
              @nif_keys,
              @field_count,
              unquote(values_ast),
              opts
            )
          end
        end
      end
    else
      # Small struct: inline iodata with compile-time collapsed keys.
      # No DerivedNIF overhead — same codegen as before the NIF feature.
      escape = quote(do: escape)
      encode_map = quote(do: encode_map)
      kv_iodata = build_kv_iodata(kv, [escape, encode_map])

      quote do
        defimpl RustyJson.Encoder, for: unquote(module) do
          def encode(%{unquote_splicing(kv)}, {unquote(escape), unquote(encode_map)}) do
            unquote(kv_iodata)
          end
        end
      end
    end
  end

  defp fields_to_encode(struct, opts) do
    fields = Map.keys(struct) -- [:__struct__]

    case {Keyword.get(opts, :only), Keyword.get(opts, :except)} do
      {nil, nil} -> fields
      {only, nil} -> only
      {nil, except} -> fields -- except
    end
  end

  defp escape_key(binary, _original, _skip) do
    check_safe_key!(binary)
    binary
  end

  defp check_safe_key!(binary) do
    for <<byte <- binary>> do
      if byte > 0x7F or byte < 0x1F or byte in ~c'"\\/' do
        raise RustyJson.EncodeError,
              "invalid byte #{inspect(byte, base: :hex)} in literal key: #{inspect(binary)}"
      end
    end

    :ok
  end

  # --- Inline iodata helpers (used for < 5 field structs) ---

  defp build_kv_iodata(kv, encode_args) do
    elements =
      kv
      |> Enum.map(&encode_pair(&1, encode_args))
      |> Enum.intersperse(",")

    collapse_static(List.flatten(["{", elements] ++ ~c'}'))
  end

  defp encode_pair({key, value}, encode_args) do
    key = IO.iodata_to_binary(RustyJson.Encode.key(key, &escape_key/3))
    key = "\"" <> key <> "\":"
    [key, quote(do: RustyJson.Encode.value(unquote(value), unquote_splicing(encode_args)))]
  end

  defp collapse_static([bin1, bin2 | rest]) when is_binary(bin1) and is_binary(bin2) do
    collapse_static([bin1 <> bin2 | rest])
  end

  defp collapse_static([other | rest]), do: [other | collapse_static(rest)]
  defp collapse_static([]), do: []

  def encode(value, _opts) do
    raise Protocol.UndefinedError,
      protocol: @protocol,
      value: value,
      description: """
      RustyJson.Encoder protocol must always be explicitly implemented.

      If you own the struct, you can derive the implementation specifying
      which fields should be encoded to JSON:

          @derive {RustyJson.Encoder, only: [..]}
          defstruct ...

      It is also possible to encode all fields, although this should
      be used carefully to avoid accidentally leaking private information
      when new fields are added:

          @derive RustyJson.Encoder
          defstruct ...

      Finally, if you don't own the struct you want to encode to JSON,
      you may use Protocol.derive/3 placed outside of any module:

          Protocol.derive(RustyJson.Encoder, NameOfTheStruct, only: [..])
          Protocol.derive(RustyJson.Encoder, NameOfTheStruct)
      """
  end
end
