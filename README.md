# RustyJson

A JSON library for Elixir powered by Rust NIFs, designed as a drop-in replacement for Jason.

## Why RustyJson?

**The Problem**: JSON encoding in Elixir can be memory-intensive. Pure-Elixir encoders create many intermediate binary allocations that pressure the garbage collector. For high-throughput applications processing large JSON payloads, this memory overhead becomes significant.

**Why a new library?** After OTP 24, Erlang's binary handling improved significantly, narrowing the performance gap between NIFs and pure-Elixir implementations. Additionally, Rustler 0.37+ (required by many modern packages) introduced breaking changes that left some existing NIF-based JSON libraries behind.

**RustyJson's approach**: RustyJson focuses on:
1. **Lower memory usage** during encoding (2-4x less BEAM memory for large payloads)
2. **Reduced BEAM scheduler load** (100-2000x fewer reductions - work happens in native code)
3. **Faster encoding/decoding** (2-3x faster for medium/large data)
4. **Full Jason API compatibility** as a true drop-in replacement
5. **Modern Rustler 0.37+ support** for compatibility with the ecosystem

## Installation

```elixir
def deps do
  [{:rustyjson, "~> 0.3"}]
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

All benchmarks on Apple Silicon M1. RustyJson's advantage grows with payload size.

### Encoding (Elixir → JSON) — Where RustyJson Shines

| Dataset | RustyJson | Jason | Speed | Memory |
|---------|-----------|-------|-------|--------|
| Settlement report (10 MB) | 24 ms | 131 ms | **5.5x faster** | **2-3x less** |
| canada.json (2.1 MB) | 6 ms | 18 ms | **3x faster** | **2-3x less** |
| twitter.json (617 KB) | 1.2 ms | 3.5 ms | **2.9x faster** | similar |

### Decoding (JSON → Elixir)

| Dataset | RustyJson | Jason | Speed |
|---------|-----------|-------|-------|
| Settlement report (10 MB) | 61 ms | 152 ms | **2.5x faster** |
| canada.json (2.1 MB) | 8 ms | 29 ms | **3.5x faster** |

Both libraries produce identical Elixir data structures, so memory usage is similar for decoding.

### Decoding API Responses (~30% faster)

Most JSON that applications decode follows the same pattern: arrays of objects with identical keys. Paginated REST endpoints (`GET /users`), GraphQL queries, database results, webhook payloads, ElasticSearch hits—they all return `[{same keys}, {same keys}, ...]`.

Use `keys: :intern` to cache object keys during parsing:

```elixir
# API response: 10,000 users with {id, name, email, created_at}
RustyJson.decode!(json, keys: :intern)  # ~30% faster
```

This allocates each key (`"id"`, `"name"`, etc.) once and reuses it across all objects, instead of re-allocating identical strings thousands of times.

**Don't use for single objects or varied schemas** - the cache overhead makes it 2-3x *slower* when keys aren't reused. Only use when you know you're decoding arrays of 10+ objects with the same structure.

### BEAM Scheduler Load

```elixir
# Reductions (BEAM work units) for encoding 10 MB settlement report:
RustyJson.encode!(data)  # 404 reductions
Jason.encode!(data)      # 11,570,847 reductions (28,000x fewer!)
```

The real benefit is **reduced BEAM scheduler load** - JSON processing happens in native code, freeing your schedulers for other work.

### When to Use RustyJson

- **Best for**: Large payloads (1MB+), API responses, data exports
- **Decoding bulk data**: Use `keys: :intern` for arrays of objects (API responses, DB results)
- **Small payloads**: Competitive on small and deeply nested JSON (optimized in v0.3.3)
- **Biggest wins**: Encoding large structures, decoding homogeneous arrays

See [docs/BENCHMARKS.md](docs/BENCHMARKS.md) for detailed methodology.

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
| Structs | Object without `__struct__` |
| Tuples | Arrays |

> **Note:** `MapSet` and `Range` are **not** encoded by default. They raise
> `Protocol.UndefinedError` with `protocol: true` (the default), matching Jason's
> behavior. Use `protocol: false` to encode them via the Rust NIF directly
> (`MapSet` → array, `Range` → object), or add an explicit `RustyJson.Encoder` impl.

### Options

**Encoding:**
- `pretty: true | integer` - Pretty print with indentation
- `escape: :json | :html_safe | :javascript_safe | :unicode_safe` - Escape mode
- `compress: :gzip | {:gzip, 0..9}` - Gzip compression
- `lean: true` - Skip special type handling for max speed
- `protocol: true` - Enable custom `RustyJson.Encoder` protocol

**Decoding:**
- `keys: :strings | :atoms | :atoms! | :intern` - Key handling
  - `:intern` - **~30% faster** for arrays of objects (REST APIs, GraphQL, DB results, webhooks)

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

Run `mix test test/json_test_suite_test.exs` to validate compliance (downloads test fixtures on first run).

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed compliance information.

## Error Handling

RustyJson provides clear, actionable error messages and predictable error handling:

```elixir
# Clear error messages tell you exactly what's wrong
RustyJson.decode(~s({"key": "value\\'s"}))
# => {:error, "Invalid escape sequence: \\'"}

