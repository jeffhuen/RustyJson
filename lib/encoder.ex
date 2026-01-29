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

  The `@derive` will generate an implementation like:

      defimpl RustyJson.Encoder, for: Person do
        def encode(value, _opts) do
          Map.take(value, [:name, :age])
        end
      end

  ## Explicit Implementation

  If you need full control, implement the protocol directly:

      defimpl RustyJson.Encoder, for: Money do
        def encode(%Money{amount: amount, currency: currency}, _opts) do
          %{amount: amount, currency: to_string(currency)}
        end
      end

  The returned value must be a JSON-encodable term (map, list, string,
  number, boolean, nil, or another struct implementing this protocol).

  ## Fallback Behavior

  Structs without an explicit `RustyJson.Encoder` implementation raise
  `Protocol.UndefinedError`. Custom types must explicitly opt in to encoding
  via `@derive RustyJson.Encoder` or `defimpl RustyJson.Encoder`.

  RustyJson has no runtime dependency on Jason. There is no fallback to
  `Jason.Encoder` — if you are migrating from Jason, update your structs to
  derive or implement `RustyJson.Encoder` directly.
  """

  @fallback_to_any true

  @typedoc """
  Encoder options passed from `RustyJson.encode!/2`.

  This is an opaque value matching `RustyJson.Encode.opts()`. Pass it as-is to
  `RustyJson.Encode` functions (`value/2`, `map/2`, `string/2`, etc.) inside
  custom encoder implementations. Do not inspect or destructure this value.

  Matches `Jason.Encoder.opts()` — custom encoder implementations that call
  `Jason.Encode.map(data, opts)` work identically with `RustyJson.Encode.map(data, opts)`.
  """
  @type opts :: RustyJson.Encode.opts()

  @doc """
  Converts `value` to a JSON-encodable type.

  The `opts` parameter carries encoding context (`:escape`, `:maps`) from
  `RustyJson.encode!/2`. Most implementations can ignore it. Implementations
  that produce function-based `%RustyJson.Fragment{}` values (like `OrderedObject`)
  use opts to propagate encoding settings to nested `encode!` calls.
  """
  @spec encode(t, opts()) :: term
  def encode(value, opts)
end

# For maps, lists, and tuples - only recurse if values might need encoding.
# Primitives (strings, numbers, atoms, booleans) pass through unchanged.
defimpl RustyJson.Encoder, for: Map do
  def encode(map, opts) do
    # Check if any value needs encoding (is a struct, map, list, or tuple)
    if Enum.any?(map, fn {_k, v} -> needs_encoding?(v) end) do
      :maps.map(fn _k, v -> RustyJson.Encoder.encode(v, opts) end, map)
    else
      map
    end
  end

  defp needs_encoding?(v) when is_map(v), do: true
  defp needs_encoding?(v) when is_list(v) and v != [], do: true
  defp needs_encoding?(v) when is_tuple(v), do: true
  defp needs_encoding?(_), do: false
end

defimpl RustyJson.Encoder, for: List do
  def encode([], _opts), do: []

  def encode(list, opts) do
    if Enum.any?(list, &needs_encoding?/1) do
      Enum.map(list, &RustyJson.Encoder.encode(&1, opts))
    else
      list
    end
  end

  defp needs_encoding?(v) when is_map(v), do: true
  defp needs_encoding?(v) when is_list(v) and v != [], do: true
  defp needs_encoding?(v) when is_tuple(v), do: true
  defp needs_encoding?(_), do: false
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

defimpl RustyJson.Encoder, for: Any do
  @moduledoc false

  defmacro __deriving__(module, _struct, opts) do
    only = Keyword.get(opts, :only)
    except = Keyword.get(opts, :except)

    case {only, except} do
      {fields, nil} when is_list(fields) ->
        quote do
          defimpl RustyJson.Encoder, for: unquote(module) do
            def encode(struct, opts) do
              Map.take(struct, unquote(fields))
              |> RustyJson.Encoder.encode(opts)
            end
          end
        end

      {nil, fields} when is_list(fields) ->
        excluded = [:__struct__ | fields]

        quote do
          defimpl RustyJson.Encoder, for: unquote(module) do
            def encode(struct, opts) do
              Map.drop(struct, unquote(excluded))
              |> RustyJson.Encoder.encode(opts)
            end
          end
        end

      {nil, nil} ->
        quote do
          defimpl RustyJson.Encoder, for: unquote(module) do
            def encode(struct, opts) do
              Map.from_struct(struct)
              |> RustyJson.Encoder.encode(opts)
            end
          end
        end
    end
  end

  def encode(%_{} = struct, _opts) do
    raise_undefined(struct)
  end

  def encode(value, _opts) do
    raise_undefined(value)
  end

  @spec raise_undefined(term()) :: no_return()
  defp raise_undefined(value) do
    raise Protocol.UndefinedError,
      protocol: @protocol,
      value: value,
      description:
        "RustyJson.Encoder protocol must always be explicitly implemented.\n\nIf you own the struct, you can derive the implementation specifying\nwhich fields should be encoded to JSON:\n\n    @derive {RustyJson.Encoder, only: [..]}\n    defstruct ...\n\nIt is also possible to encode all fields, although this should\nbe used carefully to avoid accidentally leaking private information\nwhen new fields are added:\n\n    @derive RustyJson.Encoder\n    defstruct ...\n\nFinally, if you don't own the struct you want to encode to JSON,\nyou may use Protocol.derive/3 placed outside of any module:\n\n    Protocol.derive(RustyJson.Encoder, NameOfTheStruct, only: [..])\n    Protocol.derive(RustyJson.Encoder, NameOfTheStruct)\n"
  end
end
