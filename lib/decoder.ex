defmodule RustyJson.Decoder do
  @moduledoc """
  JSON decoding module, compatible with Jason's `Decoder` module.

  Provides `parse/2` as an alternative entry point for decoding JSON.
  Delegates to `RustyJson.decode/2`.
  """

  @doc """
  Parses a JSON string into an Elixir term.

  Returns `{:ok, term}` on success or `{:error, %RustyJson.DecodeError{}}` on failure.

  ## Options

  See `RustyJson.decode/2` for available options.

  ## Examples

      iex> RustyJson.Decoder.parse(~s({"name":"Alice"}))
      {:ok, %{"name" => "Alice"}}

      iex> RustyJson.Decoder.parse("invalid")
      {:error, %RustyJson.DecodeError{}}
  """
  @spec parse(iodata(), keyword()) :: {:ok, term()} | {:error, RustyJson.DecodeError.t()}
  def parse(data, opts \\ []) do
    RustyJson.decode(data, opts)
  end
end
