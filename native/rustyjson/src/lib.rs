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
        jason_fragment = "Elixir.Jason.Fragment",
    }
}

rustler::init!("Elixir.RustyJson");

/// Direct encode - manually walks the term tree and writes JSON
/// Supports pretty printing, compression, and built-in type handling
/// No dirty scheduler - fast enough for normal scheduler
#[rustler::nif(name = "nif_encode_direct")]
fn encode_direct<'a>(
    env: Env<'a>,
    term: Term,
    indent_size: Option<u32>,
    comp_opts: Option<(compression::Algs, Option<u32>)>,
    lean: bool,
    escape: Term,
) -> Result<rustler::Binary<'a>, Error> {
    let escape_mode = direct_json::EscapeMode::from_term(escape);
    let opts = match indent_size {
        Some(n) if n > 0 => direct_json::FormatOptions::pretty(n)
            .with_lean(lean)
            .with_escape(escape_mode),
        _ => direct_json::FormatOptions::compact()
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

/// Direct decode - custom parser that builds Erlang terms during parsing
/// Uses lexical-core for fast number parsing, zero-copy strings when possible
/// No dirty scheduler - fast enough for normal scheduler
#[rustler::nif(name = "nif_decode")]
fn decode<'a>(env: Env<'a>, input: rustler::Binary, intern_keys: bool) -> Result<Term<'a>, Error> {
    let slice = input.as_slice();
    direct_decode::json_to_term(env, slice, intern_keys).map_err(|e| Error::RaiseTerm(Box::new(e)))
}