# Unencodable values return error tuples, not exceptions
RustyJson.encode(%{{:tuple, :key} => 1})
# => {:error, "Map key must be atom, string, or integer"}

# Strict UTF-16 surrogate validation per RFC 7493
RustyJson.decode(~s("\\uD800"))
# => {:error, "Lone surrogate in string"}
```

`encode/1` and `decode/1` consistently return `{:error, reason}` tuples for invalid input, making error handling predictable with pattern matching.

## How It Works

### Why RustyJson Is Different

Most Rust JSON libraries for Elixir use [serde](https://serde.rs/) to convert between Rust and Erlang types. This requires:

1. Erlang term → Rust struct (allocation)
2. Rust struct → JSON bytes (allocation)
3. JSON bytes → Erlang binary (allocation)

RustyJson eliminates the middle step by walking the Erlang term tree directly and writing JSON bytes without intermediate Rust structures.

**Native type handling in Rust:** Common Elixir types — DateTime, Decimal, URI — are encoded directly in Rust without any Elixir-side transformation. The encoder protocol walk passes these types through unchanged, and Rust formats them natively during serialization. This reduces BEAM work and intermediate allocations compared to libraries that must transform every type in Elixir before handing off to Rust. Custom user types still go through the Elixir encoder protocol as expected. (`MapSet` and `Range` are only handled natively when using `protocol: false`; with the default `protocol: true`, they raise `Protocol.UndefinedError` to match Jason.)

### Key Optimizations

**Custom Direct Encoder:**
- Walks Erlang terms directly via Rustler's term API
- Writes to a single buffer without intermediate allocations
- Uses [itoa](https://github.com/dtolnay/itoa) and [ryu](https://github.com/dtolnay/ryu) for fast number formatting
- 256-byte lookup table for O(1) escape detection

**Custom Direct Decoder:**
- Parses JSON while building Erlang terms (no intermediate AST)
- Zero-copy strings for unescaped content
- Single-entry fast path for objects and arrays (avoids heap allocation for deeply nested JSON)
- [lexical-core](https://github.com/Alexhuszagh/rust-lexical) for fast number parsing

**Memory Allocator:**
Uses [mimalloc](https://github.com/microsoft/mimalloc) by default. Alternatives available via Cargo features:

```toml
[features]
default = ["mimalloc"]
# Or: "jemalloc", "snmalloc"
```

### What We Learned

The bottleneck for JSON NIFs isn't parsing—it's building Erlang terms. SIMD-accelerated parsers use serde, requiring double conversion (JSON → Rust types → BEAM terms). RustyJson skips this by building BEAM terms directly during parsing.

The wins come from:
1. **Skipping serde entirely** - Walk JSON and build BEAM terms directly in one pass
2. **No intermediate allocations** - No Rust structs, no AST
3. **Good memory allocator** - mimalloc reduces fragmentation

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
