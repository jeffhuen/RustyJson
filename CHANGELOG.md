# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-01-28

### Breaking Changes

This release aims to achieve full Jason API parity. Three changes require action when upgrading:

**1. `decode/2` returns `%DecodeError{}` instead of a string**

```elixir
# Before (0.2.x)
{:error, message} = RustyJson.decode(bad_json)
Logger.error("Failed: #{message}")

# After (0.3.0)
{:error, %RustyJson.DecodeError{} = error} = RustyJson.decode(bad_json)
Logger.error("Failed: #{error.message}")
# Also available: error.position, error.data, error.token
```

**2. `encode/2` returns `%EncodeError{}` instead of a string**

```elixir
# Before (0.2.x)
{:error, message} = RustyJson.encode(bad_data)

# After (0.3.0)
{:error, %RustyJson.EncodeError{} = error} = RustyJson.encode(bad_data)
```

**3. `RustyJson.Encoder` protocol changed from `encode/1` to `encode/2`**

```elixir
# Before (0.2.x)
defimpl RustyJson.Encoder, for: MyStruct do
  def encode(value), do: Map.take(value, [:name])
end

# After (0.3.0)
defimpl RustyJson.Encoder, for: MyStruct do
  def encode(value, _opts), do: Map.take(value, [:name])
end
```

### Added - Full Jason Feature Parity

RustyJson now matches Jason's public API 1:1 in signatures, return types, and behavior.

#### Decode Options

