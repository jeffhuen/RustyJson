use crate::decimal::try_format_decimal;
use rustler::types::{ListIterator, MapIterator};
use rustler::{Binary, Term, TermType};
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
    pub line_separator: Vec<u8>,
    pub after_colon: Vec<u8>,
    pub indent: Vec<u8>,
    pub strict_keys: bool,
}

impl Default for FormatContext {
    fn default() -> Self {
        Self {
            line_separator: b"\n".to_vec(),
            after_colon: b" ".to_vec(),
            indent: b"  ".to_vec(),
            strict_keys: false,
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
        match std::str::from_utf8(bytes) {
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
    // Use ListIterator to avoid allocating a Vec (get via decode)
    let iter: ListIterator = term.decode().map_err(|_| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, "Failed to decode list")
    })?;

    // Peek to check if empty
    let mut iter = iter.peekable();
    if iter.peek().is_none() {
        writer.write_all(b"[]")?;
        return Ok(());
    }

    let nested = opts.nested();
    writer.write_all(b"[")?;

    let mut first = true;
    for item in iter {
        if !first {
            writer.write_all(b",")?;
        }
        first = false;
        nested.write_newline(writer)?;
        term_to_json(item, writer, nested)?;
    }

    opts.write_newline(writer)?;
    writer.write_all(b"]")?;
    Ok(())
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
            if let Some(date_str) = try_format_date(term) {
                write_json_string(&date_str, writer, escape)?;
                return Ok(Some(()));
            }
        }
        "Elixir.Time" => {
            if let Some(time_str) = try_format_time(term) {
                write_json_string(&time_str, writer, escape)?;
                return Ok(Some(()));
            }
        }
        "Elixir.NaiveDateTime" => {
            if let Some(dt_str) = try_format_naive_datetime(term) {
                write_json_string(&dt_str, writer, escape)?;
                return Ok(Some(()));
            }
        }
        "Elixir.DateTime" => {
            if let Some(dt_str) = try_format_datetime(term) {
                write_json_string(&dt_str, writer, escape)?;
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

/// Format Elixir Date as ISO8601 string: "YYYY-MM-DD"
fn try_format_date(term: &Term) -> Option<String> {
    let env = term.get_env();
    let t = *term;

    let year: i32 = get_struct_field(t, env, "year")?;
    let month: u32 = get_struct_field(t, env, "month")?;
    let day: u32 = get_struct_field(t, env, "day")?;

    Some(format!("{:04}-{:02}-{:02}", year, month, day))
}

/// Format Elixir Time as ISO8601 string: "HH:MM:SS" or "HH:MM:SS.ffffff"
fn try_format_time(term: &Term) -> Option<String> {
    let env = term.get_env();
    let t = *term;

    let hour: u32 = get_struct_field(t, env, "hour")?;
    let minute: u32 = get_struct_field(t, env, "minute")?;
    let second: u32 = get_struct_field(t, env, "second")?;
    let microsecond: (u32, u32) = get_struct_field_tuple2(t, env, "microsecond")?;

    if microsecond.0 == 0 {
        Some(format!("{:02}:{:02}:{:02}", hour, minute, second))
    } else {
        // Format with microseconds, respecting precision
        let precision = microsecond.1 as usize;
        let micro_str = format!("{:06}", microsecond.0);
        Some(format!(
            "{:02}:{:02}:{:02}.{}",
            hour,
            minute,
            second,
            &micro_str[..precision]
        ))
    }
}

/// Format Elixir NaiveDateTime as ISO8601 string: "YYYY-MM-DDTHH:MM:SS"
fn try_format_naive_datetime(term: &Term) -> Option<String> {
    let env = term.get_env();
    let t = *term;

    let year: i32 = get_struct_field(t, env, "year")?;
    let month: u32 = get_struct_field(t, env, "month")?;
    let day: u32 = get_struct_field(t, env, "day")?;
    let hour: u32 = get_struct_field(t, env, "hour")?;
    let minute: u32 = get_struct_field(t, env, "minute")?;
    let second: u32 = get_struct_field(t, env, "second")?;
    let microsecond: (u32, u32) = get_struct_field_tuple2(t, env, "microsecond")?;

    if microsecond.0 == 0 {
        Some(format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}",
            year, month, day, hour, minute, second
        ))
    } else {
        let precision = microsecond.1 as usize;
        let micro_str = format!("{:06}", microsecond.0);
        Some(format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{}",
            year,
            month,
            day,
            hour,
            minute,
            second,
            &micro_str[..precision]
        ))
    }
}

