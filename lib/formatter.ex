defmodule RustyJson.Formatter do
  @moduledoc """
  Functions for formatting JSON strings.

  This module provides utilities for pretty-printing and minifying
  JSON data, compatible with `Jason.Formatter`.
  """

  @type opts :: [
          {:indent, pos_integer() | boolean()},
          {:line_separator, String.t()},
          {:record_separator, String.t()},
          {:after_colon, String.t()}
        ]

  @doc """
  Pretty prints a JSON string.

  ## Options

    * `:indent` - Integer for indentation level (number of spaces). Default: 2.
      If `true`, 2 spaces are used.

  ## Examples

      iex> RustyJson.Formatter.pretty_print(~s({"a":1,"b":[1,2]}))
      {:ok, "{\n  \"a\": 1,\n  \"b\": [\n    1,\n    2\n  ]\n}"}
  """
  @spec pretty_print(iodata(), opts()) :: {:ok, String.t()} | {:error, String.t()}
  def pretty_print(input, opts \\ []) do
    indent = opts[:indent] || 2

    case RustyJson.decode(input) do
      {:ok, decoded} -> {:ok, RustyJson.encode!(decoded, pretty: indent)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Pretty prints a JSON string, raising on error.
  """
  @spec pretty_print!(iodata(), opts()) :: String.t()
  def pretty_print!(input, opts \\ []) do
    case pretty_print(input, opts) do
      {:ok, result} -> result
      {:error, reason} -> raise RustyJson.DecodeError, message: reason
    end
  end

  @doc """
  Minifies a JSON string by removing unnecessary whitespace.
  """
  @spec minimize(iodata()) :: {:ok, String.t()} | {:error, String.t()}
  def minimize(input) do
    case RustyJson.decode(input) do
      {:ok, decoded} -> {:ok, RustyJson.encode!(decoded)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Minifies a JSON string, raising on error.
  """
  @spec minimize!(iodata()) :: String.t()
  def minimize!(input) do
    case minimize(input) do
      {:ok, result} -> result
      {:error, reason} -> raise RustyJson.DecodeError, message: reason
    end
  end
end
