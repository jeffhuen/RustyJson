# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/jeffhuen/rustyjson/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/jeffhuen/rustyjson/releases/tag/v0.1.0