- **`keys: :copy`** - Accepted for Jason compatibility. Equivalent to `:strings` since RustyJson NIFs always produce copied binaries.
- **`keys: :atoms`** - Convert keys to atoms using `String.to_atom/1` (matches Jason — unsafe with untrusted input).
- **`keys: :atoms!`** - Convert keys to existing atoms using `String.to_existing_atom/1` (matches Jason — safe, raises if atom doesn't exist).
- **`keys: custom_function`** - Pass a function of arity 1 to transform keys recursively: `keys: &String.upcase/1`
- **`strings: :copy | :reference`** - Accepted for Jason compatibility (both behave identically).
- **`objects: :ordered_objects`** - Decode JSON objects as `%RustyJson.OrderedObject{}` structs that preserve key insertion order. Built in Rust during parsing for zero overhead. Key transforms (`:atoms`, `:atoms!`, custom functions) apply to `OrderedObject` keys as well.
- **`floats: :decimals`** - Decode JSON floats as `%Decimal{}` structs for exact decimal representation. Decimal components are parsed in Rust.
- **`decoding_integer_digit_limit`** - Configurable maximum digits for integer parsing (default: 1024, 0 to disable). Also configurable at compile time via `Application.compile_env(:rustyjson, :decoding_integer_digit_limit, 1024)`. Enforced in the Rust parser.

#### Encode Options

- **`protocol: true` is now the default** - Encoding always goes through the `RustyJson.Encoder` protocol first, matching Jason's behavior. Use `protocol: false` to bypass the protocol for maximum performance.
- **`maps: :strict`** - Detect duplicate serialized keys (e.g. atom `:a` and string `"a"` in the same map). Tracked via `HashSet` in Rust.
- **Pretty print keyword opts** - `pretty: [indent: 4, line_separator: "\r\n", after_colon: ""]` for full control over formatting. Separators are passed to and applied in Rust.
- **iodata indent** - The `:indent` option now accepts strings/iodata (e.g. `pretty: "\t"` for tab indentation), matching Jason's Formatter behavior. Indent strings are passed to Rust and applied directly.

#### New Modules

- **`RustyJson.Decoder`** - Thin wrapper matching Jason's `Jason.Decoder` API. Provides `parse/2` that delegates to `RustyJson.decode/2`.
- **`RustyJson.Encode`** - Low-level encoding functions (`value/2`, `atom/2`, `integer/1`, `float/1`, `list/2`, `keyword/2`, `map/2`, `string/2`, `struct/2`, `key/2`), compatible with `Jason.Encode`. `keyword/2` preserves insertion order (does not convert to map).
- **`RustyJson.Helpers`** - Compile-time macros `json_map/1` and `json_map_take/2` that pre-encode JSON object keys at compile time for faster runtime encoding. Preserves key insertion order, propagates encoding options (escape, maps) at runtime via function-based Fragments.
- **`RustyJson.Sigil`** - `~j` sigil (runtime, supports interpolation) and `~J` sigil (compile-time) for JSON literals. Modifiers: `a` (atoms), `A` (atoms!), `r` (reference), `c` (copy). Unknown modifiers raise `ArgumentError`.
- **`RustyJson.OrderedObject`** - Order-preserving JSON object struct with `Access` behaviour and `Enumerable` protocol.

#### Error Factories

- **`RustyJson.EncodeError.new/1`** - Factory functions for creating structured encode errors: `new({:duplicate_key, key})` and `new({:invalid_byte, byte, original})`.

### Changed

#### Error Return Types (Breaking)

- **`decode/2`** now returns `{:error, %RustyJson.DecodeError{}}` instead of `{:error, String.t()}`. The `DecodeError` struct includes `:message`, `:data`, `:position`, and `:token` fields for detailed error diagnostics.
- **`encode/2`** now returns `{:error, %RustyJson.EncodeError{} | Exception.t()}` instead of `{:error, String.t()}`.
- **`encode!/2`** now wraps NIF errors in `%RustyJson.EncodeError{}` instead of leaking `ErlangError`.

#### Encoder Protocol (Breaking)

- **`RustyJson.Encoder.encode/1`** changed to **`encode/2`** with an `opts` parameter, matching `Jason.Encoder.encode/2`. The `opts` parameter carries encoder options (`:escape`, `:maps`) as a keyword list, enabling custom implementations like `Fragment` and `OrderedObject` to respect encoding context. All protocol implementations must update from `def encode(value)` to `def encode(value, _opts)`.
- **`protocol: true` is now the default** in `encode/2` and `encode!/2`. Previously required explicit opt-in. This matches Jason, which always dispatches through its Encoder protocol.
- **`Any` fallback now raises** `Protocol.UndefinedError` for structs without an explicit `RustyJson.Encoder` implementation, matching Jason. Previously, structs were silently encoded via `Map.from_struct/1`. There is no fallback to `Jason.Encoder` — RustyJson is a complete replacement, not a bridge.
- **`MapSet` and `Range` now raise** `Protocol.UndefinedError` by default (matching Jason). Previously had pass-through encoder implementations. Use `protocol: false` to encode them via the Rust NIF directly.

#### Formatter API (Breaking)

- **`RustyJson.Formatter.pretty_print/2`** now returns `binary()` directly instead of `{:ok, binary()} | {:error, String.t()}`. Raises `RustyJson.DecodeError` on invalid input.
- **`RustyJson.Formatter.minimize/2`** now returns `binary()` directly. Same error behavior.
- **`pretty_print_to_iodata/2`** returns `iodata()` directly.
- **`minimize_to_iodata/2`** returns `iodata()` directly. No default for `opts` parameter (matching Jason).
- **Removed** `pretty_print!/2`, `pretty_print_to_iodata!/2`, `minimize!/2`, `minimize_to_iodata!/2` — Jason does not have bang variants for Formatter.
- **Stream-based rewrite** — Formatter internals ported from Jason's stream-based approach. Preserves key order and number formatting during pretty-print and minimize operations.

#### OrderedObject

- **`pop/2`** changed to **`pop/3`** with an optional `default` parameter (default: `nil`), matching `Jason.OrderedObject.pop/3`.
- Key type changed from `String.t()` to `String.Chars.t()` for Jason compatibility.

### Fixed

- **Large integer precision** — Integers exceeding `u64::MAX` are now decoded using arbitrary-precision `BigInt` (via `num-bigint`) instead of falling back to `f64`, which lost precision. Matches Jason's behavior of preserving exact integer values regardless of magnitude.
- **`html_safe` forward slash escaping** — `escape: :html_safe` now correctly escapes `/` as `\/`, matching Jason. Previously `/` was only escaped in unicode/javascript safe modes.
- **Encoding options propagation** — `escape` and `maps` options now flow correctly through the Encoder protocol, Fragment functions, Helpers macros, and OrderedObject encoding. Previously these options were consumed before reaching protocol implementations.
- **Nested Fragment encoding** — Fragments nested inside maps or lists now encode correctly in both `protocol: true` and `protocol: false` modes. The Encoder protocol now resolves Fragment functions to iodata immediately instead of wrapping in another closure, and `resolve_fragment_functions` recursively traverses maps and lists to resolve any remaining function-based Fragments before the Rust NIF.
- **Helpers key validation regex** — Fixed character class regex that incorrectly rejected alphabetic keys. Now uses hex escapes for correct ASCII range matching.

### Performance

No regressions. Relative speedup vs Jason is unchanged from v0.2.0.

### Testing

- 394 tests, all passing with 0 failures.
- New test files: `encode_test.exs`, `helpers_test.exs`, `sigil_test.exs`, `ordered_object_test.exs`, `decoder_test_module_test.exs`.
- Updated all error pattern matches across test suite for new structured error returns.
- Tightened formatter tests to use exact-match assertions instead of substring matches.
- Added coverage for: large integer precision, html_safe `/` escaping, Fragment function opts propagation, Helpers opts flow, OrderedObject key transforms and encoding opts, atoms/atoms! key decoding, sigil unknown modifiers, MapSet/Range protocol errors.

## [0.2.0] - 2025-01-25

### Added

- **Faster decoding for API responses and bulk data** (`keys: :intern`) - ~30% speedup for the most common JSON patterns

  Modern APIs return arrays of objects with the same shape: paginated endpoints (`GET /users`),
  GraphQL queries, database results, webhook events, ElasticSearch hits. This is the vast majority
  of JSON most applications decode.

  With `keys: :intern`, RustyJson caches object keys during parsing so identical keys like `"id"`,
  `"name"`, `"created_at"` are allocated once and reused across all objects in the array.

  ```elixir
  # Before: allocates "id", "name", "email" for every object
  RustyJson.decode!(json)

  # After: allocates each key once, reuses for all 10,000 objects
  RustyJson.decode!(json, keys: :intern)  # ~30% faster
  ```

  **Caution**: Don't use for single objects or varied schemas—the cache overhead makes it
  2-3x slower when keys aren't reused. Only use for homogeneous arrays of 10+ objects.

  See [BENCHMARKS.md](docs/BENCHMARKS.md#key-interning-benchmarks) for detailed performance data.

### Documentation

- **Error handling documentation** - Added comprehensive documentation highlighting RustyJson's
  clear, actionable error messages and consistent `{:error, reason}` returns:

  ```elixir
  # Clear error messages describe the problem
  RustyJson.decode(~s({"key": "value\\'s"}))
  # => {:error, "Invalid escape sequence: \\'"}

  # Consistent error tuples for invalid input
  RustyJson.encode(%{{:tuple, :key} => 1})
  # => {:error, "Map key must be atom, string, or integer"}
  ```

- Added error handling sections to README, moduledoc, and ARCHITECTURE.md

### Testing

- **Automated JSONTestSuite regression tests** - Added repeatable test suite that
  validates against [JSONTestSuite](https://github.com/nst/JSONTestSuite) on every
  test run. Ensures the documented 283/283 compliance doesn't regress. Fixtures are
  downloaded on first run to `test/fixtures/` (gitignored).

- Added `keys: :intern` validation against the full JSONTestSuite.

## [0.1.1] - 2025-01-24

### Changed

- Updated hex.pm description for better discoverability

## [0.1.0] - 2025-01-24

### Added

- **High-performance JSON encoding** - 3-6x faster than Jason for medium/large payloads
- **Memory efficient** - 10-20x lower memory usage during encoding
- **Full JSON spec compliance** - 89 tests covering RFC 8259
- **Drop-in Jason replacement** - Compatible API with `encode/2`, `decode/2`, `encode_to_iodata/2`
- **Phoenix integration** - Works with `config :phoenix, :json_library, RustyJson`

#### Encoding Features

- Native Rust handling for `DateTime`, `NaiveDateTime`, `Date`, `Time`, `Decimal`, `URI`, `MapSet`, `Range`
- Multiple escape modes: `:json`, `:html_safe`, `:javascript_safe`, `:unicode_safe`
- Pretty printing with configurable indentation
- Gzip compression with `compress: :gzip` option
- `lean: true` option for maximum performance (skips struct type detection)
- `protocol: true/false` option for custom encoding via `RustyJson.Encoder` protocol (default changed to `true` in v0.3.0)

#### Jason Compatibility

- `RustyJson.Encoder` protocol with `@derive` support
- `RustyJson.Encoder` protocol with `@derive` support
- `RustyJson.Fragment` for injecting pre-encoded JSON
- `RustyJson.Formatter` for pretty-printing and minifying JSON strings

#### Safety

- **Zero `unsafe` code** in RustyJson source (all unsafe is in audited dependencies)
- 128-level nesting depth limit per RFC 7159
- Safe Rust guarantees memory safety at compile time

### Technical Details

- Built with Rustler 0.37+ for modern OTP compatibility (24-27)
- Uses [mimalloc](https://github.com/microsoft/mimalloc) as default allocator
- Uses [itoa](https://github.com/dtolnay/itoa) and [ryu](https://github.com/dtolnay/ryu) for fast number formatting
- Uses [lexical-core](https://github.com/Alexhuszagh/rust-lexical) for number parsing
- Zero-copy string handling in decoder for unescaped strings
- 256-byte lookup table for O(1) escape detection

[0.3.0]: https://github.com/jeffhuen/rustyjson/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/jeffhuen/rustyjson/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/jeffhuen/rustyjson/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/jeffhuen/rustyjson/releases/tag/v0.1.0
