# RustyJson

A JSON library for Elixir powered by Rust NIFs, designed as a drop-in replacement for Jason.

## Why RustyJson?

**The Problem**: JSON encoding in Elixir can be memory-intensive. When encoding large data structures, Jason (and other pure-Elixir encoders) create many intermediate binary allocations that pressure the garbage collector. For high-throughput applications processing large JSON payloads, this memory overhead becomes significant.

**Why not existing Rust JSON NIFs?** After OTP 24, Erlang's binary handling improved significantly, closing the performance gap between NIFs and pure-Elixir implementations. Libraries like [jiffy](https://github.com/davisp/jiffy) and the original [jsonrs](https://github.com/benhaney/jsonrs) struggled to outperform Jason on modern BEAM versions. Additionally, the original jsonrs is incompatible with Rustler 0.37+, which is required by many other packages.

**RustyJson's approach**: Rather than trying to beat Jason on speed alone, RustyJson focuses on:
1. **Lower memory usage** during encoding (2-4x less BEAM memory for large payloads)
2. **Reduced BEAM scheduler load** (3000x fewer reductions - work happens in native code)
3. **Faster encoding/decoding** (2-3x faster for medium/large data)
4. **Full Jason API compatibility** as a true drop-in replacement
5. **Modern Rustler 0.37+ support** for compatibility with the ecosystem

## Installation

```elixir
def deps do
  [{:rustyjson, "~> 0.1"}]
end
```

