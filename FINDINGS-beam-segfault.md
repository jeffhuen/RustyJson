# beam.smp SIGSEGV in `enif_make_map_from_arrays` — independent investigation

Investigator: independent native-runtime review, 2026-08-25.
Worktree: `rustyjson-beam-crash-opus` (based on `origin/main`, RustyJson 0.4.0).

Everything below labelled **FACT** was verified against the exact crashing
binaries in this session. **INFERENCE** is reasoning over facts. **UNKNOWN** is
open. Prior claims I was asked to check are marked as confirmed or refuted, with
the method used.

---

## 0. Provenance of the artifacts analysed

**FACT.** The binaries I disassembled are the ones that crashed, not lookalikes:

| Image | Crash report identity | Local file | Match |
|---|---|---|---|
| `beam.smp` | slice UUID `CFE3E207-4B63-326A-8805-943EC7EFFC3F` | `/opt/homebrew/lib/erlang/erts-17.0.5/bin/beam.smp` | UUID identical |
| `librustyjson…nif-2.17-aarch64-apple-darwin.so` | UUID `A29ACC85-6B57-3B20-A30B-3E1783A7CDB4` | `_build/dev/lib/rustyjson/priv/native/…` | UUID identical, SHA-256 `441c13d0…7149b` identical |

The production artifact was never rebuilt or replaced. It remains the control.

---

## 1. Facts vs hypotheses

### Verified facts

| # | Fact | How verified |
|---|---|---|
| F1 | All three reports are the same fault: `EXC_BAD_ACCESS` / `SIGSEGV`, `KERN_INVALID_ADDRESS at 0xfffffffffffffffe`, `esr = 0x92000004` (data abort, translation fault level 0, **read**). Faulting thread is `erts_sched_1` — a **normal** scheduler, not dirty. | Parsed `.ips` JSON |
| F2 | The faulting instruction is `ldur x8, [x0, #-0x2]` at `_erts_cmp+0xEC` (static `0x10012fd5c`). | `llvm-objdump` of beam.smp; byte-for-byte match against the report's `instructionByteStream.atPC` |
| F3 | beam.smp contains **four** distinct static `_erts_cmp` symbols. The crash used the copy at `0x10012fc70`. Disassembling the first one `nm` reports gives a *different* instruction stream and would mislead. | `nm -n` |
| F4 | At the fault, `x0 == 0` **and** `x1 == 0`. `x0` is `erts_cmp`'s first argument and is never written on the path from entry to the faulting instruction. Both compared terms were the raw word `0`. | Register dump + instruction-by-instruction trace of the taken path |
| F5 | `THE_NON_VALUE == 0` on this build. | `enif_make_badarg` and `enif_raise_exception` both compile to `mov x0, #0x0 ; ret` |
| F6 | `erts_cmp` screens operands with `tbnz w0, #0` — **bit 0 only** — before dereferencing. A zero word is not filtered out. | Disassembly |
| F7 | Loop state in `erts_validate_and_sort_flatmap`: `x19 = mp->size = 3`, `x20 = ks`, `x21 = vs = ks + (n+3)` words, `x23 = ix = 1`, `x25/x26` equal to `x21/x20`. That is the **very first comparison of the insertion sort**: `ks[1]` vs `ks[0]`. | Disassembly of `_erts_validate_and_sort_flatmap` mapped onto the register dump |
| F8 | Therefore **`keys[0]` and `keys[1]` were both `THE_NON_VALUE`**. | F4 + F7 |
| F9 | All three crashes are identical in every register-derived quantity — `n=3`, `ix=1`, `x0=x1=0`. Only the heap addresses differ. | Cross-compared all three reports |
| F10 | RustyJson crash site: `bl map_from_term_arrays` at `.so+0x1e244`, return `0x1e248` = `parse_object+4152`. `parse_object` spans `[0x1d210, 0x1e418)`. | Disassembly + `nm` |
| F11 | It is the **plain multi-entry** path. `parse_object_shaped`, `parse_object_capture_shape`, `build_ordered_object` and `build_map_with_duplicates` all exist as separate symbols, so none was inlined into `parse_object`. The call site loads `(ptr,len)` pairs from stack slots (the `Vec`s), not the 1-element fast path. | `nm` + disassembly |
| F12 | The crashing map is the **root** JSON object. `decode_impl+1116` is the return address after `bl parse_value`, and `parse_value` **tail-calls** `parse_object` (`b 0x1d210` at `0x1b3dc`). One `parse_object` frame, returning into `decode_impl` ⇒ outermost object. | Disassembly |
| F13 | `enif_make_map_from_arrays` performs **no validation at all**. It passes the caller's pointers unchanged to `erts_map_from_ks_and_vs`, which `memcpy`s them onto the process heap and sorts them in place. | Disassembly |
| F14 | Rustler's `map_from_term_arrays` is correct: two `__rust_alloc` buffers, a copy loop reading `Term.term` at offset 0 with stride 24, the FFI call, and `__rust_dealloc` **after** the call. No use-after-free, no aliasing. | Disassembly of `.so+0x50e58…0x51070` |
| F15 | At the moment of the crash, **all 23 other threads were blocked in the kernel** (`__psynch_cvwait`, `kevent`, `__select`). No other NIF, no allocator, no ERTS heap code running anywhere. | Full thread dump of all 24 threads |
| F16 | The mechanism reproduces **exactly**: a purpose-built C NIF passing `keys = {0, 0, valid}` produces the same PC (`erts_cmp+236`), same fault address, `x0=x1=0`, `size=3`, `ix=1`. | `zprobe.so` + lldb |
| F17 | `enif_is_binary` and `enif_is_number` **also** dereference `boxed_val(x)` after testing only bit 0, so they crash on `THE_NON_VALUE` too. `enif_is_atom` is tag-only and safe. | Disassembly + a deliberately crashed VM |
| F18 | Default decode options set `intern_keys: false`, so `key_cache` is `None` on the Phoenix/Plug path. The interning branch is not merely unused — the cache is never allocated. | `lib/rustyjson.ex` `@default_decode_nif_opts` |
| F19 | There is **no `unsafe`** anywhere in RustyJson's decode path. | `grep`; only two comments mention the word |

