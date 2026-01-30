use crate::atoms;
use num_bigint::BigInt;
use rustler::{types::atom, Encoder, Env, NewBinary, Term};
use std::collections::{HashMap, HashSet};
use std::hash::{BuildHasher, Hasher};

/// Maximum nesting depth to prevent stack overflow
const MAX_DEPTH: usize = 128;

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
            validate_strings: false,
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

/// Direct JSON-to-Term parser - builds Erlang terms during parsing without intermediate representation
pub struct DirectParser<'a, 'b> {
    input: &'b [u8],
    pos: usize,
    depth: usize,
    env: Env<'a>,
    /// Optional key cache for interning repeated object keys.
    /// Only allocated when `intern_keys=true`.
    key_cache: Option<FastHashMap<&'b [u8], Term<'a>>>,
    /// Decode options controlling behavior
    opts: DecodeOptions,
}

impl<'a, 'b> DirectParser<'a, 'b> {
    #[inline]
    pub fn new(env: Env<'a>, input: &'b [u8], opts: DecodeOptions) -> Self {
        let key_cache = if opts.intern_keys {
            Some(FastHashMap::with_capacity_and_hasher(
                32,
                FnvBuildHasher::new(),
            ))
        } else {
            None
        };
        Self {
            input,
            pos: 0,
            depth: 0,
            env,
            key_cache,
            opts,
        }
    }

    #[inline]
    pub fn parse(mut self) -> Result<Term<'a>, (String, usize)> {
        self.skip_whitespace();
        let term = self.parse_value()?;
        self.skip_whitespace();
        if self.pos < self.input.len() {
            return Err(("Unexpected trailing characters".to_string(), self.pos));
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

    #[inline(always)]
    fn err(&self, msg: &str) -> (String, usize) {
        (msg.to_string(), self.pos)
    }

    #[inline]
    fn parse_value(&mut self) -> Result<Term<'a>, (String, usize)> {
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
    fn parse_null(&mut self) -> Result<Term<'a>, (String, usize)> {
        if self.input[self.pos..].starts_with(b"null") {
            self.pos += 4;
            Ok(atom::nil().encode(self.env))
        } else {
            Err(self.err("Expected 'null'"))
        }
    }

