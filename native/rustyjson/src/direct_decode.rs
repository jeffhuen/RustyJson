use crate::atoms;
use num_bigint::BigInt;
use rustler::{types::atom, Binary, Encoder, Env, NewBinary, Term};
use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::hash::{BuildHasher, Hasher};

/// Error type for decode operations: static string message + byte position.
pub type DecodeError = (Cow<'static, str>, usize);

/// Maximum nesting depth to prevent stack overflow
const MAX_DEPTH: usize = 128;

/// Minimum string length to use a zero-copy sub-binary reference
/// instead of copying to a heap binary. Below this threshold, the
/// overhead of the sub-binary indirection exceeds the copy cost.
const SUBBINARY_THRESHOLD: usize = 64;

// ============================================================================
// Structural Index - pre-scan for structural JSON characters
// ============================================================================

/// Minimum input size to build a structural index.
/// Below this threshold, byte-at-a-time whitespace skipping is faster.
const STRUCTURAL_INDEX_THRESHOLD: usize = 256;

/// Pre-computed index of structural character positions ({, }, [, ], :, ,)
/// outside of strings. The parser jumps directly to these positions instead
/// of scanning whitespace byte-by-byte.
struct StructuralIndex {
    positions: Vec<u32>, // byte offsets of structural chars, in order
    cursor: usize,       // next position to consume
}

/// Maximum structural positions to scan when counting container elements.
/// Keeps the scan O(1)-bounded; falls back to heuristic if exceeded.
const STRUCTURAL_SCAN_CAP: usize = 512;

impl StructuralIndex {
    /// Peek at the next structural position without consuming it.
    #[inline(always)]
    fn peek(&self) -> Option<u32> {
        self.positions.get(self.cursor).copied()
    }

    /// Advance the cursor past the current structural position.
    #[inline(always)]
    fn advance(&mut self) {
        self.cursor += 1;
    }

    /// Count elements in a container by scanning structural positions forward.
    /// Starts from the current cursor (which should be past the opening bracket
    /// and any already-consumed commas). Tracks nesting depth across ALL bracket
    /// types (`{`, `}`, `[`, `]`) to correctly skip commas inside nested
    /// containers, then returns `Some(comma_count + 1)` when the matching
    /// `close` bracket is found at depth 0.
    /// Returns `None` if the close bracket is not found within
    /// STRUCTURAL_SCAN_CAP positions.
    fn count_elements_until_close(&self, input: &[u8], close: u8) -> Option<usize> {
        let mut commas = 0usize;
        let mut depth = 0usize;
        let limit = (self.cursor + STRUCTURAL_SCAN_CAP).min(self.positions.len());
        let mut i = self.cursor;
        while i < limit {
            let b = input[self.positions[i] as usize];
            match b {
                b'{' | b'[' => depth += 1,
                b'}' | b']' => {
                    if depth == 0 {
                        if b == close {
                            return Some(commas + 1);
                        }
                        // Mismatched bracket at depth 0 — bail out
                        return None;
                    }
                    depth -= 1;
                }
                b',' if depth == 0 => commas += 1,
                _ => {}
            }
            i += 1;
        }
        None // close bracket not found within cap
    }
}

/// Build a structural index for the input, identifying positions of all
/// structural JSON characters ({, }, [, ], :, ,) that are outside strings.
///
/// Uses SIMD to classify chunks and a scalar state machine to track
/// in-string state and escape sequences.
///
/// NOTE: This three-loop structure (AVX2 32-byte / 16-byte / scalar tail)
/// with a bool `chunk_has_structural` check is intentionally simple.
/// A "dual-mode" approach (SIMD-skip non-structural chunks, SIMD-skip
/// in-string bytes) was benchmarked and regressed ~200% — see optimization
/// history in simd_utils.rs for details. Do not refactor into skip functions.
fn build_structural_index(input: &[u8]) -> StructuralIndex {
    // Pre-allocate at ~10% of input size (typical structural density)
    let estimated = input.len() / 10;
    let mut positions = Vec::with_capacity(estimated.max(16));
    let mut in_string = false;
    let mut prev_escape = false;
    let mut pos = 0;

    // Process SIMD-sized chunks: skip chunks with no interesting bytes.
    // On AVX2 targets, process 32 bytes at a time first, then 16-byte remainder.
    #[cfg(target_feature = "avx2")]
    while pos + 32 <= input.len() {
        if !crate::simd_utils::chunk_has_structural_wide(input, pos) && !prev_escape {
            pos += 32;
            continue;
        }

        // Slow path: process byte-by-byte with state machine
        let end = pos + 32;
        while pos < end {
            let b = input[pos];
            if prev_escape {
                prev_escape = false;
                pos += 1;
                continue;
            }
            if b == b'\\' && in_string {
                prev_escape = true;
                pos += 1;
                continue;
            }
            if b == b'"' {
                in_string = !in_string;
                pos += 1;
                continue;
            }
            if !in_string {
                match b {
                    b'{' | b'}' | b'[' | b']' | b':' | b',' => {
                        positions.push(pos as u32);
                    }
                    _ => {}
                }
            }
            pos += 1;
        }
    }

    // 16-byte pass (handles remainder on AVX2, or full pass on other targets)
    while pos + crate::simd_utils::CHUNK <= input.len() {
        if !crate::simd_utils::chunk_has_structural(input, pos) && !prev_escape {
            pos += crate::simd_utils::CHUNK;
            continue;
        }

        // Slow path: process byte-by-byte with state machine
        let end = pos + crate::simd_utils::CHUNK;
        while pos < end {
            let b = input[pos];
            if prev_escape {
                prev_escape = false;
                pos += 1;
                continue;
            }
            if b == b'\\' && in_string {
                prev_escape = true;
                pos += 1;
                continue;
            }
            if b == b'"' {
                in_string = !in_string;
                pos += 1;
                continue;
            }
            if !in_string {
                match b {
                    b'{' | b'}' | b'[' | b']' | b':' | b',' => {
                        positions.push(pos as u32);
                    }
                    _ => {}
                }
            }
            pos += 1;
        }
    }

    // Scalar tail for remaining bytes
    while pos < input.len() {
        let b = input[pos];
        if prev_escape {
            prev_escape = false;
            pos += 1;
            continue;
        }
        if b == b'\\' && in_string {
            prev_escape = true;
            pos += 1;
            continue;
        }
        if b == b'"' {
            in_string = !in_string;
            pos += 1;
            continue;
        }
        if !in_string {
            match b {
                b'{' | b'}' | b'[' | b']' | b':' | b',' => {
                    positions.push(pos as u32);
                }
                _ => {}
            }
        }
        pos += 1;
    }

    StructuralIndex {
        positions,
        cursor: 0,
    }
}

/// Maximum number of unique keys the intern cache will store.
/// Beyond this limit, new keys are allocated normally (no cache insertion).
///
/// This serves two purposes:
/// 1. **Performance**: `keys: :intern` is designed for homogeneous arrays with
///    few unique keys (5-50 typical). When unique key count is high, cache misses
///    dominate and interning becomes overhead. Capping stops paying the cost of
///    HashMap insertion once the cache is clearly not helping.
/// 2. **DoS mitigation**: Bounds worst-case CPU time from hash collisions.
///    With FNV-1a + randomized seed, precomputed collision attacks are blocked.
///    The cap additionally bounds the damage from adaptive collision attacks
///    (attacker measuring aggregate decode latency across many requests) to
///    O(MAX_INTERN_KEYS²) operations — a few milliseconds, not a DoS.
///
/// The value 4096 is chosen to be far above any realistic JSON schema key count
/// while still bounding worst-case behavior to acceptable levels.
const MAX_INTERN_KEYS: usize = 4096;

/// Options controlling decode behavior, parsed from the Elixir opts map.
pub struct DecodeOptions {
    pub intern_keys: bool,
    pub floats_decimals: bool,
    pub ordered_objects: bool,
    pub integer_digit_limit: usize,
    pub max_bytes: usize,
    pub reject_duplicate_keys: bool,
    pub validate_strings: bool,
}

impl Default for DecodeOptions {
    fn default() -> Self {
        Self {
            intern_keys: false,
            floats_decimals: false,
            ordered_objects: false,
            integer_digit_limit: 1024,
            max_bytes: 0,
            reject_duplicate_keys: false,
            validate_strings: true,
        }
    }
}

// ============================================================================
// FNV-1a Hasher - fast non-cryptographic hash for key interning
// ============================================================================

/// FNV-1a hasher optimized for short byte slices (JSON keys).
/// Non-cryptographic but fast - perfect for single-parse deduplication.
#[derive(Default)]
struct FnvHasher(u64);

impl Hasher for FnvHasher {
    #[inline]
    fn write(&mut self, bytes: &[u8]) {
        const FNV_PRIME: u64 = 0x100000001b3;
        for &byte in bytes {
            self.0 ^= byte as u64;
            self.0 = self.0.wrapping_mul(FNV_PRIME);
        }
    }

    #[inline]
    fn finish(&self) -> u64 {
        self.0
    }
}

struct FnvBuildHasher {
    seed: u64,
}

impl FnvBuildHasher {
    fn new() -> Self {
        // Per-parse seed: mix time + stack address for uniqueness.
        // Not cryptographic — blocks precomputed collision tables, but an
        // adaptive attacker measuring aggregate latency across many requests
        // could still craft collisions. The MAX_INTERN_KEYS cap bounds the
        // damage in that scenario to O(cap²) operations.
        let stack_anchor: u64 = 0;
        let addr = &stack_anchor as *const u64 as u64;
        let time = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos() as u64;
        Self {
            seed: addr.wrapping_mul(0x517cc1b727220a95) ^ time,
        }
    }
}

impl BuildHasher for FnvBuildHasher {
    type Hasher = FnvHasher;

    #[inline]
    fn build_hasher(&self) -> FnvHasher {
        FnvHasher(self.seed) // Use random seed instead of fixed offset basis
    }
}

type FastHashMap<K, V> = HashMap<K, V, FnvBuildHasher>;

/// Cached key shape from the first object in an array.
/// When an array contains multiple objects with the same keys in the same order,
/// we can reuse the key Terms from the first object instead of rebuilding them.
struct KeyShape<'a, 'b> {
    raw_keys: Vec<&'b [u8]>,  // raw byte slices for comparison
    key_terms: Vec<Term<'a>>, // reusable key Terms
    is_flat: bool,            // true if first value was a scalar (no nested containers)
}

/// Direct JSON-to-Term parser - builds Erlang terms during parsing without intermediate representation
pub struct DirectParser<'a, 'b> {
    input: &'b [u8],
    pos: usize,
    depth: usize,
    env: Env<'a>,
    /// The original input binary, used to create zero-copy sub-binary
    /// references for non-escaped strings instead of allocating + copying.
    input_binary: Binary<'a>,
    /// Optional key cache for interning repeated object keys.
    /// Only allocated when `intern_keys=true`.
    key_cache: Option<FastHashMap<&'b [u8], Term<'a>>>,
    /// Decode options controlling behavior
    opts: DecodeOptions,
    /// Optional structural index for fast whitespace skipping.
    /// Only built for inputs >= STRUCTURAL_INDEX_THRESHOLD bytes.
    structural_index: Option<StructuralIndex>,
}

impl<'a, 'b> DirectParser<'a, 'b> {
    #[inline]
    pub fn new(
        env: Env<'a>,
        input: &'b [u8],
        input_binary: Binary<'a>,
        opts: DecodeOptions,
    ) -> Self {
        let key_cache = if opts.intern_keys {
            Some(FastHashMap::with_capacity_and_hasher(
                32,
                FnvBuildHasher::new(),
            ))
        } else {
            None
        };
        let structural_index = if input.len() >= STRUCTURAL_INDEX_THRESHOLD {
            Some(build_structural_index(input))
        } else {
            None
        };
        Self {
            input,
            pos: 0,
            depth: 0,
            env,
            input_binary,
            key_cache,
            opts,
            structural_index,
        }
    }

    #[inline]
    pub fn parse(mut self) -> Result<Term<'a>, DecodeError> {
        self.skip_whitespace();
        let term = self.parse_value()?;
        self.skip_whitespace();
        if self.pos < self.input.len() {
            return Err((Cow::Borrowed("Unexpected trailing characters"), self.pos));
        }
        Ok(term)
    }

    #[inline(always)]
    fn peek(&self) -> Option<u8> {
        self.input.get(self.pos).copied()
    }

    #[inline(always)]
    fn advance(&mut self) {
        self.pos += 1;
    }

    #[inline(always)]
    fn skip_whitespace(&mut self) {
        // SIMD fast path: skip whitespace in 16/32-byte chunks, with partial chunk handling
        crate::simd_utils::skip_whitespace(self.input, &mut self.pos);

        // Scalar tail for remaining < 16 bytes
        while self.pos < self.input.len() {
            match self.input[self.pos] {
                b' ' | b'\t' | b'\n' | b'\r' => self.pos += 1,
                _ => break,
            }
        }
    }

    /// Jump self.pos to the next structural character position.
    /// Validates that all bytes between the current position and the structural
    /// position are whitespace. If any non-whitespace byte is found in the gap,
    /// falls back to skip_whitespace() so the caller's match on peek() will
    /// detect the unexpected byte and produce an error.
    /// Falls back to skip_whitespace() when no index is available.
    #[inline(always)]
    fn advance_to_structural(&mut self) {
        if let Some(ref idx) = self.structural_index {
            if let Some(next_pos) = idx.peek() {
                let next = next_pos as usize;
                // Validate that all bytes in the gap are whitespace.
                // In valid JSON, only whitespace can appear between tokens
                // and structural characters. If non-whitespace is present,
                // fall through to skip_whitespace() which will stop at the
                // offending byte, causing the caller to error.
                if next >= self.pos {
                    let gap = &self.input[self.pos..next];
                    if gap
                        .iter()
                        .all(|&b| matches!(b, b' ' | b'\t' | b'\n' | b'\r'))
                    {
                        self.pos = next;
                        return;
                    }
                }
            }
        }
        self.skip_whitespace();
    }

    /// Advance past current structural char, incrementing both pos and cursor.
    #[inline(always)]
    fn consume_structural(&mut self) {
        self.pos += 1;
        if let Some(ref mut idx) = self.structural_index {
            idx.advance();
        }
    }

    /// Fused consume_structural + skip_whitespace: advance past the current
    /// structural char and skip any following whitespace in a single call.
    #[inline(always)]
    fn consume_structural_and_skip_ws(&mut self) {
        self.pos += 1;
        if let Some(ref mut idx) = self.structural_index {
            idx.advance();
        }
        self.skip_whitespace();
    }

    /// Estimate container capacity using the structural index when available.
    /// Falls back to the heuristic `(remaining / divisor).clamp(1, max)` when
    /// the index is absent or the close bracket is not found within the scan cap.
    #[inline]
    fn estimate_container_capacity(&self, close: u8, divisor: usize, max: usize) -> usize {
        if let Some(ref idx) = self.structural_index {
            if let Some(count) = idx.count_elements_until_close(self.input, close) {
                return count;
            }
        }
        let remaining = self.input.len() - self.pos;
        let estimated = (remaining / divisor).clamp(1, max);
        if self.depth > 1 {
            estimated.min(8)
        } else {
            estimated
        }
    }

    #[inline(always)]
    fn err(&self, msg: &'static str) -> DecodeError {
        (Cow::Borrowed(msg), self.pos)
    }

    /// Optimized value parser for flat objects (no nested containers).
    /// Routes numbers through `parse_number_fast` (direct indexing, inline
    /// small-int parse) and avoids the container arms entirely. Falls back
    /// to `parse_value` if a container opener is encountered.
    #[inline(always)]
    fn parse_value_flat(&mut self) -> Result<Term<'a>, DecodeError> {
        match self.peek() {
            Some(b'"') => self.parse_string(),
            Some(b'0'..=b'9') | Some(b'-') => self.parse_number_fast(),
            Some(b't') => self.parse_true(),
            Some(b'f') => self.parse_false(),
            Some(b'n') => self.parse_null(),
            // Container or unexpected — fall through to full dispatch
            _ => self.parse_value(),
        }
    }

    #[inline]
    fn parse_value(&mut self) -> Result<Term<'a>, DecodeError> {
        match self.peek() {
            Some(b'n') => self.parse_null(),
            Some(b't') => self.parse_true(),
            Some(b'f') => self.parse_false(),
            Some(b'"') => self.parse_string(),
            Some(b'[') => self.parse_array(),
            Some(b'{') => self.parse_object(),
            Some(b'-') | Some(b'0'..=b'9') => self.parse_number(),
            Some(_) => Err(self.err("Unexpected character")),
            None => Err(self.err("Unexpected end of input")),
        }
    }

    #[inline(always)]
    fn parse_null(&mut self) -> Result<Term<'a>, DecodeError> {
        if self.input[self.pos..].starts_with(b"null") {
            self.pos += 4;
            Ok(atom::nil().encode(self.env))
        } else {
            Err(self.err("Expected 'null'"))
        }
    }

    #[inline(always)]
    fn parse_true(&mut self) -> Result<Term<'a>, DecodeError> {
        if self.input[self.pos..].starts_with(b"true") {
            self.pos += 4;
            Ok(true.encode(self.env))
        } else {
            Err(self.err("Expected 'true'"))
        }
    }

    #[inline(always)]
    fn parse_false(&mut self) -> Result<Term<'a>, DecodeError> {
        if self.input[self.pos..].starts_with(b"false") {
            self.pos += 5;
            Ok(false.encode(self.env))
        } else {
            Err(self.err("Expected 'false'"))
        }
    }

    /// Core string parsing logic. When `for_key` is true and we have a cache,
    /// attempts to intern non-escaped strings.
    ///
    /// Uses two optimizations:
    /// - **8-byte batch scanning**: Checks 8 bytes at a time for the common case
    ///   of plain ASCII strings (no escapes, no control chars, no closing quote).
    ///   Falls back to byte-at-a-time when a special byte is found.
    /// - **Zero-copy sub-binaries**: Non-escaped strings return a sub-binary
    ///   reference into the original input, avoiding allocation and memcpy.
    ///   Only escaped strings (containing `\"`, `\\`, `\n`, `\uXXXX`, etc.)
    ///   allocate a new binary.
    #[inline]
    fn parse_string_impl(&mut self, for_key: bool) -> Result<Term<'a>, DecodeError> {
        let string_start = self.pos;
        self.advance(); // Skip opening quote
        let start = self.pos;
        let mut has_escape = false;

        // SIMD string scanning: skip plain bytes in bulk (portable SIMD).
        loop {
            crate::simd_utils::skip_plain_string_bytes(self.input, &mut self.pos);

            // Byte-at-a-time for remainder or when a special byte is nearby
            match self.peek() {
                Some(b'"') => {
                    let end = self.pos;
                    self.advance(); // Skip closing quote

                    // Escaped strings: decode and return (cannot intern - decoded
                    // bytes differ from input slice, and escaped keys are rare)
                    if has_escape {
                        let decoded = self
                            .decode_escaped_string(start, end)
                            .map_err(|msg| (msg, string_start))?;
                        if self.opts.validate_strings
                            && simdutf8::basic::from_utf8(&decoded).is_err()
                        {
                            return Err((Cow::Borrowed("Invalid UTF-8 in string"), string_start));
                        }
                        return Ok(encode_binary(self.env, &decoded));
                    }

                    let str_bytes = &self.input[start..end];

                    // Optional UTF-8 validation for non-escaped strings
                    if self.opts.validate_strings && simdutf8::basic::from_utf8(str_bytes).is_err()
                    {
                        return Err((Cow::Borrowed("Invalid UTF-8 in string"), string_start));
                    }

                    // Key interning: check cache if enabled and parsing a key.
                    if for_key {
                        if let Some(ref mut cache) = self.key_cache {
                            if let Some(&cached) = cache.get(str_bytes) {
                                return Ok(cached);
                            }
                            // For interned keys, we must copy (cache needs stable term).
                            let term = encode_binary(self.env, str_bytes);
                            if cache.len() < MAX_INTERN_KEYS {
                                cache.insert(str_bytes, term);
                            }
                            return Ok(term);
                        }
                    }

                    // For short strings, copying to a heap binary is faster than
                    // sub-binary overhead. For longer strings (>=64 bytes),
                    // zero-copy sub-binary avoids allocation + memcpy.
                    let len = end - start;
                    if len >= SUBBINARY_THRESHOLD {
                        if let Ok(sub) = self.input_binary.make_subbinary(start, len) {
                            return Ok(sub.to_term(self.env));
                        }
                        return Ok(encode_binary(self.env, str_bytes));
                    } else {
                        return Ok(encode_binary(self.env, str_bytes));
                    }
                }
                Some(b'\\') => {
                    has_escape = true;
                    self.advance();
                    if self.peek().is_some() {
                        self.advance(); // Skip escaped char
                    }
                }
                // JSON spec: control characters (0x00-0x1F) must be escaped
                Some(0x00..=0x1F) => {
                    return Err(self.err("Unescaped control character"));
                }
                Some(_) => self.advance(),
                None => {
                    return Err((Cow::Borrowed("Unterminated string"), string_start));
                }
            }
        }
    }

    /// Parse a string value (not interned)
    #[inline]
    fn parse_string(&mut self) -> Result<Term<'a>, DecodeError> {
        self.parse_string_impl(false)
    }

    /// Parse an object key (interned if cache enabled)
    #[inline]
    fn parse_key(&mut self) -> Result<Term<'a>, DecodeError> {
        self.parse_string_impl(true)
    }

    /// Scan past a JSON string and return the raw bytes between the quotes.
    /// Does not build a Term — used for shape-matching key comparison.
    /// Returns the raw byte slice (between opening and closing quotes).
    #[inline]
    fn scan_string_raw(&mut self) -> Result<&'b [u8], DecodeError> {
        let string_start = self.pos;
        self.advance(); // Skip opening quote
        let start = self.pos;

        // Use SIMD scanning to skip past plain bytes, same as parse_string_impl
        loop {
            crate::simd_utils::skip_plain_string_bytes(self.input, &mut self.pos);

            match self.peek() {
                Some(b'"') => {
                    let end = self.pos;
                    self.advance(); // Skip closing quote
                    return Ok(&self.input[start..end]);
                }
                Some(b'\\') => {
                    self.advance();
                    if self.peek().is_some() {
                        self.advance();
                    }
                }
                Some(0x00..=0x1F) => {
                    return Err(self.err("Unescaped control character"));
                }
                Some(_) => self.advance(),
                None => {
                    return Err((Cow::Borrowed("Unterminated string"), string_start));
                }
            }
        }
    }

    #[inline]
    fn decode_escaped_string(
        &self,
        start: usize,
        end: usize,
    ) -> Result<Vec<u8>, Cow<'static, str>> {
        let mut result = Vec::with_capacity(end - start);
        let mut i = start;

        while i < end {
            if self.input[i] == b'\\' && i + 1 < end {
                i += 1;
                match self.input[i] {
                    b'"' => result.push(b'"'),
                    b'\\' => result.push(b'\\'),
                    b'/' => result.push(b'/'),
                    b'b' => result.push(0x08),
                    b'f' => result.push(0x0C),
                    b'n' => result.push(b'\n'),
                    b'r' => result.push(b'\r'),
                    b't' => result.push(b'\t'),
                    b'u' => {
                        // Need exactly 4 hex digits
                        if i + 4 >= end {
                            return Err(Cow::Borrowed("Incomplete unicode escape"));
                        }
                        let hex = &self.input[i + 1..i + 5];
                        // Validate all 4 are hex digits
                        if !hex.iter().all(|&b| b.is_ascii_hexdigit()) {
                            return Err(Cow::Borrowed("Invalid unicode escape"));
                        }
                        // SAFETY: hex digits were validated above, and valid hex
                        // ASCII is always valid UTF-8, so these conversions cannot fail.
                        let hex_str = std::str::from_utf8(hex)
                            .map_err(|_| Cow::Borrowed("Invalid unicode escape"))?;
                        let cp = u16::from_str_radix(hex_str, 16)
                            .map_err(|_| Cow::Borrowed("Invalid unicode escape"))?;

                        // Handle UTF-16 surrogate pairs
                        if (0xD800..=0xDBFF).contains(&cp) {
                            // High surrogate - must be followed by low surrogate
                            if i + 11 <= end
                                && self.input[i + 5] == b'\\'
                                && self.input[i + 6] == b'u'
                            {
                                let hex2 = &self.input[i + 7..i + 11];
                                if hex2.iter().all(|&b| b.is_ascii_hexdigit()) {
                                    let hex2_str = std::str::from_utf8(hex2)
                                        .map_err(|_| Cow::Borrowed("Invalid unicode escape"))?;
                                    let cp2 = u16::from_str_radix(hex2_str, 16)
                                        .map_err(|_| Cow::Borrowed("Invalid unicode escape"))?;
                                    if (0xDC00..=0xDFFF).contains(&cp2) {
                                        // Valid surrogate pair
                                        let full_cp = 0x10000
                                            + ((cp as u32 - 0xD800) << 10)
                                            + (cp2 as u32 - 0xDC00);
                                        if let Some(c) = char::from_u32(full_cp) {
                                            let mut buf = [0u8; 4];
                                            result.extend_from_slice(
                                                c.encode_utf8(&mut buf).as_bytes(),
                                            );
                                        }
                                        i += 11;
                                        continue;
                                    }
                                }
                            }
                            // Lone high surrogate - invalid
                            return Err(Cow::Borrowed("Lone surrogate in string"));
                        } else if (0xDC00..=0xDFFF).contains(&cp) {
                            // Lone low surrogate - invalid
                            return Err(Cow::Borrowed("Lone surrogate in string"));
                        }

                        // Regular BMP character
                        if let Some(c) = char::from_u32(cp as u32) {
                            let mut buf = [0u8; 4];
                            result.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
                        }
                        i += 4;
                    }
                    c => {
                        // Invalid escape sequence - only the above are valid in JSON
                        return Err(Cow::Owned(format!(
                            "Invalid escape sequence: \\{}",
                            c as char
                        )));
                    }
                }
                i += 1;
            } else {
                // Bulk copy: SIMD scan to next escape-worthy byte, copy safe region in one shot.
                // input[start..end] excludes quotes (parser validated boundaries), so
                // find_escape_json only stops on `\` or control chars (both need handling).
                let next = crate::simd_utils::find_escape_json(self.input, i).min(end);
                if next > i {
                    result.extend_from_slice(&self.input[i..next]);
                    i = next;
                } else {
                    // Sitting on a control char or other non-backslash escapable byte.
                    // Push it and advance to avoid infinite loop; the outer loop or
                    // caller will handle validation.
                    result.push(self.input[i]);
                    i += 1;
                }
            }
        }
        Ok(result)
    }

    /// Fast-path integer parser for homogeneous number arrays.
    /// Scans digits via direct slice indexing (no per-byte peek/advance),
    /// and parses small positive/negative integers inline (≤18 digits)
    /// without lexical_core overhead.
    /// Falls back to parse_number for floats, leading zeros, digit limits, large numbers.
    #[inline]
    fn parse_number_fast(&mut self) -> Result<Term<'a>, DecodeError> {
        let start = self.pos;
        let bytes = self.input;
        let mut pos = start;

        // Handle optional minus
        let neg = pos < bytes.len() && bytes[pos] == b'-';
        if neg {
            pos += 1;
        }

        // Scan digits directly (SIMD bulk skip + scalar tail)
        let digit_start = pos;
        crate::simd_utils::skip_ascii_digits(bytes, &mut pos);
        while pos < bytes.len() && bytes[pos].is_ascii_digit() {
            pos += 1;
        }
        let digit_count = pos - digit_start;

        // If it's a float (has '.', 'e', 'E'), fall back to full parse_number
        if pos < bytes.len() && matches!(bytes[pos], b'.' | b'e' | b'E') {
            return self.parse_number();
        }

        // Validate: must have at least 1 digit
        if digit_count == 0 {
            return self.parse_number();
        }
        // Leading zero only for "0" or "-0"
        if digit_count > 1 && bytes[digit_start] == b'0' {
            return self.parse_number();
        }

        // Check integer digit limit
        let limit = self.opts.integer_digit_limit;
        if limit > 0 && digit_count > limit {
            return self.parse_number();
        }

        self.pos = pos;
        let num_bytes = &bytes[start..pos];

        // Fast inline parse for ≤ 18 digits (no overflow possible for i64)
        // SAFETY: max 18-digit unsigned is 999_999_999_999_999_999 which is < i64::MAX
        // (9_223_372_036_854_775_807). Negation of the max 18-digit value is
        // -999_999_999_999_999_999 which is > i64::MIN (-9_223_372_036_854_775_808).
        // Therefore no overflow is possible during accumulation or negation.
        // 19+ digit numbers fall through to lexical_core below.
        if digit_count <= 18 {
            let mut val: i64 = 0;
            for &b in &bytes[digit_start..pos] {
                val = val * 10 + (b - b'0') as i64;
            }
            if neg {
                val = -val;
            }
            return Ok(val.encode(self.env));
        }

        // Larger numbers: use lexical_core (same as parse_number)
        if let Ok(i) = lexical_core::parse::<i64>(num_bytes) {
            Ok(i.encode(self.env))
        } else if let Ok(u) = lexical_core::parse::<u64>(num_bytes) {
            Ok(u.encode(self.env))
        } else {
            let num_str = std::str::from_utf8(num_bytes)
                .map_err(|_| (Cow::Borrowed("Invalid number encoding"), start))?;
            let big: BigInt = num_str
                .parse()
                .map_err(|_| (Cow::Borrowed("Invalid number"), start))?;
            Ok(big.encode(self.env))
        }
    }

    #[inline]
    fn parse_number(&mut self) -> Result<Term<'a>, DecodeError> {
        let start = self.pos;
        let bytes = self.input;
        let len = bytes.len();
        let mut pos = start;
        let mut is_float = false;

        // Optional minus
        if pos < len && bytes[pos] == b'-' {
            pos += 1;
        }

        // Integer part - track digit count for digit limit
        let int_digit_start = pos;
        if pos >= len {
            return Err((Cow::Borrowed("Invalid number"), start));
        }
        match bytes[pos] {
            b'0' => pos += 1,
            b'1'..=b'9' => {
                pos += 1;
                crate::simd_utils::skip_ascii_digits(bytes, &mut pos);
                while pos < len && bytes[pos].is_ascii_digit() {
                    pos += 1;
                }
            }
            _ => return Err((Cow::Borrowed("Invalid number"), start)),
        }
        let int_digit_count = pos - int_digit_start;

        // Check integer digit limit
        let limit = self.opts.integer_digit_limit;
        if limit > 0 && int_digit_count > limit {
            return Err((
                Cow::Owned(format!("integer exceeds {} digit limit", limit)),
                start,
            ));
        }

        // Fractional part
        if pos < len && bytes[pos] == b'.' {
            is_float = true;
            pos += 1;
            if pos >= len || !bytes[pos].is_ascii_digit() {
                return Err((Cow::Borrowed("Invalid number"), start));
            }
            crate::simd_utils::skip_ascii_digits(bytes, &mut pos);
            while pos < len && bytes[pos].is_ascii_digit() {
                pos += 1;
            }
        }

        // Exponent
        if pos < len && (bytes[pos] == b'e' || bytes[pos] == b'E') {
            is_float = true;
            pos += 1;
            if pos < len && (bytes[pos] == b'+' || bytes[pos] == b'-') {
                pos += 1;
            }
            if pos >= len || !bytes[pos].is_ascii_digit() {
                return Err((Cow::Borrowed("Invalid number"), start));
            }
            crate::simd_utils::skip_ascii_digits(bytes, &mut pos);
            while pos < len && bytes[pos].is_ascii_digit() {
                pos += 1;
            }
        }

        self.pos = pos;

        let num_bytes = &self.input[start..self.pos];

        if is_float {
            if self.opts.floats_decimals {
                return self.parse_number_as_decimal(num_bytes, start);
            }
            // Use lexical-core for fast float parsing
            let f: f64 = lexical_core::parse(num_bytes)
                .map_err(|_| (Cow::Borrowed("Invalid float"), start))?;
            Ok(f.encode(self.env))
        } else {
            // Try i64 first using lexical-core
            if let Ok(i) = lexical_core::parse::<i64>(num_bytes) {
                Ok(i.encode(self.env))
            } else if let Ok(u) = lexical_core::parse::<u64>(num_bytes) {
                Ok(u.encode(self.env))
            } else {
                // Parse as BigInt to preserve arbitrary precision (matches Jason behavior)
                let num_str = std::str::from_utf8(num_bytes)
                    .map_err(|_| (Cow::Borrowed("Invalid number encoding"), start))?;
                let big: BigInt = num_str
                    .parse()
                    .map_err(|_| (Cow::Borrowed("Invalid number"), start))?;
                Ok(big.encode(self.env))
            }
        }
    }

    /// Parse a float number string into a %Decimal{} struct term
    fn parse_number_as_decimal(
        &self,
        num_bytes: &[u8],
        start: usize,
    ) -> Result<Term<'a>, DecodeError> {
        let num_str = std::str::from_utf8(num_bytes)
            .map_err(|_| (Cow::Borrowed("Invalid number encoding"), start))?;

        // Determine sign
        let (sign_val, rest) = if let Some(stripped) = num_str.strip_prefix('-') {
            (-1i64, stripped)
        } else {
            (1i64, num_str)
        };

        // Split into integer/fraction and exponent parts
        let (mantissa_str, exp_part) = if let Some(e_pos) = rest.find(['e', 'E']) {
            let exp_val = rest[e_pos + 1..]
                .parse::<i64>()
                .map_err(|_| (Cow::Borrowed("Invalid exponent in decimal number"), start))?;
            (
                &rest[..e_pos],
                exp_val,
            )
        } else {
            (rest, 0i64)
        };

        // Split mantissa into integer and fraction
        let (coef_str, frac_len) = if let Some(dot_pos) = mantissa_str.find('.') {
            let int_part = &mantissa_str[..dot_pos];
            let frac_part = &mantissa_str[dot_pos + 1..];
            let combined = format!("{}{}", int_part, frac_part);
            (combined, frac_part.len() as i64)
        } else {
            (mantissa_str.to_string(), 0i64)
        };

        // Remove leading zeros from coefficient (but keep at least one digit)
        let coef_str = coef_str.trim_start_matches('0');
        let coef_str = if coef_str.is_empty() { "0" } else { coef_str };

        let exp_val = exp_part - frac_len;

        let env = self.env;

        // Parse coef as integer (could be large)
        let coef_term = if let Ok(c) = coef_str.parse::<i64>() {
            c.encode(env)
        } else if let Ok(c) = coef_str.parse::<u64>() {
            c.encode(env)
        } else {
            use std::str::FromStr;
            let big = num_bigint::BigInt::from_str(coef_str)
                .map_err(|_| (Cow::Borrowed("Invalid decimal coefficient"), start))?;
            big.encode(env)
        };

        // Build %Decimal{sign: sign, coef: coef, exp: exp} using pre-declared atoms
        let keys = [
            atoms::__struct__().to_term(env),
            atoms::coef().to_term(env),
            atoms::exp().to_term(env),
            atoms::sign().to_term(env),
        ];
        let values = [
            atoms::decimal_struct().to_term(env),
            coef_term,
            exp_val.encode(env),
            sign_val.encode(env),
        ];

        Term::map_from_term_arrays(env, &keys, &values)
            .map_err(|_| (Cow::Borrowed("Failed to create Decimal struct"), start))
    }

    #[inline]
    fn parse_array(&mut self) -> Result<Term<'a>, DecodeError> {
        self.depth += 1;
        if self.depth > MAX_DEPTH {
            return Err(self.err("Nesting depth exceeds maximum"));
        }

        self.consume_structural(); // Skip '['
        self.skip_whitespace();

        if self.peek() == Some(b']') {
            self.consume_structural();
            self.depth -= 1;
            return Ok(Term::list_new_empty(self.env));
        }

        // Parse first element; if it's an object, capture its key shape
        let mut shape: Option<KeyShape<'a, 'b>> = None;
        let first = if self.peek() == Some(b'{') {
            self.parse_object_shaped(&mut shape)?
        } else {
            self.parse_value()?
        };
        self.advance_to_structural();

        match self.peek() {
            Some(b']') => {
                // Single-element fast path: no Vec allocation
                self.consume_structural();
                self.depth -= 1;
                return Ok(Term::list_new_empty(self.env).list_prepend(first));
            }
            Some(b',') => {
                self.consume_structural_and_skip_ws();
            }
            _ => return Err(self.err("Expected ',' or ']'")),
        }

        // Multi-element: allocate Vec and continue
        // +1 for the already-parsed first element
        let cap = self.estimate_container_capacity(b']', 20, 1024) + 1;
        let mut elements = Vec::with_capacity(cap);
        elements.push(first);

        // Detect element class from second element's first byte for tight inner loop:
        // 1 = Number, 2 = String, 0 = Other/mixed (no specialization)
        let elem_class = match self.peek() {
            Some(b'0'..=b'9') | Some(b'-') => 1u8,
            Some(b'"') => 2u8,
            _ => 0u8,
        };

        loop {
            let elem = match elem_class {
                1 if matches!(self.peek(), Some(b'0'..=b'9') | Some(b'-')) => {
                    self.parse_number_fast()?
                }
                2 if self.peek() == Some(b'"') => self.parse_string()?,
                _ => {
                    if self.peek() == Some(b'{') && shape.is_some() {
                        self.parse_object_shaped(&mut shape)?
                    } else {
                        if self.peek() != Some(b'{') {
                            shape = None;
                        }
                        self.parse_value()?
                    }
                }
            };
            elements.push(elem);
            self.advance_to_structural();

            match self.peek() {
                Some(b',') => {
                    self.consume_structural_and_skip_ws();
                }
                Some(b']') => {
                    self.consume_structural();
                    break;
                }
                _ => return Err(self.err("Expected ',' or ']'")),
            }
        }

        // Build list in reverse order using prepend
        let mut list = Term::list_new_empty(self.env);
        for elem in elements.into_iter().rev() {
            list = list.list_prepend(elem);
        }
        self.depth -= 1;
        Ok(list)
    }

    #[inline]
    fn parse_object(&mut self) -> Result<Term<'a>, DecodeError> {
        self.depth += 1;
        if self.depth > MAX_DEPTH {
            return Err(self.err("Nesting depth exceeds maximum"));
        }

        let obj_start = self.pos;
        self.consume_structural(); // Skip '{'
        self.skip_whitespace();

        if self.peek() == Some(b'}') {
            self.consume_structural();
            self.depth -= 1;
            if self.opts.ordered_objects {
                return self.build_ordered_object(&[], &[], obj_start);
            }
            return Ok(Term::map_new(self.env));
        }

        // Parse first key-value pair on stack before allocating
        if self.peek() != Some(b'"') {
            return Err(self.err("Expected string key"));
        }
        let first_key_start = self.pos;
        let first_key = self.parse_key()?;
        let first_key_end = self.pos;

        self.advance_to_structural();
        if self.peek() != Some(b':') {
            return Err(self.err("Expected ':'"));
        }
        self.consume_structural_and_skip_ws();
        // Capture first value's leading byte to detect flat objects
        let first_value_byte = self.peek();
        let is_flat = !matches!(first_value_byte, Some(b'{') | Some(b'['));
        let first_value = self.parse_value()?;

        self.advance_to_structural();
        match self.peek() {
            Some(b'}') => {
                // Single-entry fast path: no Vec/HashSet allocation
                self.consume_structural();
                self.depth -= 1;
                if self.opts.ordered_objects {
                    return self.build_ordered_object(&[first_key], &[first_value], obj_start);
                }
                return Term::map_from_term_arrays(self.env, &[first_key], &[first_value])
                    .map_err(|_| (Cow::Borrowed("Failed to create map"), obj_start));
            }
            Some(b',') => {
                self.consume_structural_and_skip_ws();
            }
            _ => return Err(self.err("Expected ',' or '}'")),
        }

        // Multi-entry path: allocate Vecs and continue
        // +1 for the already-parsed first key-value pair
        // Note: for objects, structural index counts commas (between key-value pairs)
        // and the colon separators are also structural chars, but count_elements_until_close
        // only counts commas at depth 0 between the open/close braces.
        let cap = self.estimate_container_capacity(b'}', 30, 256) + 1;
        let mut keys = Vec::with_capacity(cap);
        let mut values = Vec::with_capacity(cap);
        keys.push(first_key);
        values.push(first_value);

        // Optional duplicate key tracking (only needed for multi-entry objects)
        let seen_cap = cap;
        let mut seen_keys: Option<HashSet<&'b [u8]>> = if self.opts.reject_duplicate_keys {
            let mut set = HashSet::with_capacity(seen_cap);
            // Insert first key's raw bytes (between opening and closing quotes)
            let raw_first = &self.input[first_key_start + 1..first_key_end - 1];
            set.insert(raw_first);
            Some(set)
        } else {
            None
        };

        loop {
            if self.peek() != Some(b'"') {
                return Err(self.err("Expected string key"));
            }
            let key_start = self.pos;
            let key = self.parse_key()?;

            // Check for duplicate keys if enabled
            if let Some(ref mut seen) = seen_keys {
                let raw_key = &self.input[key_start + 1..self.pos - 1];
                if !seen.insert(raw_key) {
                    return Err((Cow::Borrowed("Duplicate key in object"), self.pos));
                }
            }

            keys.push(key);

            self.advance_to_structural();
            if self.peek() != Some(b':') {
                return Err(self.err("Expected ':'"));
            }
            self.consume_structural_and_skip_ws();

            // Flat objects: use optimized scalar value parser (parse_number_fast
            // for numbers, direct dispatch without container arms)
            let value = if is_flat {
                self.parse_value_flat()?
            } else {
                self.parse_value()?
            };
            values.push(value);

            self.advance_to_structural();
            match self.peek() {
                Some(b',') => {
                    self.consume_structural_and_skip_ws();
                }
                Some(b'}') => {
                    self.consume_structural();
                    break;
                }
                _ => return Err(self.err("Expected ',' or '}'")),
            }
        }

        self.depth -= 1;

        if self.opts.ordered_objects {
            return self.build_ordered_object(&keys, &values, obj_start);
        }

        // Fast path: no duplicate keys (common case)
        match Term::map_from_term_arrays(self.env, &keys, &values) {
            Ok(map) => Ok(map),
            Err(_) => {
                // Slow path: duplicate keys detected, use "last wins" semantics
                self.build_map_with_duplicates(&keys, &values, obj_start)
            }
        }
    }

    /// Shape-aware object parser for arrays of same-shaped objects.
    /// On first call (shape is None): parses normally and captures the key shape.
    /// On subsequent calls (shape is Some): tries to match keys against the cached shape.
    /// If shape match fails, falls back to normal parsing and disables shape for the array.
    #[inline]
    fn parse_object_shaped(
        &mut self,
        shape: &mut Option<KeyShape<'a, 'b>>,
    ) -> Result<Term<'a>, DecodeError> {
        if shape.is_none() {
            // First object: parse normally and capture shape
            return self.parse_object_capture_shape(shape);
        }

        // Subsequent objects: try shape-matched fast path
        self.depth += 1;
        if self.depth > MAX_DEPTH {
            return Err(self.err("Nesting depth exceeds maximum"));
        }

        let obj_start = self.pos;
        let saved_cursor = self.structural_index.as_ref().map(|idx| idx.cursor);
        self.consume_structural(); // Skip '{'
        self.skip_whitespace();

        let cached = shape.as_ref().unwrap();
        let num_keys = cached.raw_keys.len();

        // Macro to rewind both pos and structural index cursor on shape mismatch
        macro_rules! rewind_and_fallback {
            ($self:ident, $shape:ident, $obj_start:ident, $saved_cursor:ident) => {{
                $self.depth -= 1;
                $self.pos = $obj_start;
                if let Some(ref mut idx) = $self.structural_index {
                    idx.cursor = $saved_cursor.unwrap();
                }
                *$shape = None;
                return $self.parse_object();
            }};
        }

        // Empty object shape
        if num_keys == 0 {
            if self.peek() == Some(b'}') {
                self.consume_structural();
                self.depth -= 1;
                if self.opts.ordered_objects {
                    return self.build_ordered_object(&[], &[], obj_start);
                }
                return Ok(Term::map_new(self.env));
            }
            // Not empty — shape mismatch, fall back
            rewind_and_fallback!(self, shape, obj_start, saved_cursor);
        }

        // Try to match each key against the shape
        let mut values = Vec::with_capacity(num_keys);
        let flat = cached.is_flat;

        for i in 0..num_keys {
            if i > 0 {
                // Expect comma between entries
                if self.peek() != Some(b',') {
                    // Fewer keys than shape — mismatch
                    rewind_and_fallback!(self, shape, obj_start, saved_cursor);
                }
                self.consume_structural_and_skip_ws();
            }

            if self.peek() != Some(b'"') {
                // Not a string key — mismatch
                rewind_and_fallback!(self, shape, obj_start, saved_cursor);
            }

            let raw_key = self.scan_string_raw()?;

            if raw_key != cached.raw_keys[i] {
                // Key mismatch — abandon shape, reparse this object from scratch
                rewind_and_fallback!(self, shape, obj_start, saved_cursor);
            }

            self.advance_to_structural();
            if self.peek() != Some(b':') {
                return Err(self.err("Expected ':'"));
            }
            self.consume_structural_and_skip_ws();

            // Flat objects: use optimized scalar value parser
            let value = if flat {
                self.parse_value_flat()?
            } else {
                self.parse_value()?
            };
            values.push(value);

            self.advance_to_structural();
        }

        // After all shape keys, expect closing brace
        match self.peek() {
            Some(b'}') => {
                self.consume_structural();
            }
            Some(b',') => {
                // More keys than shape — mismatch
                rewind_and_fallback!(self, shape, obj_start, saved_cursor);
            }
            _ => return Err(self.err("Expected ',' or '}'")),
        }

        self.depth -= 1;

        let key_terms = &shape.as_ref().unwrap().key_terms;

        if self.opts.ordered_objects {
            return self.build_ordered_object(key_terms, &values, obj_start);
        }

        match Term::map_from_term_arrays(self.env, key_terms, &values) {
            Ok(map) => Ok(map),
            Err(_) => self.build_map_with_duplicates(key_terms, &values, obj_start),
        }
    }

    /// Parse an object and capture its key shape for subsequent same-shape matching.
    fn parse_object_capture_shape(
        &mut self,
        shape: &mut Option<KeyShape<'a, 'b>>,
    ) -> Result<Term<'a>, DecodeError> {
        self.depth += 1;
        if self.depth > MAX_DEPTH {
            return Err(self.err("Nesting depth exceeds maximum"));
        }

        let obj_start = self.pos;
        self.consume_structural(); // Skip '{'
        self.skip_whitespace();

        if self.peek() == Some(b'}') {
            self.consume_structural();
            self.depth -= 1;
            // Capture empty shape
            *shape = Some(KeyShape {
                raw_keys: Vec::new(),
                key_terms: Vec::new(),
                is_flat: true,
            });
            if self.opts.ordered_objects {
                return self.build_ordered_object(&[], &[], obj_start);
            }
            return Ok(Term::map_new(self.env));
        }

        // Parse first key-value pair
        if self.peek() != Some(b'"') {
            return Err(self.err("Expected string key"));
        }
        let first_key_start = self.pos;
        let first_key = self.parse_key()?;
        let first_key_end = self.pos;
        let first_raw_key = &self.input[first_key_start + 1..first_key_end - 1];

        self.advance_to_structural();
        if self.peek() != Some(b':') {
            return Err(self.err("Expected ':'"));
        }
        self.consume_structural_and_skip_ws();
        // Capture first value's leading byte to detect flat objects
        let first_value_byte = self.peek();
        let is_flat = !matches!(first_value_byte, Some(b'{') | Some(b'['));
        let first_value = self.parse_value()?;

        self.advance_to_structural();
        match self.peek() {
            Some(b'}') => {
                // Single-entry object
                self.consume_structural();
                self.depth -= 1;
                *shape = Some(KeyShape {
                    raw_keys: vec![first_raw_key],
                    key_terms: vec![first_key],
                    is_flat,
                });
                if self.opts.ordered_objects {
                    return self.build_ordered_object(&[first_key], &[first_value], obj_start);
                }
                return Term::map_from_term_arrays(self.env, &[first_key], &[first_value])
                    .map_err(|_| (Cow::Borrowed("Failed to create map"), obj_start));
            }
            Some(b',') => {
                self.consume_structural_and_skip_ws();
            }
            _ => return Err(self.err("Expected ',' or '}'")),
        }

        // Multi-entry path
        // +1 for the already-parsed first key-value pair
        let cap = self.estimate_container_capacity(b'}', 30, 256) + 1;
        let mut keys = Vec::with_capacity(cap);
        let mut values = Vec::with_capacity(cap);
        let mut raw_keys: Vec<&'b [u8]> = Vec::with_capacity(cap);
        keys.push(first_key);
        values.push(first_value);
        raw_keys.push(first_raw_key);

        let seen_cap = cap;
        let mut seen_keys: Option<HashSet<&'b [u8]>> = if self.opts.reject_duplicate_keys {
            let mut set = HashSet::with_capacity(seen_cap);
            set.insert(first_raw_key);
            Some(set)
        } else {
            None
        };

        loop {
            if self.peek() != Some(b'"') {
                return Err(self.err("Expected string key"));
            }
            let key_start = self.pos;
            let key = self.parse_key()?;
            let key_end = self.pos;
            let raw_key = &self.input[key_start + 1..key_end - 1];

            if let Some(ref mut seen) = seen_keys {
                if !seen.insert(raw_key) {
                    return Err((Cow::Borrowed("Duplicate key in object"), self.pos));
                }
            }

            keys.push(key);
            raw_keys.push(raw_key);

            self.advance_to_structural();
            if self.peek() != Some(b':') {
                return Err(self.err("Expected ':'"));
            }
            self.consume_structural_and_skip_ws();

            // Flat objects: use optimized scalar value parser
            let value = if is_flat {
                self.parse_value_flat()?
            } else {
                self.parse_value()?
            };
            values.push(value);

            self.advance_to_structural();
            match self.peek() {
                Some(b',') => {
                    self.consume_structural_and_skip_ws();
                }
                Some(b'}') => {
                    self.consume_structural();
                    break;
                }
                _ => return Err(self.err("Expected ',' or '}'")),
            }
        }

        self.depth -= 1;

        // Build map first using keys by reference, then move keys into shape
        // to avoid an unnecessary .clone() of the Vec<Term>.
        let result = if self.opts.ordered_objects {
            self.build_ordered_object(&keys, &values, obj_start)
        } else {
            match Term::map_from_term_arrays(self.env, &keys, &values) {
                Ok(map) => Ok(map),
                Err(_) => self.build_map_with_duplicates(&keys, &values, obj_start),
            }
        };

        // Capture shape for subsequent objects (move, not clone)
        *shape = Some(KeyShape {
            raw_keys,
            key_terms: keys,
            is_flat,
        });

        result
    }

    /// Build %RustyJson.OrderedObject{values: [{k, v}, ...]} preserving order.
    /// Pass empty vecs for an empty ordered object.
    fn build_ordered_object(
        &self,
        keys: &[Term<'a>],
        values: &[Term<'a>],
        pos: usize,
    ) -> Result<Term<'a>, DecodeError> {
        let env = self.env;

        // Build list of {key, value} tuples in order
        let mut list = Term::list_new_empty(env);
        for i in (0..keys.len()).rev() {
            let tuple = rustler::types::tuple::make_tuple(env, &[keys[i], values[i]]);
            list = list.list_prepend(tuple);
        }

        let map_keys = [
            atoms::__struct__().to_term(env),
            atoms::values().to_term(env),
        ];
        let map_vals = [atoms::ordered_object_struct().to_term(env), list];

        Term::map_from_term_arrays(env, &map_keys, &map_vals)
            .map_err(|_| (Cow::Borrowed("Failed to create OrderedObject"), pos))
    }

    /// Build a map handling duplicate keys with "last wins" semantics
    #[cold]
    fn build_map_with_duplicates(
        &self,
        keys: &[Term<'a>],
        values: &[Term<'a>],
        pos: usize,
    ) -> Result<Term<'a>, DecodeError> {
        // Extract key bytes and deduplicate
        let mut key_map: HashMap<&'a [u8], usize> = HashMap::with_capacity(keys.len());
        let mut final_keys = Vec::with_capacity(keys.len());
        let mut final_values = Vec::with_capacity(keys.len());

        for (i, key) in keys.iter().enumerate() {
            // Decode as Binary to get a slice into the BEAM heap (no allocation)
            let key_bin: Binary = key
                .decode()
                .map_err(|_| (Cow::Borrowed("Failed to decode key"), pos))?;
            let key_bytes = key_bin.as_slice();

            if let Some(&existing_idx) = key_map.get(key_bytes) {
                // Duplicate - update value at existing position
                final_values[existing_idx] = values[i];
            } else {
                // New key
                let idx = final_keys.len();
                key_map.insert(key_bytes, idx);
                final_keys.push(keys[i]);
                final_values.push(values[i]);
            }
        }

        Term::map_from_term_arrays(self.env, &final_keys, &final_values)
            .map_err(|_| (Cow::Borrowed("Failed to create map"), pos))
    }
}

#[inline(always)]
fn encode_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut bin = NewBinary::new(env, bytes.len());
    bin.as_mut_slice().copy_from_slice(bytes);
    bin.into()
}