### Inferences

| # | Inference | Confidence |
|---|---|---|
| I1 | RustyJson's `Vec<Term>` genuinely held raw `0` at indices 0 and 1 when `map_from_term_arrays` was called. The only alternative is that the freshly `__rust_alloc`'d `Vec<u64>` was zeroed in the few hundred nanoseconds between the copy loop and the FFI call, with no other thread running. | High |
| I2 | The payload's root object had exactly 3 keys. | High |
| I3 | Nothing is knowable about `keys[2]` — the sort crashes at `ix=1` before ever reading it. If `keys[0..1]` had been valid and only `keys[2]` bad, we would see `x23 = 2`. | Certain |

### Refuted or materially weakened

| # | Prior claim | Verdict |
|---|---|---|
| R1 | "mimalloc symbol interposition with RustCSV was ruled out" | **Confirmed, and now with a stated method.** `librustyjson.so` statically links mimalloc (175 symbols) but has **no `__DATA,__interpose` section** and exports no malloc-family symbols — so its mimalloc serves only Rust's `#[global_allocator]`, privately. `librustycsv.so` contains **zero** mimalloc symbols. There is no shared or duplicated allocator between them. |
| R2 | "Another NIF corrupted memory" | **Weakened.** Nothing else was executing at crash time (F15), and three crashes produced a byte-identical signature. Random cross-NIF corruption does not reproduce `n=3, ix=1, ks[0]=ks[1]=0` three times. |
| R3 | "Tidewave/MCP traffic is the trigger" | **Weakened.** Tidewave decodes and encodes with `Jason` directly in every call site (`control_socket.ex`, `router.ex`, `mcp/http.ex`, …) and `plug Tidewave` sits *before* `Plug.Parsers` in the endpoint. Tidewave's own JSON never reaches RustyJson. |
| R4 | "NIF 2.17 artifact on a 2.18-capable VM" | **No supporting evidence, and irrelevant to this fault.** The failure is a data fault on a term word, not an ABI mismatch. |
| R5 | "The bad term is in the keys array, not values" | **Confirmed by disassembly.** `erts_validate_and_sort_flatmap` compares only `ks[]`; `vs[]` is swapped in tandem but never passed to `erts_cmp`. |
| R6 | "Crash is the ordinary multi-entry `parse_object`, not the shape-cache call near line 1414" | **Confirmed** (F10, F11). |
| R7 | "Symbol begins near 0x1d210, crash frame 0x1e248 after a `bl` at 0x1e244" | **Confirmed exactly** (F10). |

