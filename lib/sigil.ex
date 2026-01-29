defmodule RustyJson.Sigil do
  @moduledoc """
  JSON sigils for convenient JSON literals, compatible with Jason's `Sigil` module.

  ## Sigils

  - `~j` — Decodes a JSON string. Supports interpolation. Without interpolation,
    decoding happens at compile time.
  - `~J` — Decodes a JSON string at compile time. No interpolation.

  ## Modifiers

  | Modifier | Option |
  |----------|--------|
  | `a` | `keys: :atoms` |
  | `A` | `keys: :atoms!` |
  | `r` | `strings: :reference` |
  | `c` | `strings: :copy` |

  Unknown modifiers raise `ArgumentError`.

  ## Examples

      import RustyJson.Sigil

      ~j({"name": "Alice", "age": 30})
      #=> %{"name" => "Alice", "age" => 30}

      ~j({"name": "Alice"})a
      #=> %{name: "Alice"}

      ~J({"x": 1, "y": 2})
      #=> %{"x" => 1, "y" => 2}

  ## Usage

  Add `import RustyJson.Sigil` to use the sigils in your module.
  """

  @doc """
  Handles the `~j` sigil for JSON decoding.

  When the string has no interpolation, decoding happens at compile time.
  With interpolation, decoding happens at runtime.
  """
  defmacro sigil_j({:<<>>, _meta, [string]}, modifiers) when is_binary(string) do
    opts = mods_to_opts(modifiers)
    Macro.escape(RustyJson.decode!(string, opts))
  end

  defmacro sigil_j(term, modifiers) do
    opts = Macro.escape(mods_to_opts(modifiers))

    quote do
      RustyJson.decode!(unquote(term), unquote(opts))
    end
  end

  @doc """
  Handles the `~J` sigil for compile-time JSON decoding.

  No interpolation is supported. Decoding always happens at compile time.
  """
  defmacro sigil_J({:<<>>, _meta, [string]}, modifiers) when is_binary(string) do
    opts = mods_to_opts(modifiers)
    Macro.escape(RustyJson.decode!(string, opts))
  end

  defp mods_to_opts(modifiers) do
    Enum.flat_map(modifiers, fn
      ?a -> [keys: :atoms]
      ?A -> [keys: :atoms!]
      ?r -> [strings: :reference]
      ?c -> [strings: :copy]
      m -> raise ArgumentError, "unknown sigil modifier #{<<?", m, ?">>}"
    end)
  end
end
