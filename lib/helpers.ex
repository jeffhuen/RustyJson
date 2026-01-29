defmodule RustyJson.Helpers do
  @moduledoc """
  Compile-time helpers for JSON encoding, compatible with Jason's `Helpers` module.

  Provides macros that pre-encode JSON object keys at compile time
  for faster runtime encoding.

  ## Examples

      import RustyJson.Helpers

      def render(user) do
        json_map(name: user.name, email: user.email)
      end

      def render_partial(user) do
        json_map_take(user, [:name, :email])
      end
  """

  @doc """
  Encodes a keyword list as a JSON object with keys pre-encoded at compile time.

  Values are encoded at runtime. Returns a `%RustyJson.Fragment{}`.

  Keys must be atoms with ASCII printable characters only (no `\\`, `/`, `"`).

  ## Examples

      iex> import RustyJson.Helpers
      iex> fragment = json_map(name: "Alice", age: 30)
      iex> RustyJson.encode!(fragment, protocol: true)
      ~s({"name":"Alice","age":30})
  """
  defmacro json_map(kv) do
    # Jason behavior: preserve order (no sorting)
    # kv = Enum.sort_by(kv, &elem(&1, 0))

    encoded_keys =
      Enum.map(kv, fn {key, _} ->
        key_str = Atom.to_string(key)
        validate_json_key!(key_str)
        RustyJson.encode!(key_str)
      end)

    value_asts = Enum.map(kv, fn {_, v} -> v end)

    quote do
      RustyJson.Helpers.__json_map__(unquote(encoded_keys), unquote(value_asts))
    end
  end

  @doc """
  Encodes selected keys from a map as a JSON object with keys pre-encoded at compile time.

  Takes a map and a compile-time list of atom keys. Values are looked up and
  encoded at runtime. Returns a `%RustyJson.Fragment{}`.

  Raises `ArgumentError` at runtime if the map is missing any of the specified keys.

  ## Examples

    iex> import RustyJson.Helpers
    iex> user = %{name: "Alice", age: 30, email: "alice@example.com"}
    iex> fragment = json_map_take(user, [:name, :age])
    iex> RustyJson.encode!(fragment, protocol: true)
    ~s({"name":"Alice","age":30})
  """
  defmacro json_map_take(map, take) do
    # Jason behavior: preserve order of requested keys (no sorting)
    # take = Enum.sort(take)

    encoded_key_pairs =
      Enum.map(take, fn key ->
        key_str = Atom.to_string(key)
        validate_json_key!(key_str)
        {RustyJson.encode!(key_str), key}
      end)

    quote do
      RustyJson.Helpers.__json_map_take__(
        unquote(map),
        unquote(Macro.escape(encoded_key_pairs)),
        unquote(take)
      )
    end
  end

  @doc false
  def __json_map__(encoded_keys, values) do
    %RustyJson.Fragment{
      encode: fn opts ->
        [
          "{"
          | encoded_keys
            |> Enum.zip(values)
            |> Enum.with_index()
            |> Enum.flat_map(fn {{key_json, value}, idx} ->
              prefix = if idx > 0, do: [","], else: []
              prefix ++ [key_json, ":", RustyJson.Encode.value(value, opts)]
            end)
        ] ++ ["}"]
      end
    }
  end

  @doc false
  def __json_map_take__(map, encoded_key_pairs, requested_keys) do
    values =
      Enum.map(encoded_key_pairs, fn {_, key_atom} ->
        case Map.fetch(map, key_atom) do
          {:ok, val} ->
            val

          :error ->
            raise ArgumentError,
                  "expected a map with keys #{inspect(requested_keys)}, got: #{inspect(map)}"
        end
      end)

    %RustyJson.Fragment{
      encode: fn opts ->
        [
          "{"
          | encoded_key_pairs
            |> Enum.zip(values)
            |> Enum.with_index()
            |> Enum.flat_map(fn {{{key_json, _}, value}, idx} ->
              prefix = if idx > 0, do: [","], else: []
              prefix ++ [key_json, ":", RustyJson.Encode.value(value, opts)]
            end)
        ] ++ ["}"]
      end
    }
  end

  defp validate_json_key!(key_str) do
    if not String.match?(key_str, ~r/^[\x20-\x21\x23-\x2E\x30-\x5B\x5D-\x7E]*$/) do
      raise ArgumentError,
            "json_map/json_map_take keys must be ASCII printable " <>
              "(excluding \", \\, /), got: #{inspect(key_str)}"
    end
  end
end
