# Publishing RustyJson

From: https://hexdocs.pm/rustler_precompiled/precompilation_guide.html#recommended-flow

## Release Process

1. Update version in `mix.exs` (`@version`)
2. Update version in `native/rustyjson/Cargo.toml`
3. Update `CHANGELOG.md` with changes
4. Commit changes: `git commit -am "Prepare vX.Y.Z release"`
5. Create git tag: `git tag vX.Y.Z` (must match Mix version with `v` prefix)
6. Push with tags: `git push && git push --tags`
7. Wait for GitHub Actions to build all precompiled NIFs (~10-15 min)
8. Download checksums: `mix rustler_precompiled.download RustyJson --all`
9. Commit checksums: `git commit -am "Add checksums for vX.Y.Z"`
10. Push: `git push`
11. Publish to Hex: `mix hex.publish`

## Version Checklist

- [ ] `mix.exs` - `@version "X.Y.Z"`
- [ ] `native/rustyjson/Cargo.toml` - `version = "X.Y.Z"`
- [ ] `CHANGELOG.md` - Add release notes under `## [X.Y.Z] - YYYY-MM-DD`
- [ ] Git tag matches Mix version (e.g., `v0.1.0` for version `0.1.0`)

## Precompiled Targets

The release workflow builds for:

| Platform | Targets |
|----------|---------|
| Linux | x86_64, aarch64 (glibc and musl) |
| macOS | x86_64, aarch64 (Apple Silicon) |
| Windows | x86_64 (GNU and MSVC) |
| ARM | armhf, riscv64 |

NIF versions: 2.15 (OTP 24+), 2.16 (OTP 26+), 2.17 (OTP 27+)

## License

MIT License - see [LICENSE](LICENSE)
