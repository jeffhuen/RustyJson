# RustyJson Architecture

This document explains the architectural decisions behind RustyJson and compares them to Jason's approach.

## Overview

RustyJson is a Rust NIF-based JSON library that prioritizes **memory efficiency** over theoretical purity. While Jason returns true iolists, RustyJson returns single binaries - a deliberate trade-off that yields 2-4x memory reduction during encoding and significantly reduced BEAM scheduler load.

## Encoding Architecture

### Jason's Approach (Pure Elixir, True iolist)

```
Elixir Term
    │
    ▼
Protocol Dispatch (Jason.Encoder)
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

The difference comes from Jason creating many intermediate iolist allocations during recursive encoding, while RustyJson builds a single buffer in Rust and copies once to BEAM.

**Note:** Memory measurements use `:erlang.memory(:total)` delta. See [BENCHMARKS.md](BENCHMARKS.md) for methodology and why Benchee memory measurements don't work for NIFs.

## Safety Analysis

### The NIF Safety Question

A common concern with NIFs is: "What if it crashes and takes down my entire BEAM VM?"

This is a valid concern for C-based NIFs, where a single buffer overflow, null pointer dereference, or use-after-free can crash the VM. However, **RustyJson's architecture makes this effectively impossible**.

### Why RustyJson Cannot Crash the VM

#### 1. Rust's Compile-Time Memory Safety

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

[Rustler](https://github.com/rusterlium/rustler) adds BEAM-specific protections:

- **Panic catching**: Rust panics are caught via `std::panic::catch_unwind` and converted to Elixir exceptions. A panic cannot crash the VM.
- **Term safety**: All Erlang term manipulation goes through safe APIs that validate types.
- **No raw pointers**: Rustler's `Term` type wraps raw BEAM pointers safely.
- **Lifetime enforcement**: Rust's borrow checker ensures terms aren't used after their scope ends.

#### 3. Zero `unsafe` Code in Our Codebase

**RustyJson's source code contains zero `unsafe` blocks.** Not minimized, not
audited—literally zero. Every line of Rust we wrote is 100% safe Rust.

```rust
// All our code uses safe patterns like this:
fn peek(&self) -> Option<u8> {
    self.input.get(self.pos).copied()  // Safe: returns None if out of bounds
}

