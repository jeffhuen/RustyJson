# beam.smp SIGSEGV in `enif_make_map_from_arrays` — root cause found

Investigator: independent native-runtime review, 2026-08-25.
Worktree: `rustyjson-beam-crash-opus` (based on `origin/main`, RustyJson 0.4.0).

**Root cause: two NIFs in one BEAM each statically link mimalloc.** On macOS
each copy keeps its arenas and page map private to its own `.so` but stores the
per-thread default heap in the *same fixed TLS slot*. One copy's `mi_realloc`
can therefore be handed a block the other copy allocated, miss its page-map
lookup, report `usable_size == 0`, and copy **zero bytes** — silently returning
fresh memory and freeing the original. In `parse_object` that destroys `keys[0]`
and `keys[1]`, which reach `enif_make_map_from_arrays` as `THE_NON_VALUE` and
kill the VM inside `erts_cmp`.

Reproduced on demand, 100% of runs, in seconds. Fixed and regression-tested.

---

## 1. Provenance

**FACT.** Everything below was disassembled from the binaries that actually
crashed:

| Image | Crash report identity | Local file | Match |
|---|---|---|---|
| `beam.smp` | UUID `CFE3E207-…FFC3F` | `/opt/homebrew/lib/erlang/erts-17.0.5/bin/beam.smp` | UUID identical |
| `librustyjson…2.17…so` | UUID `A29ACC85-…7CDB4` | `_build/dev/lib/rustyjson/priv/native/…` | UUID + SHA-256 `441c13d0…7149b` identical |

The production artifact was never rebuilt or replaced; it remains the control.

**Embedded compiler metadata, recovered from the artifact:**

| Property | Value | Source |
|---|---|---|
| Build host | GitHub macOS runner (`/Users/runner/…`) | embedded cargo registry paths |
| rustc commit | `67854e511de21d881bb16426996cd4259d44aa2e` | embedded `/rustc/<hash>/` std paths |
| Toolchain channel | **nightly** | `.github/workflows/release.yml:61` `dtolnay/rust-toolchain@nightly` |
| SDK / min OS | 14.5 / 11.0 | `LC_BUILD_VERSION` |
| LTO | **fat** (`lto = true`) | `native/rustyjson/.cargo/config.toml` |
| Declared NIF ABI | **2.17** | `movk x9, #0x11, lsl #32` in `nif_init` |

No installed toolchain matches that commit, so exact codegen reproduction was
not possible; it was not needed — the fault reproduces across three different
ABIs and two different rustc versions (see §5).

---

## 2. The failure, verified instruction by instruction

```
rustyjson  .so+0x1e244   bl   map_from_term_arrays      ; parse_object, multi-entry path
rustler    .so+0x5102c   blr  x8                        ; -> enif_make_map_from_arrays
beam.smp   0x1001a4e9c   bl   erts_factory_proc_prealloc_init(&f, proc, 2*3+4 = 10 words)
beam.smp   0x1001a4eb0   bl   erts_map_from_ks_and_vs(&f, keys, values, 3)
             0x1001ee638   memcpy(hp, keys, 24)         ; copies the Rust Vec verbatim
beam.smp   0x1001ee6d8   bl   erts_validate_and_sort_flatmap(mp)
             0x1001ee748   ldp  x1, x0, [x26]           ; x1 = ks[0], x0 = ks[1]
             0x1001ee760   bl   erts_cmp                ; insertion sort, ix = 1
beam.smp   0x10012fd5c   ldur x8, [x0, #-0x2]           ; <<<< FAULT, x0 = 0
```

**Register-derived facts** (identical in all three reports; only heap addresses
differ): `mp->size = 3`, `ix = 1`, `x0 = x1 = 0`. That is the *first* comparison
of the insertion sort, so `keys[0]` and `keys[1]` were both `THE_NON_VALUE`.
Nothing is knowable about `keys[2]` — had it been the bad one, `ix` would be 2.