/// Format Elixir DateTime as ISO8601 string with timezone
fn try_format_datetime(term: &Term) -> Option<String> {
    let env = term.get_env();
    let t = *term;

    let year: i32 = get_struct_field(t, env, "year")?;
    let month: u32 = get_struct_field(t, env, "month")?;
    let day: u32 = get_struct_field(t, env, "day")?;
    let hour: u32 = get_struct_field(t, env, "hour")?;
    let minute: u32 = get_struct_field(t, env, "minute")?;
    let second: u32 = get_struct_field(t, env, "second")?;
    let microsecond: (u32, u32) = get_struct_field_tuple2(t, env, "microsecond")?;

    // Get timezone info
    let std_offset: i32 = get_struct_field(t, env, "std_offset").unwrap_or(0);
    let utc_offset: i32 = get_struct_field(t, env, "utc_offset").unwrap_or(0);
    let total_offset = std_offset + utc_offset;

    let base = if microsecond.0 == 0 {
        format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}",
            year, month, day, hour, minute, second
        )
    } else {
        let precision = microsecond.1 as usize;
        let micro_str = format!("{:06}", microsecond.0);
        format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{}",
            year,
            month,
            day,
            hour,
            minute,
            second,
            &micro_str[..precision]
        )
    };

    if total_offset == 0 {
        Some(format!("{}Z", base))
    } else {
        let offset_hours = total_offset.abs() / 3600;
        let offset_mins = (total_offset.abs() % 3600) / 60;
        let sign = if total_offset >= 0 { '+' } else { '-' };
        Some(format!(
            "{}{}{:02}:{:02}",
            base, sign, offset_hours, offset_mins
        ))
    }
}

