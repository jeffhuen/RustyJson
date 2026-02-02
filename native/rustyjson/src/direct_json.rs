use crate::decimal::try_format_decimal;
use rustler::types::{ListIterator, MapIterator};
use rustler::{Binary, Term, TermType};
use smallvec::SmallVec;
use std::collections::HashSet;
use std::io::Write;

/// Escape mode for JSON string encoding
#[derive(Clone, Copy, PartialEq)]
pub enum EscapeMode {
    /// Standard JSON escaping (default)
    Json,
    /// Also escape <, >, & for safe HTML embedding
    HtmlSafe,
    /// Escape all non-ASCII characters as \uXXXX
    UnicodeSafe,
    /// Escape line/paragraph separators for JavaScript embedding
    JavaScriptSafe,
}

impl EscapeMode {
    pub fn from_term(term: rustler::Term) -> Self {
        if let Ok(name) = term.atom_to_string() {
            match name.as_str() {
                "html_safe" => EscapeMode::HtmlSafe,
                "unicode_safe" => EscapeMode::UnicodeSafe,
                "javascript_safe" => EscapeMode::JavaScriptSafe,
                _ => EscapeMode::Json,
            }
        } else {
            EscapeMode::Json
        }
    }
}

/// Shared formatting context holding heap-allocated separator strings.
/// Referenced by `FormatOptions` to avoid cloning on every `nested()` call.
pub struct FormatContext {
    pub line_separator: SmallVec<[u8; 16]>,
    pub after_colon: SmallVec<[u8; 16]>,
    pub indent: SmallVec<[u8; 16]>,
    pub strict_keys: bool,
    pub sort_keys: bool,
}

impl Default for FormatContext {
    fn default() -> Self {
        Self {
            line_separator: SmallVec::from_slice(b"\n"),
            after_colon: SmallVec::from_slice(b" "),
            indent: SmallVec::from_slice(b"  "),
            strict_keys: false,
            sort_keys: false,
        }
    }
}

/// Formatting options for JSON output
#[derive(Clone, Copy)]
pub struct FormatOptions<'ctx> {
    /// Whether pretty printing is enabled
    pretty: bool,
    /// Current indentation level (internal use)
    depth: u32,
    /// If true, skip special struct handling (Date, Time, etc.)
    lean: bool,
    /// Escape mode for strings
    escape: EscapeMode,
    /// Shared context with heap-allocated data
    ctx: &'ctx FormatContext,
}

impl<'ctx> FormatOptions<'ctx> {
    pub fn compact(ctx: &'ctx FormatContext) -> Self {
        Self {
            pretty: false,
            depth: 0,
            lean: false,
            escape: EscapeMode::Json,
            ctx,
        }
    }

    pub fn pretty(ctx: &'ctx FormatContext) -> Self {
        Self {
            pretty: true,
            depth: 0,
            lean: false,
            escape: EscapeMode::Json,
            ctx,
        }
    }

    pub fn with_lean(mut self, lean: bool) -> Self {
        self.lean = lean;
        self
    }

    pub fn with_escape(mut self, escape: EscapeMode) -> Self {
        self.escape = escape;
        self
    }

    #[inline(always)]
    fn is_pretty(&self) -> bool {
        self.pretty
    }

    #[inline(always)]
    fn is_lean(&self) -> bool {
        self.lean
    }

    #[inline(always)]
    pub fn strict_keys(&self) -> bool {
        self.ctx.strict_keys
    }

    #[inline(always)]
    pub fn sort_keys(&self) -> bool {
        self.ctx.sort_keys
    }

    #[inline(always)]
    fn escape_mode(&self) -> EscapeMode {
        self.escape
    }

    #[inline(always)]
    fn nested(&self) -> Self {
        Self {
            pretty: self.pretty,
            depth: self.depth + 1,
            lean: self.lean,
            escape: self.escape,
            ctx: self.ctx,
        }
    }

    #[inline(always)]
    fn write_newline<W: Write>(&self, writer: &mut W) -> Result<(), std::io::Error> {
        if self.is_pretty() {
            writer.write_all(&self.ctx.line_separator)?;
            let indent = &self.ctx.indent;
            for _ in 0..self.depth {
                writer.write_all(indent)?;
            }
        }
        Ok(())
    }

    #[inline(always)]
    fn write_space<W: Write>(&self, writer: &mut W) -> Result<(), std::io::Error> {
        if self.is_pretty() {
            writer.write_all(&self.ctx.after_colon)?;
        }
        Ok(())
    }
}

/// Maximum nesting depth to prevent stack overflow
const MAX_DEPTH: u32 = 128;

/// Check for duplicate keys in strict mode. Returns an error if the key was already seen.
#[inline]
fn check_strict_key(seen: &mut Option<HashSet<String>>, key: &str) -> Result<(), std::io::Error> {
    if let Some(ref mut set) = seen {
        if !set.insert(key.to_string()) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("duplicate key: {:?}", key),
            ));
        }
    }
    Ok(())
}

/// Write a term directly to JSON, bypassing serde.
pub fn term_to_json<W: Write>(
    term: Term,
    writer: &mut W,
    opts: FormatOptions<'_>,
) -> Result<(), std::io::Error> {
    if opts.depth > MAX_DEPTH {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("Nesting depth exceeds maximum of {}", MAX_DEPTH),
        ));
    }

    match term.get_type() {
        TermType::Atom => write_atom(term, writer, opts),
        TermType::Binary => write_binary(term, writer, opts),
        TermType::Integer => write_integer(term, writer),
        TermType::Float => write_float(term, writer),
        TermType::List => write_list(term, writer, opts),
        TermType::Map => write_map(term, writer, opts),
        TermType::Tuple => write_tuple(term, writer, opts),
        _ => Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("Unsupported term type: {:?}", term.get_type()),
        )),
    }
}

