defmodule RustyJson.Encode do
  @moduledoc """
  Low-level encoding functions, compatible with `Jason.Encode`.

  These functions encode individual Elixir terms to JSON iodata.
  They delegate to `RustyJson.encode!/2` which uses the Rust NIF
  for maximum performance.

  ## Opts

  Functions that accept `opts` use a map containing encoding options.
  Use `opts/1` to build the options map from an escape mode atom.

  ## Examples

      iex> opts = RustyJson.Encode.opts(:json)
      iex> RustyJson.Encode.string("hello", opts)
      ~s("hello")

      iex> RustyJson.Encode.integer(42)
      "42"
  """

  @typedoc """
  Encoding options map.

  Contains `:escape` key with the escape mode to use.
  Build with `opts/1`.
  """
  @opaque opts :: map()

  @doc """
  Builds encoding options from an escape mode.

  ## Examples

      iex> RustyJson.Encode.opts(:json)
      %{escape: :json}

      iex> RustyJson.Encode.opts(:html_safe)
      %{escape: :html_safe}
  """
  @spec opts(RustyJson.escape_mode()) :: opts()
  def opts(escape \\ :json), do: %{escape: escape}

  @doc """
  Encodes any term to JSON iodata.

  Returns `{:ok, iodata}` on success or `{:error, exception}` on failure.
  """
  @spec encode(term(), map()) ::
          {:ok, iodata()} | {:error, RustyJson.EncodeError.t() | Exception.t()}
  def encode(value, user_opts \\ %{}) do
    escape = Map.get(user_opts, :escape, :json)
    maps = Map.get(user_opts, :maps, :naive)
    {:ok, RustyJson.encode!(value, escape: escape, maps: maps)}
  rescue
    e in [RustyJson.EncodeError] -> {:error, e}
    e -> {:error, e}
  end

  @doc "Encodes a term using the given opts. Dispatches based on type."
  @spec value(term(), opts()) :: iodata()
  def value(value, opts), do: do_encode(value, opts)

  @doc "Encodes an atom to a JSON string."
  @spec atom(atom(), opts()) :: iodata()
  def atom(atom, opts), do: do_encode(atom, opts)

  @doc "Encodes an integer to a JSON number."
  @spec integer(integer()) :: iodata()
  def integer(integer), do: RustyJson.encode!(integer)

  @doc "Encodes a float to a JSON number."
  @spec float(float()) :: iodata()
  def float(float), do: RustyJson.encode!(float)

  @doc "Encodes a list to a JSON array."
  @spec list(list(), opts()) :: iodata()
  def list(list, opts), do: do_encode(list, opts)

  @doc """
  Encodes a term as a JSON object key.

  Accepts strings, atoms, and any term implementing `String.Chars`.
  Compatible with `Jason.Encode.key/2`.

  ## Examples

      iex> opts = RustyJson.Encode.opts()
      iex> RustyJson.Encode.key("name", opts)
      ~s("name")

      iex> opts = RustyJson.Encode.opts()
      iex> RustyJson.Encode.key(:status, opts)
      ~s("status")
  """
  @spec key(term(), opts()) :: iodata()
  def key(string, opts) when is_binary(string), do: do_encode(string, opts)
  def key(atom, opts) when is_atom(atom), do: do_encode(Atom.to_string(atom), opts)
  def key(other, opts), do: do_encode(to_string(other), opts)

  @doc """
  Encodes a keyword list as a JSON object, preserving key order.

  Unlike `map/2`, this preserves the insertion order of keys.
  """
  @spec keyword(keyword(), opts()) :: iodata()
  def keyword(keyword, opts) do
    escape = Map.get(opts, :escape, :json)
    pairs = Enum.map(keyword, fn {k, v} -> {Atom.to_string(k), v} end)
    # Encode as a list of pairs which the NIF handles as an ordered object
    # We build the JSON manually to preserve order
    inner =
      pairs
      |> Enum.map(fn {k, v} ->
        [RustyJson.encode!(k, escape: escape), ":", RustyJson.encode!(v, escape: escape)]
      end)
      |> Enum.intersperse(",")

    IO.iodata_to_binary(["{", inner, "}"])
  end

  @doc "Encodes a map to a JSON object."
  @spec map(map(), opts()) :: iodata()
  def map(map, opts), do: do_encode(map, opts)

  @doc "Encodes a string to a JSON string."
  @spec string(String.t(), opts()) :: iodata()
  def string(string, opts), do: do_encode(string, opts)

  @doc "Encodes a struct to a JSON object."
  @spec struct(struct(), opts()) :: iodata()
  def struct(struct, opts), do: do_encode(struct, opts)

  defp do_encode(term, opts) do
    escape = Map.get(opts, :escape, :json)
    RustyJson.encode!(term, escape: escape)
  end
end