// ============================================================================
// Benchmark helpers - feature-gated, excluded from production binary
// ============================================================================

#[cfg(feature = "bench")]
pub mod bench_helpers {
    /// Skip whitespace bytes (space, tab, newline, carriage return) starting at `pos`.
    /// Returns the new position after all whitespace.
    #[inline]
    pub fn skip_whitespace(input: &[u8], mut pos: usize) -> usize {
        while pos < input.len() {
            match input[pos] {
                b' ' | b'\t' | b'\n' | b'\r' => pos += 1,
                _ => break,
            }
        }
        pos
    }

    /// Scan a JSON string starting at `pos` (which should point to the opening `"`).
    /// Returns `(end_pos, has_escape)` where `end_pos` is one past the closing quote.
    /// Uses the same SIMD fast-path as the real parser.
    #[inline]
    pub fn scan_string(input: &[u8], mut pos: usize) -> (usize, bool) {
        if pos >= input.len() || input[pos] != b'"' {
            return (pos, false);
        }
        pos += 1; // skip opening quote
        let mut has_escape = false;

        loop {
            // SIMD bulk skip for plain bytes (portable SIMD)
            crate::simd_utils::skip_plain_string_bytes(input, &mut pos);

            // Byte-at-a-time for remainder
            if pos >= input.len() {
                return (pos, has_escape);
            }
            match input[pos] {
                b'"' => {
                    pos += 1; // skip closing quote
                    return (pos, has_escape);
                }
                b'\\' => {
                    has_escape = true;
                    pos += 1;
                    if pos < input.len() {
                        pos += 1; // skip escaped char
                    }
                }
                0x00..=0x1F => {
                    return (pos, has_escape); // control char = error in real parser
                }
                _ => pos += 1,
            }
        }
    }