#[inline(always)]
fn write_atom<W: Write>(
    term: Term,
    writer: &mut W,
    opts: FormatOptions<'_>,
) -> Result<(), std::io::Error> {
    if let Ok(s) = term.atom_to_string() {
        match s.as_str() {
            "true" => writer.write_all(b"true")?,
            "false" => writer.write_all(b"false")?,
            "nil" | "null" => writer.write_all(b"null")?,
            _ => write_json_string(&s, writer, opts.escape_mode())?,
        }
        Ok(())
    } else {
        Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Failed to decode atom",
        ))
    }
}

#[inline(always)]
fn write_binary<W: Write>(
    term: Term,
    writer: &mut W,
    opts: FormatOptions<'_>,
) -> Result<(), std::io::Error> {
    // Use Binary for zero-copy access to bytes
    if let Ok(binary) = term.decode::<Binary>() {
        let bytes = binary.as_slice();
        // Check if valid UTF-8 - error on invalid bytes (Jason compatibility)
        match simdutf8::basic::from_utf8(bytes) {
            Ok(s) => {
                write_json_string_escaped(s, writer, opts.escape_mode())?;
                Ok(())
            }
            Err(_) => Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "Failed to decode binary",
            )),
        }
    } else {
        Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Failed to decode binary",
        ))
    }
}

#[inline(always)]
fn write_integer<W: Write>(term: Term, writer: &mut W) -> Result<(), std::io::Error> {
    if let Ok(n) = term.decode::<i64>() {
        let mut buf = itoa::Buffer::new();
        writer.write_all(buf.format(n).as_bytes())?;
        return Ok(());
    }
    if let Ok(n) = term.decode::<u64>() {
        let mut buf = itoa::Buffer::new();
        writer.write_all(buf.format(n).as_bytes())?;
        return Ok(());
    }
    if let Ok(n) = term.decode::<i128>() {
        write!(writer, "{}", n)?;
        return Ok(());
    }
    if let Ok(n) = term.decode::<num_bigint::BigInt>() {
        write!(writer, "{}", n)?;
        return Ok(());
    }
    Err(std::io::Error::new(
        std::io::ErrorKind::InvalidData,
        "Failed to decode integer",
    ))
}

#[inline(always)]
fn write_float<W: Write>(term: Term, writer: &mut W) -> Result<(), std::io::Error> {
    if let Ok(f) = term.decode::<f64>() {
        if f.is_finite() {
            let mut buf = ryu::Buffer::new();
            writer.write_all(buf.format(f).as_bytes())?;
            Ok(())
        } else {
            Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "Non-finite float",
            ))
        }
    } else {
        Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Failed to decode float",
        ))
    }
}

#[inline(always)]
fn write_list<W: Write>(
    term: Term,
    writer: &mut W,
    opts: FormatOptions<'_>,
) -> Result<(), std::io::Error> {
    let mut iter: ListIterator = term.decode().map_err(|_| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, "Failed to decode list")
    })?;

    let first_item = match iter.next() {
        None => {
            writer.write_all(b"[]")?;
            return Ok(());
        }
        Some(item) => item,
    };

    let nested = opts.nested();
    writer.write_all(b"[")?;
    nested.write_newline(writer)?;
    term_to_json(first_item, writer, nested)?;

    for item in iter {
        writer.write_all(b",")?;
        nested.write_newline(writer)?;
        term_to_json(item, writer, nested)?;
    }

    opts.write_newline(writer)?;
    writer.write_all(b"]")?;
    Ok(())
}

/// Extract the JSON key string from a Term (atom, binary, or integer).
/// Returns Ok(key_string) or Err. For atoms, returns None for "__struct__" to signal skipping.
#[inline]
fn key_to_string(key: &Term) -> Result<Option<String>, std::io::Error> {
    match key.get_type() {
        TermType::Atom => {
            if let Ok(key_str) = key.atom_to_string() {
                if key_str == "__struct__" {
                    Ok(None)
                } else {
                    Ok(Some(key_str))
                }
            } else {
                Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "Failed to decode atom key",
                ))
            }
        }
        TermType::Binary => {
            if let Ok(binary) = key.decode::<Binary>() {
                if let Ok(s) = std::str::from_utf8(binary.as_slice()) {
                    Ok(Some(s.to_string()))
                } else {
                    Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "Non-UTF8 binary as map key",
                    ))
                }
            } else {
                Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "Failed to decode binary key",
                ))
            }
        }
        TermType::Integer => {
            if let Ok(n) = key.decode::<i64>() {
                let mut buf = itoa::Buffer::new();
                Ok(Some(buf.format(n).to_string()))
            } else {
                Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "Failed to decode integer key",
                ))
            }
        }
        _ => Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Map key must be atom, string, or integer",
        )),
    }
}

#[inline(always)]
fn write_map<W: Write>(
    term: Term,
    writer: &mut W,
    opts: FormatOptions<'_>,
) -> Result<(), std::io::Error> {
    // Check for special struct types using pre-interned __struct__ atom.
    // This is a single map_get with a cached atom — no Atom::from_str overhead.
    // Only done when not in lean mode.
    if !opts.is_lean() {
        if let Ok(struct_name) = term.map_get(crate::atoms::__struct__().to_term(term.get_env())) {
            if let Some(result) =
                try_format_special_struct_from_name(&term, &struct_name, writer, opts)?
            {
                return Ok(result);
            }
        }
    }

    if opts.sort_keys() {
        write_map_sorted(term, writer, opts)
    } else {
        write_map_unsorted(term, writer, opts)
    }
}

