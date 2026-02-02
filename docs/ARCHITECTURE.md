# RustyJson Architecture

This document explains the architectural decisions behind RustyJson and compares NIF-based encoding to pure-Elixir approaches.

## Overview

RustyJson is a Rust NIF-based JSON library that prioritizes **memory efficiency** over theoretical purity. While pure-Elixir encoders return true iolists, RustyJson returns single binaries - a deliberate trade-off that yields 2-4x memory reduction during encoding and significantly reduced BEAM scheduler load.

## Encoding Architecture

### Pure Elixir Approach (iolist output)

```
Elixir Term
    │
    ▼
Protocol Dispatch (Encoder)
    │
    ▼
Build iolist incrementally
["{", ['"', "key", '"'], ":", "1", "}"]
    │
    ▼
Return iolist (many small binaries)
```

**Characteristics:**
- Many small BEAM binary allocations
- Each struct/map/list creates nested list structures
- BEAM owns all memory from the start
- Can theoretically stream to sockets without flattening

### RustyJson's Approach (Rust NIF, Single Binary)

```
Elixir Term
    │
    ▼
Optional: Protocol Dispatch (RustyJson.Encoder)
    │
    ▼
NIF Call ──────────────────────────┐
    │                              │
    ▼                              │ Rust
Walk term tree directly            │
Write to single buffer (mimalloc)  │
    │                              │
    ▼                              │
Copy buffer to BEAM binary ────────┘
    │
    ▼
Return single binary
```

**Characteristics:**
- One buffer allocation in Rust
- No intermediate Elixir terms created
- Single copy from Rust → BEAM at the end
- Must complete encoding before returning

## Memory Comparison

For a 2MB JSON payload (canada.json benchmark):

| Phase | Jason | RustyJson |
|-------|-------|-----------|
| Input term | ~6 MB | ~6 MB |
| During encoding | +5.8 MB (iolist allocations) | +2.4 MB (single binary) |
| BEAM reductions | ~964,000 | ~3,500 (275x fewer) |
| Final output | 2 MB iolist | 2 MB binary |

The difference comes from iolist-based encoding creating many intermediate allocations during recursive encoding, while RustyJson builds a single buffer in Rust and copies once to BEAM.

**Note:** Memory measurements use `:erlang.memory(:total)` delta. See [BENCHMARKS.md](BENCHMARKS.md) for methodology and why Benchee memory measurements don't work for NIFs.

## Safety Analysis

### The NIF Safety Question

A common concern with NIFs is: "What if it crashes and takes down my entire BEAM VM?"

This is a valid concern for C-based NIFs, where a single buffer overflow, null pointer dereference, or use-after-free can crash the VM. However, **RustyJson contains zero `unsafe` code** — not minimized, not audited, literally zero — making VM crashes from our code effectively impossible.

### 1. Rust's Compile-Time Memory Safety

Rust eliminates entire categories of bugs at compile time:

| Bug Category | C/C++ NIF | Rust NIF | How Rust Prevents |
|--------------|-----------|----------|-------------------|
| Null pointer dereference | Runtime crash | Won't compile | `Option<T>` forces handling |
| Buffer overflow | Runtime crash | Won't compile | Bounds checking enforced |
| Use after free | Runtime crash | Won't compile | Ownership system |
| Double free | Runtime crash | Won't compile | Single owner rule |
| Data races | Undefined behavior | Won't compile | Send/Sync traits |
| Uninitialized memory | Undefined behavior | Won't compile | All values initialized |

These aren't runtime checks that could be bypassed—the Rust compiler literally refuses to produce code with these bugs.

#### 2. Rustler's Safety Layer