Two traps worth recording: `beam.smp` contains **four** distinct static
`_erts_cmp` symbols (the crash used `0x10012fc70`, not the first one `nm`
reports), and `parse_value` **tail-calls** `parse_object`, which is why no
`parse_value` frame appears and why the crashing map is the *root* object.

### Why the fault address is `0xfffffffffffffffe`

`boxed_val(t) = t - TAG_PRIMARY_BOXED = t - 2`. `erts_cmp` screens operands with
`tbnz w0, #0` — **bit 0 only** — so a word with primary tag `0b00` reaches the
load. With `a = 0`, the address is `0 - 2 = 0xFFFFFFFFFFFFFFFE`, matching `far`
and `esr = 0x92000004` (level-0 translation fault, read). `THE_NON_VALUE == 0`
is confirmed: `enif_make_badarg` and `enif_raise_exception` both compile to
`mov x0, #0x0 ; ret`.

The same bit-0-only pattern appears in `enif_is_binary` and `enif_is_number`,
so those are **not** usable as guards — verified by deliberately crashing a VM.
`enif_is_atom` is tag-only and safe.

`enif_make_map_from_arrays` validates nothing: it passes the caller's pointers
straight through, and `erts_map_from_ks_and_vs` memcpys and sorts them.

---

## 3. Who zeroed the terms

### The reallocation

`parse_object` sizes its key vector with
`estimate_container_capacity(b'}', 30, 256) + 1`. With no structural index
(inputs < 256 bytes) that is `(remaining / 30).clamp(1, 256) + 1`. **Measured**,
not assumed:

```
MCP-shaped 3-key (37 B) : cap_before=2 -> 3rd push realloc=true  (0x…630080 -> 0x…670000)
tiny 3-key       (19 B) : cap_before=2 -> 3rd push realloc=true
3-key            (296 B): cap_before=3 -> no realloc
```

So a 3-key **root** object under 256 bytes reallocates 48 → 96 bytes on the third
push. `RawVec::grow_one` (new_cap = `max(2*cap, 4)`) and `finish_grow` are both
**correct**; `finish_grow` branches on `cbz x1` (old_cap == 0) and otherwise
calls `mi_realloc_aligned`, which must preserve the 48 bytes holding `keys[0]`
and `keys[1]`.

### The zero-byte copy

Inside mimalloc's `_mi_theap_realloc_zero`:

```
37e4c: ldr  x8, [x8, x9]        ; page-map level-1 entry
37e50: cbz  x8, ->0x37f9c       ; MISS
37e58: ldr  x26, [x8, x9, lsl #3]
37e5c: cbz  x26, ->0x37fa0      ; MISS
...
37fa0: mov  x22, #0x0           ; <<<< usable_size = 0
...
37f3c: cmp  x22, x20
37f40: csel x2, x22, x20, lo    ; copysize = min(usable_size, newsize)
37f4c: bl   memcpy              ; min(0, 96) = 0 bytes
37f54: bl   _mi_free            ; old block freed anyway
```

A page-map miss yields `usable_size = 0`, so the copy moves nothing and the
caller gets a fresh, uninitialised block — zeros on a fresh page. `keys[2]` is
written afterwards, directly into the new buffer.

### Why the lookup misses

**`librustycsv-v0.4.4` also statically links mimalloc.** My first pass wrongly
cleared it: `nm -a | grep mi_` returned 0 because its mimalloc symbols are
stripped. The code is unambiguously present:

| NIF | mimalloc strings | page map | fixed TLS slot `0x360` uses |
|---|---|---|---|
| `librustyjson` | yes | yes | 52 |
| `librustycsv` | yes | yes | 52 |
| `libencoding_rs_nif` | no | no | 0 |
| `beam.smp` | n/a | n/a | 0 |

Both read the per-thread heap from `TPIDRRO_EL0 + 0x360` (slot 108) while each
consults **its own private page map** (`adrp 0xd2000; ldr [x8, #0xcc0]`). A block
allocated while that slot held the other instance's heap is invisible to this
instance's page map — exactly the miss above.

