# Allocator safety

**RustyJson ships with no bundled memory allocator, and you should think hard
before enabling one.**

Since v0.4.1 the `mimalloc` cargo feature is opt-in rather than default. This
page explains why, what it costs you, and when it is safe to turn back on.

## Why the default changed

A NIF is a shared library loaded into a BEAM that may already host other NIFs.
When a Rust NIF sets `#[global_allocator]` to a statically linked allocator,
that allocator is private to *that* `.so` — its arenas, its free lists, and (for
mimalloc) its page map are not shared with any other NIF.

On macOS, mimalloc also stores the per-thread default heap in a **fixed TLS
slot** (offset `0x360` from the thread pointer). That slot is process-global.
So when two NIFs each bundle mimalloc:

- they **share** the TLS slot that names the current thread's heap, but
- they each keep a **private** page map for looking blocks up.

A block allocated while the slot held the other copy's heap is therefore
invisible to this copy's page map. `mi_realloc` then takes this path:

```c
size_t size = _mi_usable_size(p);        // page-map miss -> 0
void*  newp = mi_heap_malloc(heap, newsize);
memcpy(newp, p, min(newsize, size));     // min(newsize, 0) == 0 bytes
mi_free(p);                              // original freed anyway
```

It copies **nothing**, frees the original, and hands back fresh, uninitialised
memory — which reads as zeroes on a fresh page. Every live value in that block
is silently destroyed. No error, no crash at the point of damage.

### What that did to RustyJson

`DirectParser::parse_object` collects object keys into a `Vec<Term>`. For a
small (<256 byte) 3-key **root** object the capacity estimate is 2, so the third
push reallocates 48 → 96 bytes. Those 48 bytes are exactly `keys[0]` and
`keys[1]`. With the zero-byte copy above, both become `0` — `THE_NON_VALUE`.

`enif_make_map_from_arrays` validates nothing. It memcpys the array onto the
process heap and sorts it, and `erts_cmp` dereferences `boxed_val(0)` at address
`0 - 2`:

```
EXC_BAD_ACCESS (SIGSEGV) at 0xfffffffffffffffe
  erts_cmp+236
  erts_validate_and_sort_flatmap+100
  erts_map_from_ks_and_vs+300
  enif_make_map_from_arrays+172
  rustler::Term::map_from_term_arrays
  rustyjson::DirectParser::parse_object
```

The whole VM dies. This was observed three times in a production dev server on
2026-08-25 and reproduced on demand against `rusty_csv` 0.4.4, which also
bundles mimalloc. Full investigation:
[`BEAM_SEGFAULT_INVESTIGATION.md`](BEAM_SEGFAULT_INVESTIGATION.md).

## What it costs to leave the allocator off

Measured on an M1 Pro, median of 5 rounds, decode only:

| payload | system allocator | mimalloc | mimalloc gain |
|---|---|---|---|
| small 3-key root object | 690 ns/op | 484 ns/op | 1.43× |
| deeply nested (40 levels) | 5125 ns/op | 3997 ns/op | 1.28× |
| 200-element array of objects | 81.1 µs/op | 67.4 µs/op | 1.20× |
| 40-key flat object | 8336 ns/op | 8280 ns/op | ~1.00× |
| **aggregate** | **813 ms** | **679 ms** | **1.20×** |

So mimalloc is worth roughly 20% overall, and up to ~40% on small payloads. That
is real, which is why the feature still exists — but it is not worth an
occasional unexplained VM crash, so it is no longer the default.

## When it is safe to enable

Enable a bundled allocator only if **RustyJson is the only NIF in your VM that
bundles one**. Check every Rust NIF you load:

```sh
for so in _build/dev/lib/*/priv/native/*.so; do
  n=$(strings -a "$so" | grep -c "^mimalloc: error: $")
  [ "$n" -gt 0 ] && echo "bundles mimalloc: $so"
done
```

If that prints nothing other than RustyJson, you are clear. Common Elixir NIFs
that bundle mimalloc include `rusty_csv`. Re-run the check whenever you add a
Rust dependency — the failure mode is silent.

Then:

```sh
RUSTYJSON_ALLOCATOR=mimalloc FORCE_RUSTYJSON_BUILD=1 mix compile
```

Accepted values are `mimalloc`, `jemalloc`, and `snmalloc`. This requires a
local build; the published precompiled artifacts never bundle an allocator.

`jemalloc` and `snmalloc` do not use mimalloc's fixed-slot trick, but the
general rule still holds: two NIFs bundling the *same* allocator can collide,
and the consequences are silent heap corruption. Only one NIF per VM should
override the global allocator.

## Things that do not fix this

- **`mimalloc/local_dynamic_tls`** — verified not to help. It changes the
  `__thread` TLS model; mimalloc's macOS `__builtin_thread_pointer()` fast path
  is independent of it and the fixed-slot accesses remain.
- **Rebuilding for a different NIF ABI** — verified irrelevant. The corruption
  reproduces identically on NIF 2.15, 2.17 and 2.18, and disappears on all three
  when the allocator is removed.

## Regression guard

`test/allocator_isolation_test.exs` fails the build if a default artifact ever
links mimalloc again. It is deliberately a build-shape assertion rather than a
functional test, because no functional test can detect this class of bug — the
corruption is silent until the VM dies somewhere unrelated.