/// Write map entries in sorted key order.
fn write_map_sorted<W: Write>(
    term: Term,
    writer: &mut W,
    opts: FormatOptions<'_>,
) -> Result<(), std::io::Error> {
    let iter = MapIterator::new(term).ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, "Failed to iterate map")
    })?;

    let strict = opts.strict_keys();
    let mut seen_keys: Option<HashSet<String>> = if strict { Some(HashSet::new()) } else { None };

    // Collect entries, skipping __struct__
    let mut entries: Vec<(String, Term)> = Vec::new();
    for (key, value) in iter {
        match key_to_string(&key)? {
            None => continue, // __struct__
            Some(key_str) => {
                check_strict_key(&mut seen_keys, &key_str)?;
                entries.push((key_str, value));
            }
        }
    }

    if entries.is_empty() {
        writer.write_all(b"{}")?;
        return Ok(());
    }

    entries.sort_by(|a, b| a.0.cmp(&b.0));

    let nested = opts.nested();
    let escape = opts.escape_mode();

    writer.write_all(b"{")?;
    for (i, (key_str, value)) in entries.iter().enumerate() {
        if i > 0 {
            writer.write_all(b",")?;
        }
        nested.write_newline(writer)?;
        write_json_string(key_str, writer, escape)?;
        writer.write_all(b":")?;
        nested.write_space(writer)?;
        term_to_json(*value, writer, nested)?;
    }
    opts.write_newline(writer)?;
    writer.write_all(b"}")?;
    Ok(())
}

/// Write map entries in iteration order (unsorted, zero overhead).
#[inline(always)]
fn write_map_unsorted<W: Write>(
    term: Term,
    writer: &mut W,
    opts: FormatOptions<'_>,
) -> Result<(), std::io::Error> {
    let iter = MapIterator::new(term).ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, "Failed to iterate map")
    })?;

    let nested = opts.nested();
    let escape = opts.escape_mode();
    let strict = opts.strict_keys();
    let mut seen_keys: Option<HashSet<String>> = if strict { Some(HashSet::new()) } else { None };

    // We don't know if map is empty until we iterate, so track first entry
    let mut started = false;

    for (key, value) in iter {
        if key.get_type() == TermType::Atom {
            if let Ok(key_str) = key.atom_to_string() {
                if key_str == "__struct__" {
                    // Skip __struct__ key from output
                    continue;
                }

                check_strict_key(&mut seen_keys, &key_str)?;

                // Write opening brace on first non-filtered entry
                if !started {
                    writer.write_all(b"{")?;
                    started = true;
                } else {
                    writer.write_all(b",")?;
                }
                nested.write_newline(writer)?;
                write_json_string(&key_str, writer, escape)?;
            } else {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "Failed to decode atom key",
                ));
            }
        } else {
            // Non-atom key — this map is definitely not a struct, no need to
            // check for __struct__. Write opening brace if needed.
            if !started {
                writer.write_all(b"{")?;
                started = true;
            } else {
                writer.write_all(b",")?;
            }
            nested.write_newline(writer)?;

            // Write key - strings and integers
            match key.get_type() {
                TermType::Binary => {
                    if let Ok(binary) = key.decode::<Binary>() {
                        if let Ok(s) = std::str::from_utf8(binary.as_slice()) {
                            check_strict_key(&mut seen_keys, s)?;
                            write_json_string(s, writer, escape)?;
                        } else {
                            return Err(std::io::Error::new(
                                std::io::ErrorKind::InvalidData,
                                "Non-UTF8 binary as map key",
                            ));
                        }
                    } else {
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::InvalidData,
                            "Failed to decode binary key",
                        ));
                    }
                }
                TermType::Integer => {
                    // Convert integer keys to strings
                    if let Ok(n) = key.decode::<i64>() {
                        let mut buf = itoa::Buffer::new();
                        let key_str = buf.format(n);
                        check_strict_key(&mut seen_keys, key_str)?;
                        write_json_string(key_str, writer, escape)?;
                    } else {
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::InvalidData,
                            "Failed to decode integer key",
                        ));
                    }
                }
                _ => {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "Map key must be atom, string, or integer",
                    ));
                }
            }
        }

        writer.write_all(b":")?;
        nested.write_space(writer)?;
        term_to_json(value, writer, nested)?;
    }

    if started {
        opts.write_newline(writer)?;
        writer.write_all(b"}")?;
    } else {
        // Empty map (or map with only __struct__)
        writer.write_all(b"{}")?;
    }
    Ok(())
}

/// Try to format special Elixir structs (Decimal, Date, Time, DateTime, NaiveDateTime, URI).
/// Called when we encounter __struct__ during map iteration — the struct name value
/// is passed directly, avoiding a separate map_get lookup.
/// Returns Ok(Some(())) if handled, Ok(None) if not a special struct, Err on error.
fn try_format_special_struct_from_name<W: Write>(
    term: &Term,
    struct_name_term: &Term,
    writer: &mut W,
    opts: FormatOptions<'_>,
) -> Result<Option<()>, std::io::Error> {
    let struct_str = match struct_name_term.atom_to_string() {
        Ok(s) => s,
        Err(_) => return Ok(None),
    };

    let escape = opts.escape_mode();

    match struct_str.as_str() {
        "Elixir.Decimal" => {
            if let Some(decimal_string) = try_format_decimal(term) {
                write_json_string(&decimal_string, writer, escape)?;
                return Ok(Some(()));
            }
        }
        "Elixir.Date" => {
            if try_write_date(term, writer)? {
                return Ok(Some(()));
            }
        }
        "Elixir.Time" => {
            if try_write_time(term, writer)? {
                return Ok(Some(()));
            }
        }
        "Elixir.NaiveDateTime" => {
            if try_write_naive_datetime(term, writer)? {
                return Ok(Some(()));
            }
        }
        "Elixir.DateTime" => {
            if try_write_datetime(term, writer)? {
                return Ok(Some(()));
            }
        }
        "Elixir.URI" => {
            if let Some(uri_str) = try_format_uri(term) {
                write_json_string(&uri_str, writer, escape)?;
                return Ok(Some(()));
            }
        }
        "Elixir.MapSet" => {
            // MapSet has a "map" field containing the actual data as map keys
            if let Some(()) = try_format_mapset(term, writer, opts)? {
                return Ok(Some(()));
            }
        }
        "Elixir.Range" => {
            // Range has first, last, step fields - encode as array [first, last] or [first, last, step]
            if let Some(()) = try_format_range(term, writer, opts)? {
                return Ok(Some(()));
            }
        }
        "Elixir.RustyJson.Fragment" | "Elixir.Jason.Fragment" => {
            if let Some(()) = try_format_fragment(term, writer)? {
                return Ok(Some(()));
            }
        }
        _ => {}
    }

    Ok(None)
}

