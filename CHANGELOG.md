# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- `protocol: true` option for custom encoding via `RustyJson.Encoder` protocol

#### Jason Compatibility

- `RustyJson.Encoder` protocol with `@derive` support
- Automatic fallback to `Jason.Encoder` implementations when `protocol: true`
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

[0.2.0]: https://github.com/jeffhuen/rustyjson/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/jeffhuen/rustyjson/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/jeffhuen/rustyjson/releases/tag/v0.1.0
