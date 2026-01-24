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
| large_list | 2.3 MB | 50,000 items (generated) |
| deep_nested | 1.1 KB | 100 levels deep (generated) |
| wide_object | 75 KB | 5,000 keys (generated) |

## Results Summary

### Decode Performance

| Input | RustyJson | Jason | Speedup | Memory Reduction |
|-------|-----------|-------|---------|------------------|
| canada.json (2.1MB) | 8.51 ms | 29.42 ms | **3.5x faster** | **7,274x less** |
| citm_catalog.json (1.6MB) | 2.85 ms | 9.39 ms | **3.3x faster** | **2,794x less** |
| twitter.json (617KB) | 1.91 ms | 4.53 ms | **2.4x faster** | **1,198x less** |
| large_list (50k items) | 15.81 ms | 35.78 ms | **2.3x faster** | **13,974x less** |
| deep_nested (100 levels) | 7.89 μs | 7.23 μs | 1.1x slower | **10x less** |
| wide_object (5k keys) | 0.59 ms | 1.24 ms | **2.1x faster** | **403x less** |

### Encode Performance

| Input | RustyJson | Jason | Speedup | Memory Reduction |
|-------|-----------|-------|---------|------------------|
| canada (2.1MB) | 4.41 ms | 12.95 ms | **2.9x faster** | **52,567x less** |
| citm_catalog (1.6MB) | 2.08 ms | 4.27 ms | **2.1x faster** | **27,382x less** |
| twitter (617KB) | 1.21 ms | 3.53 ms | **2.9x faster** | **14,495x less** |
| large_list (50k items) | 12.02 ms | 27.99 ms | **2.3x faster** | **169,566x less** |
| deep_nested (100 levels) | 10.65 μs | 10.63 μs | 1.0x (same) | **88x less** |
| wide_object (5k keys) | 282.48 μs | 691.03 μs | **2.4x faster** | **4,785x less** |

### Roundtrip Performance (Decode + Encode)

| Input | RustyJson | Jason | Speedup | Memory Reduction |
|-------|-----------|-------|---------|------------------|
| canada.json (2.1MB) | 13.81 ms | 47.71 ms | **3.5x faster** | **11,967x less** |
| citm_catalog.json (1.6MB) | 5.63 ms | 14.00 ms | **2.5x faster** | **5,378x less** |
| twitter.json (617KB) | 3.87 ms | 8.85 ms | **2.3x faster** | **2,581x less** |

## Key Findings

1. **Consistent speedup**: RustyJson is 2-3.5x faster than Jason across all real-world datasets.

2. **Dramatic memory reduction**: RustyJson uses 1,000x to 170,000x less memory during encoding. This is due to RustyJson writing directly to a single Rust buffer vs Jason creating many intermediate BEAM binaries.

3. **Small payload overhead**: For tiny payloads (< 1KB), NIF call overhead makes RustyJson roughly equivalent to Jason. This is expected and acceptable.

4. **Best for**: Medium to large JSON payloads (1KB - 100MB+), high-throughput APIs, memory-constrained environments.

## Running Benchmarks

To run these benchmarks yourself:

```bash
# 1. Add benchmark dependencies to mix.exs (dev only)
# {:benchee, "~> 1.0", only: :dev},
# {:benchee_html, "~> 1.0", only: :dev},
# {:benchee_markdown, "~> 0.3", only: :dev}

# 2. Fetch dependencies
mix deps.get

# 3. Download test data
mkdir -p bench/data && cd bench/data
curl -LO https://raw.githubusercontent.com/miloyip/nativejson-benchmark/master/data/canada.json
curl -LO https://raw.githubusercontent.com/miloyip/nativejson-benchmark/master/data/citm_catalog.json
curl -LO https://raw.githubusercontent.com/miloyip/nativejson-benchmark/master/data/twitter.json
cd ../..

# 4. Run benchmarks
mix run bench/stress_bench.exs
```

Results will be output to the console and saved to `bench/output/` (HTML and Markdown formats).
