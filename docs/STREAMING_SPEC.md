# Streaming JSON Encode/Decode Specification

> **Status: Under Consideration**
> This is a design document exploring potential streaming support. Not yet implemented or committed to.

This document outlines the architectural design for streaming JSON encoding and decoding in RustyJson.

## Motivation

Current RustyJson requires the entire data structure in memory before encoding, and the entire JSON string before decoding. For 100MB+ payloads, this creates memory pressure even though RustyJson is already 2-3x more efficient than Jason.

**Goal**: Enable processing of arbitrarily large JSON without holding everything in memory.

## Design Principles

1. **Single-pass processing** - Never walk terms twice, never re-parse bytes
2. **Minimal copying** - Data flows through, not accumulated
3. **Memory bounded** - Peak memory independent of total payload size
4. **NIF-safe** - Don't block BEAM schedulers
5. **Composable** - Works with Elixir Stream/Enum
6. **Zero unsafe Rust** - Maintain our safety guarantees

## Streaming Encode

### API Design

```elixir
# Stream of terms → Stream of JSON chunks
items
|> RustyJson.encode_stream()
|> Enum.into(file)

# With options
items
|> RustyJson.encode_stream(chunk_size: 64_000)
|> Stream.into(socket)
```

### Semantics

The input stream is treated as a **JSON array**:

```elixir
Stream.repeatedly(fn -> %{id: 1} end)
|> Stream.take(3)
|> RustyJson.encode_stream()
|> Enum.to_list()

# => ["[", "{\"id\":1}", ",{\"id\":2}", ",{\"id\":3}", "]"]
```

Each chunk is valid UTF-8 but not necessarily valid standalone JSON.

### Architecture Options

#### Option A: Chunked NIF Calls (Recommended)

```
Elixir Stream                          Rust NIF
     │                                     │
     │──── first item ────────────────────▶│
     │                                     │ encode item
     │◀─── "[" + encoded ─────────────────│
     │                                     │
     │──── next item ─────────────────────▶│
     │                                     │ encode item
     │◀─── "," + encoded ─────────────────│
     │                                     │
     │──── :done ─────────────────────────▶│
     │◀─── "]" ───────────────────────────│
```

**Pros:**
- Each NIF call is short (~1ms for reasonable items)
- No state management complexity
- BEAM scheduler friendly
- Natural backpressure via Stream

**Cons:**
- NIF call overhead per item (~0.1ms)
- Can't batch small items efficiently

**Implementation:**
```rust
#[rustler::nif]
fn encode_stream_item(term: Term, is_first: bool) -> Result<String, String> {
    let prefix = if is_first { "[" } else { "," };
    let json = encode_term(term)?;
    Ok(format!("{}{}", prefix, json))
}

#[rustler::nif]
fn encode_stream_end() -> &'static str {
    "]"
}
```

#### Option B: Dirty Scheduler + Yielding

```
Elixir                              Dirty Scheduler NIF
   │                                        │
   │──── entire stream ────────────────────▶│
   │                                        │ for each item:
   │                                        │   encode
   │◀──── chunk ───────────────────────────│   yield chunk
   │                                        │   encode
   │◀──── chunk ───────────────────────────│   yield chunk
   │                                        │   ...
   │◀──── done ────────────────────────────│
```

**Pros:**
- No per-item NIF overhead
- Can batch intelligently
- Single context for entire stream

**Cons:**
- Requires dirty scheduler (blocks one dirty thread)
- Complex yielding mechanism (enif_consume_timeslice?)
- Harder to implement correctly

**Not recommended** - complexity not justified for JSON encoding.

#### Option C: Batched Chunked Calls (Hybrid)

```elixir
items
|> Stream.chunk_every(100)  # Batch 100 items
|> Stream.flat_map(&RustyJson.encode_batch/1)
```

**Pros:**
- Amortizes NIF overhead
- Still scheduler-friendly
- Simple implementation

**Cons:**
- User must choose batch size
- Doesn't help if items are already large

**Implementation:**
```rust
#[rustler::nif]
fn encode_batch(terms: Vec<Term>, is_first_batch: bool) -> Result<String, String> {
    let mut result = String::new();
    for (i, term) in terms.iter().enumerate() {
        if i == 0 && is_first_batch {
            result.push('[');
        } else {
            result.push(',');
        }
        encode_term_into(term, &mut result)?;
    }
    Ok(result)
}
```

### Recommendation: Option A + Optional Batching

Start with Option A (simple chunked calls). If benchmarks show NIF overhead is significant for small items, add Option C as `encode_stream(batch_size: 100)`.

## Streaming Decode

### API Design

```elixir
# Stream of bytes → Stream of parsed items
File.stream!("huge.json", [], 64_000)
|> RustyJson.decode_stream()
|> Stream.each(&process/1)
|> Stream.run()

# From single binary (for top-level array)
RustyJson.decode_stream(huge_json)
|> Enum.take(10)
```

