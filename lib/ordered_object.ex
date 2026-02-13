defmodule RustyJson.OrderedObject do
  @moduledoc """
  An ordered JSON object that preserves key insertion order.

  A wrapper around a keyword list (that supports non-atom keys) allowing for
  proper protocol implementations.

  This struct is used when decoding JSON with `objects: :ordered_objects` option.
  It preserves the original order of keys as they appeared in the JSON input.

  Implements the `Access` behaviour and `Enumerable` protocol with
  complexity similar to keywords/lists.

  ## Decoding

      iex> RustyJson.decode!(~s({"b":2,"a":1}), objects: :ordered_objects)
      %RustyJson.OrderedObject{values: [{"b", 2}, {"a", 1}]}

  ## Encoding

  When encoded back to JSON, the original key order is preserved:

      iex> obj = %RustyJson.OrderedObject{values: [{"b", 2}, {"a", 1}]}
      iex> RustyJson.encode!(obj)
      ~s({"b":2,"a":1})

  ## Access

      iex> obj = RustyJson.OrderedObject.new([{"x", 1}, {"y", 2}])
      iex> obj["x"]
      1
  """

  @behaviour Access

  @type t :: %__MODULE__{
          values: [{String.Chars.t(), term()}]
        }

  defstruct values: []

  @doc """
  Creates a new OrderedObject from a list of key-value tuples.
  """
  @spec new(list({String.Chars.t(), term()})) :: t()
  def new(values) when is_list(values) do
    %__MODULE__{values: values}
  end

  @impl Access
  def fetch(%__MODULE__{values: values}, key) do
    case :lists.keyfind(key, 1, values) do
      {_, value} -> {:ok, value}
      false -> :error
    end
  end

  @impl Access
  def get_and_update(%__MODULE__{values: values} = obj, key, function) do
    {result, new_values} = get_and_update(values, [], key, function)
    {result, %{obj | values: new_values}}
  end

  @impl Access
  def pop(%__MODULE__{values: values} = obj, key, default \\ nil) do
    case :lists.keyfind(key, 1, values) do
      {_, value} -> {value, %{obj | values: delete_key(values, key)}}
      false -> {default, obj}
    end
  end

  defp get_and_update([{key, current} | t], acc, key, fun) do
    case fun.(current) do
      {get, value} ->
        {get, :lists.reverse(acc, [{key, value} | t])}

      :pop ->
        {current, :lists.reverse(acc, t)}

      other ->
        raise "the given function must return a two-element tuple or :pop, got: #{inspect(other)}"
    end
  end

  defp get_and_update([{_, _} = h | t], acc, key, fun), do: get_and_update(t, [h | acc], key, fun)

  defp get_and_update([], acc, key, fun) do
    case fun.(nil) do
      {get, update} ->
        {get, [{key, update} | :lists.reverse(acc)]}

      :pop ->
        {nil, :lists.reverse(acc)}

      other ->
        raise "the given function must return a two-element tuple or :pop, got: #{inspect(other)}"
    end
  end

  defp delete_key([{key, _} | tail], key), do: delete_key(tail, key)
  defp delete_key([{_, _} = pair | tail], key), do: [pair | delete_key(tail, key)]
  defp delete_key([], _key), do: []
end

defimpl Enumerable, for: RustyJson.OrderedObject do
  def count(%{values: []}), do: {:ok, 0}
  def count(_obj), do: {:error, __MODULE__}

  def member?(%{values: []}, _value), do: {:ok, false}
  def member?(_obj, _value), do: {:error, __MODULE__}

  def slice(%{values: []}), do: {:ok, 0, fn _, _ -> [] end}
  def slice(_obj), do: {:error, __MODULE__}

  def reduce(%{values: values}, acc, fun), do: Enumerable.List.reduce(values, acc, fun)
end

defimpl RustyJson.Encoder, for: RustyJson.OrderedObject do
  # Pass through to Rust for native formatting with proper pretty-printing.
  # Only pre-process values when they contain structs/tuples that need
  # Encoder protocol dispatch; otherwise return as-is (zero allocation).
  def encode(%RustyJson.OrderedObject{values: values} = obj, opts) do
    if needs_encoding?(values) do
      %RustyJson.OrderedObject{values: preprocess_values(values, opts)}
    else
      obj
    end
  end

  defp needs_encoding?([]), do: false
  defp needs_encoding?([{_k, %{__struct__: _}} | _rest]), do: true
  defp needs_encoding?([{_k, v} | _rest]) when is_tuple(v), do: true

  defp needs_encoding?([{_k, v} | rest]) when is_map(v) do
    has_struct_key?(v) or needs_encoding?(rest)
  end

  defp needs_encoding?([{_k, v} | rest]) when is_list(v) do
    needs_encoding_list?(v) or needs_encoding?(rest)
  end

  defp needs_encoding?([{_k, _v} | rest]), do: needs_encoding?(rest)

  defp has_struct_key?(map), do: :maps.is_key(:__struct__, map)

  defp needs_encoding_list?([]), do: false
  defp needs_encoding_list?([%{__struct__: _} | _]), do: true
  defp needs_encoding_list?([v | _]) when is_tuple(v), do: true

  defp needs_encoding_list?([v | rest]) when is_map(v) do
    has_struct_key?(v) or needs_encoding_list?(rest)
  end

  defp needs_encoding_list?([v | rest]) when is_list(v) do
    needs_encoding_list?(v) or needs_encoding_list?(rest)
  end

  defp needs_encoding_list?([_ | rest]), do: needs_encoding_list?(rest)

  defp preprocess_values([], _opts), do: []

  defp preprocess_values([{k, v} | rest], opts) do
    [{k, RustyJson.Encoder.encode(v, opts)} | preprocess_values(rest, opts)]
  end
end
