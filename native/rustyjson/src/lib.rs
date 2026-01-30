use rustler::{Env, Error, Term};

#[cfg(feature = "mimalloc")]
#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

#[cfg(feature = "jemalloc")]
#[global_allocator]
static GLOBAL: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;

#[cfg(feature = "snmalloc")]
#[global_allocator]
static GLOBAL: snmalloc_rs::SnMalloc = snmalloc_rs::SnMalloc;

mod compression;
mod decimal;
mod direct_decode;
mod direct_json;

mod atoms {
    rustler::atoms! {
        encode,
        rustyjson_fragment = "Elixir.RustyJson.Fragment",
        // Encode option keys
        indent,
        compression,
        lean,
        escape,
        strict_keys,
        pretty_opts,
        line_separator,
        after_colon,
        // Decode option keys
        intern_keys,
        floats_decimals,
        ordered_objects,
        integer_digit_limit,
        max_bytes,
        reject_duplicate_keys,
        validate_strings,
        // Struct construction atoms
        __struct__,
        decimal_struct = "Elixir.Decimal",
        ordered_object_struct = "Elixir.RustyJson.OrderedObject",
        sign,
        coef,
        exp,
        values,
    }
}

rustler::init!("Elixir.RustyJson");

/// Extract a typed value from an Elixir map by atom key, returning default if missing.
#[inline]
fn get_opt<'a, T: rustler::Decoder<'a>>(
    env: Env<'a>,
    map: Term<'a>,
    key: rustler::types::atom::Atom,
    default: T,
) -> T {
    map.map_get(key.to_term(env))
        .ok()
        .and_then(|v| v.decode::<T>().ok())
        .unwrap_or(default)
}

/// Convenience wrapper for boolean opts.
#[inline]
fn get_opt_bool<'a>(
    env: Env<'a>,
    map: Term<'a>,
    key: rustler::types::atom::Atom,
    default: bool,
) -> bool {
    get_opt(env, map, key, default)
}

/// Shared encode implementation used by both normal and dirty scheduler NIFs
fn encode_direct_impl<'a>(
    env: Env<'a>,
    term: Term,
    opts_map: Term<'a>,
) -> Result<rustler::Binary<'a>, Error> {
    // Unpack options from the Elixir map
    let indent_size: Option<u32> = get_opt(env, opts_map, atoms::indent(), None);
    let comp_opts: Option<(compression::Algs, Option<u32>)> =
        get_opt(env, opts_map, atoms::compression(), None);
    let lean: bool = get_opt_bool(env, opts_map, atoms::lean(), false);
    let strict_keys: bool = get_opt_bool(env, opts_map, atoms::strict_keys(), false);

    let escape_term = opts_map
        .map_get(atoms::escape().to_term(env))
        .unwrap_or_else(|_| rustler::types::atom::nil().to_term(env));
    let escape_mode = direct_json::EscapeMode::from_term(escape_term);

    let pretty_opts_term = opts_map
        .map_get(atoms::pretty_opts().to_term(env))
        .unwrap_or_else(|_| rustler::types::atom::nil().to_term(env));

    // Build shared context with heap-allocated separators
    let mut ctx = direct_json::FormatContext {
        strict_keys,
        ..Default::default()
    };

    // Parse pretty_opts map for custom separators and indent
    if pretty_opts_term.get_type() == rustler::TermType::Map {
        if let Ok(val) = pretty_opts_term.map_get(atoms::line_separator().to_term(env)) {
            if let Ok(binary) = val.decode::<rustler::Binary>() {
                ctx.line_separator = binary.as_slice().to_vec();
            }
        }
        if let Ok(val) = pretty_opts_term.map_get(atoms::after_colon().to_term(env)) {
            if let Ok(binary) = val.decode::<rustler::Binary>() {
                ctx.after_colon = binary.as_slice().to_vec();
            }
        }
        if let Ok(val) = pretty_opts_term.map_get(atoms::indent().to_term(env)) {
            if let Ok(binary) = val.decode::<rustler::Binary>() {
                ctx.indent = binary.as_slice().to_vec();
            }
        }
    }

    // Set indent from indent_size param if no custom indent was set via pretty_opts
    if let Some(n) = indent_size {
        if n > 0 {
            // Only override if pretty_opts didn't set a custom indent
            let has_custom_indent = pretty_opts_term.get_type() == rustler::TermType::Map
                && pretty_opts_term
                    .map_get(atoms::indent().to_term(env))
                    .is_ok();
            if !has_custom_indent {
                ctx.indent = vec![b' '; n as usize];
            }
        }
    }

    let opts = match indent_size {
        Some(n) if n > 0 => direct_json::FormatOptions::pretty(&ctx)
            .with_lean(lean)
            .with_escape(escape_mode),
        _ => direct_json::FormatOptions::compact(&ctx)
            .with_lean(lean)
            .with_escape(escape_mode),
    };

    // Check if compression is requested
    let uses_compression = matches!(comp_opts, Some((compression::Algs::Gzip, _)));

    if uses_compression {
        // Use compression writer
        let mut buf = compression::get_writer(comp_opts);
        direct_json::term_to_json(term, &mut buf, opts)
            .map_err(|e| Error::RaiseTerm(Box::new(e.to_string())))?;
        let output = buf
            .get_buf()
            .map_err(|e| Error::RaiseTerm(Box::new(format!("{}", e))))?;
        let mut bin = rustler::NewBinary::new(env, output.len());
        bin.as_mut_slice().copy_from_slice(&output);
        Ok(bin.into())
    } else {
        // Fast path: write to Vec with small initial capacity
        let mut output: Vec<u8> = Vec::with_capacity(128);
        direct_json::term_to_json(term, &mut output, opts)
            .map_err(|e| Error::RaiseTerm(Box::new(e.to_string())))?;
        let mut bin = rustler::NewBinary::new(env, output.len());
        bin.as_mut_slice().copy_from_slice(&output);
        Ok(bin.into())
    }
}

