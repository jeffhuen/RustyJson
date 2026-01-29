defmodule RustyJson.EncodeError do
  @moduledoc """
  Exception raised when JSON encoding fails.

  This exception is raised by `RustyJson.encode!/2` when the input cannot be
  encoded to valid JSON.

  ## Fields

  * `:message` - Human-readable error description

  ## Common Causes

  | Error | Cause |
  |-------|-------|
  | `"Failed to decode binary"` | Binary is not valid UTF-8 |
  | `"Non-finite float"` | Float is NaN or Infinity |
  | `"Nesting depth exceeds maximum"` | More than 128 levels of nesting |
  | `"Unsupported term type"` | Term type cannot be encoded (e.g., PID, Reference) |

  ## Examples

      iex> RustyJson.encode!(<<0xFF>>)
      ** (RustyJson.EncodeError) Failed to decode binary

      iex> RustyJson.encode!(:math.log(-1))
      ** (RustyJson.EncodeError) Non-finite float

  ## Handling Errors

  Use `RustyJson.encode/2` to get `{:error, reason}` instead of raising:

      case RustyJson.encode(data) do
        {:ok, json} -> send_response(json)
        {:error, reason} -> Logger.error("Encoding failed: \#{reason}")
      end

  """

  @typedoc """
  Encode error exception struct.
  """
  @type t :: %__MODULE__{
          message: String.t(),
          __exception__: true
        }

  defexception [:message]

  @doc """
  Creates an `EncodeError` from a tagged error reason.

  Matches Jason's `EncodeError.new/1` API for compatibility.

  ## Examples

      iex> RustyJson.EncodeError.new({:duplicate_key, "name"})
      %RustyJson.EncodeError{message: "duplicate key: name"}

      iex> RustyJson.EncodeError.new({:invalid_byte, ?\\n, "hello\\nworld"})
      %RustyJson.EncodeError{message: "invalid byte 0x0A in string: \\"hello\\\\nworld\\""}
  """
  @spec new({:duplicate_key, term()} | {:invalid_byte, byte(), String.t()}) :: t()
  def new({:duplicate_key, key}) do
    %__MODULE__{message: "duplicate key: #{key}"}
  end

  def new({:invalid_byte, byte, original}) do
    %__MODULE__{
      message:
        "invalid byte 0x#{Integer.to_string(byte, 16) |> String.pad_leading(2, "0")} in string: #{inspect(original)}"
    }
  end

  @impl true
  @spec exception(String.t() | keyword()) :: t()
  def exception(message) when is_binary(message) do
    %__MODULE__{message: message}
  end

  def exception(opts) when is_list(opts) do
    message = Keyword.get(opts, :message, "JSON encode error")
    %__MODULE__{message: message}
  end
end

defmodule RustyJson.DecodeError do
  @moduledoc """
  Exception raised when JSON decoding fails.

  This exception is raised by `RustyJson.decode!/2` when the input is not valid JSON.

  ## Fields

  * `:message` - Human-readable error description
  * `:data` - The original input data that failed to decode
  * `:position` - The byte position in the input where the error occurred
  * `:token` - A short snippet of input around the error position

  ## Common Causes

  | Error | Cause |
  |-------|-------|
  | `"Unexpected character at position N"` | Unexpected character where a JSON value was expected |
  | `"Expected string key at position N"` | Object key is not a quoted string |
  | `"Unexpected end of input"` | JSON is truncated |
  | `"Unexpected trailing characters"` | Extra content after valid JSON |
  | `"Nesting depth exceeds maximum"` | More than 128 levels of nesting |

  ## Examples

      iex> try do
      ...>   RustyJson.decode!("invalid")
      ...> rescue
      ...>   e in RustyJson.DecodeError ->
      ...>     {e.message, e.position, e.data}
      ...> end
      {"Unexpected character at position 0", 0, "invalid"}

  ## Handling Errors

  Use `RustyJson.decode/2` to get `{:error, reason}` instead of raising:

      case RustyJson.decode(user_input) do
        {:ok, data} -> process(data)
        {:error, reason} -> Logger.warning("Invalid JSON: \#{reason}")
      end

  """

  @typedoc """
  Decode error exception struct.
  """
  @type t :: %__MODULE__{
          message: String.t(),
          data: String.t() | nil,
          position: non_neg_integer() | nil,
          token: String.t() | nil,
          __exception__: true
        }

  defexception [:message, :data, :position, :token]

  @impl true
  @spec exception(String.t() | keyword() | map()) :: t()
  def exception(message) when is_binary(message) do
    %__MODULE__{message: message, data: nil, position: nil, token: nil}
  end

  def exception(%{} = attrs) do
    struct!(__MODULE__, attrs)
  end

  def exception(opts) when is_list(opts) do
    message = Keyword.get(opts, :message, "JSON decode error")

    %__MODULE__{
      message: message,
      data: Keyword.get(opts, :data),
      position: Keyword.get(opts, :position),
      token: Keyword.get(opts, :token)
    }
  end
end
