defmodule RustyJson.OrderedObject do
  @moduledoc """
  An ordered JSON object that preserves key insertion order.

  This struct is used when decoding JSON with `objects: :ordered_objects` option.
  It preserves the original order of keys as they appeared in the JSON input.

  Implements the `Access` behaviour for key-based lookup and the `Enumerable`
  protocol for iteration over `{key, value}` pairs.

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

  defimpl Enumerable do
    def count(%RustyJson.OrderedObject{values: values}), do: {:ok, length(values)}

    def member?(%RustyJson.OrderedObject{values: values}, {key, value}) do
      {:ok, Enum.any?(values, fn {k, v} -> k == key and v == value end)}
    end

    def member?(_, _), do: {:ok, false}

    def reduce(%RustyJson.OrderedObject{values: values}, acc, fun) do
      Enumerable.List.reduce(values, acc, fun)
    end

    def slice(%RustyJson.OrderedObject{values: values}) do
      size = length(values)
      {:ok, size, &Enum.slice(values, &1, &2)}
    end
  end

  @behaviour Access

  @impl Access
  def fetch(%__MODULE__{values: values}, key) do
    case List.keyfind(values, key, 0) do
      {_, value} -> {:ok, value}
      nil -> :error
    end
  end

  @impl Access
  def get_and_update(%__MODULE__{values: values} = obj, key, fun) do
    case List.keyfind(values, key, 0) do
      {_, value} ->
        case fun.(value) do
          {get, new_value} ->
            new_values = List.keyreplace(values, key, 0, {key, new_value})
            {get, %{obj | values: new_values}}

          :pop ->
            new_values = List.keydelete(values, key, 0)
            {value, %{obj | values: new_values}}
        end

      nil ->
        case fun.(nil) do
          {get, new_value} ->
            {get, %{obj | values: values ++ [{key, new_value}]}}

          :pop ->
            {nil, obj}
        end
    end
  end

  @impl Access
  def pop(%__MODULE__{values: values} = obj, key, default \\ nil) do
    case List.keyfind(values, key, 0) do
      {_, value} ->
        new_values = List.keydelete(values, key, 0)
        {value, %{obj | values: new_values}}

      nil ->
        {default, obj}
    end
  end
end

defimpl RustyJson.Encoder, for: RustyJson.OrderedObject do
  def encode(%RustyJson.OrderedObject{values: values}, opts) do
    # Build a function-based fragment so encoding opts (escape, maps) are respected
    %RustyJson.Fragment{
      encode: fn encode_opts ->
        final_opts = merge_opts(opts, encode_opts)

        [
          "{"
          | values
            |> Enum.with_index()
            |> Enum.flat_map(fn {{key, value}, idx} ->
              prefix = if idx > 0, do: [","], else: []

              prefix ++
                [RustyJson.encode!(key, final_opts), ":", RustyJson.encode!(value, final_opts)]
            end)
        ] ++ ["}"]
      end
    }
  end

  defp merge_opts(opts, encode_opts) do
    merged =
      cond do
        is_map(opts) and is_map(encode_opts) -> Map.merge(opts, encode_opts)
        is_map(encode_opts) -> Enum.to_list(encode_opts)
        is_map(opts) -> Enum.to_list(opts)
        is_list(encode_opts) -> encode_opts
        is_list(opts) -> opts
        true -> []
      end

    if is_map(merged), do: Enum.to_list(merged), else: merged
  end
end
