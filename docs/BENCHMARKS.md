# RustyJson Benchmarks

Benchmarks comparing RustyJson vs Jason using real-world datasets from [nativejson-benchmark](https://github.com/miloyip/nativejson-benchmark).

## Test Environment

| Attribute | Value |
|-----------|-------|
| OS | macOS |
| CPU | Apple M1 Pro |
| Cores | 10 |
| Memory | 16 GB |
| Elixir | 1.19.4 |
| Erlang/OTP | 28.2 |

## Test Data

| Dataset | Size | Description |
|---------|------|-------------|
| canada.json | 2.1 MB | Geographic coordinates (number-heavy) |
| citm_catalog.json | 1.6 MB | Event catalog (mixed types) |
| twitter.json | 617 KB | Social media with CJK (unicode-heavy) |

## Results Summary

### Speed Performance

| Input | RustyJson | Jason | Speedup |
|-------|-----------|-------|---------|
| canada.json (2.1MB) | 14 ms | 48 ms | **3.4x faster** |
| citm_catalog.json (1.6MB) | 6 ms | 14 ms | **2.5x faster** |
| twitter.json (617KB) | 4 ms | 9 ms | **2.3x faster** |

### Memory Performance

| Input | RustyJson | Jason | Reduction |
|-------|-----------|-------|-----------|
| canada.json (2.1MB) | 2.4 MB | 5.8 MB | **2-3x less** |
| citm_catalog.json (1.6MB) | 0.5 MB | 2.1 MB | **3-4x less** |
| twitter.json (617KB) | ~0.7 MB | ~0.7 MB | similar |

*Memory measured via `:erlang.memory(:total)` delta in isolated processes. See methodology below.*

## Key Findings

1. **Consistent speedup**: RustyJson is **2-3x faster** than Jason across all operations.

2. **Encode memory efficiency**: RustyJson uses **2-4x less BEAM memory** for encoding larger payloads because it returns a single binary instead of an iolist.

3. **Decode memory**: Similar to Jason - both produce identical Elixir data structures.

4. **Best for**: Medium to large JSON payloads (1KB+), high-throughput APIs, latency-sensitive applications.

## Why Benchee Memory Measurements Don't Work for NIFs

**Important**: Benchee's memory measurement feature does not work correctly for NIF-based libraries like RustyJson.

### What Benchee Reports (Incorrect)

When running Benchee with `memory_time: 2`, you may see results like:

| Library | Memory |
|---------|--------|
| RustyJson | 0.00169 MB |
| Jason | 20.27 MB |

This suggests RustyJson uses **12,000x less memory** - which is wrong.

### Why This Happens

Benchee measures memory using BEAM introspection (`:erlang.memory/0`). This only tracks:
- BEAM process heap allocations
- BEAM binary allocations
- ETS table memory

RustyJson allocates memory in **Rust via mimalloc**, which is completely invisible to BEAM's memory tracking. The 0.00169 MB Benchee reports is just the overhead of the NIF call itself, not the actual memory used.

### Can Benchee Be Fixed?

No, there's no way to make Benchee measure NIF memory correctly because:

1. **NIF memory is off-heap**: Rust's allocator (mimalloc) manages its own memory pool outside the BEAM
2. **No BEAM visibility**: `:erlang.memory/0` cannot see native allocations
3. **Cross-runtime barrier**: The BEAM has no mechanism to query memory from embedded native code

To properly measure NIF memory, you would need:
- System-level memory tracking (RSS before/after)
- Custom allocator instrumentation in the Rust code
- External profiling tools like Instruments or Valgrind

### What We Actually Measured

We use `:erlang.memory(:total)` delta in isolated processes, which captures:
- All BEAM allocations during the operation
- The final binary/data structure retained

This gives a fair comparison of BEAM-side memory impact, though it still doesn't capture temporary Rust allocations (which are freed immediately when the NIF returns).

## Understanding the Memory Difference

### Why RustyJson Uses Less Memory for Encoding

**Jason's allocation pattern:**
```
encode(data)
  → allocate "{" binary
  → allocate "\"key\"" binary
  → allocate ":" binary
  → allocate "\"value\"" binary
  → allocate list cells to link them
  → return iolist (many small BEAM allocations)
```

**RustyJson's allocation pattern:**
```
encode(data)
  → [Rust: allocate buffer, write JSON, free buffer]
  → copy to single BEAM binary
  → return binary (one BEAM allocation)
```

Jason creates many small allocations that cause GC pressure. RustyJson creates one allocation.

### BEAM Work Comparison

```elixir
# Reductions (BEAM work units) for encoding:
# canada.json:       RustyJson ~3,500   vs Jason ~964,000  (275x fewer)
# citm_catalog.json: RustyJson ~300     vs Jason ~621,000  (2000x fewer)
# twitter.json:      RustyJson ~2,000   vs Jason ~511,000  (260x fewer)
```

The real benefit of RustyJson is **reduced BEAM scheduler load** (100-2000x fewer reductions) - all the heavy lifting happens in native code.

## Running Benchmarks

```bash
# 1. Download test data
mkdir -p bench/data && cd bench/data
curl -LO https://raw.githubusercontent.com/miloyip/nativejson-benchmark/master/data/canada.json
curl -LO https://raw.githubusercontent.com/miloyip/nativejson-benchmark/master/data/citm_catalog.json
curl -LO https://raw.githubusercontent.com/miloyip/nativejson-benchmark/master/data/twitter.json
cd ../..

# 2. Run memory benchmarks (no extra deps needed)
mix run bench/memory_bench.exs

# 3. (Optional) Run speed benchmarks with Benchee
# Add to mix.exs: {:benchee, "~> 1.0", only: :dev}
mix deps.get
mix run bench/stress_bench.exs
```

## Methodology Notes

- **Speed**: Benchee with `warmup: 2s, time: 5s` - reliable and accurate
- **Memory**: `:erlang.memory(:total)` delta in isolated spawned processes
- **Do NOT use**: Benchee's `memory_time` option for NIF comparisons (gives misleading results)
- Results may vary by ±10-20% across runs due to GC timing
