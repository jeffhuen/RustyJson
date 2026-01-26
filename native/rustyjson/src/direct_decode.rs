use rustler::{types::atom, Encoder, Env, NewBinary, Term};
use std::collections::HashMap;
use std::hash::{BuildHasher, Hasher};

/// Maximum nesting depth to prevent stack overflow
const MAX_DEPTH: usize = 128;

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

struct FnvBuildHasher;

impl BuildHasher for FnvBuildHasher {
    type Hasher = FnvHasher;

    #[inline]
    fn build_hasher(&self) -> FnvHasher {
        FnvHasher(0xcbf29ce484222325) // FNV offset basis
    }
}

impl Default for FnvBuildHasher {
    fn default() -> Self {
        FnvBuildHasher
    }
}

type FastHashMap<K, V> = HashMap<K, V, FnvBuildHasher>;

/// Direct JSON-to-Term parser - builds Erlang terms during parsing without intermediate representation
pub struct DirectParser<'a, 'b> {
    input: &'b [u8],
    pos: usize,
    depth: usize,
    env: Env<'a>,
    /// Optional key cache for interning repeated object keys.
    /// Only allocated when `intern_keys=true`.
    key_cache: Option<FastHashMap<&'b [u8], Term<'a>>>,
}

impl<'a, 'b> DirectParser<'a, 'b> {
    #[inline]
    pub fn new(env: Env<'a>, input: &'b [u8], intern_keys: bool) -> Self {
        Self {
            input,
            pos: 0,
            depth: 0,
            env,
            key_cache: if intern_keys {
                Some(FastHashMap::with_capacity_and_hasher(32, FnvBuildHasher))
            } else {
                None
            },
        }
    }

    #[inline]
    pub fn parse(mut self) -> Result<Term<'a>, String> {
        self.skip_whitespace();
        let term = self.parse_value()?;
        self.skip_whitespace();
        if self.pos < self.input.len() {
            return Err(format!(
                "Unexpected trailing characters at position {}",
                self.pos
            ));
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
        while let Some(&byte) = self.input.get(self.pos) {
            match byte {
                b' ' | b'\t' | b'\n' | b'\r' => self.pos += 1,
                _ => break,
            }
        }
    }