/// Format pre-encoded JSON fragment
fn try_format_fragment<W: Write>(
    term: &Term,
    writer: &mut W,
) -> Result<Option<()>, std::io::Error> {
    let env = term.get_env();
    let t = *term;

    let encode_atom = crate::atoms::encode().to_term(env);
    let encode_term = match t.map_get(encode_atom) {
        Ok(v) => v,
        Err(_) => return Ok(None),
    };

    write_iodata(writer, encode_term)?;
    Ok(Some(()))
}

/// Write iodata directly to writer
fn write_iodata<W: Write>(writer: &mut W, term: Term) -> Result<(), std::io::Error> {
    if term.is_binary() {
        let binary: Binary = term.decode().map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::InvalidData, "Failed to decode binary")
        })?;
        writer.write_all(binary.as_slice())?;
        Ok(())
    } else if term.is_list() {
        let mut current = term;
        while let Ok((head, tail)) = current.list_get_cell() {
            write_iodata(writer, head)?;
            current = tail;
        }
        if !current.is_empty_list() {
            write_iodata(writer, current)?;
        }
        Ok(())
    } else if let Ok(byte) = term.decode::<u8>() {
        writer.write_all(&[byte])?;
        Ok(())
    } else {
        Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Invalid iodata in fragment",
        ))
    }
}

/// Write a zero-padded unsigned integer directly to the writer.
#[inline]
fn write_padded<W: Write>(writer: &mut W, val: u32, width: u8) -> std::io::Result<()> {
    let mut buf = [b'0'; 6]; // max width we need is 6 (microseconds)
    let w = width as usize;
    let mut v = val;
    let mut i = w;
    while i > 0 {
        i -= 1;
        buf[i] = b'0' + (v % 10) as u8;
        v /= 10;
    }
    writer.write_all(&buf[..w])
}

/// Write a zero-padded signed integer directly to the writer.
/// For negative values, writes '-' prefix then the absolute value zero-padded to `width` digits.
#[inline]
fn write_padded_i32<W: Write>(writer: &mut W, val: i32, width: u8) -> std::io::Result<()> {
    if val < 0 {
        writer.write_all(b"-")?;
        write_padded(writer, val.unsigned_abs(), width)
    } else {
        write_padded(writer, val as u32, width)
    }
}

/// Write microsecond fractional part (e.g. ".123456") directly to writer.
/// Writes `precision` digits from the 6-digit zero-padded microsecond value.
#[inline]
fn write_microsecond_frac<W: Write>(
    writer: &mut W,
    micro_val: u32,
    precision: usize,
) -> std::io::Result<()> {
    writer.write_all(b".")?;
    let mut buf = [b'0'; 6];
    let mut v = micro_val;
    let mut i = 6;
    while i > 0 {
        i -= 1;
        buf[i] = b'0' + (v % 10) as u8;
        v /= 10;
    }
    writer.write_all(&buf[..precision])
}

/// Write Elixir Date directly as quoted ISO8601: "YYYY-MM-DD"
/// Returns Ok(true) if handled, Ok(false) if fields missing.
fn try_write_date<W: Write>(term: &Term, writer: &mut W) -> std::io::Result<bool> {
    let env = term.get_env();
    let t = *term;

    let year: i32 = match get_struct_field_atom(t, env, crate::atoms::year()) {
        Some(v) => v,
        None => return Ok(false),
    };
    let month: u32 = match get_struct_field_atom(t, env, crate::atoms::month()) {
        Some(v) => v,
        None => return Ok(false),
    };
    let day: u32 = match get_struct_field_atom(t, env, crate::atoms::day()) {
        Some(v) => v,
        None => return Ok(false),
    };

    writer.write_all(b"\"")?;
    write_padded_i32(writer, year, 4)?;
    writer.write_all(b"-")?;
    write_padded(writer, month, 2)?;
    writer.write_all(b"-")?;
    write_padded(writer, day, 2)?;
    writer.write_all(b"\"")?;
    Ok(true)
}

/// Write Elixir Time directly as quoted ISO8601: "HH:MM:SS" or "HH:MM:SS.ffffff"
/// Returns Ok(true) if handled, Ok(false) if fields missing.
fn try_write_time<W: Write>(term: &Term, writer: &mut W) -> std::io::Result<bool> {
    let env = term.get_env();
    let t = *term;

    let hour: u32 = match get_struct_field_atom(t, env, crate::atoms::hour()) {
        Some(v) => v,
        None => return Ok(false),
    };
    let minute: u32 = match get_struct_field_atom(t, env, crate::atoms::minute()) {
        Some(v) => v,
        None => return Ok(false),
    };
    let second: u32 = match get_struct_field_atom(t, env, crate::atoms::second()) {
        Some(v) => v,
        None => return Ok(false),
    };
    let microsecond: (u32, u32) =
        match get_struct_field_tuple2_atom(t, env, crate::atoms::microsecond()) {
            Some(v) => v,
            None => return Ok(false),
        };

    writer.write_all(b"\"")?;
    write_padded(writer, hour, 2)?;
    writer.write_all(b":")?;
    write_padded(writer, minute, 2)?;
    writer.write_all(b":")?;
    write_padded(writer, second, 2)?;
    if microsecond.0 != 0 {
        let precision = microsecond.1 as usize;
        write_microsecond_frac(writer, microsecond.0, precision)?;
    }
    writer.write_all(b"\"")?;
    Ok(true)
}