    #[inline(always)]
    fn parse_true(&mut self) -> Result<Term<'a>, (String, usize)> {
        if self.input[self.pos..].starts_with(b"true") {
            self.pos += 4;
            Ok(true.encode(self.env))
        } else {
            Err(self.err("Expected 'true'"))
        }
    }

    #[inline(always)]
    fn parse_false(&mut self) -> Result<Term<'a>, (String, usize)> {
        if self.input[self.pos..].starts_with(b"false") {
            self.pos += 5;
            Ok(false.encode(self.env))
        } else {
            Err(self.err("Expected 'false'"))
        }
    }

    /// Core string parsing logic. When `for_key` is true and we have a cache,
    /// attempts to intern non-escaped strings.
    #[inline]
    fn parse_string_impl(&mut self, for_key: bool) -> Result<Term<'a>, (String, usize)> {
        let string_start = self.pos;
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
                        let decoded = self
                            .decode_escaped_string(start, end)
                            .map_err(|msg| (msg, string_start))?;
                        if self.opts.validate_strings && std::str::from_utf8(&decoded).is_err() {
                            return Err(("Invalid UTF-8 in string".to_string(), string_start));
                        }
                        return Ok(encode_binary(self.env, &decoded));
                    }

                    let str_bytes = &self.input[start..end];

                    // Optional UTF-8 validation for non-escaped strings
                    if self.opts.validate_strings && std::str::from_utf8(str_bytes).is_err() {
                        return Err(("Invalid UTF-8 in string".to_string(), string_start));
                    }

                    // Key interning: check cache if enabled and parsing a key.
                    if for_key {
                        if let Some(ref mut cache) = self.key_cache {
                            if let Some(&cached) = cache.get(str_bytes) {
                                return Ok(cached);
                            }
                            let term = encode_binary(self.env, str_bytes);
                            // Only insert if below the cap. Beyond MAX_INTERN_KEYS,
                            // the cache is not helping (too many unique keys) and
                            // continuing to grow it adds cost without benefit.
                            if cache.len() < MAX_INTERN_KEYS {
                                cache.insert(str_bytes, term);
                            }
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
                    return Err(self.err("Unescaped control character"));
                }
                _ => self.advance(),
            }
        }
        Err(("Unterminated string".to_string(), string_start))
    }

    /// Parse a string value (not interned)
    #[inline]
    fn parse_string(&mut self) -> Result<Term<'a>, (String, usize)> {
        self.parse_string_impl(false)
    }

    /// Parse an object key (interned if cache enabled)
    #[inline]
    fn parse_key(&mut self) -> Result<Term<'a>, (String, usize)> {
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
    fn parse_number(&mut self) -> Result<Term<'a>, (String, usize)> {
        let start = self.pos;
        let mut is_float = false;

        // Optional minus
        if self.peek() == Some(b'-') {
            self.advance();
        }

        // Integer part - track digit count for digit limit
        let int_digit_start = self.pos;
        match self.peek() {
            Some(b'0') => self.advance(),
            Some(b'1'..=b'9') => {
                self.advance();
                while matches!(self.peek(), Some(b'0'..=b'9')) {
                    self.advance();
                }
            }
            _ => return Err(("Invalid number".to_string(), start)),
        }
        let int_digit_count = self.pos - int_digit_start;

        // Check integer digit limit
        let limit = self.opts.integer_digit_limit;
        if limit > 0 && int_digit_count > limit {
            return Err((format!("integer exceeds {} digit limit", limit), start));
        }

        // Fractional part
        if self.peek() == Some(b'.') {
            is_float = true;
            self.advance();
            if !matches!(self.peek(), Some(b'0'..=b'9')) {
                return Err(("Invalid number".to_string(), start));
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
                return Err(("Invalid number".to_string(), start));
            }
            while matches!(self.peek(), Some(b'0'..=b'9')) {
                self.advance();
            }
        }

        let num_bytes = &self.input[start..self.pos];

        if is_float {
            if self.opts.floats_decimals {
                return self.parse_number_as_decimal(num_bytes, start);
            }
            // Use lexical-core for fast float parsing
            let f: f64 =
                lexical_core::parse(num_bytes).map_err(|_| ("Invalid float".to_string(), start))?;
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
                    .map_err(|_| ("Invalid number encoding".to_string(), start))?;
                let big: BigInt = num_str
                    .parse()
                    .map_err(|_| ("Invalid number".to_string(), start))?;
                Ok(big.encode(self.env))
            }
        }
    }

    /// Parse a float number string into a %Decimal{} struct term
    fn parse_number_as_decimal(
        &self,
        num_bytes: &[u8],
        start: usize,
    ) -> Result<Term<'a>, (String, usize)> {
        let num_str = std::str::from_utf8(num_bytes)
            .map_err(|_| ("Invalid number encoding".to_string(), start))?;

        // Determine sign
        let (sign_val, rest) = if let Some(stripped) = num_str.strip_prefix('-') {
            (-1i64, stripped)
        } else {
            (1i64, num_str)
        };

        // Split into integer/fraction and exponent parts
        let (mantissa_str, exp_part) = if let Some(e_pos) = rest.find(['e', 'E']) {
            (
                &rest[..e_pos],
                rest[e_pos + 1..].parse::<i64>().unwrap_or(0),
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
                .map_err(|_| ("Invalid decimal coefficient".to_string(), start))?;
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
            .map_err(|_| ("Failed to create Decimal struct".to_string(), start))
    }

    #[inline]
    fn parse_array(&mut self) -> Result<Term<'a>, (String, usize)> {
        self.depth += 1;
        if self.depth > MAX_DEPTH {
            return Err(self.err("Nesting depth exceeds maximum"));
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
    fn parse_object(&mut self) -> Result<Term<'a>, (String, usize)> {
        self.depth += 1;
        if self.depth > MAX_DEPTH {
            return Err(self.err("Nesting depth exceeds maximum"));
        }

        let obj_start = self.pos;
        self.advance(); // Skip '{'
        self.skip_whitespace();

        if self.peek() == Some(b'}') {
            self.advance();
            self.depth -= 1;
            if self.opts.ordered_objects {
                return self.build_ordered_object(vec![], vec![], obj_start);
            }
            return Ok(Term::map_new(self.env));
        }

        // Estimate capacity based on remaining input size
        let remaining = self.input.len() - self.pos;
        let estimated_capacity = (remaining / 30).clamp(4, 256);
        let mut keys = Vec::with_capacity(estimated_capacity);
        let mut values = Vec::with_capacity(estimated_capacity);

        // Optional duplicate key tracking
        let mut seen_keys: Option<HashSet<Vec<u8>>> = if self.opts.reject_duplicate_keys {
            Some(HashSet::with_capacity(estimated_capacity))
        } else {
            None
        };

        loop {
            // Parse key (use parse_key for potential interning)
            if self.peek() != Some(b'"') {
                return Err(self.err("Expected string key"));
            }
            let key_start = self.pos;
            let key = self.parse_key()?;

            // Check for duplicate keys if enabled — uses raw input bytes
            // (the region between quotes) rather than the decoded Term
            if let Some(ref mut seen) = seen_keys {
                // key_start is the opening quote, self.pos is after closing quote
                // The raw key content is between opening quote + 1 and closing quote - 1
                let raw_key = &self.input[key_start + 1..self.pos - 1];
                if !seen.insert(raw_key.to_vec()) {
                    return Err(("Duplicate key in object".to_string(), self.pos));
                }
            }

            keys.push(key);

            self.skip_whitespace();
            if self.peek() != Some(b':') {
                return Err(self.err("Expected ':'"));
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
                _ => return Err(self.err("Expected ',' or '}'")),
            }
        }

        self.depth -= 1;

        if self.opts.ordered_objects {
            return self.build_ordered_object(keys, values, obj_start);
        }

        // Fast path: no duplicate keys (common case)
        match Term::map_from_term_arrays(self.env, &keys, &values) {
            Ok(map) => Ok(map),
            Err(_) => {
                // Slow path: duplicate keys detected, use "last wins" semantics
                self.build_map_with_duplicates(keys, values, obj_start)
            }
        }
    }

    /// Build %RustyJson.OrderedObject{values: [{k, v}, ...]} preserving order.
    /// Pass empty vecs for an empty ordered object.
    fn build_ordered_object(
        &self,
        keys: Vec<Term<'a>>,
        values: Vec<Term<'a>>,
        pos: usize,
    ) -> Result<Term<'a>, (String, usize)> {
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
            .map_err(|_| ("Failed to create OrderedObject".to_string(), pos))
    }

    /// Build a map handling duplicate keys with "last wins" semantics
    #[cold]
    fn build_map_with_duplicates(
        &self,
        keys: Vec<Term<'a>>,
        values: Vec<Term<'a>>,
        pos: usize,
    ) -> Result<Term<'a>, (String, usize)> {
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
            .map_err(|_| ("Failed to create map".to_string(), pos))
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
pub fn json_to_term<'a>(
    env: Env<'a>,
    json: &[u8],
    opts: DecodeOptions,
) -> Result<Term<'a>, (String, usize)> {
    if opts.max_bytes > 0 && json.len() > opts.max_bytes {
        return Err((
            format!(
                "input size {} exceeds max_bytes limit of {}",
                json.len(),
                opts.max_bytes
            ),
            0,
        ));
    }
    DirectParser::new(env, json, opts).parse()
}
