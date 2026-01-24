# Release Process for RustyJson

1. Update version in `mix.exs` and `CHANGELOG.md`
2. Commit: `git commit -am "Bump version to x.y.z"`
3. Push to main
4. Trigger NIF build: `gh workflow run release.yml --field version=x.y.z`
5. Wait for builds → draft release created
6. Generate checksums: `mix rustler_precompiled.download RustyJson --all --print`
7. Commit and push checksums: `git add checksum-Elixir.RustyJson.exs && git commit -m "Add vx.y.z checksums" && git push`
8. Publish draft release on GitHub
9. Create and push tag: `git tag vx.y.z && git push origin vx.y.z`
10. Publish to Hex: `mix hex.publish`

## Notes

- Step 4 verifies that input version matches `mix.exs`, so steps 1-3 must happen first
- Step 5 creates a **draft** release with all NIF binaries attached
- Step 9 triggers another workflow run, but the release already exists so it just updates it

## Useful commands

```bash
# Monitor build progress
gh run list --workflow=release.yml
gh run watch <run-id>

# Check draft release
gh release view vx.y.z

# Publish draft release
gh release edit vx.y.z --draft=false
```
