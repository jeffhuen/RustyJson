defmodule RustyJson.Compat.Jason do
  @moduledoc """
  Jason compatibility layer for RustyJson.

  This module provides automatic fallback to `Jason.Encoder` implementations
  when encoding structs with `protocol: true`. It allows RustyJson to be a
  true drop-in replacement for Jason without requiring code changes.

  ## Performance Warning

  **This compatibility layer is only active when `protocol: true` is passed.**

  ```elixir
  # Default - NO compatibility overhead, straight to Rust
  RustyJson.encode!(data)

  # With protocol - compatibility layer active
  RustyJson.encode!(data, protocol: true)
  ```

  When active, this layer:
  1. Checks if a struct has a `Jason.Encoder` implementation
  2. If found, calls `Jason.encode_to_iodata!/1` to encode it
  3. Wraps the result in a `RustyJson.Fragment` for the Rust NIF

  This adds Elixir-side overhead for each struct with a Jason.Encoder.

  ## How It Works

  When you encode a struct with `protocol: true`:

  ```
  %UserWithJasonEncoder{...}
        │
        ▼
  RustyJson.Encoder.Any.encode/1
        │
        ▼
  jason_encoder_available?/2  ◄── Checks for Jason.Encoder impl
        │
        ▼ (if found)
  Jason.encode_to_iodata!/1   ◄── Calls Jason to encode
        │
        ▼
  %RustyJson.Fragment{...}    ◄── Wraps as Fragment
        │
        ▼
  Rust NIF                    ◄── Writes iodata directly
  ```

  ## Supported Scenarios

  | Scenario | Supported | Notes |
  |----------|-----------|-------|
  | `@derive Jason.Encoder` | ✅ | Works with `:only`/`:except` options |
  | `defimpl Jason.Encoder` | ✅ | Custom implementations work |
  | `Jason.Fragment` | ✅ | Converted to `RustyJson.Fragment` |
  | Nested Jason-encoded structs | ✅ | Recursively handled |

  ## Example

  ```elixir
  # Existing code with Jason.Encoder
  defmodule User do
    @derive {Jason.Encoder, only: [:id, :name]}
    defstruct [:id, :name, :password_hash]
  end

  # Works with RustyJson when protocol: true
  user = %User{id: 1, name: "Alice", password_hash: "secret"}
  RustyJson.encode!(user, protocol: true)
  # => {"id":1,"name":"Alice"}
  ```

  ## When to Use

  Use `protocol: true` when:
  - Migrating from Jason and you have existing `Jason.Encoder` implementations
  - You need custom struct encoding and don't want to implement `RustyJson.Encoder`

  For maximum performance, implement `RustyJson.Encoder` directly instead.
  """

  @doc """
  Checks if a struct has a usable `Jason.Encoder` implementation.

  Returns `true` if:
  - `Jason.Encoder` module is loaded
  - The struct has an implementation (not `Jason.Encoder.Any`)
  - The implementation exports `encode/2`

  ## Examples

      iex> RustyJson.Compat.Jason.encoder_available?(%UserWithJasonEncoder{})
      true

      iex> RustyJson.Compat.Jason.encoder_available?(%PlainStruct{})
      false

  """
  @spec encoder_available?(struct()) :: boolean()
  def encoder_available?(struct) when is_struct(struct) do
    if Code.ensure_loaded?(Jason.Encoder) and function_exported?(Jason.Encoder, :impl_for, 1) do
      case Jason.Encoder.impl_for(struct) do
        nil -> false
        Jason.Encoder.Any -> false
        impl -> function_exported?(impl, :encode, 2)
      end
    else
      false
    end
  end

  @doc """
  Encodes a struct using its `Jason.Encoder` implementation.

  Returns a `RustyJson.Fragment` containing the pre-encoded JSON as iodata.
  The Rust NIF will write this directly to output without re-encoding.

  ## Examples

      iex> user = %UserWithJasonEncoder{id: 1, name: "Alice"}
      iex> fragment = RustyJson.Compat.Jason.encode_with_jason(user)
      iex> fragment.encode
      [123, [[34, "id", 34], 58, "1"], 44, [[34, "name", 34], 58, [34, "Alice", 34]], 125]

  """
  @spec encode_with_jason(struct()) :: RustyJson.Fragment.t()
  def encode_with_jason(struct) when is_struct(struct) do
    %RustyJson.Fragment{encode: Jason.encode_to_iodata!(struct)}
  end

  @doc """
  Converts a `Jason.Fragment` to a `RustyJson.Fragment`.

  Jason.Fragment stores either:
  - A function `(opts -> iodata)` in the `:encode` field
  - Pre-computed iodata in the `:encode` field

  This function normalizes both cases to a `RustyJson.Fragment` with iodata.

  ## Examples

      iex> jason_frag = Jason.Fragment.new(~s({"pre":"encoded"}))
      iex> rusty_frag = RustyJson.Compat.Jason.convert_fragment(jason_frag)
      iex> rusty_frag.encode
      "{\\"pre\\":\\"encoded\\"}"

  """
  @spec convert_fragment(struct()) :: RustyJson.Fragment.t()
  def convert_fragment(%{__struct__: Jason.Fragment, encode: encode}) when is_function(encode, 1) do
    %RustyJson.Fragment{encode: encode.(nil)}
  end

  def convert_fragment(%{__struct__: Jason.Fragment, encode: encode}) do
    %RustyJson.Fragment{encode: encode}
  end
end