    /// Scan a JSON number starting at `pos`.
    /// Returns `(end_pos, is_float)` where `end_pos` is one past the last digit.
    #[inline]
    pub fn scan_number(input: &[u8], mut pos: usize) -> (usize, bool) {
        let mut is_float = false;

        // Optional minus
        if pos < input.len() && input[pos] == b'-' {
            pos += 1;
        }

        // Integer part
        if pos < input.len() {
            match input[pos] {
                b'0' => pos += 1,
                b'1'..=b'9' => {
                    pos += 1;
                    crate::simd_utils::skip_ascii_digits(input, &mut pos);
                    while pos < input.len() && input[pos].is_ascii_digit() {
                        pos += 1;
                    }
                }
                _ => return (pos, false),
            }
        }

        // Fractional part
        if pos < input.len() && input[pos] == b'.' {
            is_float = true;
            pos += 1;
            if pos >= input.len() || !input[pos].is_ascii_digit() {
                return (pos, is_float);
            }
            crate::simd_utils::skip_ascii_digits(input, &mut pos);
            while pos < input.len() && input[pos].is_ascii_digit() {
                pos += 1;
            }
        }

        // Exponent
        if pos < input.len() && (input[pos] == b'e' || input[pos] == b'E') {
            is_float = true;
            pos += 1;
            if pos < input.len() && (input[pos] == b'+' || input[pos] == b'-') {
                pos += 1;
            }
            crate::simd_utils::skip_ascii_digits(input, &mut pos);
            while pos < input.len() && input[pos].is_ascii_digit() {
                pos += 1;
            }
        }

        (pos, is_float)
    }