/// Write Elixir NaiveDateTime directly as quoted ISO8601: "YYYY-MM-DDTHH:MM:SS[.ffffff]"
/// Returns Ok(true) if handled, Ok(false) if fields missing.
fn try_write_naive_datetime<W: Write>(term: &Term, writer: &mut W) -> std::io::Result<bool> {
    let env = term.get_env();
    let t = *term;

    let year: i32 = match get_struct_field_atom(t, env, crate::atoms::year()) {
        Some(v) => v,
        None => return Ok(false),
    };
    let month: u32 = match get_struct_field_atom(t, env, crate::atoms::month()) {
        Some(v) => v,
        None => return Ok(false),
    };
    let day: u32 = match get_struct_field_atom(t, env, crate::atoms::day()) {
        Some(v) => v,
        None => return Ok(false),
    };
    let hour: u32 = match get_struct_field_atom(t, env, crate::atoms::hour()) {
        Some(v) => v,
        None => return Ok(false),
    };
    let minute: u32 = match get_struct_field_atom(t, env, crate::atoms::minute()) {
        Some(v) => v,
        None => return Ok(false),
    };
    let second: u32 = match get_struct_field_atom(t, env, crate::atoms::second()) {
        Some(v) => v,
        None => return Ok(false),
    };
    let microsecond: (u32, u32) =
        match get_struct_field_tuple2_atom(t, env, crate::atoms::microsecond()) {
            Some(v) => v,
            None => return Ok(false),
        };

    writer.write_all(b"\"")?;
    write_padded_i32(writer, year, 4)?;
    writer.write_all(b"-")?;
    write_padded(writer, month, 2)?;
    writer.write_all(b"-")?;
    write_padded(writer, day, 2)?;
    writer.write_all(b"T")?;
    write_padded(writer, hour, 2)?;
    writer.write_all(b":")?;
    write_padded(writer, minute, 2)?;
    writer.write_all(b":")?;
    write_padded(writer, second, 2)?;
    if microsecond.0 != 0 {
        let precision = microsecond.1 as usize;
        write_microsecond_frac(writer, microsecond.0, precision)?;
    }
    writer.write_all(b"\"")?;
    Ok(true)
}

/// Write Elixir DateTime directly as quoted ISO8601 with timezone: "YYYY-MM-DDTHH:MM:SSZ" or "...±HH:MM"
/// Returns Ok(true) if handled, Ok(false) if fields missing.
fn try_write_datetime<W: Write>(term: &Term, writer: &mut W) -> std::io::Result<bool> {
    let env = term.get_env();
    let t = *term;

    let year: i32 = match get_struct_field_atom(t, env, crate::atoms::year()) {
        Some(v) => v,
        None => return Ok(false),
    };
    let month: u32 = match get_struct_field_atom(t, env, crate::atoms::month()) {
        Some(v) => v,
        None => return Ok(false),
    };
    let day: u32 = match get_struct_field_atom(t, env, crate::atoms::day()) {
        Some(v) => v,
        None => return Ok(false),
    };
    let hour: u32 = match get_struct_field_atom(t, env, crate::atoms::hour()) {
        Some(v) => v,
        None => return Ok(false),
    };
    let minute: u32 = match get_struct_field_atom(t, env, crate::atoms::minute()) {
        Some(v) => v,
        None => return Ok(false),
    };
    let second: u32 = match get_struct_field_atom(t, env, crate::atoms::second()) {
        Some(v) => v,
        None => return Ok(false),
    };
    let microsecond: (u32, u32) =
        match get_struct_field_tuple2_atom(t, env, crate::atoms::microsecond()) {
            Some(v) => v,
            None => return Ok(false),
        };

    let std_offset: i32 = get_struct_field_atom(t, env, crate::atoms::std_offset()).unwrap_or(0);
    let utc_offset: i32 = get_struct_field_atom(t, env, crate::atoms::utc_offset()).unwrap_or(0);
    let total_offset = std_offset + utc_offset;

    writer.write_all(b"\"")?;
    write_padded_i32(writer, year, 4)?;
    writer.write_all(b"-")?;
    write_padded(writer, month, 2)?;
    writer.write_all(b"-")?;
    write_padded(writer, day, 2)?;
    writer.write_all(b"T")?;
    write_padded(writer, hour, 2)?;
    writer.write_all(b":")?;
    write_padded(writer, minute, 2)?;
    writer.write_all(b":")?;
    write_padded(writer, second, 2)?;
    if microsecond.0 != 0 {
        let precision = microsecond.1 as usize;
        write_microsecond_frac(writer, microsecond.0, precision)?;
    }

    if total_offset == 0 {
        writer.write_all(b"Z")?;
    } else {
        let offset_hours = (total_offset.abs() / 3600) as u32;
        let offset_mins = ((total_offset.abs() % 3600) / 60) as u32;
        if total_offset >= 0 {
            writer.write_all(b"+")?;
        } else {
            writer.write_all(b"-")?;
        }
        write_padded(writer, offset_hours, 2)?;
        writer.write_all(b":")?;
        write_padded(writer, offset_mins, 2)?;
    }

    writer.write_all(b"\"")?;
    Ok(true)
}

/// Format Elixir URI as string
fn try_format_uri(term: &Term) -> Option<String> {
    let env = term.get_env();
    let t = *term;

    // Build URI string from components using cached atoms
    let scheme: Option<String> = get_struct_field_opt_atom(t, env, crate::atoms::scheme());
    let userinfo: Option<String> = get_struct_field_opt_atom(t, env, crate::atoms::userinfo());
    let host: Option<String> = get_struct_field_opt_atom(t, env, crate::atoms::host());
    let port: Option<i32> = get_struct_field_opt_atom(t, env, crate::atoms::port());
    let path: Option<String> = get_struct_field_opt_atom(t, env, crate::atoms::path());
    let query: Option<String> = get_struct_field_opt_atom(t, env, crate::atoms::query());
    let fragment: Option<String> = get_struct_field_opt_atom(t, env, crate::atoms::fragment());

    // Pre-compute capacity to avoid repeated reallocations
    let estimated_cap = scheme.as_ref().map_or(0, |s| s.len() + 3) // "scheme://"
        + userinfo.as_ref().map_or(0, |u| u.len() + 1) // "userinfo@"
        + host.as_ref().map_or(0, |h| h.len())
        + port.map_or(0, |_| 6) // ":65535"
        + path.as_ref().map_or(0, |p| p.len())
        + query.as_ref().map_or(0, |q| q.len() + 1) // "?query"
        + fragment.as_ref().map_or(0, |f| f.len() + 1); // "#fragment"
    let mut result = String::with_capacity(estimated_cap);

    if let Some(ref s) = scheme {
        result.push_str(s);
        result.push_str("://");
    }

    if let Some(u) = userinfo {
        result.push_str(&u);
        result.push('@');
    }

    if let Some(h) = host {
        result.push_str(&h);
    }

    // Omit default ports (80 for http, 443 for https)
    if let Some(p) = port {
        let is_default_port = match scheme.as_deref() {
            Some("http") => p == 80,
            Some("https") => p == 443,
            _ => false,
        };
        if !is_default_port {
            result.push(':');
            result.push_str(&p.to_string());
        }
    }

    if let Some(p) = path {
        result.push_str(&p);
    }

    if let Some(q) = query {
        result.push('?');
        result.push_str(&q);
    }

    if let Some(f) = fragment {
        result.push('#');
        result.push_str(&f);
    }

    Some(result)
}