### Semantics

Input must be a **JSON array at the top level**. Each element is yielded as parsed:

```elixir
"[{\"a\":1},{\"b\":2},{\"c\":3}]"
|> RustyJson.decode_stream()
|> Enum.to_list()

# => [%{"a" => 1}, %{"b" => 2}, %{"c" => 3}]
```

### Architecture Options

#### Option A: Stateful Parser Resource (Recommended)

```
Elixir                              Rust NIF
   │                                    │
   │──── create_parser() ──────────────▶│
   │◀──── parser_ref ──────────────────│  (NIF resource)
   │                                    │
   │──── feed(ref, chunk) ─────────────▶│
   │                                    │  parse chunk
   │                                    │  buffer incomplete token
   │◀──── [item1, item2] ──────────────│  return complete items
   │                                    │
   │──── feed(ref, chunk) ─────────────▶│
   │                                    │  continue parsing
   │◀──── [item3] ─────────────────────│
   │                                    │
   │──── finish(ref) ──────────────────▶│
   │                                    │  validate EOF
   │◀──── :ok / {:error, ...} ─────────│
```

**Pros:**
- Handles tokens split across chunks
- Minimal memory (only buffers incomplete tokens)
- Each `feed` call is short
- Clean resource cleanup via Rustler

**Cons:**
- State management complexity
- Must handle all edge cases (strings with escapes spanning chunks, etc.)

**Implementation:**
```rust
struct StreamParser {
    buffer: Vec<u8>,      // Incomplete data from last chunk
    depth: usize,         // Current nesting depth
    in_string: bool,      // Are we inside a string?
    escape_next: bool,    // Was last char a backslash?
    position: usize,      // Byte position for errors
}

#[rustler::resource]
impl StreamParser {
    fn feed(&mut self, chunk: &[u8]) -> Result<Vec<Term>, Error> {
        // Append chunk to buffer
        // Scan for complete top-level array elements
        // Parse and return complete elements
        // Keep incomplete data in buffer
    }
}
```

#### Option B: Chunk-at-a-time (Simpler but Limited)

Only works if each chunk contains complete JSON values:

```rust
#[rustler::nif]
fn decode_one(json: &str, offset: usize) -> Result<(Term, usize), Error> {
    // Parse one value starting at offset
    // Return (value, new_offset)
}
```

**Pros:**
- Stateless, simple
- No resource management

**Cons:**
- Fails if values span chunks
- User must handle chunking correctly

**Not recommended** - too fragile for real use.

### Recommendation: Option A (Stateful Parser)

The complexity is justified because:
1. Real-world JSON chunks don't align with value boundaries
2. Strings can contain escaped characters spanning chunks
3. Users expect it to "just work"

## Memory Analysis

### Current (Non-Streaming)

```
10 MB JSON array with 10,000 items

Decode:
  Input:  10 MB (JSON string)
  Output: 15 MB (Elixir terms)
  Peak:   25 MB

Encode:
  Input:  15 MB (Elixir terms)
  Output: 10 MB (JSON binary)
  Peak:   25 MB
```

### With Streaming

```
Same 10 MB JSON array

Streaming Decode:
  Input buffer:  64 KB (chunk size)
  Item buffer:   ~1 KB (one item)
  Output:        yielded immediately
  Peak:          < 1 MB (independent of total size!)

Streaming Encode:
  Input:         one item at a time
  Output buffer: ~1 KB (one encoded item)
  Peak:          < 1 MB
```

## Edge Cases

### Streaming Decode

1. **Whitespace between elements**: Must handle `[ 1 , 2 ]` with arbitrary whitespace
2. **Strings with commas**: `["a,b", "c"]` - comma inside string isn't delimiter
3. **Nested arrays/objects**: `[[1,2], [3,4]]` - only yield top-level elements
4. **Escape sequences**: `["line1\nline2"]` - handle `\n`, `\uXXXX`, etc.
5. **Chunk boundary in string**: `"hel` | `lo"` - buffer incomplete string
6. **Chunk boundary in escape**: `"\u00` | `41"` - buffer incomplete escape
7. **Empty array**: `[]` - yield nothing, return `:ok`
8. **Not an array**: `{"a":1}` - return error (top-level must be array)

### Streaming Encode

1. **Nil/null values**: Encode as `null`
2. **Nested structures**: Fully encode each item (no partial objects)
3. **Encoding errors**: Stop stream, return error
4. **Empty stream**: Return `[]`
5. **Protocol types**: Support `RustyJson.Encoder` protocol if enabled

## Performance Targets