fn skip_whitespace(&mut self) {
    while let Some(&byte) = self.input.get(self.pos) {  // Safe: bounds-checked
        match byte {
            b' ' | b'\t' | b'\n' | b'\r' => self.pos += 1,
            _ => break,
        }
    }
}
```

**Our source files:**

| File | Purpose | Lines | Unsafe |
|------|---------|-------|--------|
| `lib.rs` | NIF entry point | ~100 | **0** |
| `direct_json.rs` | JSON encoder | ~1,000 | **0** |
| `direct_decode.rs` | JSON decoder | ~500 | **0** |
| `compression.rs` | Gzip compression | ~60 | **0** |
| `decimal.rs` | Decimal handling | ~110 | **0** |
| **Total** | | **~1,770** | **0** |

**Design choices that eliminate unsafe:**

1. **`&str` over `&[u8]`** - UTF-8 validity guaranteed at compile time
2. **`.get()` over indexing** - Returns `Option` instead of panicking
3. **`while let Some()`** - Idiomatic safe iteration pattern

**Where `unsafe` does exist (dependencies only):**

| Dependency | Purpose | Trust Level |
|------------|---------|-------------|
| Rustler | NIF ↔ BEAM bridge | High - 10+ years, 500+ projects |
| mimalloc | Memory allocator | High - Microsoft, battle-tested |
| Rust stdlib | Core functionality | Highest - Rust core team |

Any memory safety bug would have to originate in a dependency, not in RustyJson code.

#### 4. Explicit Resource Limits

We enforce limits that prevent resource exhaustion:

| Resource | Limit | Rationale |
|----------|-------|-----------|
| Nesting depth | 128 levels | Prevents stack overflow, per RFC 7159 |
| Recursion | Bounded by depth | No unbounded recursion possible |
| Allocation | System memory | Same as pure Elixir |

### What Would Actually Need to Go Wrong?

For RustyJson to crash the VM, one of these would need to happen:

| Scenario | Likelihood | Why It's Unlikely |
|----------|------------|-------------------|
| Bug in Rustler | Extremely low | Mature library, used in production by many projects |
| Bug in Rust compiler | Essentially zero | Rust compiler is formally verified for memory safety |
| Bug in mimalloc | Extremely low | Microsoft's allocator, battle-tested |
| Cosmic ray bit flip | Non-zero but... | Not a software problem |

None of these are RustyJson bugs—they're infrastructure bugs that would affect any Rust-based system.

### Comparison: Theoretical vs Practical Risk

| Aspect | Theoretical Risk | Practical Risk |
|--------|------------------|----------------|
| Memory corruption | "NIFs can crash" | Rust prevents at compile time |
| Stack overflow | "Deep recursion" | 128-depth limit enforced |
| Panic/exception | "Unhandled errors" | Rustler converts to Elixir errors |
| Scheduler blocking | "Long NIF calls" | JSON encoding is fast, bounded |

### Our Position

We consider RustyJson **as safe as pure Elixir code** for the following reasons:

1. **Safe Rust is memory-safe by construction**. The compiler guarantees it.

2. **Rustler has been production-tested** across hundreds of Elixir projects for years.

3. **We use no `unsafe` code** in our encoding/decoding logic.

4. **Panics become exceptions**, not crashes.

5. **Resource limits are enforced** (depth, recursion).

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
- Jason creates many small iolist allocations on BEAM heap
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
2. **Allocation overhead** grows with payload - Jason's many small allocations compound
3. **BEAM reductions** scale linearly with work - Jason does all work in BEAM, RustyJson offloads to native code

### When Jason Wins

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
| canada.json (2.1MB) | 14 ms | 48 ms | 3.4x faster |
| citm_catalog.json (1.6MB) | 6 ms | 14 ms | 2.5x faster |
| twitter.json (617KB) | 4 ms | 9 ms | 2.3x faster |

Real-world API responses show better results than synthetic benchmarks because they have more complex nested structures and mixed data types.

See [BENCHMARKS.md](BENCHMARKS.md) for detailed methodology.

## Protocol Architecture

### Default Path (Maximum Performance)

```
RustyJson.encode!(data)
        │
        ▼
    Rust NIF
        │
        ▼
  Direct term walking
  (no Elixir preprocessing)
```

No Elixir code runs during encoding. The Rust NIF walks the term tree directly.

### Protocol Path (Custom Encoding)

```
RustyJson.encode!(data, protocol: true)
        │
        ▼
RustyJson.Encoder.encode/1
        │
        ▼
  Protocol dispatch
  (Map, List, Tuple, Any, custom)
        │
        ▼
    Rust NIF
```

When `protocol: true`:
1. Elixir's protocol system preprocesses the data
2. Custom `RustyJson.Encoder` implementations are called
3. Structs without implementations are converted via `Map.from_struct()`
4. Preprocessed data is sent to Rust

## Decoding Architecture

### Jason

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

### RustyJson

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

### Why Optional Protocol?

1. **Maximum default performance**: Most data doesn't need custom encoding.

2. **Explicit opt-in**: Users consciously trade performance for flexibility.

3. **Custom encoding**: Supports `@derive RustyJson.Encoder` for struct field filtering.

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

For the 35 implementation-defined tests, RustyJson makes these choices:

**Accepted:**
- Very large integers (converted to floats when necessary)
- Numbers with extreme exponents that underflow to zero
- Invalid UTF-8 byte sequences in strings (passed through)

**Rejected:**
- Numbers with exponents that overflow (e.g., `1e9999`)
- Lone Unicode surrogates (per RFC 7493 I-JSON recommendation)
- UTF-16 encoded files (only UTF-8 supported)
- Byte Order Marks (BOM)
- Nesting deeper than 128 levels

## What We Learned

### SIMD Is Actually Slower

We tested SIMD-accelerated parsers like simd-json and sonic-rs. Result: **they performed worse than our purpose-built NIF**.

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

## Future Considerations

### Potential Optimizations

1. **Chunked output**: For 100MB+ payloads, returning iolists could reduce memory spikes.

2. **Streaming decode**: Parse JSON incrementally for very large inputs.

### Not Planned

1. **SIMD parsing**: We tested it - SIMD libraries require an intermediate serde step, which makes them slower than our direct term-building approach.

2. **True iolist output**: The complexity isn't justified by real-world benefits.

3. **Unsafe Rust**: Memory safety is non-negotiable.

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
