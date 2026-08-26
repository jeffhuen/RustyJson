# CPU targeting

RustyJson's published artifacts target the **x86_64 baseline** (SSE2, 16-byte
SIMD) and the AArch64 baseline (NEON). There are no CPU-specific precompiled
variants. If you want code tuned to your exact processor, build from source.

## Why no precompiled AVX2 build

Shipping a CPU-specific artifact means deciding, at install time, what the host
CPU can do — and then downloading a binary that will crash if the guess is
wrong. An AVX2 binary on a CPU without AVX2 is an illegal instruction, which
takes down the whole VM.

Through v0.4.1 RustyJson shipped an AVX2 variant selected by a compile-time
probe. Each platform's branch had a distinct problem:

| Platform | How it guessed | Problem |
|---|---|---|
| Linux | read `/proc/cpuinfo` | correct, but silently shelled out when `/proc` wasn't mounted |
| macOS | `System.cmd("sysctl", ...)` | compile-time subprocess; trips dependency audits, and resolves `sysctl` through `PATH` |
| Windows | hardcoded `true` | **wrong.** Any x86_64 Windows machine without AVX2 got a crashing binary |

The Windows branch assumed "practically all x86_64 Windows machines are Haswell
or newer," which conflates *Haswell-or-newer* with *has AVX2*. Atom-lineage
parts (Apollo Lake, Gemini Lake — common in budget laptops and mini-PCs) shipped
without AVX2 well into 2020, as did AMD before Zen. Those machines received a
binary that could not run.

None of that is fixable in the general case, because the premise is unsound: the
machine that builds the artifact is not the machine that runs it. Building from
source removes the guess entirely — the compiler sees the actual CPU.

## Building for your own CPU

```sh
RUSTFLAGS="-C target-cpu=native" FORCE_RUSTYJSON_BUILD=1 mix compile
```

This requires a Rust toolchain. `native` targets the exact host processor, which
is strictly better than the fixed `x86-64-v3` floor the old variant used.

To build for a specific baseline instead of the host — for example when the
build machine and the deployment target differ — name it explicitly:

```sh
RUSTFLAGS="-C target-cpu=x86-64-v3" FORCE_RUSTYJSON_BUILD=1 mix compile
```

> **`-C target-cpu=native` has the same hazard as the old variant, just moved.**
> If you build in a container or CI image and deploy the result to a different
> machine, you can produce exactly the crash described above. Use an explicit
> `target-cpu` whenever the build host and run host may differ.

### Setting `RUSTFLAGS` replaces `.cargo/config.toml`, it does not merge

Cargo picks exactly one source of rustflags. Setting the `RUSTFLAGS` environment
variable overrides the `[target.*] rustflags` entries in
`native/rustyjson/.cargo/config.toml` wholesale rather than adding to them.

This matters for **musl** targets, which need `-C target-feature=-crt-static` to
produce a loadable `cdylib`. If you set `RUSTFLAGS` on musl, carry that flag
yourself:

```sh
RUSTFLAGS="-C target-feature=-crt-static -C target-cpu=native" \
  FORCE_RUSTYJSON_BUILD=1 mix compile
```

## What a baseline build still gets

Dropping the variants does not mean giving up AVX2 entirely. `simdutf8`, which
RustyJson uses for UTF-8 validation, dispatches at **runtime**: it compiles an
AVX2 implementation behind `#[target_feature]` and calls it only after checking
the CPU. A baseline artifact contains that code and uses it on capable
hardware — verified by disassembling the published binary, where every AVX2
instruction in the x86_64 baseline artifact lives in
`simdutf8::…::avx2::validate_utf8_basic` and nowhere else.

Runtime dispatch is what makes this safe: one binary, correct everywhere, fast
where it can be. RustyJson's own scanning paths use `std::simd` and are selected
at compile time instead, so those run SSE2 in a baseline build. That is the only
part a source build changes.

## Is it worth it?

Measured on `ubuntu-22.04`, comparing an `x86-64-v3` build against baseline,
each benchmark checked against its own A/A noise floor:

| Path | Effect of AVX2 |
|---|---|
| `string_scan` — clean ASCII/UTF-8, 512 B–64 KB | **45–55% faster** |
| `string_scan` — clean ASCII/UTF-8, 32–128 B | 26–46% faster |
| `string_scan` — **escaped** strings, 128 B–64 KB | **29–40% slower** |
| `escape_decode` — heavily escaped | 22–27% slower |
| Number parsing, hashing | no consistent effect |

Wider chunks help when there is nothing to find and hurt when there is: on
escape-dense input the vector loop bails out early and repeatedly, paying setup
cost it never amortizes.

**These are microbenchmarks of internal scanning functions, not end-to-end
decode.** Scanning is a minority of total decode time — term construction
(`enif_make_*`) dominates — so the end-to-end effect is substantially smaller
than the figures above in both directions. Measure your own workload before
assuming a CPU-specific build is worth the build-time cost, particularly if your
JSON is escape-heavy.

Reproduce with the `AVX2 benchmark` workflow in `.github/workflows/`.
