# RustyJson

RustyJson is a Rust-backed JSON library for Elixir. Its common encode and decode
calls follow Jason, so most call sites can move over with a module-name change.
It exists for applications where JSON has become measurable work.

## Start with Jason

[Jason](https://github.com/michalmuskala/jason) is a good default for most
Elixir applications. It is pure Elixir and keeps builds and deployments simple.
If Jason already meets your latency and memory needs, keep using it.

RustyJson is useful when profiling points at JSON: multi-megabyte API responses,
large exports, ingestion pipelines, or high volumes of repeated records. It moves
parsing and serialization into Rust and reads or writes BEAM terms without first
building an intermediate Rust representation.

On this repository's Apple M1 Pro benchmarks, encoding a roughly 10 MB payload is
about 5-6x faster than Jason and uses 2-3x less total memory. Large decodes are
about 2.4-3.5x faster. Smaller payloads show smaller gains. These results explain
why the library exists, but they are not a promise for every application. Benchmark
the payloads that matter to you.

## Deliberate tradeoffs

RustyJson is a native dependency. Precompiled binaries cover the supported
targets, while source builds require nightly Rust. RustyJson's own Rust source
contains no `unsafe` blocks, which reduces the risk of memory-unsafe bugs in the
library. Your application still loads a NIF and relies on native dependencies. If
that operational cost outweighs the measured gain, Jason is the better fit.

RustyJson also takes a stricter position on JSON keys. It keeps decoded keys as
strings and leaves out the modes that create atoms dynamically from JSON input.
Code that relied on `keys: :atoms` or the lowercase `a` sigil modifier must change.
[Why RustyJson keeps decoded keys as strings](docs/KEY_HANDLING.md) explains the
reason and the practical effect on evolving APIs.

Unknown options and invalid option values raise instead of being ignored. Custom
structs require a `RustyJson.Encoder` implementation; RustyJson does not fall back
to `Jason.Encoder` or Elixir's `JSON.Encoder`. These choices make mistakes visible
at the call site, but they mean compatibility is deliberate rather than absolute.

## Installation

```elixir
def deps do
  [{:rustyjson, "~> 0.4"}]
end
```

Prebuilt binaries are provided through [Rustler Precompiled](https://github.com/philss/rustler_precompiled)
for the supported targets and NIF versions. On x86_64, the build selects an AVX2
variant when the host CPU supports it. To build from source, set
`FORCE_RUSTYJSON_BUILD=true`.

## Using the API

The common encode/decode calls mirror Jason:

```elixir
# Core calls match Jason
RustyJson.encode(term)           # => {:ok, json} | {:error, reason}
RustyJson.encode!(term)          # => json | raises
RustyJson.decode(json)           # => {:ok, term} | {:error, reason}
RustyJson.decode!(json)          # => term | raises

# Phoenix interface
RustyJson.encode_to_iodata(term)
RustyJson.encode_to_iodata!(term)

# Pretty-print when needed
RustyJson.encode!(data, pretty: true)
```

### Phoenix integration

```elixir
# config/config.exs
config :phoenix, :json_library, RustyJson
```

When Phoenix LiveView 1.2+ is present, RustyJson encodes
`%Phoenix.LiveView.JS{}` through `Phoenix.LiveView.JS.to_encodable/1` without
declaring Phoenix or LiveView as package dependencies. RustyJson still requires
explicit `RustyJson.Encoder` implementations for other custom structs; it does
not fall back to `Jason.Encoder` or Elixir's `JSON.Encoder`.

## Moving from Jason

Most call sites can change `Jason` to `RustyJson` directly:

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

## Upgrading from RustyJson 0.3

RustyJson 0.4 removes APIs that create atoms dynamically and rejects invalid
options:

- Replace `keys: :atoms` with string keys (the default) or `keys: :atoms!` when
  every key atom already exists.
- Replace lowercase `a` on `~j`/`~J` with no modifier for strings or uppercase
  `A` for existing atoms.
- Remove unknown encode/decode options. `:protocol`, `:lean`, `:sort_keys`, and
  `:validate_strings` require booleans; `:decoding_integer_digit_limit`,
  `:max_bytes`, and `:dirty_threshold` require non-negative integers. Invalid
  `:pretty` values or nested keys also raise `ArgumentError`.

## Benchmarks

These results were measured on an Apple M1 Pro. They show where RustyJson's
architecture helps, but payload shape and hardware matter. Run the benchmark suite
against your own data before choosing a library for performance alone.

### Encoding

| Dataset | RustyJson | Jason | Speed | Memory |
|---------|-----------|-------|-------|--------|
| Settlement report (10 MB) | 24 ms | 131 ms | **5.5x faster** | **2-3x less** |
| canada.json (2.1 MB) | 6 ms | 18 ms | **3x faster** | **2-3x less** |
| twitter.json (617 KB) | 1.2 ms | 3.5 ms | **2.9x faster** | similar |

### Decoding

| Dataset | RustyJson | Jason | Speed |
|---------|-----------|-------|-------|
| Settlement report (10 MB) | 61 ms | 152 ms | **2.5x faster** |
| canada.json (2.1 MB) | 8 ms | 29 ms | **3.5x faster** |

Both libraries produce the same Elixir data structures, so their decoded results
use similar amounts of memory.

### Repeated keys in API responses

API responses and database results often contain arrays of objects with the same
keys. `keys: :intern` caches those key strings during parsing:

```elixir
# API response: 10,000 users with {id, name, email, created_at}
RustyJson.decode!(json, keys: :intern)  # ~30% faster
```

This allocates each repeated key once and reuses it across the array. The option is
slower for a single object or varied schemas because it pays cache overhead without
reusing entries. Use it when you know the payload contains at least 10 similarly
shaped objects.

### BEAM reductions and scheduler behavior

```elixir
# Reductions (BEAM work units) for encoding 10 MB settlement report:
RustyJson.encode!(data)  # 404 reductions
Jason.encode!(data)      # 11,570,847 reductions
```

RustyJson uses roughly 28,000x fewer reductions in this test because the NIF does
most of the work. The CPU work still exists. Decodes of 100 KB or more use a dirty
scheduler by default. Encoding uses a dirty scheduler automatically for gzip
compression; for a large uncompressed encode, pass `scheduler: :dirty` when
blocking a normal scheduler is a concern.

See [docs/BENCHMARKS.md](docs/BENCHMARKS.md) for detailed methodology.

## API reference

### Built-in types

RustyJson handles these types in Rust without protocol overhead:

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

### Fragments

Use a fragment to inject JSON that has already been encoded:

```elixir
fragment = RustyJson.Fragment.new(~s({"pre":"encoded"}))
RustyJson.encode!(%{data: fragment})
# => {"data":{"pre":"encoded"}}
```

### Formatter

Pretty-print or minimize a JSON string:

```elixir
RustyJson.Formatter.pretty_print(json_string)
RustyJson.Formatter.minimize(json_string)
```

### Common options

The [RustyJson module documentation](https://hexdocs.pm/rustyjson/RustyJson.html)
contains the complete option list.

**Encoding:**

- `pretty: true | integer` - Pretty print with indentation
- `escape: :json | :html_safe | :javascript_safe | :unicode_safe` - Escape mode
- `compress: :gzip | {:gzip, 0..9}` - Gzip compression
- `lean: true` - Skip special type handling for max speed
- `protocol: true` - Enable custom `RustyJson.Encoder` protocol
- `sort_keys: true` - Sort map keys lexicographically (useful for snapshot tests, caching, diffing)
- `scheduler: :auto | :normal | :dirty` - Choose where encoding NIF work runs

**Decoding:**

- `keys: :strings | :atoms! | :copy | :intern | function` - Key handling (`:atoms` is intentionally unsupported)
  - `:intern` - **~30% faster** for arrays of objects (REST APIs, GraphQL, DB results, webhooks)
- `dirty_threshold: non-negative integer` - Input size that moves decoding to a dirty scheduler
- `max_bytes: non-negative integer` - Reject inputs larger than the given byte limit

### Custom encoders

For custom types, implement the `RustyJson.Encoder` protocol and use `protocol: true`:

```elixir
defimpl RustyJson.Encoder, for: Money do
  def encode(%Money{amount: amount, currency: currency}, _opts) do
    RustyJson.Encode.map(%{amount: Decimal.to_string(amount), currency: currency}, _opts)
  end
end

RustyJson.encode!(money)
```

Or use `@derive`:

```elixir
defmodule User do
  @derive {RustyJson.Encoder, only: [:name, :email]}
  defstruct [:name, :email, :password_hash]
end
```

## JSON compliance

RustyJson passes all 283 mandatory cases from
[JSONTestSuite](https://github.com/nst/JSONTestSuite):

- 95/95 `y_` tests (must accept)
- 188/188 `n_` tests (must reject)
- Rejects lone surrogates per [RFC 7493 I-JSON](https://datatracker.ietf.org/doc/html/rfc7493)

Run `mix test test/json_test_suite_test.exs` to validate compliance (downloads test fixtures on first run).

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed compliance information.

## Error handling

Data errors return exception structs with a message and, for decode errors, a
byte position:

```elixir
# Decode errors include a byte position
{:error, error} = RustyJson.decode(~s({"key": "value\\'s"}))
error.message
# => "Invalid escape sequence: \\' at position 8"

# Unencodable values return error tuples, not exceptions
{:error, error} = RustyJson.encode(%{{:tuple, :key} => 1})
error.message
# => "Map key must be atom, string, or integer"

# Strict UTF-16 surrogate validation per RFC 7493
{:error, error} = RustyJson.decode(~s("\\uD800"))
error.message
# => "Lone surrogate in string at position 0"
```

`encode/1` and `decode/1` return `{:error, exception}` tuples for invalid data.
Invalid options raise `ArgumentError`, keeping configuration mistakes separate
from data errors.

## How RustyJson reduces work

For encoding, a [serde](https://serde.rs/)-based NIF normally converts data in
three stages:

1. Erlang term → Rust struct (allocation)
2. Rust struct → JSON bytes (allocation)
3. JSON bytes → Erlang binary (allocation)

For encoding, RustyJson walks the Erlang term tree and writes JSON bytes directly.
For decoding, it builds BEAM terms while parsing instead of creating an
intermediate Rust syntax tree.

Common Elixir types such as `DateTime`, `Decimal`, and `URI` pass through the
encoder protocol unchanged and are formatted in Rust. Custom types still use the
Elixir encoder protocol. `MapSet` and `Range` require `protocol: false` or an
explicit encoder implementation.

### Direct encoder

- Walks Erlang terms directly via Rustler's term API
- Writes to a single buffer without intermediate allocations
- Uses [itoa](https://github.com/dtolnay/itoa) and [ryu](https://github.com/dtolnay/ryu) for fast number formatting
- SIMD-accelerated escape scanning (16 bytes/iter, 32 bytes/iter on AVX2)
- 256-byte lookup table for O(1) escape detection

### Direct decoder

- Parses JSON while building Erlang terms (no intermediate AST)
- SIMD-accelerated string scanning, whitespace skipping, and structural character indexing
- Zero-copy strings for unescaped content
- Single-entry fast path for objects and arrays (avoids heap allocation for deeply nested JSON)
- [lexical-core](https://github.com/Alexhuszagh/rust-lexical) for fast number parsing

### Portable SIMD

- All SIMD uses Rust's `std::simd`, with one code path per pattern and no `unsafe` blocks
- The compiler generates optimal instructions for each target: SSE2 on x86_64, NEON on aarch64, scalar on others
- AVX2 precompiled variants use 32-byte wide paths for additional throughput on Haswell+ CPUs

### Allocator

RustyJson uses [mimalloc](https://github.com/microsoft/mimalloc) by default.
Source builds can select jemalloc or snmalloc in `Cargo.toml`:

```toml
[features]
default = ["mimalloc"]
# Or: "jemalloc", "snmalloc"
```

## Limits

- JSON nesting is limited to 128 levels.
- Precompiled binaries cover the supported targets. Other targets need a source build.
- Source builds require nightly Rust for `#![feature(portable_simd)]`.

## Acknowledgments

- [Rustler](https://github.com/rusterlium/rustler) - Erlang NIF bindings for Rust
- [Jason](https://github.com/michalmuskala/jason) - API design and behavior reference
- [Original Jsonrs](https://github.com/benhaney/jsonrs) - Initial inspiration

## License

[MIT License](LICENSE)