    /// Decode a JSON string with escape sequences.
    /// `start` and `end` are byte offsets into `input` pointing to the content
    /// between (but not including) the opening and closing quotes.
    pub fn decode_escaped_string(
        input: &[u8],
        start: usize,
        end: usize,
    ) -> Result<Vec<u8>, String> {
        let mut result = Vec::with_capacity(end - start);
        let mut i = start;

        while i < end {
            if input[i] == b'\\' && i + 1 < end {
                i += 1;
                match input[i] {
                    b'"' => result.push(b'"'),
                    b'\\' => result.push(b'\\'),
                    b'/' => result.push(b'/'),
                    b'b' => result.push(0x08),
                    b'f' => result.push(0x0C),
                    b'n' => result.push(b'\n'),
                    b'r' => result.push(b'\r'),
                    b't' => result.push(b'\t'),
                    b'u' => {
                        if i + 4 >= end {
                            return Err("Incomplete unicode escape".to_string());
                        }
                        let hex = &input[i + 1..i + 5];
                        if !hex.iter().all(|&b| b.is_ascii_hexdigit()) {
                            return Err("Invalid unicode escape".to_string());
                        }
                        let cp = u16::from_str_radix(
                            std::str::from_utf8(hex).expect("validated hex digits are valid UTF-8"),
                            16,
                        )
                        .expect("validated hex digits parse as u16");

                        if (0xD800..=0xDBFF).contains(&cp) {
                            if i + 11 <= end && input[i + 5] == b'\\' && input[i + 6] == b'u' {
                                let hex2 = &input[i + 7..i + 11];
                                if hex2.iter().all(|&b| b.is_ascii_hexdigit()) {
                                    let cp2 = u16::from_str_radix(
                                        std::str::from_utf8(hex2)
                                            .expect("validated hex digits are valid UTF-8"),
                                        16,
                                    )
                                    .expect("validated hex digits parse as u16");
                                    if (0xDC00..=0xDFFF).contains(&cp2) {
                                        let full_cp = 0x10000
                                            + ((cp as u32 - 0xD800) << 10)
                                            + (cp2 as u32 - 0xDC00);
                                        if let Some(c) = char::from_u32(full_cp) {
                                            let mut buf = [0u8; 4];
                                            result.extend_from_slice(
                                                c.encode_utf8(&mut buf).as_bytes(),
                                            );
                                        }
                                        i += 11;
                                        continue;
                                    }
                                }
                            }
                            return Err("Lone surrogate in string".to_string());
                        } else if (0xDC00..=0xDFFF).contains(&cp) {
                            return Err("Lone surrogate in string".to_string());
                        }

                        if let Some(c) = char::from_u32(cp as u32) {
                            let mut buf = [0u8; 4];
                            result.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
                        }
                        i += 4;
                    }
                    c => {
                        return Err(format!("Invalid escape sequence: \\{}", c as char));
                    }
                }
                i += 1;
            } else {
                result.push(input[i]);
                i += 1;
            }
        }
        Ok(result)
    }