/// Format Elixir MapSet as JSON array
/// MapSet stores data as %MapSet{map: %{elem1 => [], elem2 => [], ...}}
fn try_format_mapset<W: Write>(
    term: &Term,
    writer: &mut W,
    opts: FormatOptions<'_>,
) -> Result<Option<()>, std::io::Error> {
    let env = term.get_env();
    let t = *term;

    // Get the internal map field using cached atom
    let map_term = match t.map_get(crate::atoms::map().to_term(env)) {
        Ok(m) => m,
        Err(_) => return Ok(None),
    };

    // The keys of the internal map are the set elements
    let iter = match MapIterator::new(map_term) {
        Some(i) => i,
        None => return Ok(None),
    };

    let nested = opts.nested();
    writer.write_all(b"[")?;

    let mut first = true;
    for (key, _value) in iter {
        if !first {
            writer.write_all(b",")?;
        }
        first = false;
        nested.write_newline(writer)?;
        term_to_json(key, writer, nested)?;
    }

    opts.write_newline(writer)?;
    writer.write_all(b"]")?;
    Ok(Some(()))
}

/// Format Elixir Range as JSON object {first, last, step}
/// Range is %Range{first: x, last: y, step: z}
fn try_format_range<W: Write>(
    term: &Term,
    writer: &mut W,
    opts: FormatOptions<'_>,
) -> Result<Option<()>, std::io::Error> {
    let env = term.get_env();
    let t = *term;

    let first: i64 = match get_struct_field_atom(t, env, crate::atoms::first()) {
        Some(v) => v,
        None => return Ok(None),
    };
    let last: i64 = match get_struct_field_atom(t, env, crate::atoms::last()) {
        Some(v) => v,
        None => return Ok(None),
    };
    let step: i64 = get_struct_field_atom(t, env, crate::atoms::step()).unwrap_or(1);

    let escape = opts.escape_mode();
    let nested = opts.nested();

    writer.write_all(b"{")?;
    nested.write_newline(writer)?;

    // Write "first": value
    write_json_string("first", writer, escape)?;
    writer.write_all(b":")?;
    nested.write_space(writer)?;
    write!(writer, "{}", first)?;

    writer.write_all(b",")?;
    nested.write_newline(writer)?;

    // Write "last": value
    write_json_string("last", writer, escape)?;
    writer.write_all(b":")?;
    nested.write_space(writer)?;
    write!(writer, "{}", last)?;

    // Only include step if it's not 1
    if step != 1 {
        writer.write_all(b",")?;
        nested.write_newline(writer)?;
        write_json_string("step", writer, escape)?;
        writer.write_all(b":")?;
        nested.write_space(writer)?;
        write!(writer, "{}", step)?;
    }

    opts.write_newline(writer)?;
    writer.write_all(b"}")?;
    Ok(Some(()))
}

/// Helper to get a struct field value using a pre-interned atom (no Atom::from_str overhead)
#[inline]
fn get_struct_field_atom<'a, T: rustler::Decoder<'a>>(
    term: Term<'a>,
    env: rustler::Env<'a>,
    field_atom: rustler::types::atom::Atom,
) -> Option<T> {
    let field_term = term.map_get(field_atom.to_term(env)).ok()?;
    field_term.decode().ok()
}

/// Helper to get an optional struct field using a pre-interned atom (returns None if field is nil)
#[inline]
fn get_struct_field_opt_atom<'a, T: rustler::Decoder<'a>>(
    term: Term<'a>,
    env: rustler::Env<'a>,
    field_atom: rustler::types::atom::Atom,
) -> Option<T> {
    let field_term = term.map_get(field_atom.to_term(env)).ok()?;

    // Check if nil
    if field_term.get_type() == TermType::Atom {
        if let Ok(s) = field_term.atom_to_string() {
            if s == "nil" {
                return None;
            }
        }
    }

    field_term.decode().ok()
}

/// Helper to get a 2-tuple field using a pre-interned atom
#[inline]
fn get_struct_field_tuple2_atom<'a, T1, T2>(
    term: Term<'a>,
    env: rustler::Env<'a>,
    field_atom: rustler::types::atom::Atom,
) -> Option<(T1, T2)>
where
    T1: rustler::Decoder<'a>,
    T2: rustler::Decoder<'a>,
{
    let field_term = term.map_get(field_atom.to_term(env)).ok()?;
    let tuple = rustler::types::tuple::get_tuple(field_term).ok()?;
    if tuple.len() != 2 {
        return None;
    }
    let v1: T1 = tuple[0].decode().ok()?;
    let v2: T2 = tuple[1].decode().ok()?;
    Some((v1, v2))
}