Corroboration from the original crash: registers `x14 = 0x3c875c004c8` and
`x17 = 0x3c875c003c0`, which I initially dismissed as non-addresses, are
mimalloc arena pointers in the same high range as the reproduction's
`0x33742f60000`.

---

## 4. Reproduction

The instrument was a temporary `term_guard` cargo feature (off by default) with
three checkpoints: `check_produced` at key creation, `check_after_push` after
every push, and `check_arrays` immediately before the ERTS call. The post-push
checkpoint is the instruction-locating one, because `push` is the only step that
relocates terms.

It was removed once the root cause was proven — it is diagnostic scaffolding,
not part of the fix, and it added call sites to the hottest parse loop. It
remains in git history at commit `cbf9e21` if it is ever needed again.

Driver: `/tmp/dual_alloc_repro.exs` — interleave `RustyCSV.RFC4180.parse_string`
and `RustyJson.decode!` of a small 3-key root object across all schedulers.

```
[rustyjson term_guard] after_push: keys: len=3 cap_before=2 bad_index=0
  ptr=0x33742f60000 prev_ptr=0x33742e50060 reallocated=true
  words=[0000000000000000, 0000000000000000, 000000010f0b0c8a]
```

`keys[0] = keys[1] = 0`, `keys[2]` a valid boxed term (`…8a & 0b11 = 0b10`),
`len = 3`, realloc from capacity 2 — **bit-for-bit the production crash**.

---

## 5. Controls: ABI version is not the cause