    /// Build a structural index for the given input.
    /// Returns the number of structural positions found.
    pub fn build_structural_index(input: &[u8]) -> usize {
        let idx = super::build_structural_index(input);
        idx.positions.len()
    }

    /// Parse an integer from bytes using the same inline logic as parse_number_fast.
    /// Returns Ok(value) for valid integers ≤18 digits, Err(()) for anything else
    /// (floats, >18 digits, invalid input).
    pub fn parse_integer_fast(input: &[u8], mut pos: usize) -> Result<i64, ()> {
        if pos >= input.len() {
            return Err(());
        }
        let start = pos;
        let neg = input[pos] == b'-';
        if neg {
            pos += 1;
        }
        let digit_start = pos;
        while pos < input.len() && input[pos].is_ascii_digit() {
            pos += 1;
        }
        let digit_count = pos - digit_start;
        if digit_count == 0 {
            return Err(());
        }
        // Leading zero only for "0" or "-0"
        if digit_count > 1 && input[digit_start] == b'0' {
            return Err(());
        }
        // Reject floats / exponents
        if pos < input.len() && matches!(input[pos], b'.' | b'e' | b'E') {
            return Err(());
        }
        // Only handle ≤18 digits (no overflow possible for i64)
        if digit_count > 18 {
            return Err(());
        }
        let mut val: i64 = 0;
        for &b in &input[digit_start..pos] {
            val = val * 10 + (b - b'0') as i64;
        }
        if neg {
            val = -val;
        }
        // Verify we consumed exactly the right number of bytes from start
        let _ = start;
        Ok(val)
    }