    #[inline]
    fn parse_value(&mut self) -> Result<Term<'a>, String> {
        match self.peek() {
            Some(b'n') => self.parse_null(),
            Some(b't') => self.parse_true(),
            Some(b'f') => self.parse_false(),
            Some(b'"') => self.parse_string(),
            Some(b'[') => self.parse_array(),
            Some(b'{') => self.parse_object(),
            Some(b'-') | Some(b'0'..=b'9') => self.parse_number(),
            Some(c) => Err(format!(
                "Unexpected character '{}' at position {}",
                c as char, self.pos
            )),
            None => Err("Unexpected end of input".to_string()),
        }
    }

    #[inline(always)]
    fn parse_null(&mut self) -> Result<Term<'a>, String> {
        if self.input[self.pos..].starts_with(b"null") {
            self.pos += 4;
            Ok(atom::nil().encode(self.env))
        } else {
            Err(format!("Expected 'null' at position {}", self.pos))
        }
    }

    #[inline(always)]
    fn parse_true(&mut self) -> Result<Term<'a>, String> {
        if self.input[self.pos..].starts_with(b"true") {
            self.pos += 4;
            Ok(true.encode(self.env))
        } else {
            Err(format!("Expected 'true' at position {}", self.pos))
        }
    }

    #[inline(always)]
    fn parse_false(&mut self) -> Result<Term<'a>, String> {
        if self.input[self.pos..].starts_with(b"false") {
            self.pos += 5;
            Ok(false.encode(self.env))
        } else {
            Err(format!("Expected 'false' at position {}", self.pos))
        }
    }

    /// Core string parsing logic. When `for_key` is true and we have a cache,
    /// attempts to intern non-escaped strings.
    #[inline]
    fn parse_string_impl(&mut self, for_key: bool) -> Result<Term<'a>, String> {
        self.advance(); // Skip opening quote
        let start = self.pos;
        let mut has_escape = false;

        // Fast path: scan for end quote, checking for escapes
        while let Some(b) = self.peek() {
            match b {
                b'"' => {
                    let end = self.pos;
                    self.advance(); // Skip closing quote

                    // Escaped strings: decode and return (cannot intern - decoded
                    // bytes differ from input slice, and escaped keys are rare)
                    if has_escape {
                        let decoded = self.decode_escaped_string(start, end)?;
                        return Ok(encode_binary(self.env, &decoded));
                    }

                    let str_bytes = &self.input[start..end];

                    // Key interning: check cache if enabled and parsing a key.
                    // Note: Keys with escape sequences are NOT interned because:
                    // 1. We can't use raw input bytes as cache key (they differ from decoded form)
                    // 2. Escaped keys in object schemas are rare in practice
                    // 3. Performance impact is negligible for typical data
                    if for_key {
                        if let Some(ref mut cache) = self.key_cache {
                            if let Some(&cached) = cache.get(str_bytes) {
                                return Ok(cached);
                            }
                            let term = encode_binary(self.env, str_bytes);
                            cache.insert(str_bytes, term);
                            return Ok(term);
                        }
                    }

                    return Ok(encode_binary(self.env, str_bytes));
                }
                b'\\' => {
                    has_escape = true;
                    self.advance();
                    if self.peek().is_some() {
                        self.advance(); // Skip escaped char
                    }
                }
                // JSON spec: control characters (0x00-0x1F) must be escaped
                0x00..=0x1F => {
                    return Err(format!(
                        "Unescaped control character at position {}",
                        self.pos
                    ));
                }
                _ => self.advance(),
            }
        }
        Err("Unterminated string".to_string())
    }

    /// Parse a string value (not interned)
    #[inline]
    fn parse_string(&mut self) -> Result<Term<'a>, String> {
        self.parse_string_impl(false)
    }

    /// Parse an object key (interned if cache enabled)
    #[inline]
    fn parse_key(&mut self) -> Result<Term<'a>, String> {
        self.parse_string_impl(true)
    }

    #[inline]
    fn decode_escaped_string(&self, start: usize, end: usize) -> Result<Vec<u8>, String> {
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
                            return Err("Incomplete unicode escape".to_string());
                        }
                        let hex = &self.input[i + 1..i + 5];
                        // Validate all 4 are hex digits
                        if !hex.iter().all(|&b| b.is_ascii_hexdigit()) {
                            return Err("Invalid unicode escape".to_string());
                        }
                        let cp =
                            u16::from_str_radix(std::str::from_utf8(hex).unwrap(), 16).unwrap();

                        // Handle UTF-16 surrogate pairs
                        if (0xD800..=0xDBFF).contains(&cp) {
                            // High surrogate - must be followed by low surrogate
                            if i + 11 <= end
                                && self.input[i + 5] == b'\\'
                                && self.input[i + 6] == b'u'
                            {
                                let hex2 = &self.input[i + 7..i + 11];
                                if hex2.iter().all(|&b| b.is_ascii_hexdigit()) {
                                    let cp2 =
                                        u16::from_str_radix(std::str::from_utf8(hex2).unwrap(), 16)
                                            .unwrap();
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
                            return Err("Lone surrogate in string".to_string());
                        } else if (0xDC00..=0xDFFF).contains(&cp) {
                            // Lone low surrogate - invalid
                            return Err("Lone surrogate in string".to_string());
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
                        return Err(format!("Invalid escape sequence: \\{}", c as char));
                    }
                }
                i += 1;
            } else {
                result.push(self.input[i]);
                i += 1;
            }
        }
        Ok(result)
    }

    #[inline]
    fn parse_number(&mut self) -> Result<Term<'a>, String> {
        let start = self.pos;
        let mut is_float = false;

        // Optional minus
        if self.peek() == Some(b'-') {
            self.advance();
        }

        // Integer part
        match self.peek() {
            Some(b'0') => self.advance(),
            Some(b'1'..=b'9') => {
                self.advance();
                while matches!(self.peek(), Some(b'0'..=b'9')) {
                    self.advance();
                }
            }
            _ => return Err(format!("Invalid number at position {}", self.pos)),
        }

        // Fractional part
        if self.peek() == Some(b'.') {
            is_float = true;
            self.advance();
            if !matches!(self.peek(), Some(b'0'..=b'9')) {
                return Err(format!("Invalid number at position {}", self.pos));
            }
            while matches!(self.peek(), Some(b'0'..=b'9')) {
                self.advance();
            }
        }

        // Exponent
        if matches!(self.peek(), Some(b'e') | Some(b'E')) {
            is_float = true;
            self.advance();
            if matches!(self.peek(), Some(b'+') | Some(b'-')) {
                self.advance();
            }
            if !matches!(self.peek(), Some(b'0'..=b'9')) {
                return Err(format!("Invalid number at position {}", self.pos));
            }
            while matches!(self.peek(), Some(b'0'..=b'9')) {
                self.advance();
            }
        }

        let num_bytes = &self.input[start..self.pos];

        if is_float {
            // Use lexical-core for fast float parsing
            let f: f64 = lexical_core::parse(num_bytes).map_err(|_| "Invalid float")?;
            Ok(f.encode(self.env))
        } else {
            // Try i64 first using lexical-core
            if let Ok(i) = lexical_core::parse::<i64>(num_bytes) {
                Ok(i.encode(self.env))
            } else if let Ok(u) = lexical_core::parse::<u64>(num_bytes) {
                Ok(u.encode(self.env))
            } else {
                // Fall back to float for very large numbers
                let f: f64 = lexical_core::parse(num_bytes).map_err(|_| "Invalid number")?;
                Ok(f.encode(self.env))
            }
        }
    }

    #[inline]
    fn parse_array(&mut self) -> Result<Term<'a>, String> {
        self.depth += 1;
        if self.depth > MAX_DEPTH {
            return Err(format!("Nesting depth exceeds maximum of {}", MAX_DEPTH));
        }

        self.advance(); // Skip '['
        self.skip_whitespace();

        if self.peek() == Some(b']') {
            self.advance();
            self.depth -= 1;
            return Ok(Term::list_new_empty(self.env));
        }

        // Estimate capacity based on remaining input size (rough heuristic)
        let remaining = self.input.len() - self.pos;
        let estimated_capacity = (remaining / 20).clamp(8, 1024);
        let mut elements = Vec::with_capacity(estimated_capacity);

        loop {
            let elem = self.parse_value()?;
            elements.push(elem);
            self.skip_whitespace();

            match self.peek() {
                Some(b',') => {
                    self.advance();
                    self.skip_whitespace();
                }
                Some(b']') => {
                    self.advance();
                    break;
                }
                _ => return Err(format!("Expected ',' or ']' at position {}", self.pos)),
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
    fn parse_object(&mut self) -> Result<Term<'a>, String> {
        self.depth += 1;
        if self.depth > MAX_DEPTH {
            return Err(format!("Nesting depth exceeds maximum of {}", MAX_DEPTH));
        }

        self.advance(); // Skip '{'
        self.skip_whitespace();

        if self.peek() == Some(b'}') {
            self.advance();
            self.depth -= 1;
            return Ok(Term::map_new(self.env));
        }

        // Estimate capacity based on remaining input size
        let remaining = self.input.len() - self.pos;
        let estimated_capacity = (remaining / 30).clamp(4, 256);
        let mut keys = Vec::with_capacity(estimated_capacity);
        let mut values = Vec::with_capacity(estimated_capacity);

        loop {
            // Parse key (use parse_key for potential interning)
            if self.peek() != Some(b'"') {
                return Err(format!("Expected string key at position {}", self.pos));
            }
            let key = self.parse_key()?;
            keys.push(key);

            self.skip_whitespace();
            if self.peek() != Some(b':') {
                return Err(format!("Expected ':' at position {}", self.pos));
            }
            self.advance();
            self.skip_whitespace();

            // Parse value
            let value = self.parse_value()?;
            values.push(value);

            self.skip_whitespace();
            match self.peek() {
                Some(b',') => {
                    self.advance();
                    self.skip_whitespace();
                }
                Some(b'}') => {
                    self.advance();
                    break;
                }
                _ => return Err(format!("Expected ',' or '}}' at position {}", self.pos)),
            }
        }

        self.depth -= 1;

        // Fast path: no duplicate keys (common case)
        match Term::map_from_term_arrays(self.env, &keys, &values) {
            Ok(map) => Ok(map),
            Err(_) => {
                // Slow path: duplicate keys detected, use "last wins" semantics
                self.build_map_with_duplicates(keys, values)
            }
        }
    }

    /// Build a map handling duplicate keys with "last wins" semantics
    #[cold]
    fn build_map_with_duplicates(
        &self,
        keys: Vec<Term<'a>>,
        values: Vec<Term<'a>>,
    ) -> Result<Term<'a>, String> {
        // Extract key bytes and deduplicate
        let mut key_map: HashMap<Vec<u8>, usize> = HashMap::with_capacity(keys.len());
        let mut final_keys = Vec::with_capacity(keys.len());
        let mut final_values = Vec::with_capacity(keys.len());

        for (i, key) in keys.iter().enumerate() {
            // Get the binary bytes from the key term
            let key_bytes: Vec<u8> = key.decode().unwrap_or_default();

            if let Some(&existing_idx) = key_map.get(&key_bytes) {
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
            .map_err(|_| "Failed to create map".to_string())
    }
}

#[inline(always)]
fn encode_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut bin = NewBinary::new(env, bytes.len());
    bin.as_mut_slice().copy_from_slice(bytes);
    bin.into()
}

/// Parse JSON directly to Erlang terms without intermediate representation
#[inline]
pub fn json_to_term<'a>(env: Env<'a>, json: &[u8], intern_keys: bool) -> Result<Term<'a>, String> {
    DirectParser::new(env, json, intern_keys).parse()
}
