# Release Process for RustyJson

## Steps

1. Update version in `mix.exs` and `native/rustyjson/Cargo.toml`
2. Update `CHANGELOG.md`
3. Commit: `git commit -am "Bump version to x.y.z"`
4. Push to main: `git push origin main`
5. Trigger NIF build: `gh workflow run release.yml --field version=x.y.z`
6. **Wait for ALL 45 builds to complete** (~5-10 min)
   ```bash
   gh run watch <run-id>
   ```
7. Verify draft release has 45 assets (30 baseline + 15 AVX2):
   ```bash
   gh release view vx.y.z --json assets --jq '.assets | length'
   ```
8. Publish draft release (assets must be public before checksums can be generated):
   ```bash
   gh release edit vx.y.z --draft=false
   ```
9. Generate checksums: `mix rustler_precompiled.download RustyJson --all --print`
10. Commit checksums: `git add checksum-Elixir.RustyJson.exs && git commit -m "Add vx.y.z checksums" && git push`
11. Publish to Hex: `mix hex.publish`

## Important Notes

- **Do NOT publish the draft release (step 8) until ALL 45 jobs complete and assets are attached**
- The workflow creates a draft release - each job attaches its asset to this draft
- Publishing too early causes a race condition where later jobs fail to attach their assets
- Step 7 verifies all assets are present before proceeding
- Draft release assets are not publicly accessible, so the release must be published before generating checksums
- Publishing the release automatically creates the git tag (no need to create it manually)

## Useful Commands

```bash
# Monitor build progress
gh run list --workflow=release.yml
gh run watch <run-id>

# Check draft release assets
gh release view vx.y.z --json assets --jq '.assets | length'  # Should be 45
gh release view vx.y.z --json assets --jq '.assets[].name'

# If something goes wrong, delete and retry
gh release delete vx.y.z --yes
gh workflow run release.yml --field version=x.y.z
```
