# NIF for RustyJson

Rust NIF implementing high-performance JSON encoding and decoding for Elixir.

## Safety

**This crate contains zero `unsafe` code.** All source files use 100% safe Rust:

| File | Purpose | Unsafe |
|------|---------|--------|
| `lib.rs` | NIF entry point | **0** |
| `direct_json.rs` | JSON encoder | **0** |
| `direct_decode.rs` | JSON decoder | **0** |
| `compression.rs` | Gzip support | **0** |
| `decimal.rs` | Decimal handling | **0** |

The only `unsafe` exists in dependencies (Rustler, mimalloc, stdlib).

## Implementation

Unlike typical Rust JSON libraries that use serde for serialization, RustyJson uses a custom implementation:

**Encoder (`direct_json.rs`):**
- Walks Erlang terms directly via Rustler's term API
- Writes JSON to a buffer without intermediate Rust data structures
- Uses `itoa` for integers, `ryu` for floats
- 256-byte lookup table for O(1) escape detection
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
