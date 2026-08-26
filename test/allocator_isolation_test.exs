defmodule RustyJson.AllocatorIsolationTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Regression guard for the 2026-08-25 `beam.smp` segfault.

  Three VM crashes were traced to two NIFs in one BEAM each statically linking
  mimalloc. On macOS mimalloc keeps the per-thread default heap in a *fixed* TLS
  slot while keeping its arenas and page map private to the `.so`, so one copy's
  `mi_realloc` can receive a block the other copy allocated, miss the page-map
  lookup, report `usable_size == 0`, and copy zero bytes — handing back fresh
  memory and freeing the original.

  In `DirectParser::parse_object` that destroys `keys[0]` and `keys[1]` when a
  small 3-key root object grows its key vector from capacity 2 to 4, and those
  zero words reach `enif_make_map_from_arrays`, which validates nothing and
  crashes the VM in `erts_cmp`.

  The fix is that RustyJson no longer bundles an allocator by default. This test
  fails if that regresses, because the failure mode is silent VM-wide heap
  corruption that no functional test can catch.

  Set `RUSTYJSON_ALLOW_BUNDLED_ALLOCATOR=1` if you are deliberately building
  with the opt-in `mimalloc` feature and have confirmed RustyJson is the only
  mimalloc-bundling NIF in the VM.
  """

  # Emitted by mimalloc's own error reporting; present whenever it is linked in.
  @mimalloc_fingerprints ["mimalloc: error: ", "unable to extend the page map"]

  describe "bundled allocator" do
    @tag :allocator
    test "the loaded NIF does not statically link mimalloc" do
      case nif_path() do
        nil ->
          flunk("could not locate the loaded rustyjson NIF under priv/native")

        path ->
          blob = File.read!(path)
          found = Enum.filter(@mimalloc_fingerprints, &String.contains?(blob, &1))

          if System.get_env("RUSTYJSON_ALLOW_BUNDLED_ALLOCATOR") in ["1", "true"] do
            assert is_list(found)
          else
            assert found == [],
                   """
                   #{Path.basename(path)} statically links mimalloc #{inspect(found)}.

                   Two NIFs in one BEAM that each bundle mimalloc share macOS TLS
                   slot 0x360 while keeping private page maps. One copy's
                   mi_realloc then copies zero bytes instead of preserving the
                   block, which silently zeroes live terms and takes the VM down
                   inside erts_cmp. See docs/ALLOCATOR_SAFETY.md.

                   Build without the `mimalloc` cargo feature, or set
                   RUSTYJSON_ALLOW_BUNDLED_ALLOCATOR=1 if RustyJson is provably
                   the only mimalloc-bundling NIF in this VM.
                   """
          end
      end
    end
  end

  defp nif_path do
    :rustyjson
    |> :code.priv_dir()
    |> case do
      {:error, _} -> nil
      dir -> dir |> to_string() |> Path.join("native/*.{so,dll,dylib}") |> Path.wildcard()
    end
    |> case do
      nil -> nil
      [] -> nil
      paths -> Enum.max_by(paths, &File.stat!(&1).mtime)
    end
  end
end