Pre-built binaries are provided via [Rustler Precompiled](https://github.com/philss/rustler_precompiled). To build from source, set `FORCE_RUSTYJSON_BUILD=true`.

## Drop-in Jason Replacement

RustyJson implements the same API as Jason:

```elixir
# These work identically to Jason
RustyJson.encode(term)           # => {:ok, json} | {:error, reason}
RustyJson.encode!(term)          # => json | raises
RustyJson.decode(json)           # => {:ok, term} | {:error, reason}
RustyJson.decode!(json)          # => term | raises

# Phoenix interface
RustyJson.encode_to_iodata(term)
RustyJson.encode_to_iodata!(term)

# Options match Jason
RustyJson.encode!(data, pretty: true)
RustyJson.decode!(json, keys: :atoms)
```

### Phoenix Integration

```elixir
# config/config.exs
config :phoenix, :json_library, RustyJson
```

## Migrating from Jason

Find/replace `Jason` → `RustyJson` in your codebase:

```elixir
# Before
@derive {Jason.Encoder, only: [:name, :email]}
Jason.encode!(data)
Jason.Fragment.new(json)

# After
@derive {RustyJson.Encoder, only: [:name, :email]}
RustyJson.encode!(data)
RustyJson.Fragment.new(json)
```

### Fragments

Inject pre-encoded JSON directly:

```elixir
fragment = RustyJson.Fragment.new(~s({"pre":"encoded"}))
RustyJson.encode!(%{data: fragment})
# => {"data":{"pre":"encoded"}}
```

### Formatter

Pretty-print or minify JSON strings:

```elixir
RustyJson.Formatter.pretty_print(json_string)
RustyJson.Formatter.minify(json_string)
```

## Benchmarks

All benchmarks run on Apple Silicon M1. Results may vary on other architectures.

### Speed (Roundtrip)

Using datasets from [nativejson-benchmark](https://github.com/miloyip/nativejson-benchmark):

| Dataset | RustyJson | Jason | Speedup |
|---------|-----------|-------|---------|
| canada.json (2.1MB) | 14 ms | 48 ms | **3.4x faster** |
| citm_catalog.json (1.6MB) | 6 ms | 14 ms | **2.5x faster** |
| twitter.json (617KB) | 4 ms | 9 ms | **2.3x faster** |

### Memory (Encoding)

| Dataset | RustyJson | Jason | Reduction |
|---------|-----------|-------|-----------|
| canada.json (2.1MB) | 2.4 MB | 5.8 MB | **2-3x less** |
| citm_catalog.json (1.6MB) | 0.5 MB | 2.1 MB | **3-4x less** |

### BEAM Scheduler Load

```elixir
# Reductions (BEAM work units) for encoding canada.json:
RustyJson.encode!(data)  # 322 reductions
Jason.encode!(data)      # 962,398 reductions (3000x less!)
```

The real benefit is **reduced BEAM scheduler load** - JSON processing happens in native code, freeing your schedulers for other work.

*Note: Small payloads (<1KB) show minimal difference due to NIF call overhead. See [docs/BENCHMARKS.md](docs/BENCHMARKS.md) for detailed methodology.*

## Features

### Built-in Type Support

These types are handled natively in Rust without protocol overhead:

| Type | JSON Output |
|------|-------------|
| `DateTime` | `"2024-01-15T14:30:00Z"` |
| `NaiveDateTime` | `"2024-01-15T14:30:00"` |
| `Date` | `"2024-01-15"` |
| `Time` | `"14:30:00"` |
| `Decimal` | `"123.45"` |
| `URI` | `"https://example.com"` |
| `MapSet` | `[1, 2, 3]` |
| `Range` | `{"first": 1, "last": 10}` |
| Structs | Object without `__struct__` |
| Tuples | Arrays |

### Options

**Encoding:**
- `pretty: true | integer` - Pretty print with indentation
- `escape: :json | :html_safe | :javascript_safe | :unicode_safe` - Escape mode
- `compress: :gzip | {:gzip, 0..9}` - Gzip compression
- `lean: true` - Skip special type handling for max speed
- `protocol: true` - Enable custom `RustyJson.Encoder` protocol

**Decoding:**
- `keys: :strings | :atoms | :atoms!` - Key handling

### Custom Encoding

For custom types, implement the `RustyJson.Encoder` protocol and use `protocol: true`:

```elixir
defimpl RustyJson.Encoder, for: Money do
  def encode(%Money{amount: amount, currency: currency}) do
    %{amount: Decimal.to_string(amount), currency: currency}
  end
end

RustyJson.encode!(money, protocol: true)
```

Or use `@derive`:

```elixir
defmodule User do
  @derive {RustyJson.Encoder, only: [:name, :email]}
  defstruct [:name, :email, :password_hash]
end
```

## JSON Spec Compliance

RustyJson is fully compliant with RFC 8259 and passes **283/283 mandatory tests** from [JSONTestSuite](https://github.com/nst/JSONTestSuite):

- **95/95** `y_` tests (must accept)
- **188/188** `n_` tests (must reject)
- Rejects lone surrogates per [RFC 7493 I-JSON](https://datatracker.ietf.org/doc/html/rfc7493)

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed compliance information.

## How It Works

### Why RustyJson Is Different

Most Rust JSON libraries for Elixir use [serde](https://serde.rs/) to convert between Rust and Erlang types. This requires:

1. Erlang term → Rust struct (allocation)
2. Rust struct → JSON bytes (allocation)
3. JSON bytes → Erlang binary (allocation)

RustyJson eliminates the middle step by walking the Erlang term tree directly and writing JSON bytes without intermediate Rust structures.

### Key Optimizations

**Custom Direct Encoder:**
- Walks Erlang terms directly via Rustler's term API
- Writes to a single buffer without intermediate allocations
- Uses [itoa](https://github.com/dtolnay/itoa) and [ryu](https://github.com/dtolnay/ryu) for fast number formatting
- 256-byte lookup table for O(1) escape detection

**Custom Direct Decoder:**
- Parses JSON while building Erlang terms (no intermediate AST)
- Zero-copy strings for unescaped content
- [lexical-core](https://github.com/Alexhuszagh/rust-lexical) for fast number parsing

**Memory Allocator:**
Uses [mimalloc](https://github.com/microsoft/mimalloc) by default. Alternatives available via Cargo features:

```toml
[features]
default = ["mimalloc"]
# Or: "jemalloc", "snmalloc"
```

### What We Learned

The bottleneck for JSON NIFs isn't parsing or formatting—it's crossing the NIF boundary and building Erlang terms. SIMD-accelerated parsers like simd-json and sonic-rs showed minimal improvement because term construction dominates the workload.

The wins come from:
1. **Avoiding intermediate allocations** (no Rust structs, no serde)
2. **Efficient term building** (direct writes to Erlang heap)
3. **Good memory allocator** (mimalloc reduces fragmentation)

## Limitations

- Maximum nesting depth: 128 levels (per RFC 7159)
- Decoding very large payloads (>500 KB) may be only marginally faster than Jason
- Benchmarks are on Apple Silicon M1; results on other architectures may differ

## Acknowledgments

- [Rustler](https://github.com/rusterlium/rustler) - Erlang NIF bindings for Rust
- [Jason](https://github.com/michalmuskala/jason) - API design and behavior reference
- [Original Jsonrs](https://github.com/benhaney/jsonrs) - Initial inspiration

## License

[MIT License](LICENSE)
