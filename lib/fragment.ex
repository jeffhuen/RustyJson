defmodule RustyJson.Fragment do
  @moduledoc """
  Represents pre-encoded JSON that should be injected directly into output.

  Fragments come in three forms:

  ## Static Fragments (iodata)

      # Pre-encode some JSON
      fragment = RustyJson.Fragment.new(~s({"already": "encoded"}))

      # Include in a larger structure
      RustyJson.encode!(%{data: fragment, extra: "field"})
      # => {"data":{"already":"encoded"},"extra":"field"}

  ## Function-based Fragments

  Function-based fragments receive encoding options at runtime, enabling
  context-aware encoding (e.g., respecting `escape: :html_safe`). This is
  used internally by `RustyJson.Helpers.json_map/1` and `RustyJson.OrderedObject`.

      fragment = RustyJson.Fragment.new(fn opts ->
        escape = Keyword.get(opts, :escape, :json)
        # ... produce iodata based on encoding context
      end)

  The function receives a keyword list of options (e.g., `[escape: :html_safe, maps: :naive]`)
  and must return iodata.

  ## Raw iodata Fragments

  Used internally by `RustyJson.Encoder` Map and List implementations.
  When encoding data that contains structs or tuples, these impls produce
  Fragments with raw iodata (from `RustyJson.Encode.map/2` or
  `RustyJson.Encode.list/2`) instead of intermediate data structures. This
  enables single-pass serialization — the NIF writes the pre-built iodata
  directly rather than re-walking the tree.
  """

  @type t :: %__MODULE__{encode: iodata() | (term() -> iodata())}

  defstruct [:encode]

  @doc """
  Creates a new fragment from pre-encoded JSON iodata or a function.

  When given iodata, it is wrapped in a function for uniform internal
  representation, matching Jason's behavior. When given a 1-arity function,
  the function receives encoder options (a keyword list) and must return iodata.
  """
  @spec new(iodata() | (term() -> iodata())) :: t()
  def new(data) when is_binary(data) or is_list(data) do
    %__MODULE__{encode: fn _ -> data end}
  end

  def new(encode) when is_function(encode, 1) do
    %__MODULE__{encode: encode}
  end

  @doc """
  Creates a validated fragment, ensuring the input is valid JSON.

  Raises `RustyJson.DecodeError` if the input is not valid JSON.
  """
  @spec new!(iodata()) :: t()
  def new!(data) do
    _ = RustyJson.decode!(IO.iodata_to_binary(data))
    %__MODULE__{encode: fn _ -> data end}
  end
end

defimpl RustyJson.Encoder, for: RustyJson.Fragment do
  def encode(%RustyJson.Fragment{encode: encode}, opts) when is_function(encode, 1) do
    %RustyJson.Fragment{encode: encode.(opts)}
  end

  def encode(%RustyJson.Fragment{} = frag, _opts), do: frag
end