[Rustler](https://github.com/rusterlium/rustler) adds BEAM-specific protections on top of Rust's compile-time guarantees:

- **Panic catching**: Rustler wraps every NIF call in `std::panic::catch_unwind`. If any Rust code panics (e.g., an unexpected `unwrap()` failure), the panic is caught at the FFI boundary and converted to an Elixir exception. This is critical because an uncaught Rust panic unwinding across the C FFI boundary into the BEAM would be undefined behavior. With Rustler, a panic cannot crash the VM — it becomes a normal Elixir error.
- **Term safety**: All Erlang term manipulation goes through safe APIs that validate types. You cannot accidentally create an invalid term or corrupt the BEAM heap.
- **No raw pointers**: Rustler's `Term` type wraps raw BEAM pointers safely. Direct pointer arithmetic is never exposed to NIF authors.
- **Lifetime enforcement**: Rust's borrow checker ensures terms aren't used after their owning `Env` scope ends. This prevents use-after-free bugs that plague C-based NIFs.
- **Resource objects**: Rustler manages Rust structs passed to Erlang via reference-counted resource objects. The struct is automatically dropped when no longer referenced — no manual cleanup, no leaks.

#### 3. Zero `unsafe` — Portable SIMD via `std::simd`

RustyJson uses Rust's `std::simd` (portable SIMD) for all vectorized operations. This is a safe abstraction over hardware SIMD — the compiler generates optimal instructions for each target automatically:

- **x86_64**: SSE2 (16-byte chunks), AVX2 (32-byte chunks) when the compile target supports it
- **aarch64**: NEON (16-byte chunks)
- **Other targets**: Scalar fallback emitted by the compiler

There is **no `unsafe` code** in RustyJson. No raw SIMD intrinsics, no `std::arch::*` imports, no runtime feature detection, no `#[cfg(target_arch)]` branching. One codepath per pattern, portable across all targets.

**`std::simd` API discipline:**

The `portable_simd` feature gate is unstable, but not all APIs behind it are equally risky. The [critical stabilization blockers](https://github.com/rust-lang/portable-simd/issues/364) are swizzle (blocked on const generics), mask element types, and lane count bounds — none of which we use. RustyJson only relies on the uncontroversial subset that has no open design questions:

- `Simd::from_slice`, `Simd::splat` — vector construction
- `simd_eq`, `simd_lt`, `simd_ge` — comparison operators
- `Mask::any`, `Mask::all`, `Mask::to_bitmask` — mask operations
- `Mask` bitwise ops (`|`, `&`, `!`) — combining conditions

These APIs have stable semantics today. If `portable_simd` is split into independently-stabilizable feature gates (as discussed in the tracking issue), the subset we use would be first in line.

We explicitly avoid APIs blocked from stabilization: `simd_swizzle!`, `Simd::scatter/gather`, `Simd::interleave/deinterleave`, `SimdFloat::to_int_unchecked`, `Simd::resize`, and `Simd::rotate_elements_left/right`. These are documented in `simd_utils.rs` as a DO NOT USE list.

**SIMD scanning patterns** (all in `simd_utils.rs`):
1. **String scanning**: Skip past plain string bytes (no `"`, `\`, or control chars)
2. **Structural detection**: Find JSON structural characters (`{}[],:"\`)
3. **Whitespace skipping**: Skip contiguous whitespace chunks
4. **Escape finding**: Locate the first byte needing JSON/HTML/Unicode/JavaScript escaping

Each function processes 32-byte wide chunks on AVX2 targets, then 16-byte chunks, with a scalar tail for remaining bytes.

**Our source files:**

| File | Purpose | `unsafe` |
|------|---------|----------|
| `lib.rs` | NIF entry point, feature flags | None |
| `simd_utils.rs` | Portable SIMD scanning (all patterns) | None |
| `direct_json.rs` | JSON encoder | None |
| `direct_decode.rs` | JSON decoder | None |
| `nif_binary_writer.rs` | Growable NIF binary | None |
| `compression.rs` | Gzip compression | None |
| `decimal.rs` | Decimal handling | None |
| **Total** | | **None** |

**Design choices that eliminate unsafe:**

1. **`&str` over `&[u8]`** — UTF-8 validity guaranteed at compile time
2. **`.get()` over indexing** — Returns `Option` instead of panicking
3. **`while let Some()`** — Idiomatic safe iteration pattern
4. **`std::simd` over `std::arch`** — Portable SIMD with no `unsafe` blocks

**Where `unsafe` does exist (dependencies only):**

| Dependency | Purpose | Trust Level |
|------------|---------|-------------|
| Rustler | NIF ↔ BEAM bridge | High — 10+ years, 500+ projects |
| mimalloc | Memory allocator | High — Microsoft, battle-tested |
| Rust stdlib | Core functionality | Highest — Rust core team |

Any memory safety bug would have to originate in a dependency, not in RustyJson code.

#### 4. Explicit Resource Limits

We enforce limits that prevent resource exhaustion:

| Resource | Limit | Rationale |
|----------|-------|-----------|
| Nesting depth | 128 levels | Prevents stack overflow, per RFC 7159 |
| Recursion | Bounded by depth | No unbounded recursion possible |
| Intern cache keys | 4096 unique keys | Bounds hash collision worst-case; stops cache overhead for pathological input |
| Input size | Configurable (`max_bytes`) | Prevents memory exhaustion from oversized payloads |
| Allocation | System memory | Same as pure Elixir |

#### 5. Continuous Fuzzing

We use [cargo-fuzz](https://github.com/rust-fuzz/cargo-fuzz) (libFuzzer + AddressSanitizer) to test
boundary correctness. Six fuzz targets cover string scanning, structural index building, whitespace skipping,
number parsing, escape decoding, and encode-side escape scanning. Seed corpora include synthetic inputs at
SIMD chunk boundaries (8/16/32 bytes) and the full JSONTestSuite.

### What Would Actually Need to Go Wrong?

For RustyJson to crash the VM, one of these would need to happen:

| Scenario | Likelihood | Why It's Unlikely |
|----------|------------|-------------------|
| Bug in Rustler | Extremely low | Mature library, used in production by many projects |
| Bug in Rust compiler | Essentially zero | Rust compiler is formally verified for memory safety |
| Bug in mimalloc | Extremely low | Microsoft's allocator, battle-tested |

None of these are RustyJson bugs — they're infrastructure bugs that would affect any Rust-based system.

### Our Position

We consider RustyJson **as safe as pure Elixir code** for the following reasons:

1. **Safe Rust is memory-safe by construction**. The compiler guarantees it.

2. **Rustler catches panics at the FFI boundary** via `catch_unwind`, converting them to Elixir exceptions. A Rust panic cannot crash the BEAM VM.

3. **Zero `unsafe` code**. The entire codebase — including SIMD — is safe Rust. Portable SIMD via `std::simd` lets the compiler generate optimal vector instructions without requiring `unsafe` blocks.

4. **Resource limits are enforced** (depth, recursion, intern cache cap).

The "NIFs can crash your VM" warning applies to **C-based NIFs** where a single bug can corrupt memory. It does not meaningfully apply to safe Rust NIFs, which have the same memory safety guarantees as the BEAM itself.

### When to Consider Alternatives

If you require defense-in-depth for untrusted input, you could:

1. **Run encoding in a Task**: Crashes isolated to that process
2. **Use Jason for untrusted input**: Pure Elixir, cannot crash VM
3. **Add pre-validation**: Check input structure before encoding

However, we believe these are unnecessary for RustyJson given the safety guarantees above.

### Garbage Collection

| Aspect | Jason | RustyJson |
|--------|-------|-----------|
| Allocation pattern | Many small binaries | One large binary |
| GC type | Regular + refc | Refc only |
| GC timing | Incremental | Atomic release |
| Memory spike | During encoding | Brief, at copy |

**Refc binaries** (>64 bytes) are reference-counted and stored outside the process heap. RustyJson always produces refc binaries for non-trivial output.

## Performance Characteristics

### Encode vs Decode: Why They Differ

**Encoding** is where RustyJson has the biggest advantage:
- Pure-Elixir encoders create many small iolist allocations on BEAM heap
- RustyJson builds one buffer in Rust, copies once to BEAM
- Result: 3-6x faster, 2-3x less memory, 100-28,000x fewer BEAM reductions

**Decoding** shows smaller gains:
- Both produce identical Elixir data structures (maps, lists, strings)
- Final memory usage is similar (same data, same BEAM terms)
- RustyJson is 2-3x faster due to optimized parsing
- But memory advantage is minimal since output is the same

### Why Larger Files Show Bigger Gains

RustyJson's encoding advantage scales with payload size:

| Payload Size | Speed Advantage | Memory Advantage | Reductions |
|--------------|-----------------|------------------|------------|
| < 1 KB | ~1x (NIF overhead) | similar | ~10x fewer |
| 1-2 MB | 2-3x faster | 2-3x less | 200-2000x fewer |
| 10+ MB | 5-6x faster | 2-3x less | 28,000x fewer |

This is because:
1. **NIF call overhead** is fixed (~0.1ms) regardless of payload size
2. **Allocation overhead** grows with payload - iolist-based encoding creates many small allocations that compound
3. **BEAM reductions** scale linearly with work - pure-Elixir encoders do all work in BEAM, RustyJson offloads to native code

### When Pure-Elixir Wins

1. **Tiny payloads (<100 bytes)**: NIF call overhead exceeds encoding time
2. **Streaming scenarios**: True iolists can be sent to sockets incrementally
3. **Partial failure recovery**: Failed encodes don't leave large allocations

### When RustyJson Wins

1. **Large payloads (1MB+)**: 5-6x faster, 2-3x less memory, 28,000x fewer reductions
2. **Medium payloads (1KB-1MB)**: 2-3x faster, 2-3x less memory
3. **High-throughput APIs**: Dramatically reduced BEAM scheduler load
4. **Memory-constrained environments**: Lower peak memory usage

### Real-World Performance

**Amazon Settlement Reports (10 MB JSON files):**

| Operation | RustyJson | Jason | Speed | Memory |
|-----------|-----------|-------|-------|--------|
| Encode | 24 ms | 131 ms | **5.5x faster** | **2.7x less** |
| Decode | 61 ms | 152 ms | **2.5x faster** | similar |

**Synthetic benchmarks ([nativejson-benchmark](https://github.com/miloyip/nativejson-benchmark)):**

| Dataset | RustyJson | Jason | Speedup |
|---------|-----------|-------|---------|
| canada.json (2.1MB) roundtrip | 14 ms | 48 ms | 3.4x faster |
| citm_catalog.json (1.6MB) roundtrip | 6 ms | 14 ms | 2.5x faster |
| twitter.json (617KB) roundtrip | 4 ms | 9 ms | 2.3x faster |

Real-world API responses show better results than synthetic benchmarks because they have more complex nested structures and mixed data types.

See [BENCHMARKS.md](BENCHMARKS.md) for detailed methodology.

## Protocol Architecture

### Default Path (Protocol Enabled)

```
RustyJson.encode!(data)
        │
        ▼
RustyJson.Encoder.encode/2
        │
        ▼
  Protocol dispatch
  (Map, List, Tuple, Fragment, Any, custom)
        │
        ▼
  Resolve function-based Fragments
        │
        ▼
    Rust NIF
```

By default (`protocol: true`), encoding goes through the `RustyJson.Encoder` protocol, matching Jason's behavior. Built-in type implementations (strings, numbers, atoms, maps, lists) pass through unchanged, so overhead is minimal. Custom `@derive` or `defimpl` implementations preprocess data before the NIF.

Structs without an explicit `RustyJson.Encoder` implementation raise `Protocol.UndefinedError`. RustyJson is a complete Jason replacement and has no runtime dependency on Jason.

### Bypass Path (Maximum Performance)

```
RustyJson.encode!(data, protocol: false)
        │
        ▼
  Resolve function-based Fragments
        │
        ▼
    Rust NIF
        │
        ▼
  Direct term walking
  (no Elixir preprocessing)
```

With `protocol: false`, the Rust NIF walks the term tree directly. Function-based Fragments (from `json_map`, `OrderedObject`, etc.) are still resolved in Elixir before sending to the NIF.

## Decoding Architecture

### Pure Elixir Approach

```
JSON String
    │
    ▼
Recursive descent parser (Elixir)
    │
    ▼
Build Elixir terms during parse
    │
    ▼
Return term
```

### RustyJson (NIF) Approach

```
JSON String
    │
    ▼
NIF Call ──────────────────────────┐
    │                              │
    ▼                              │ Rust
Custom parser                      │
Build Erlang terms via Rustler     │
Zero-copy strings when possible    │
    │                              │
    ▼ ─────────────────────────────┘
Return term (already on BEAM heap)
```

Decoding builds terms directly on the BEAM heap via Rustler's term API, avoiding intermediate Rust allocations.

## Fragment Architecture

Fragments allow injecting pre-encoded JSON:

```
%RustyJson.Fragment{encode: ~s({"pre":"encoded"})}
        │
        ▼
    Rust NIF
        │
        ▼
  Detect Fragment struct
  Write iodata directly to buffer
  (no re-encoding)
```

This is critical for:
- PostgreSQL `jsonb_agg` results
- Cached JSON responses
- Third-party API proxying

## Design Decisions

### Why Single Binary Instead of iolist?

1. **Memory efficiency**: The 2-4x memory reduction and 100-2000x fewer BEAM reductions outweigh the theoretical benefits of iolists.

2. **Phoenix flattens anyway**: `Plug.Conn` typically calls `IO.iodata_to_binary/1` before sending responses.

3. **Simpler NIF interface**: Returning a single binary is cleaner than building nested Erlang lists in Rust.

4. **Predictable performance**: Single allocation is easier to reason about than many small ones.

### Why Protocol-by-Default with Opt-Out?

1. **Jason compatibility**: Jason always dispatches through its Encoder protocol. Using `protocol: true` as the default ensures drop-in behavior.

2. **Minimal overhead for built-in types**: Primitive types (strings, numbers, atoms) have pass-through implementations that add negligible cost.

3. **Custom encoding**: Supports `@derive RustyJson.Encoder` for struct field filtering, and falls back to `Jason.Encoder` for interop.

4. **Opt-out for performance**: Use `protocol: false` to bypass the protocol entirely when you have no custom encoders and want maximum throughput.

### Why 128-Level Depth Limit?

1. **RFC 7159 compliance**: The spec recommends implementations limit nesting.

2. **Stack safety**: Prevents stack overflow in recursive encoding/decoding.

3. **DoS protection**: Malicious deeply-nested JSON can't exhaust resources.

## JSON Specification Compliance

RustyJson is fully compliant with [RFC 8259](https://tools.ietf.org/html/rfc8259) (The JavaScript Object Notation Data Interchange Format) and [ECMA-404](https://www.ecma-international.org/publications-and-standards/standards/ecma-404/).

### Compliance Summary

| RFC 8259 Section | Description | Status |
|------------------|-------------|--------|
| §2 | Structural tokens (`{}`, `[]`, `:`, `,`) | ✓ Compliant |
| §2 | Whitespace (space, tab, LF, CR) | ✓ Compliant |
| §3 | Values (`null`, `true`, `false`) | ✓ Compliant |
| §4 | Objects (string keys, any values) | ✓ Compliant |
| §5 | Arrays (ordered values) | ✓ Compliant |
| §6 | Numbers (integer, fraction, exponent) | ✓ Compliant |
| §7 | Strings (UTF-8, escapes, unicode) | ✓ Compliant |

### Intentional Deviation: Lone Surrogates

RustyJson **rejects lone Unicode surrogates** (e.g., `\uD800` without a trailing low surrogate).

```elixir
# Valid surrogate pair - accepted
RustyJson.decode(~s(["\\uD834\\uDD1E"]))  # => {:ok, ["𝄞"]}

# Lone high surrogate - rejected
RustyJson.decode(~s(["\\uD800"]))  # => {:error, "Lone surrogate in string"}

# Lone low surrogate - rejected
RustyJson.decode(~s(["\\uDC00"]))  # => {:error, "Lone surrogate in string"}
```

**Why we reject lone surrogates:**

1. **RFC 7493 (I-JSON) recommendation**: The "Internet JSON" profile explicitly recommends rejecting lone surrogates for interoperability.

2. **Security**: Lone surrogates can cause issues in downstream systems that expect valid UTF-8/UTF-16.

3. **Industry consensus**: Most modern JSON parsers (including Jason, Python's `json`, Go's `encoding/json`) reject lone surrogates.

4. **RFC 8259 allows this**: The spec says implementations "MAY" accept lone surrogates, not "MUST".

### Invalid JSON Handling

RustyJson correctly rejects all invalid JSON with descriptive error messages:

| Invalid Input | Error |
|---------------|-------|
| `{a: 1}` | Unquoted object key |
| `[1,]` | Trailing comma |
| `[01]` | Leading zeros in numbers |
| `[NaN]` | NaN not valid JSON |
| `[Infinity]` | Infinity not valid JSON |
| `["\\x00"]` | Invalid escape sequence |
| `{'a': 1}` | Single quotes not allowed |

### Error Handling Philosophy

RustyJson prioritizes **clear, actionable error messages** and **consistent error handling**.

**Clear error messages:**

Error messages describe the problem, not just its location:

```elixir
RustyJson.decode("{\"foo\":\"bar\\'s\"}")
# => {:error, "Invalid escape sequence: \\'"}

RustyJson.decode("[1, 2,]")
# => {:error, "Expected value at position 6"}
```

**Structured error returns:**

`encode/2` and `decode/2` return structured error structs for detailed diagnostics:

```elixir
RustyJson.encode(%{{:a, :b} => 1})
# => {:error, %RustyJson.EncodeError{message: "Map key must be atom, string, or integer"}}

RustyJson.decode("invalid")
# => {:error, %RustyJson.DecodeError{message: "...", position: 0, data: "invalid", token: "invalid"}}
```

This makes error handling predictable—pattern match on results without needing `try/rescue`.

### Test Coverage

RustyJson has been validated against the comprehensive [JSONTestSuite](https://github.com/nst/JSONTestSuite) by Nicolas Seriot:

| Category | Result | Description |
|----------|--------|-------------|
| **y_* (must accept)** | 95/95 ✓ | Valid JSON that parsers MUST accept |
| **n_* (must reject)** | 188/188 ✓ | Invalid JSON that parsers MUST reject |
| **i_* (implementation-defined)** | 15 accept, 20 reject | Edge cases where behavior is unspecified |

**Total mandatory compliance: 283/283 (100%)**

RustyJson also passes the [nativejson-benchmark](https://github.com/miloyip/nativejson-benchmark) conformance tests:
- Parse Validation (JSON_checker test suite)
- Parse Double (66 decimal precision tests)
- Parse String (9 string tests)
- Roundtrip (27 JSON roundtrip tests)

### Implementation-Defined Behavior

For the 35 implementation-defined tests (`i_*`), RustyJson makes these choices:

**Accepted (5 tests):**
- Numbers that underflow to zero or convert to large integers

**Rejected (30 tests):**
- Invalid UTF-8 byte sequences in strings (`validate_strings` defaults to `true`, matching Jason)
- Numbers with exponents that overflow (e.g., `1e9999`)
- Lone Unicode surrogates in `\uXXXX` escapes (per RFC 7493 I-JSON)
- Non-UTF-8 encodings (UTF-16, BOM)
- Nesting deeper than 128 levels

See `test/json_test_suite_test.exs` for the complete list with explanations.

## What We Learned

### SIMD Is Actually Slower

We tested SIMD-accelerated parsers like simd-json and sonic-rs. The SIMD parsing gains were negated by the serde conversion overhead.

Why? The bottleneck for JSON NIFs isn't parsing—it's **building Erlang terms**. SIMD libraries optimize for parsing JSON into native data structures, but for Elixir we need to:
1. Parse JSON → intermediate Rust types (serde)
2. Convert Rust types → BEAM terms
3. Copy data to BEAM heap

This double conversion negates SIMD's parsing speed advantage. Our approach skips the intermediate step entirely—we walk JSON bytes and build BEAM terms directly in one pass.

### The Real Wins

The performance gains come from:
1. **Avoiding intermediate allocations** - No serde, no Rust structs
2. **Direct term building** - Walk input once, write BEAM terms directly
3. **Single output buffer** - One allocation instead of many iolist fragments
4. **Good memory allocator** - mimalloc reduces fragmentation

### Scheduler Strategy

BEAM documentation recommends NIFs complete in under 1 millisecond to maintain scheduler fairness. RustyJson exceeds this for large payloads (10 MB encode takes ~24ms). Dirty schedulers run NIFs on separate threads to avoid blocking normal schedulers.

We benchmarked dirty schedulers and found they **hurt performance for small payloads**:

| Payload | Normal | Dirty | Result |
|---------|--------|-------|--------|
| 1 KB encode | 9 µs | 62 µs | **Dirty 7x slower** |
| 10 KB encode | 177 µs | 136 µs | Dirty 23% faster |
| 5 MB encode | 43 ms | 43 ms | Similar |

Under concurrent load (50 processes), normal schedulers had **1.7x higher throughput** for encoding and **2.2x higher** for decoding with small payloads.

**Why dirty schedulers hurt for small payloads**:
1. **Migration overhead** - Process must migrate to dirty scheduler pool and back
2. **Limited pool** - Only N dirty CPU schedulers (N = CPU cores), creating bottlenecks
3. **Cache effects** - Different thread means cold CPU caches

**Hybrid approach**: Now that the library is mature, RustyJson offers automatic dispatch that avoids the small-payload penalty while protecting against scheduler blocking on large inputs:

- **Decode**: Auto-dispatches to dirty scheduler when `byte_size(input) >= dirty_threshold` (default: 100KB). This is a cheap check and a reasonable proxy for work. Set `dirty_threshold: 0` to disable.
- **Encode**: Explicit opt-in via `scheduler: :dirty`. Can't cheaply estimate output size, so auto-dispatch is only triggered when `compress: :gzip` is used (compression is always CPU-heavy). Use `scheduler: :normal` to force normal scheduler.

This preserves the performance advantage for small payloads (the common case) while preventing scheduler blocking for large inputs.

## Decode Strategies

RustyJson supports optional decode strategies that can significantly improve performance for specific data patterns.

### Key Interning (`keys: :intern`)

When decoding arrays of objects with the same schema (repeated keys), key interning caches string keys to avoid re-allocating them for each object.

```elixir
# Default - no interning
RustyJson.decode!(json)

# Enable key interning for homogeneous arrays
RustyJson.decode!(json, keys: :intern)
```

**How it works:**

Without interning (default):
```
[{"id":1,"name":"a"}, {"id":2,"name":"b"}, ...]
      ↓
Allocate "id" string (object 1)
Allocate "name" string (object 1)
Allocate "id" string (object 2)    ← duplicate allocation
Allocate "name" string (object 2)  ← duplicate allocation
... × N objects
```

With interning:
```
[{"id":1,"name":"a"}, {"id":2,"name":"b"}, ...]
      ↓
Allocate "id" string (object 1)
Allocate "name" string (object 1)
Reuse "id" reference (object 2)    ← cache hit
Reuse "name" reference (object 2)  ← cache hit
... × N objects
```

**Implementation details:**

*Hasher choice:* We use a hand-rolled FNV-1a hasher with a per-parse randomized seed instead of Rust's default SipHash. SipHash is DoS-resistant but ~3x slower for short keys, which would negate the performance benefit of interning. The randomized seed (time + stack address) blocks precomputed collision tables. An adaptive attacker measuring aggregate decode latency across many requests could still craft collisions, but the `MAX_INTERN_KEYS` cap (see below) bounds the damage to O(cap²) operations — a few milliseconds, not a DoS.

*Parser design:* Rather than duplicating string parsing logic, we refactored to `parse_string_impl(for_key: bool)`. This single implementation handles both string values (`for_key: false`) and object keys (`for_key: true`), with interning logic gated behind the `for_key` flag and cache presence check. This avoids code duplication while ensuring interning overhead is zero when disabled.

*Escaped keys:* Keys containing escape sequences (e.g., `"field\nname"`) are NOT interned. The raw JSON bytes (`field\nname`) differ from the decoded string (`field<newline>name`), so we can't use the input slice as a cache key. This is rare in practice—object keys almost never contain escapes.

*Cache cap:* The cache stops accepting new entries after `MAX_INTERN_KEYS` (4096) unique keys. Beyond that threshold, new keys are allocated normally (no worse than default mode without interning). This serves two purposes: (1) **performance** — when unique key count is high, the cache is clearly not helping and growing it further is pure overhead; (2) **DoS mitigation** — bounds worst-case CPU time from hash collisions to O(4096²) operations regardless of hash quality. The cap is internal and not user-configurable; 4096 is far above any realistic JSON schema key count.

*Memory:* Cache is pre-allocated with 32 slots and grows as needed up to the cap. Dropped automatically when parsing completes (no cleanup required).

**When to use `keys: :intern`:**

| Use Case | Benefit |
|----------|---------|
| API responses (arrays of records) | **~30% faster** |
| Database query results | **~30% faster** |
| Log/event streams | **~30% faster** |
| Bulk data imports | **~30% faster** |

**When NOT to use `keys: :intern`:**

| Use Case | Penalty |
|----------|---------|
| Single configuration object | **2.5-3x slower** |
| Heterogeneous arrays (different keys) | **2.5-3x slower** |
| Unknown/variable schemas | **2.5-3x slower** |

The overhead comes from maintaining a HashMap cache (using FNV-1a hashing). When keys aren't reused, you pay the cache cost without any benefit.

**Benchmark results (pure Rust parsing):**

| Scenario | Default | `keys: :intern` | Result |
|----------|---------|-----------------|--------|
| 10k objects × 5 keys | 3.46 ms | 2.45 ms | **29% faster** |
| 10k objects × 10 keys | 6.92 ms | 4.88 ms | **29% faster** |
| Single object, 1000 keys | 52 µs | 169 µs | **3.2x slower** |
| Heterogeneous 500 objects | 186 µs | 475 µs | **2.5x slower** |

See [BENCHMARKS.md](BENCHMARKS.md#key-interning-benchmarks) for detailed results.

## Future Considerations

### Potential Optimizations

1. **Chunked output**: For 100MB+ payloads, returning iolists could reduce memory spikes.

2. **Streaming decode**: Parse JSON incrementally for very large inputs.

### Not Planned

1. **SIMD parsing**: SIMD libraries require an intermediate serde step, negating the parsing speed gains when building BEAM terms.

2. **True iolist output**: The complexity isn't justified by real-world benefits.

3. **`unsafe` Rust**: The codebase is entirely safe Rust, including SIMD. We intend to keep it that way.

4. **Custom allocators per-call**: mimalloc is fast enough globally.

## References

- [Rustler](https://github.com/rusterlium/rustler) - Safe Rust NIFs for Erlang/Elixir
- [Jason](https://github.com/michalmuskala/jason) - Reference implementation
- [RFC 8259](https://tools.ietf.org/html/rfc8259) - The JavaScript Object Notation (JSON) Data Interchange Format
- [RFC 7493](https://tools.ietf.org/html/rfc7493) - The I-JSON Message Format (Internet JSON profile)
- [ECMA-404](https://www.ecma-international.org/publications-and-standards/standards/ecma-404/) - The JSON Data Interchange Syntax
- [JSONTestSuite](https://github.com/nst/JSONTestSuite) - Comprehensive JSON parser test suite
- [nativejson-benchmark](https://github.com/miloyip/nativejson-benchmark) - JSON conformance and performance benchmark
- [mimalloc](https://github.com/microsoft/mimalloc) - Memory allocator
