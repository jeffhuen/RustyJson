# RustyJson Benchmarks

Comprehensive benchmarks comparing RustyJson vs Jason across synthetic and real-world datasets.

## Key Findings

1. **Encoding is where RustyJson shines** - 3-6x faster, 2-3x less memory
2. **Decoding is faster** (2-3x) but memory usage is similar (both produce identical Elixir terms)
3. **Larger payloads = bigger advantage** - Real-world 10MB files show better results than synthetic benchmarks
4. **BEAM scheduler load dramatically reduced** - 100-28,000x fewer reductions

## Test Environment

| Attribute | Value |
|-----------|-------|
| OS | macOS |
| CPU | Apple M1 Pro |
| Cores | 10 |
| Memory | 16 GB |
| Elixir | 1.19.4 |
| Erlang/OTP | 28.2 |

## Real-World Benchmarks: Amazon Settlement Reports

These are production JSON files from Amazon SP-API settlement reports, representing real-world API response patterns with nested objects, arrays of transactions, and mixed data types.

### Encoding Performance (Elixir → JSON)

| File Size | RustyJson | Jason | Speed | Memory |
|-----------|-----------|-------|-------|--------|
| 10.87 MB | 24 ms | 131 ms | **5.5x faster** | **2.7x less** |
| 9.79 MB | 21 ms | 124 ms | **5.9x faster** | **2-3x less** |
| 9.38 MB | 21 ms | 104 ms | **5.0x faster** | **2-3x less** |

### Decoding Performance (JSON → Elixir)

| File Size | RustyJson | Jason | Speed | Memory |
|-----------|-----------|-------|-------|--------|
| 10.87 MB | 61 ms | 152 ms | **2.5x faster** | similar |
| 9.79 MB | 55 ms | 134 ms | **2.4x faster** | similar |
| 9.38 MB | 50 ms | 119 ms | **2.4x faster** | similar |

### BEAM Reductions (Scheduler Load)

| File Size | RustyJson | Jason | Reduction |
|-----------|-----------|-------|-----------|
| 10.87 MB encode | 404 | 11,570,847 | **28,641x fewer** |

This is the most dramatic difference - RustyJson offloads virtually all work to native code.

## Synthetic Benchmarks: nativejson-benchmark

Using standard datasets from [nativejson-benchmark](https://github.com/miloyip/nativejson-benchmark):

| Dataset | Size | Description |
|---------|------|-------------|
| canada.json | 2.1 MB | Geographic coordinates (number-heavy) |
| citm_catalog.json | 1.6 MB | Event catalog (mixed types) |
| twitter.json | 617 KB | Social media with CJK (unicode-heavy) |

### Roundtrip Performance (Decode + Encode)

| Input | RustyJson | Jason | Speedup |
|-------|-----------|-------|---------|
| canada.json | 14 ms | 48 ms | **3.4x faster** |
| citm_catalog.json | 6 ms | 14 ms | **2.5x faster** |
| twitter.json | 4 ms | 9 ms | **2.3x faster** |

### BEAM Reductions by Dataset

| Dataset | RustyJson | Jason | Ratio |
|---------|-----------|-------|-------|
| canada.json | ~3,500 | ~964,000 | **275x fewer** |
| citm_catalog.json | ~300 | ~621,000 | **2,000x fewer** |
| twitter.json | ~2,000 | ~511,000 | **260x fewer** |

## Why Encoding Shows Bigger Gains

### Jason's Encoding Pattern

```
encode(data)
  → allocate "{" binary
  → allocate "\"key\"" binary
  → allocate ":" binary
  → allocate "\"value\"" binary
  → allocate list cells to link them
  → return iolist (many BEAM allocations)
```

### RustyJson's Encoding Pattern

```
encode(data)
  → [Rust: walk terms, write to single buffer]
  → copy buffer to BEAM binary
  → return binary (one BEAM allocation)
```

Jason creates many small BEAM allocations that cause GC pressure. RustyJson creates one.

### Why Decoding Memory is Similar

Both libraries produce identical Elixir data structures when decoding. The resulting maps, lists, and strings take the same space regardless of which library created them.

## Why Benchee Memory Measurements Don't Work for NIFs

**Important**: Benchee's `memory_time` option gives misleading results for NIF-based libraries.

### What Benchee Reports (Incorrect)

```
| Library   | Memory    |
|-----------|-----------|
| RustyJson | 0.00169 MB |
| Jason     | 20.27 MB   |
```

This suggests 12,000x less memory - which is wrong.

### Why This Happens

Benchee measures memory using `:erlang.memory/0`, which only tracks BEAM allocations:
- BEAM process heap
- BEAM binary space
- ETS tables

RustyJson allocates memory in **Rust via mimalloc**, completely invisible to BEAM tracking. The 0.00169 MB is just NIF call overhead.

### How We Measure Instead

We use `:erlang.memory(:total)` delta in isolated spawned processes:

```elixir
spawn(fn ->
  :erlang.garbage_collect()
  before = :erlang.memory(:total)
  results = for _ <- 1..10, do: RustyJson.encode!(data)
  after_mem = :erlang.memory(:total)
  # Report (after_mem - before) / 10
end)
```

This captures BEAM allocations during the operation. For total system memory (including NIF), we verified with RSS measurements that Rust adds only ~1-2 MB temporary overhead.

### Actual Memory Comparison

For a 10 MB settlement report encode:

| Metric | RustyJson | Jason |
|--------|-----------|-------|
| BEAM memory | 6.7 MB | 17.9 MB |
| NIF overhead | ~1-2 MB | N/A |
| **Total** | **~8 MB** | **~18 MB** |
| **Ratio** | | **2-3x less** |

## Running Benchmarks

```bash
# 1. Download synthetic test data
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

## Summary

| Operation | Speed | Memory | Reductions |
|-----------|-------|--------|------------|
| **Encode (large)** | 5-6x faster | 2-3x less | 28,000x fewer |
| **Encode (medium)** | 2-3x faster | 2-3x less | 200-2000x fewer |
| **Decode** | 2-3x faster | similar | — |

**Bottom line**: RustyJson's biggest advantage is encoding large payloads, where it's 5-6x faster with 2-3x less memory and dramatically reduced BEAM scheduler load.