#[inline(always)]
fn write_tuple<W: Write>(
    term: Term,
    writer: &mut W,
    opts: FormatOptions<'_>,
) -> Result<(), std::io::Error> {
    let items = rustler::types::tuple::get_tuple(term).map_err(|_| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, "Failed to decode tuple")
    })?;

    if items.is_empty() {
        writer.write_all(b"[]")?;
        return Ok(());
    }

    let nested = opts.nested();
    writer.write_all(b"[")?;

    let mut first = true;
    for item in items.iter() {
        if !first {
            writer.write_all(b",")?;
        }
        first = false;
        nested.write_newline(writer)?;
        term_to_json(*item, writer, nested)?;
    }

    opts.write_newline(writer)?;
    writer.write_all(b"]")?;
    Ok(())
}

// ---------------------------------------------------------------------------
// SIMD escape scanning — delegates to portable SIMD in simd_utils
// ---------------------------------------------------------------------------

/// Find the index of the first byte in `bytes[start..]` needing JSON escape
/// (control char < 0x20, `"`, or `\`). Returns `bytes.len()` if none found.
#[inline]
fn find_next_escape_json(bytes: &[u8], start: usize) -> usize {
    crate::simd_utils::find_escape_json(bytes, start)
}

/// Find the next byte needing escape in HtmlSafe mode.
#[inline]
fn find_next_escape_html(bytes: &[u8], start: usize) -> usize {
    crate::simd_utils::find_escape_html(bytes, start)
}

/// Find the next byte needing escape in UnicodeSafe mode.
#[inline]
fn find_next_escape_unicode(bytes: &[u8], start: usize) -> usize {
    crate::simd_utils::find_escape_unicode(bytes, start)
}

/// Find the next byte needing escape in JavaScriptSafe mode.
#[inline]
fn find_next_escape_javascript(bytes: &[u8], start: usize) -> usize {
    crate::simd_utils::find_escape_javascript(bytes, start)
}

// ---------------------------------------------------------------------------
// Escape byte writer helper
// ---------------------------------------------------------------------------

/// Write the JSON escape sequence for a single byte that needs escaping.
#[inline]
fn write_escape_byte<W: Write>(writer: &mut W, byte: u8) -> std::io::Result<()> {
    match byte {
        b'"' => writer.write_all(b"\\\""),
        b'\\' => writer.write_all(b"\\\\"),
        b'\n' => writer.write_all(b"\\n"),
        b'\r' => writer.write_all(b"\\r"),
        b'\t' => writer.write_all(b"\\t"),
        0x08 => writer.write_all(b"\\b"),
        0x0c => writer.write_all(b"\\f"),
        _ => write!(writer, "\\u{:04x}", byte),
    }
}

/// Handle one escape event for HtmlSafe mode starting at `pos`.
/// Returns the next position to continue scanning from.
#[inline]
fn write_escape_html<W: Write>(writer: &mut W, bytes: &[u8], pos: usize) -> std::io::Result<usize> {
    let b = bytes[pos];
    // Standard JSON escapes
    if b < 0x20 || b == b'"' || b == b'\\' {
        write_escape_byte(writer, b)?;
        return Ok(pos + 1);
    }
    // HTML-special ASCII
    match b {
        b'<' => {
            writer.write_all(b"\\u003c")?;
            return Ok(pos + 1);
        }
        b'>' => {
            writer.write_all(b"\\u003e")?;
            return Ok(pos + 1);
        }
        b'&' => {
            writer.write_all(b"\\u0026")?;
            return Ok(pos + 1);
        }
        b'/' => {
            writer.write_all(b"\\/")?;
            return Ok(pos + 1);
        }
        _ => {}
    }
    // High byte (>= 0xE2) — check for U+2028 / U+2029 (encoded as E2 80 A8 / E2 80 A9)
    if b >= 0xE2 && pos + 2 < bytes.len() && bytes[pos] == 0xE2 && bytes[pos + 1] == 0x80 {
        if bytes[pos + 2] == 0xA8 {
            writer.write_all(b"\\u2028")?;
            return Ok(pos + 3);
        }
        if bytes[pos + 2] == 0xA9 {
            writer.write_all(b"\\u2029")?;
            return Ok(pos + 3);
        }
    }
    // Not actually something we need to escape — write the full UTF-8 char and skip past it
    let char_len = utf8_char_len(b);
    let end = (pos + char_len).min(bytes.len());
    writer.write_all(&bytes[pos..end])?;
    Ok(end)
}

/// Handle one escape event for UnicodeSafe mode starting at `pos`.
/// Returns the next position to continue scanning from.
#[inline]
fn write_escape_unicode_at<W: Write>(
    writer: &mut W,
    _s: &str,
    bytes: &[u8],
    pos: usize,
) -> std::io::Result<usize> {
    let b = bytes[pos];
    // Standard JSON escapes
    if b < 0x20 || b == b'"' || b == b'\\' {
        write_escape_byte(writer, b)?;
        return Ok(pos + 1);
    }
    // Non-ASCII: escape as \uXXXX
    if b >= 0x80 {
        let char_len = utf8_char_len(b);
        let end = (pos + char_len).min(bytes.len());
        if let Ok(ch_str) = std::str::from_utf8(&bytes[pos..end]) {
            for ch in ch_str.chars() {
                write!(writer, "\\u{:04x}", ch as u32)?;
            }
        }
        return Ok(end);
    }
    // Should not reach here, but write byte as-is
    writer.write_all(&bytes[pos..pos + 1])?;
    Ok(pos + 1)
}

/// Handle one escape event for JavaScriptSafe mode starting at `pos`.
/// Returns the next position to continue scanning from.
#[inline]
fn write_escape_javascript_at<W: Write>(
    writer: &mut W,
    bytes: &[u8],
    pos: usize,
) -> std::io::Result<usize> {
    let b = bytes[pos];
    // Standard JSON escapes
    if b < 0x20 || b == b'"' || b == b'\\' {
        write_escape_byte(writer, b)?;
        return Ok(pos + 1);
    }
    // High byte (>= 0xE2) — check for U+2028 / U+2029
    if b >= 0xE2 && pos + 2 < bytes.len() && bytes[pos] == 0xE2 && bytes[pos + 1] == 0x80 {
        if bytes[pos + 2] == 0xA8 {
            writer.write_all(b"\\u2028")?;
            return Ok(pos + 3);
        }
        if bytes[pos + 2] == 0xA9 {
            writer.write_all(b"\\u2029")?;
            return Ok(pos + 3);
        }
    }
    // Not actually something we need to escape — write the full UTF-8 char
    let char_len = utf8_char_len(b);
    let end = (pos + char_len).min(bytes.len());
    writer.write_all(&bytes[pos..end])?;
    Ok(end)
}

