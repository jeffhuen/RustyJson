# NIF for RustyJson

Rust NIF implementing high-performance JSON encoding and decoding for Elixir.

## Safety

**This crate contains zero `unsafe` code.** All source files use 100% safe Rust. The only `unsafe` exists in dependencies (Rustler, mimalloc, stdlib).

## SIMD Performance Strategy

**RustyJson uses hardware-accelerated SIMD (Single Instruction, Multiple Data) for maximum throughput — with zero `unsafe` code.**

We use Rust's `std::simd` (portable SIMD) for all vectorized operations. The compiler generates optimal instructions for each target architecture automatically:
- **x86_64**: SSE2 (16-byte), AVX2 (32-byte) when available at compile time
- **aarch64**: NEON (16-byte)
- **Other targets**: Scalar fallback (no SIMD, no regression)

There is no runtime feature detection, no `unsafe`, and no architecture-specific intrinsics. One codepath per pattern, portable across all targets.

We only use `std::simd` APIs that are on the stabilization track (`Simd::from_slice`, `Simd::splat`, comparison operators, `Mask` operations). Blocked APIs like `simd_swizzle!`, `Simd::scatter/gather`, and `Simd::interleave/deinterleave` are explicitly avoided.

We rely on battle-tested foundations like `rustler` (NIF abstraction), `mimalloc` (allocator), and `simdutf8` (SIMD UTF-8 validation).

## Implementation

Unlike typical Rust JSON libraries that use serde for serialization, RustyJson uses a custom implementation:

**Encoder (`direct_json.rs`):**
- Walks Erlang terms directly via Rustler's term API
- Writes JSON to a buffer without intermediate Rust data structures
- Uses `itoa` for integers, `ryu` for floats
- SIMD-accelerated escape scanning via `std::simd` (portable, zero `unsafe`)
- Handles DateTime, Date, Time, Decimal, URI, MapSet, Range natively
- Uses `&str` instead of `&[u8]` to guarantee UTF-8 at compile time

**Decoder (`direct_decode.rs`):**
- Custom recursive descent parser
- Builds Erlang terms during parsing (no intermediate AST)
- Zero-copy strings for unescaped content
- Uses `lexical-core` for fast number parsing
- Uses `.get()` for safe bounds-checked access

## Memory Allocator

Uses mimalloc by default. Alternatives available via Cargo features:

```toml
[features]
default = ["mimalloc"]
jemalloc = ["dep:tikv-jemallocator"]
snmalloc = ["dep:snmalloc-rs"]
```

## Building

```bash
FORCE_RUSTYJSON_BUILD=1 mix compile
```

## License

MIT License - see [LICENSE](../../LICENSE)