### Unknowns

- **U1 — the central one.** *How* the zeros got into the `Vec<Term>`. See §4: no RustyJson code path can produce `THE_NON_VALUE`.
- U2. The payload. No probe capture exists from the crash window.
- U3. Whether `values[]` was also corrupted.

---

## 2. The exact call site, and what ERTS was doing

```
rustyjson  .so+0x1e244   bl   map_from_term_arrays          ; parse_object, multi-entry path
rustler    .so+0x5102c   blr  x8                            ; -> enif_make_map_from_arrays
beam.smp   0x1001a4e9c   bl   erts_factory_proc_prealloc_init(&f, env->proc, 2*3+4 = 10 words)
beam.smp   0x1001a4eb0   bl   erts_map_from_ks_and_vs(&f, keys, values, 3)
             0x1001ee624   *hp++ = make_arityval(3)
             0x1001ee638   memcpy(hp,      keys,   24)      ; <- copies the Rust Vec verbatim
             0x1001ee6d0   memcpy(mp+0x18, values, 24)
beam.smp   0x1001ee6d8   bl   erts_validate_and_sort_flatmap(mp)
             0x1001ee748   ldp  x1, x0, [x26]               ; x1 = ks[0], x0 = ks[1]
             0x1001ee760   bl   erts_cmp                    ; insertion sort, ix = 1
beam.smp   0x10012fd5c   ldur x8, [x0, #-0x2]               ; <<<< FAULT, x0 = 0
```

ERTS was performing the **first comparison of the insertion sort** that
`erts_map_from_ks_and_vs` runs to canonicalise a small (flat) map's key order.
The heap layout confirms the arithmetic: `vs - ks = 0x30` = 6 words = `n + 3`
with `n = 3`, and the allocation is exactly `2n + 4 = 10` words wide
(`0x114160628 … 0x114160678`, and `x3` held `0x114160678`).

`enif_make_map_from_arrays` is an **unchecked** API. It never inspects the words
it is given. Any invalid word is an immediate, unrecoverable VM kill.

---

## 3. Why the fault address is `0xfffffffffffffffe` — derived, not assumed

ERTS tags terms in the low bits: `TAG_PRIMARY_HEADER = 0b00`,
`LIST = 0b01`, `BOXED = 0b10`, `IMMED1 = 0b11`. A boxed term is dereferenced by
`boxed_val(t) = (Eterm *)(t - TAG_PRIMARY_BOXED)`, i.e. `t - 2`.

`erts_cmp`'s float fast path compiles to:

```asm
10012fd54:  tbnz  w0, #0, ->compound     ; bit 0 of a set?  -> not a pointer
10012fd58:  tbnz  w1, #0, ->compound     ; bit 0 of b set?
10012fd5c:  ldur  x8, [x0, #-0x2]        ; *boxed_val(a)          <<<< FAULT
10012fd60:  cmp   x8, #0x58              ; HEADER_FLONUM?
```

Only **bit 0** is tested. A word with primary tag `0b00` therefore reaches the
load. With `a = 0`:

```
addr = 0 - 2 = 0xFFFFFFFFFFFFFFFE
```

which is exactly the reported `far` and the reported subtype. `esr = 0x92000004`
decodes as a level-0 translation fault on a read — an address with no page table
entry at all, which `0xFFFF…FFFE` is by construction.