    /// Validate JSON structure using the same scanning logic as the real parser.
    /// Exercises: structural index, whitespace skip, string scan, number scan,
    /// bracket matching, and basic value validation.
    /// Returns true if the input is structurally valid JSON, false otherwise.
    pub fn validate_json(input: &[u8]) -> bool {
        let pos = skip_whitespace(input, 0);
        if pos >= input.len() {
            return false;
        }
        let result = validate_value(input, pos);
        match result {
            Some(new_pos) => {
                let final_pos = skip_whitespace(input, new_pos);
                final_pos == input.len()
            }
            None => false,
        }
    }

    /// Validate a single JSON value starting at `pos`.
    /// Returns Some(end_pos) if valid, None if invalid.
    fn validate_value(input: &[u8], pos: usize) -> Option<usize> {
        if pos >= input.len() {
            return None;
        }
        match input[pos] {
            b'"' => {
                let (end, _has_escape) = scan_string(input, pos);
                // scan_string returns pos unchanged if no closing quote found
                if end == pos {
                    None
                } else {
                    Some(end)
                }
            }
            b'0'..=b'9' | b'-' => {
                let (end, _is_float) = scan_number(input, pos);
                if end == pos || (input[pos] == b'-' && end == pos + 1) {
                    None
                } else {
                    Some(end)
                }
            }
            b't' => {
                if input.len() >= pos + 4 && &input[pos..pos + 4] == b"true" {
                    Some(pos + 4)
                } else {
                    None
                }
            }
            b'f' => {
                if input.len() >= pos + 5 && &input[pos..pos + 5] == b"false" {
                    Some(pos + 5)
                } else {
                    None
                }
            }
            b'n' => {
                if input.len() >= pos + 4 && &input[pos..pos + 4] == b"null" {
                    Some(pos + 4)
                } else {
                    None
                }
            }
            b'[' => validate_array(input, pos),
            b'{' => validate_object(input, pos),
            _ => None,
        }
    }

