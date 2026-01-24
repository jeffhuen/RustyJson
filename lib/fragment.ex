defmodule RustyJson.Fragment do
  @moduledoc """
  Represents pre-encoded JSON that should be injected directly into output.

  This is compatible with `Jason.Fragment` - if you have existing code using
  Jason.Fragment, RustyJson will handle it correctly.

  ## Usage

      # Pre-encode some JSON
      fragment = RustyJson.Fragment.new(~s({"already": "encoded"}))

      # Include in a larger structure
      RustyJson.encode!(%{data: fragment, extra: "field"})
      # => {"data":{"already":"encoded"},"extra":"field"}
  """

  @type t :: %__MODULE__{encode: iodata() | (term() -> iodata())}

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
  def encode(%RustyJson.Fragment{encode: encode} = fragment) when is_function(encode, 1) do
    %{fragment | encode: encode.(nil)}
  end

  def encode(%RustyJson.Fragment{} = fragment), do: fragment
end