**So yes: the fault address is precisely the consequence of `boxed_val(0)`, and
the invalid raw term is exactly `0x0000000000000000` = `THE_NON_VALUE`.** This is
now derived from the disassembly of the exact binary and independently confirmed
by a live control experiment (F16), not asserted.

The same bit-0-only pattern appears in `enif_is_binary` and `enif_is_number`
(F17), which is why those are *not* usable as guards — I crashed a VM proving it.

---

## 4. Narrowest RustyJson paths that could furnish a malformed key

Keys reach the crashing array through exactly one route:

```
parse_object                        (direct_decode.rs:1157)
  -> parse_key                      (:660)  -> parse_string_impl(for_key = true)  (:567)
  -> keys.push(term)
  -> Term::map_from_term_arrays     (:1287-ish, the guarded call)
```

`parse_string_impl` has four term-producing exits. All were checked at source
**and** machine level (the compiled function's complete `bl` target list):

| Exit | Produces the term via | Can it yield `0`? |
|---|---|---|
| escaped string | `encode_binary` → `NewBinary::new` → `enif_make_new_binary` | **No.** The term is whatever `erts_new_binary` returns; there is no failure path, and Rustler panics if the data pointer is null. |
| `len >= 64` | `Binary::make_subbinary` → `enif_make_sub_binary` | **No.** Returns a heap-bits copy (≤64 B) or a sub-bits reference; no `THE_NON_VALUE` return. Out-of-range offsets return `Err` in Rust before the FFI call. |
| short string | `encode_binary` (as above) | **No.** |
| intern-cache hit | `FastHashMap<&[u8], Term>` lookup | **Not live.** `intern_keys` defaults to `false`, so the cache is `None` on the Phoenix path (F18). Even when enabled, the hasher is deterministic per parse and the stored terms come from `encode_binary`. |

Lifetime / Env / reallocation / FFI assumptions, all checked and all holding:

- **Env.** One `Env<'a>` for the whole call, taken from the NIF argument. No
  `OwnedEnv`, no `enif_alloc_env`, no message env, no `enif_schedule_nif`
  rescheduling. Every key term belongs to the same env as the map being built.
- **GC.** A plain NIF cannot be garbage-collected mid-call; `HAlloc` inside
  `enif_make_new_binary` allocates a *heap fragment* rather than collecting.
  `erts_factory_proc_prealloc_init` likewise does not collect. So terms held in
  Rust `Vec`s across the parse cannot go stale.
- **Reallocation.** `keys`/`values` are `Vec::with_capacity(cap)` then `push`ed.
  Safe Rust; a realloc copies before freeing. `Term` is `Copy`, 24 bytes, raw
  word at offset 0.
- **FFI.** Rustler copies `Term.term` into fresh `Vec<u64>`s and frees them only
  after the call returns (F14).
- **Memory safety.** No `unsafe` in the decode path (F19).

**Conclusion for §4: I could not find any path in RustyJson 0.4.0 that is
capable of placing `THE_NON_VALUE` in a key array.** This is a negative result
established at both source and machine-code level, and it is the reason no
root-cause patch is offered below.

---

## 5. Discriminating instrumentation — producer vs victim (implemented here)

Added: `native/rustyjson/src/term_guard.rs`, behind the **`term_guard` cargo
feature** (off by default, so released artifacts are unaffected).

Two checkpoints, deliberately separated in time:

1. **Producer checkpoint** — `parse_key` validates the term the instant it is
   created (`direct_decode.rs:660`).
2. **Consumer checkpoint** — `parse_object` validates both arrays immediately
   before `Term::map_from_term_arrays` (the exact call that crashed), plus the
   single-entry fast paths.

| Which fires | Conclusion |
|---|---|
| **producer** | RustyJson emitted an unusable term. **RustyJson defect.** |
| **consumer only** | The term was valid when created and became `0` while sitting in the `Vec`. **RustyJson is a victim** of memory corruption. |
| **neither**, VM still dies | The bad word is not `0`, or it is written inside the remaining ~hundreds-of-nanoseconds window. |

The check is arithmetic only — it must never call back into ERTS, because
`enif_is_binary`/`enif_is_number` reproduce the very crash being hunted (F17).
It rejects `THE_NON_VALUE` and any word with primary tag `0b00` (a header word,
never legal as a standalone term).

On a violation it writes an `fsync`ed forensic record — checkpoint, index, every
raw key/value word, byte offset, thread id, and **the complete input payload** —
to `$RUSTYJSON_GUARD_DIR` (default `/tmp/rustyjson-guard`), then raises a normal
decode error instead of letting the VM die. Unlike the Elixir-level probe this
works no matter which caller invoked the decode.

Build and run:

```sh
RUSTYJSON_TERM_GUARD=1 FORCE_RUSTYJSON_BUILD=1 mix compile
RUSTYJSON_GUARD_DIR=/var/tmp/rustyjson-guard  # optional, somewhere durable
```

**Verification performed:**

- `cargo test --lib term_guard` → 5/5 pass, including a case reconstructed from
  the actual crash registers (`keys = [0, 0, 0x11416060a]` → caught at index 0).
- Full Elixir suite with the guard **on**: **470 passed**, and the guard never
  fired — no false positives across the JSONTestSuite conformance fixtures.
- Full Elixir suite with the guard **off**: see §8.
- `cargo check` and `cargo clippy` clean in both configurations.

---

## 6. Patch status — deliberately **no** functional patch

I did not ship a "skip/repair invalid keys" change. §4 establishes that no known
RustyJson path can create the bad term, so such a change would be a placebo: it
would silence the symptom, destroy the evidence, and mislabel the cause.

The next observation that settles it is precisely the guard in §5: run the dev
server on a `term_guard` build until it trips. **Which checkpoint fires decides
the question**, and either way you get the payload.

If the producer checkpoint fires, the fix belongs in `parse_string_impl` and the
guard becomes the regression test. If only the consumer checkpoint fires, the
investigation moves to whatever is writing into RustyJson's heap — and the next
step there is a `MALLOC_PROTECT_BEFORE`/guard-page or ASan run, not a RustyJson
change.

Independently of root cause, one **API-hardening** observation is worth passing
upstream to Rustler: `Term::map_from_term_arrays` hands unvalidated words to an
ERTS entry point that cannot defend itself, turning any caller mistake into a VM
kill rather than a Rust error. A debug-assertion there would cost nothing in
release builds. That is a suggestion, not this crash's fix.

---

## 7. Assessment of the SBR `JSONProbe`

**Will it preserve the crashing payload?** For the traffic it covers, yes. The
design is sound: capture *before* the call, `fsync` before returning, delete in
an `after` block, unique filename, `:exclusive` open, `0700`/`0600` modes. A VM
kill leaves the in-flight captures behind, and the docstring correctly warns
that more than one may survive.

**Two real coverage gaps:**

1. **Direct callers bypass it entirely.** The probe is installed only as
   `config :phoenix, :json_library`. Eight modules call `RustyJson.decode/1,2`
   or `decode!` directly (`journal_entry_exporter.ex`, `reconciliation_reports.ex`,
   `accounts/user.ex`, `sqs_client.ex`, and four LiveViews). Those decodes are
   invisible to the probe. Given the crash is a **3-key root object**, this gap
   matters.
2. **Tidewave never routes through it.** Tidewave uses `Jason` directly
   everywhere, and `plug Tidewave` precedes `Plug.Parsers` in the endpoint. If
   MCP traffic is genuinely implicated, this probe will not see it.

Plug-level JSON bodies *are* covered: dev sets `plug_init_mode: :runtime`, so
`Phoenix.json_library()` in the endpoint's `Plug.Parsers` options resolves at
request time to `Cinderbase.JSONProbe`. (Worth knowing that `Phoenix.json_library/0`
uses `Application.get_env`, not `compile_env` — so it is *not* tracked as a
compile-time dependency. Under `:compile` init mode this config change would not
have forced a recompile and the probe would have been silently bypassed.)

**Does it change timing/behaviour too much?** Yes, materially — enough that I
would not trust a non-reproduction while it is enabled:

- `mkdir_p` + `chmod` + `open` + `write` + **`fsync`** + `rm` per decode. The
  file operations run on dirty-IO schedulers, so the calling process is
  **descheduled before every decode**.
- `:erlang.term_to_binary(capture)` copies the entire payload and allocates a
  large binary on the caller's heap immediately before the decode — which can
  trigger a GC and change the heap the map is later built on.

If the bug is at all sensitive to heap layout or scheduling, the probe plausibly
masks it. The in-NIF guard from §5 has none of these costs on the success path
and does not touch the filesystem unless a violation is detected — it is the
better instrument, and the two can run together.

---

## 8. Handoff

**Root-cause confidence**

- *Mechanism*: **certain.** A raw `0` (`THE_NON_VALUE`) in the keys array handed
  to `enif_make_map_from_arrays` is dereferenced as `boxed_val(0)` by `erts_cmp`
  during the flat-map key sort. Reproduced exactly, register for register.
- *Origin of the zero*: **unresolved.** RustyJson's `Vec<Term>` held `0` at
  indices 0 and 1 (high confidence), but **no RustyJson code path can produce
  `THE_NON_VALUE`** — verified at source and machine level. Producer vs victim
  is genuinely open; do not close it either way on current evidence.
- Do **not** treat "RustyJson is on the stack" as culpability, and do not treat
  my negative result as exoneration. The guard decides it.

**Files and lines**

| Path | Why |
|---|---|
| `native/rustyjson/src/direct_decode.rs:1319` | The crashing `Term::map_from_term_arrays(self.env, &keys, &values)` — `.so+0x1e244`. (Line 1287 in the unmodified tree, before the guard was inserted.) |
| `native/rustyjson/src/direct_decode.rs:661` | `parse_key` — the only key producer; producer checkpoint at :666 |
| `native/rustyjson/src/direct_decode.rs:567` | `parse_string_impl` — all four term-producing exits |
| `native/rustyjson/src/term_guard.rs` | **New.** The discriminator |
| `native/rustyjson/Cargo.toml` | **New** `term_guard` feature |
| `lib/rustyjson.ex` | `features: cargo_features`, driven by `RUSTYJSON_TERM_GUARD` |
| beam.smp `0x10012fd5c` | `erts_cmp+236`, the faulting instruction |

**Patch status**

- No functional change to decoding. Deliberate — see §6.
- Added: feature-gated instrumentation, 5 Rust unit tests, a documented build
  switch. Default build is behaviourally unchanged.

**Next commands**

```sh
# 1. Rust unit tests for the guard predicate
cd native/rustyjson && cargo test --lib term_guard

# 2. Build the dev server against a guard build and leave it running
cd /path/to/sold-by-robots
RUSTYJSON_TERM_GUARD=1 FORCE_RUSTYJSON_BUILD=1 \
  RUSTYJSON_GUARD_DIR=/var/tmp/rustyjson-guard mix phx.server

# 3. When it trips (or the VM dies again)
ls -t /var/tmp/rustyjson-guard        # which checkpoint fired -> producer or victim
ls -t /tmp/rustyjson-probe            # surviving JSONProbe captures
ls -t ~/Library/Logs/DiagnosticReports/beam.smp-*.ips

# 4. Re-read any new crash the same way (registers are the evidence, not the symbols)
python3 <scratchpad>/threads.py <report>.ips
```

**Also worth doing on the SBR side**

- Route the eight direct `RustyJson.decode` call sites through the probe, or
  rely on the in-NIF guard instead (it has no coverage gap).
- Keep the exact `.so` (`441c13d0…`) pinned as the control.

**Reproduction harness left in the scratchpad** (`zprobe.c`, `zprobe.erl`,
`threads.py`, `my-control-crashes/`): builds a C NIF that reproduces the crash
on demand, and proves `enif_is_binary` is unsafe on `THE_NON_VALUE`. The two
`.ips` files my own control runs generated were moved out of
`~/Library/Logs/DiagnosticReports/` so the three original reports remain the
only beam.smp crashes there.