/// Shared decode implementation used by both normal and dirty scheduler NIFs
fn decode_impl<'a>(
    env: Env<'a>,
    input: rustler::Binary,
    opts_map: Term<'a>,
) -> Result<Term<'a>, Error> {
    let slice = input.as_slice();

    // Parse options from Elixir map
    let decode_opts = direct_decode::DecodeOptions {
        intern_keys: get_opt_bool(env, opts_map, atoms::intern_keys(), false),
        floats_decimals: get_opt_bool(env, opts_map, atoms::floats_decimals(), false),
        ordered_objects: get_opt_bool(env, opts_map, atoms::ordered_objects(), false),
        integer_digit_limit: get_opt(env, opts_map, atoms::integer_digit_limit(), 1024usize),
        max_bytes: get_opt(env, opts_map, atoms::max_bytes(), 0usize),
        reject_duplicate_keys: get_opt_bool(env, opts_map, atoms::reject_duplicate_keys(), false),
        validate_strings: get_opt_bool(env, opts_map, atoms::validate_strings(), true),
    };

    direct_decode::json_to_term(env, slice, decode_opts).map_err(|e| Error::RaiseTerm(Box::new(e)))
}

/// Direct encode on normal scheduler
#[rustler::nif(name = "nif_encode_direct")]
fn encode_direct<'a>(
    env: Env<'a>,
    term: Term,
    opts_map: Term<'a>,
) -> Result<rustler::Binary<'a>, Error> {
    encode_direct_impl(env, term, opts_map)
}

/// Direct encode on dirty CPU scheduler for large payloads
#[rustler::nif(name = "nif_encode_direct_dirty", schedule = "DirtyCpu")]
fn encode_direct_dirty<'a>(
    env: Env<'a>,
    term: Term,
    opts_map: Term<'a>,
) -> Result<rustler::Binary<'a>, Error> {
    encode_direct_impl(env, term, opts_map)
}

/// Direct decode on normal scheduler
#[rustler::nif(name = "nif_decode")]
fn decode<'a>(env: Env<'a>, input: rustler::Binary, opts_map: Term<'a>) -> Result<Term<'a>, Error> {
    decode_impl(env, input, opts_map)
}

/// Direct decode on dirty CPU scheduler for large payloads
#[rustler::nif(name = "nif_decode_dirty", schedule = "DirtyCpu")]
fn decode_dirty<'a>(
    env: Env<'a>,
    input: rustler::Binary,
    opts_map: Term<'a>,
) -> Result<Term<'a>, Error> {
    decode_impl(env, input, opts_map)
}