Every ABI label below was read **from the built artifact** (following
`nif_init`'s constant reference), not from cargo's per-feature build dirs, which
report stale values. Each cell is a fresh build plus 200k interleaved ops.

| NIF ABI | Allocator | Result |
|---|---|---|
| 2.15 (rustler default) | mimalloc | **corrupted** (4 incidental runs) |
| **2.17** (production's) | mimalloc | **corrupted** |
| 2.17 | system | survived 200k |
| **2.18** (runtime-native) | mimalloc | **corrupted** |
| 2.18 | system | survived 200k |
| 2.17 | mimalloc + `local_dynamic_tls` | **corrupted** |
| — | RustyJson alone, no RustyCSV | survived 200k |

**The allocator is the sole discriminant.** Three different declared ABIs all
corrupt with mimalloc and all survive without it, so the 2.17-artifact-on-a-2.18-VM
theory is refuted rather than merely unsupported. A 2.18 rebuild passes only when
the allocator is also changed — the allocator-matched counterfactual (2.18 +
mimalloc) still corrupts, so **rebuilding for 2.18 is not a fix**.

`local_dynamic_tls` is also refuted: the fixed-slot accesses remain (74) because
mimalloc's macOS `__builtin_thread_pointer()` fast path is independent of the
`__thread` TLS model.

### Can rustler_precompiled ship 2.18?

**No.** `deps/rustler_precompiled/lib/rustler_precompiled/config.ex:33` sets
`@available_nif_versions ~w(2.14 2.15 2.16 2.17)`, and `nif_versions` is passed
through `validate_list!/3`. Requesting `"2.18"` raises at compile time. Rustler
0.38 itself *does* have `nif_version_2_18`, so a 2.18 artifact is buildable —
but only locally under `FORCE_RUSTYJSON_BUILD=1`, never downloaded or published.
This is an independent packaging limitation, unrelated to the crash.

---

## 6. Fix and regression coverage

**`native/rustyjson/Cargo.toml`: `default = ["mimalloc"]` → `default = []`.**
RustyJson no longer bundles an allocator; `mimalloc` remains opt-in with the
hazard documented inline. Proven green by cells B and D.

Removing mimalloc from *either* side fixes this pair — with only one instance,
the TLS slot is uncontested. RustyJson is the repo under change here, so it is
the side that gives way. **RustyCSV 0.4.4 should get the same treatment**, since
any other mimalloc-bundling NIF would re-create the hazard with it.

`test/allocator_isolation_test.exs` fails the build if the artifact ever links
a bundled allocator again. Verified in both directions: passes on the default
build, fails when one is enabled. This matters because the failure mode is
silent VM-wide heap corruption that no functional test can detect.

The allocator remains available for VMs where RustyJson is the only NIF
bundling one — it is worth ~20% on decode. See
[`ALLOCATOR_SAFETY.md`](ALLOCATOR_SAFETY.md) for the measurements, the audit
procedure, and the opt-in:

```sh
RUSTYJSON_ALLOCATOR=mimalloc FORCE_RUSTYJSON_BUILD=1 mix compile
```

Verification: **471 Elixir tests pass**, `cargo clippy` clean under the pinned
`nightly-2026-07-27` toolchain, guard never fired on the JSONTestSuite corpus
while it was installed.

---

## 7. The SBR `JSONProbe`

Sound for what it covers — capture before, `fsync`, delete in `after`, unique
`:exclusive` filename — but two coverage gaps: **eight modules call
`RustyJson.decode` directly** and bypass it, and **Tidewave decodes with `Jason`
everywhere** (`plug Tidewave` precedes `Plug.Parsers`), so MCP traffic never
reaches it. Plug-level bodies *are* covered because dev sets
`plug_init_mode: :runtime`.

It also distorts timing materially: `fsync` per decode deschedules the caller
onto dirty IO, and `term_to_binary` of the payload can trigger a GC immediately
before the decode. Given the root cause is now known, **the probe can be removed**
along with its config block.

---

## 8. Handoff

**Confidence: root cause proven.** Mechanism verified by disassembly, reproduced
on demand with a bit-for-bit register match, and confirmed by a 2×2 allocator ×
ABI control matrix plus a negative control (RustyJson alone).

**What is proven about who zeroed the terms:** mimalloc's `_mi_theap_realloc_zero`,
executing a `memcpy` of length `min(usable_size, newsize)` where `usable_size`
was 0 because the block was invisible to that instance's page map. The
triggering condition is two mimalloc copies sharing macOS TLS slot 108.

**What remains unknown (and does not affect the fix):** the exact scheduling that
flips slot ownership per thread; the crashing payload's bytes (predicted <256 B,
3-key root object — an MCP-shaped JSON-RPC request fits exactly); and whether
`values[]` was equally corrupted (unobservable — `erts_cmp` only compares keys,
but the values vector reallocates identically, so it almost certainly was).

**Files changed**

| Path | Change |
|---|---|
| `native/rustyjson/Cargo.toml` | `default = []` — the fix, with rationale |
| `test/allocator_isolation_test.exs` | **new** regression guard |
| `docs/ALLOCATOR_SAFETY.md` | **new** user-facing hazard + audit procedure |
| `lib/rustyjson.ex` | `RUSTYJSON_ALLOCATOR` opt-in |
| `.github/workflows/*.yml`, `rust-toolchain.toml` | pinned `nightly-2026-07-27` |

The parser itself is unchanged: `native/rustyjson/src/` is byte-identical to
`main`. The diagnostic instrumentation that found the bug lives in history at
`cbf9e21`.

**Next commands for the SBR agent**

```sh
# 1. Rebuild RustyJson from this branch without the bundled allocator.
cd /path/to/sold-by-robots
FORCE_RUSTYJSON_BUILD=1 mix deps.compile rustyjson --force

# 2. Confirm the artifact no longer links mimalloc (expect 0).
strings -a _build/dev/lib/rustyjson/priv/native/*.so | grep -c "^mimalloc: error: $"

# 3. Same check for rusty_csv (expect 1 today -- it should also drop mimalloc).
strings -a _build/dev/lib/rusty_csv/priv/native/*.so | grep -c "^mimalloc: error: $"

# 4. Run the dev server normally.

# 5. Remove the probe: delete lib/cinderbase/json_probe.ex and the
#    config/config.exs block that sets :phoenix, :json_library to it.
```

Reproduction harness kept in the session scratchpad (`zprobe.c`, `threads.py`,
`abi_of_so.py`, `matrix.sh`, `my-control-crashes/`). The two `.ips` files my own
control runs produced were moved out of `~/Library/Logs/DiagnosticReports/`, so
the three original crash reports remain the only `beam.smp` entries there.
