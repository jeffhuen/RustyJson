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

  ## Common Causes

  | Error | Cause |
  |-------|-------|
  | `"expected value at position N"` | Unexpected character where a JSON value was expected |
  | `"expected string at position N"` | Object key is not a quoted string |
  | `"unexpected end of input"` | JSON is truncated |
  | `"trailing characters after JSON"` | Extra content after valid JSON |
  | `"maximum nesting depth exceeded"` | More than 128 levels of nesting |

  ## Examples

      iex> RustyJson.decode!("invalid")
      ** (RustyJson.DecodeError) expected value at position 0

      iex> RustyJson.decode!("{key: 1}")
      ** (RustyJson.DecodeError) expected string at position 1

      iex> RustyJson.decode!("[1, 2,]")
      ** (RustyJson.DecodeError) trailing comma at position 6

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
          __exception__: true
        }

  defexception [:message]

  @impl true
  @spec exception(String.t() | keyword()) :: t()
  def exception(message) when is_binary(message) do
    %__MODULE__{message: message}
  end

  def exception(opts) when is_list(opts) do
    message = Keyword.get(opts, :message, "JSON decode error")
    %__MODULE__{message: message}
  end
end