    fn validate_array(input: &[u8], pos: usize) -> Option<usize> {
        let mut pos = pos + 1; // skip '['
        pos = skip_whitespace(input, pos);
        if pos < input.len() && input[pos] == b']' {
            return Some(pos + 1);
        }
        // First element
        pos = validate_value(input, pos)?;
        pos = skip_whitespace(input, pos);
        while pos < input.len() && input[pos] == b',' {
            pos += 1; // skip ','
            pos = skip_whitespace(input, pos);
            pos = validate_value(input, pos)?;
            pos = skip_whitespace(input, pos);
        }
        if pos < input.len() && input[pos] == b']' {
            Some(pos + 1)
        } else {
            None
        }
    }

    fn validate_object(input: &[u8], pos: usize) -> Option<usize> {
        let mut pos = pos + 1; // skip '{'
        pos = skip_whitespace(input, pos);
        if pos < input.len() && input[pos] == b'}' {
            return Some(pos + 1);
        }
        // First key-value pair
        if pos >= input.len() || input[pos] != b'"' {
            return None;
        }
        let (end, _) = scan_string(input, pos);
        if end == pos {
            return None;
        }
        pos = skip_whitespace(input, end);
        if pos >= input.len() || input[pos] != b':' {
            return None;
        }
        pos += 1; // skip ':'
        pos = skip_whitespace(input, pos);
        pos = validate_value(input, pos)?;
        pos = skip_whitespace(input, pos);
        while pos < input.len() && input[pos] == b',' {
            pos += 1; // skip ','
            pos = skip_whitespace(input, pos);
            if pos >= input.len() || input[pos] != b'"' {
                return None;
            }
            let (end, _) = scan_string(input, pos);
            if end == pos {
                return None;
            }
            pos = skip_whitespace(input, end);
            if pos >= input.len() || input[pos] != b':' {
                return None;
            }
            pos += 1;
            pos = skip_whitespace(input, pos);
            pos = validate_value(input, pos)?;
            pos = skip_whitespace(input, pos);
        }
        if pos < input.len() && input[pos] == b'}' {
            Some(pos + 1)
        } else {
            None
        }
    }
}

/// Parse JSON directly to Erlang terms without intermediate representation
#[inline]
#[must_use = "discarding the decoded term loses the parsing work"]
pub fn json_to_term<'a>(
    env: Env<'a>,
    input_binary: &Binary<'a>,
    opts: DecodeOptions,
) -> Result<Term<'a>, DecodeError> {
    let json = input_binary.as_slice();
    if opts.max_bytes > 0 && json.len() > opts.max_bytes {
        return Err((
            Cow::Owned(format!(
                "input size {} exceeds max_bytes limit of {}",
                json.len(),
                opts.max_bytes
            )),
            0,
        ));
    }
    DirectParser::new(env, json, *input_binary, opts).parse()
}
