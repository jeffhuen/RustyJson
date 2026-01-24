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
        def encode(value) do
          Map.take(value, [:name, :age])
        end
      end

  ## Explicit Implementation

  If you need full control, implement the protocol directly:

      defimpl RustyJson.Encoder, for: Money do
        def encode(%Money{amount: amount, currency: currency}) do
          %{amount: amount, currency: to_string(currency)}
        end
      end

  The returned value must be a JSON-encodable term (map, list, string,
  number, boolean, nil, or another struct implementing this protocol).
  """

  @fallback_to_any true

  @doc """
  Converts `value` to a JSON-encodable type.
  """
  @spec encode(t) :: term
  def encode(value)
end

# For maps, lists, and tuples - only recurse if values might need encoding.
# Primitives (strings, numbers, atoms, booleans) pass through unchanged.
defimpl RustyJson.Encoder, for: Map do
  def encode(map) do
    # Check if any value needs encoding (is a struct, map, list, or tuple)
    if Enum.any?(map, fn {_k, v} -> needs_encoding?(v) end) do
      :maps.map(fn _k, v -> RustyJson.Encoder.encode(v) end, map)
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
  def encode([]), do: []

  def encode(list) do
    if Enum.any?(list, &needs_encoding?/1) do
      Enum.map(list, &RustyJson.Encoder.encode/1)
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
  def encode(tuple) do
    tuple |> Tuple.to_list() |> RustyJson.Encoder.encode()
  end
end

# Built-in types are passed through to Rust which handles them natively.
# This avoids double-processing while maintaining protocol compatibility.
defimpl RustyJson.Encoder, for: [Date, Time, NaiveDateTime, DateTime, MapSet, Range] do
  def encode(value), do: value
end

defimpl RustyJson.Encoder, for: URI do
  def encode(uri), do: uri
end

if Code.ensure_loaded?(Decimal) do
  defimpl RustyJson.Encoder, for: Decimal do
    def encode(decimal), do: decimal
  end
end

defimpl RustyJson.Encoder, for: Any do
  @moduledoc false

  # Delegate to RustyJson.Compat.Jason for Jason compatibility.
  # See that module for documentation on performance implications.
  alias RustyJson.Compat.Jason, as: JasonCompat

  defmacro __deriving__(module, _struct, opts) do
    fields = fields_to_encode(opts)

    quote do
      defimpl RustyJson.Encoder, for: unquote(module) do
        def encode(struct) do
          Map.take(struct, unquote(fields))
          |> RustyJson.Encoder.encode()
        end
      end
    end
  end

  defp fields_to_encode(opts) do
    cond do
      only = Keyword.get(opts, :only) ->
        only

      except = Keyword.get(opts, :except) ->
        quote do
          Map.keys(%unquote(opts[:struct]){}) -- [:__struct__ | unquote(except)]
        end

      true ->
        quote do
          Map.keys(%unquote(opts[:struct]){}) -- [:__struct__]
        end
    end
  end

  def encode(%{__struct__: Jason.Fragment} = fragment) do
    # Jason.Fragment compatibility - see RustyJson.Compat.Jason
    JasonCompat.convert_fragment(fragment)
  end

  def encode(%{__struct__: _module} = struct) do
    # Check for Jason.Encoder fallback - see RustyJson.Compat.Jason
    if JasonCompat.encoder_available?(struct) do
      JasonCompat.encode_with_jason(struct)
    else
      struct
      |> Map.from_struct()
      |> RustyJson.Encoder.encode()
    end
  end

  def encode(value), do: value
end