/// Format Elixir URI as string
fn try_format_uri(term: &Term) -> Option<String> {
    let env = term.get_env();
    let t = *term;

    // Build URI string from components
    let scheme: Option<String> = get_struct_field_opt(t, env, "scheme");
    let userinfo: Option<String> = get_struct_field_opt(t, env, "userinfo");
    let host: Option<String> = get_struct_field_opt(t, env, "host");
    let port: Option<i32> = get_struct_field_opt(t, env, "port");
    let path: Option<String> = get_struct_field_opt(t, env, "path");
    let query: Option<String> = get_struct_field_opt(t, env, "query");
    let fragment: Option<String> = get_struct_field_opt(t, env, "fragment");

    let mut result = String::new();

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

    // Get the internal map field
    let map_atom = rustler::types::atom::Atom::from_str(env, "map").ok();
    let map_atom = match map_atom {
        Some(a) => a,
        None => return Ok(None),
    };

    let map_term = match t.map_get(map_atom.to_term(env)) {
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

    let first: i64 = match get_struct_field(t, env, "first") {
        Some(v) => v,
        None => return Ok(None),
    };
    let last: i64 = match get_struct_field(t, env, "last") {
        Some(v) => v,
        None => return Ok(None),
    };
    let step: i64 = get_struct_field(t, env, "step").unwrap_or(1);

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

/// Helper to get a struct field value
fn get_struct_field<'a, T: rustler::Decoder<'a>>(
    term: Term<'a>,
    env: rustler::Env<'a>,
    field: &str,
) -> Option<T> {
    let field_atom = rustler::types::atom::Atom::from_str(env, field).ok()?;
    let field_term = term.map_get(field_atom.to_term(env)).ok()?;
    field_term.decode().ok()
}

/// Helper to get an optional struct field (returns None if field is nil)
fn get_struct_field_opt<'a, T: rustler::Decoder<'a>>(
    term: Term<'a>,
    env: rustler::Env<'a>,
    field: &str,
) -> Option<T> {
    let field_atom = rustler::types::atom::Atom::from_str(env, field).ok()?;
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

/// Helper to get a 2-tuple field like microsecond: {123456, 6}
fn get_struct_field_tuple2<'a, T1, T2>(
    term: Term<'a>,
    env: rustler::Env<'a>,
    field: &str,
) -> Option<(T1, T2)>
where
    T1: rustler::Decoder<'a>,
    T2: rustler::Decoder<'a>,
{
    let field_atom = rustler::types::atom::Atom::from_str(env, field).ok()?;
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

/// Table for checking if a byte needs escaping in JSON mode
/// 0 = safe, 1 = needs escape
static ESCAPE_TABLE: [u8; 256] = {
    let mut table = [0u8; 256];
    // Control characters 0x00-0x1f need escaping
    let mut i = 0;
    while i < 32 {
        table[i] = 1;
        i += 1;
    }
    table[b'"' as usize] = 1;
    table[b'\\' as usize] = 1;
    table
};

/// Fast JSON string escaping - processes safe bytes in bulk
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

    // For standard JSON mode, use the fast path (byte-based)
    if escape_mode == EscapeMode::Json {
        let mut start = 0;
        for (i, &byte) in bytes.iter().enumerate() {
            if ESCAPE_TABLE[byte as usize] == 1 {
                // Write everything up to this point
                if start < i {
                    writer.write_all(&bytes[start..i])?;
                }
                // Write escape sequence
                match byte {
                    b'"' => writer.write_all(b"\\\"")?,
                    b'\\' => writer.write_all(b"\\\\")?,
                    b'\n' => writer.write_all(b"\\n")?,
                    b'\r' => writer.write_all(b"\\r")?,
                    b'\t' => writer.write_all(b"\\t")?,
                    b'\x08' => writer.write_all(b"\\b")?,
                    b'\x0c' => writer.write_all(b"\\f")?,
                    _ => write!(writer, "\\u{:04x}", byte)?,
                }
                start = i + 1;
            }
        }
        // Write remaining bytes
        if start < bytes.len() {
            writer.write_all(&bytes[start..])?;
        }
    } else {
        // Slower path for special escape modes - need to handle multi-byte chars
        for ch in s.chars() {
            match ch {
                '"' => writer.write_all(b"\\\"")?,
                '\\' => writer.write_all(b"\\\\")?,
                '\n' => writer.write_all(b"\\n")?,
                '\r' => writer.write_all(b"\\r")?,
                '\t' => writer.write_all(b"\\t")?,
                '\x08' => writer.write_all(b"\\b")?,
                '\x0c' => writer.write_all(b"\\f")?,
                '\x00'..='\x1f' => write!(writer, "\\u{:04x}", ch as u32)?,
                // HTML-safe escaping
                '<' if escape_mode == EscapeMode::HtmlSafe => writer.write_all(b"\\u003c")?,
                '>' if escape_mode == EscapeMode::HtmlSafe => writer.write_all(b"\\u003e")?,
                '&' if escape_mode == EscapeMode::HtmlSafe => writer.write_all(b"\\u0026")?,
                '/' if escape_mode == EscapeMode::HtmlSafe => writer.write_all(b"\\/")?,
                // JavaScript-safe: escape line/paragraph separators
                '\u{2028}'
                    if escape_mode == EscapeMode::JavaScriptSafe
                        || escape_mode == EscapeMode::HtmlSafe =>
                {
                    writer.write_all(b"\\u2028")?
                }
                '\u{2029}'
                    if escape_mode == EscapeMode::JavaScriptSafe
                        || escape_mode == EscapeMode::HtmlSafe =>
                {
                    writer.write_all(b"\\u2029")?
                }
                // Unicode-safe: escape all non-ASCII
                c if escape_mode == EscapeMode::UnicodeSafe && !c.is_ascii() => {
                    write!(writer, "\\u{:04x}", c as u32)?
                }
                // Default: write character as-is
                c => {
                    let mut buf = [0u8; 4];
                    let encoded = c.encode_utf8(&mut buf);
                    writer.write_all(encoded.as_bytes())?;
                }
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
