defmodule RustyJson.Fragment do
  @moduledoc """
  Represents pre-encoded JSON that should be injected directly into output.

  Fragments come in two forms:

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
  """

  @type t :: %__MODULE__{encode: iodata() | (keyword() -> iodata())}

  defstruct [:encode]

  @doc """
  Creates a new fragment from pre-encoded JSON.
  """
  @spec new(iodata()) :: t()
  def new(data) when is_binary(data) or is_list(data) do
    %__MODULE__{encode: data}
  end

  @spec new((term() -> iodata())) :: t()
  def new(encode) when is_function(encode, 1) do
    %__MODULE__{encode: encode}
  end

  @doc """
  Creates a validated fragment, ensuring the input is valid JSON.

  Raises an error if the input is not valid JSON.
  """
  @spec new!(iodata()) :: t()
  def new!(data) do
    _ = RustyJson.decode!(IO.iodata_to_binary(data))
    %__MODULE__{encode: data}
  end
end

defimpl RustyJson.Encoder, for: RustyJson.Fragment do
  def encode(%RustyJson.Fragment{encode: encode} = fragment, opts) when is_function(encode, 1) do
    %{fragment | encode: encode.(opts)}
  end

  def encode(%RustyJson.Fragment{} = fragment, _opts), do: fragment
end