| Operation | Current | Streaming Target | Notes |
|-----------|---------|------------------|-------|
| Encode 10MB | 24 ms | 30 ms | ~25% overhead acceptable |
| Decode 10MB | 61 ms | 75 ms | ~25% overhead acceptable |
| Peak memory | 25 MB | < 1 MB | Main goal |
| Per-item overhead | N/A | < 0.01 ms | Must be negligible |

## API Summary

```elixir
# Streaming encode
@spec encode_stream(Enumerable.t(), keyword()) :: Enumerable.t()
def encode_stream(items, opts \\ [])

# Streaming decode from chunks
@spec decode_stream(Enumerable.t(), keyword()) :: Enumerable.t()
def decode_stream(chunks, opts \\ [])

# Streaming decode from binary (convenience)
@spec decode_stream(binary(), keyword()) :: Enumerable.t()
def decode_stream(json, opts \\ []) when is_binary(json)

# Options:
#   chunk_size: integer() - target output chunk size for encode (default: 65536)
#   batch_size: integer() - items to batch per NIF call (default: 1)
```

## Implementation Phases

### Phase 1: Streaming Encode (Simpler)

1. Implement `encode_stream_item/2` NIF
2. Implement `encode_stream_end/0` NIF
3. Build Elixir `Stream` wrapper
4. Add tests for all edge cases
5. Benchmark against non-streaming

### Phase 2: Streaming Decode (Complex)

1. Implement `StreamParser` Rustler resource
2. Implement `create_parser/0`, `feed/2`, `finish/1` NIFs
3. Build Elixir `Stream` wrapper
4. Handle all edge cases (chunk boundaries, escapes, etc.)
5. Add comprehensive tests
6. Benchmark against non-streaming

### Phase 3: Optimization

1. Add batching option for small items
2. Profile and optimize hot paths
3. Buffer reuse to minimize allocations

## Techniques Investigated (Not Beneficial for NIFs)

We evaluated several advanced parsing techniques and found they don't help for Elixir/BEAM NIFs:

### SIMD Structural Indexing

**What it is**: Use SIMD instructions to find structural characters (`[`, `]`, `{`, `}`, `,`, `"`) in parallel, processing 32-64 bytes at once. This is how simdjson achieves its speed.

**Why it doesn't help us**: The bottleneck for JSON NIFs isn't parsing—it's **building BEAM terms**. SIMD can find structure 10-20x faster, but term construction (allocating on BEAM heap via Rustler) dominates total time. We tested simd-json and sonic-rs for non-streaming decode and they were actually **slower** due to the required serde intermediate step.

For streaming, SIMD would only speed up finding element boundaries, which is already fast with simple byte scanning. Not worth the complexity.

### Parallel Element Parsing

**What it is**: Once element boundaries are known, parse multiple elements on different threads using rayon or similar.

**Why it doesn't help us**:
1. NIF environments are tied to BEAM schedulers
2. Terms created on the wrong scheduler require `enif_make_copy` (expensive)
3. Coordination overhead between threads can eat the parallelism benefit
4. Term construction is still the bottleneck, now with added synchronization

### Zero-Copy String References

**What it is**: Return references into the original JSON buffer instead of copying string bytes. Only copy when escape processing is needed.

**Why it doesn't help us**: BEAM needs to own all data. We can't return pointers into Rust memory—the data must be copied to BEAM heap eventually. The copy is unavoidable.

### Tape-Based Parsing

**What it is**: Build a flat "tape" of tokens in first pass, then traverse tape to build output.

**Why it doesn't help us**: Adds an intermediate representation (the tape) without reducing term construction work. Actually increases total allocations.

### What Actually Helps

| Technique | Status | Benefit |
|-----------|--------|---------|
| Adaptive batching | Recommended | Amortizes NIF call overhead |
| Buffer reuse | Recommended | Reduces allocations |
| Simple state machine | Implemented | Minimal overhead for boundary detection |
| SIMD parsing | Investigated | Not beneficial (term construction dominates) |
| Parallel parsing | Investigated | Not beneficial (scheduler/copy overhead) |
| Zero-copy strings | Investigated | Not possible (BEAM must own data) |

## Open Questions

1. **Should streaming decode support objects as root?** Could yield `{key, value}` tuples.
2. **Should we support NDJSON (newline-delimited)?** Common for log files.
3. **What chunk size default?** 64KB seems reasonable, needs benchmarking.
4. **Should errors be exceptions or tagged tuples?** Current API uses both patterns.

## References

- [Rustler Resources](https://docs.rs/rustler/latest/rustler/resource/index.html)
- [ijson (Python streaming)](https://github.com/ICRAR/ijson)
- [Go json.Decoder](https://pkg.go.dev/encoding/json#Decoder)
- [simdjson On-Demand API](https://github.com/simdjson/simdjson/blob/master/doc/ondemand.md)