/// Returns the length of a UTF-8 character from its first byte.
#[inline(always)]
fn utf8_char_len(b: u8) -> usize {
    if b < 0x80 {
        1
    } else if b < 0xE0 {
        2
    } else if b < 0xF0 {
        3
    } else {
        4
    }
}

/// Fast JSON string escaping - processes safe bytes in bulk using SIMD scanning.
///
/// Takes `&str` to guarantee valid UTF-8 at compile time, eliminating unsafe code.
/// The fast path converts to bytes internally (zero-cost operation).
#[inline(always)]
fn write_json_string_escaped<W: Write>(
    s: &str,
    writer: &mut W,
    escape_mode: EscapeMode,
) -> Result<(), std::io::Error> {
    let bytes = s.as_bytes();
    writer.write_all(b"\"")?;

    match escape_mode {
        EscapeMode::Json => {
            let mut pos = 0;
            while pos < bytes.len() {
                let next = find_next_escape_json(bytes, pos);
                if next > pos {
                    writer.write_all(&bytes[pos..next])?;
                }
                if next >= bytes.len() {
                    break;
                }
                write_escape_byte(writer, bytes[next])?;
                pos = next + 1;
            }
        }
        EscapeMode::HtmlSafe => {
            let mut pos = 0;
            while pos < bytes.len() {
                let next = find_next_escape_html(bytes, pos);
                if next > pos {
                    writer.write_all(&bytes[pos..next])?;
                }
                if next >= bytes.len() {
                    break;
                }
                pos = write_escape_html(writer, bytes, next)?;
            }
        }
        EscapeMode::UnicodeSafe => {
            let mut pos = 0;
            while pos < bytes.len() {
                let next = find_next_escape_unicode(bytes, pos);
                if next > pos {
                    writer.write_all(&bytes[pos..next])?;
                }
                if next >= bytes.len() {
                    break;
                }
                pos = write_escape_unicode_at(writer, s, bytes, next)?;
            }
        }
        EscapeMode::JavaScriptSafe => {
            let mut pos = 0;
            while pos < bytes.len() {
                let next = find_next_escape_javascript(bytes, pos);
                if next > pos {
                    writer.write_all(&bytes[pos..next])?;
                }
                if next >= bytes.len() {
                    break;
                }
                pos = write_escape_javascript_at(writer, bytes, next)?;
            }
        }
    }

    writer.write_all(b"\"")?;
    Ok(())
}

/// Fast JSON string escaping with configurable escape modes
#[inline(always)]
fn write_json_string<W: Write>(
    s: &str,
    writer: &mut W,
    escape_mode: EscapeMode,
) -> Result<(), std::io::Error> {
    write_json_string_escaped(s, writer, escape_mode)
}

/// Public wrapper for write_json_string_escaped, used by encode_fields NIF
pub fn write_json_string_escaped_pub<W: Write>(
    s: &str,
    writer: &mut W,
    escape_mode: EscapeMode,
) -> Result<(), std::io::Error> {
    write_json_string_escaped(s, writer, escape_mode)
}

/// Public wrapper for write_integer, used by encode_fields NIF
pub fn write_integer_pub<W: Write>(term: Term, writer: &mut W) -> Result<(), std::io::Error> {
    write_integer(term, writer)
}

#[cfg(feature = "bench")]
pub mod bench_helpers {
    use super::*;

    pub fn escape_string_json(input: &str) -> Vec<u8> {
        let mut buf = Vec::new();
        write_json_string_escaped(input, &mut buf, EscapeMode::Json).unwrap();
        buf
    }

    pub fn escape_string_html(input: &str) -> Vec<u8> {
        let mut buf = Vec::new();
        write_json_string_escaped(input, &mut buf, EscapeMode::HtmlSafe).unwrap();
        buf
    }

    pub fn escape_string_unicode(input: &str) -> Vec<u8> {
        let mut buf = Vec::new();
        write_json_string_escaped(input, &mut buf, EscapeMode::UnicodeSafe).unwrap();
        buf
    }

    pub fn escape_string_javascript(input: &str) -> Vec<u8> {
        let mut buf = Vec::new();
        write_json_string_escaped(input, &mut buf, EscapeMode::JavaScriptSafe).unwrap();
        buf
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_write_json_string() {
        let mut buf = Vec::new();
        write_json_string("hello", &mut buf, EscapeMode::Json).unwrap();
        assert_eq!(String::from_utf8(buf).unwrap(), "\"hello\"");

        let mut buf = Vec::new();
        write_json_string("hello\"world", &mut buf, EscapeMode::Json).unwrap();
        assert_eq!(String::from_utf8(buf).unwrap(), "\"hello\\\"world\"");

        let mut buf = Vec::new();
        write_json_string("line1\nline2", &mut buf, EscapeMode::Json).unwrap();
        assert_eq!(String::from_utf8(buf).unwrap(), "\"line1\\nline2\"");
    }

    #[test]
    fn test_html_safe_escaping() {
        let mut buf = Vec::new();
        write_json_string("<script>", &mut buf, EscapeMode::HtmlSafe).unwrap();
        assert_eq!(String::from_utf8(buf).unwrap(), "\"\\u003cscript\\u003e\"");

        let mut buf = Vec::new();
        write_json_string("a & b", &mut buf, EscapeMode::HtmlSafe).unwrap();
        assert_eq!(String::from_utf8(buf).unwrap(), "\"a \\u0026 b\"");
    }
}
