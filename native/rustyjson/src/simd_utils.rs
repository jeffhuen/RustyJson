// ============================================================================
// Portable SIMD utilities for JSON byte scanning
// ============================================================================
//
// Uses `std::simd` (portable SIMD) — one codepath per pattern, no `unsafe`.
// On x86_64 with AVX2, functions process 32 bytes/iter then 16-byte remainder.
// On all other targets, 16 bytes/iter only.
//
// ## Stabilization status
//
// The `portable_simd` feature gate is unstable, but the critical stabilization
// blockers (https://github.com/rust-lang/portable-simd/issues/364) are swizzle,
// mask element types, and lane count bounds — none of which we use.
//
// ## DO NOT USE — blocked from stabilization
//
// - `simd_swizzle!` / `Swizzle` trait — blocked on const generics
// - `Simd::scatter` / `Simd::gather` — no stabilization RFC
// - `Simd::interleave` / `Simd::deinterleave` — no stabilization RFC
// - `SimdFloat::to_int_unchecked` — safety concerns
// - `Simd::resize` — API under review
// - `Simd::rotate_elements_left/right` — depends on swizzle
// - `StdFloat` trait — not needed; use `ryu` for floats
//
// ## SAFE TO USE — stable semantics, no open design questions
//
// - `Simd::from_slice`, `Simd::splat`
// - `simd_eq`, `simd_ne`, `simd_le`, `simd_lt`, `simd_ge`, `simd_gt`
// - `Mask::any`, `Mask::all`, `Mask::to_bitmask`
// - `Mask` bitwise ops (`|`, `&`, `!`)
//
// ============================================================================
// OPTIMIZATION HISTORY — do not repeat these regressions
// ============================================================================
//
// ### `.any()` + `break` vs `to_bitmask().trailing_zeros()` + `return`
//
// Two exit strategies exist for SIMD scanning loops:
//
//   A) `.any()` + `break` — stop at the chunk containing a hit, let the
//      scalar tail find the exact byte. Minimal loop body (load, compare,
//      branch). Best when the caller immediately inspects input[pos].
//
//   B) `to_bitmask().trailing_zeros()` + `return` — compute the exact byte
//      position within the chunk. More instructions per iteration but avoids
//      the scalar tail entirely. Best when the caller needs the position for
//      a bulk operation (e.g. extend_from_slice) and won't re-inspect bytes.
//
// When to use which:
//
//   - Encoder string scanning (`skip_plain_string_bytes`, `find_escape_html`,
//     `find_escape_unicode`, `find_escape_javascript`): USE (A).
//     The encoder's write loop immediately inspects the byte at `pos` to
//     decide what escape to write. The bitmask precision is wasted because
//     the scalar tail finds the byte in 0-15 iterations anyway. Benchmarked
//     ~300% regression on short/escaped strings when (B) was used here.
//
//   - Decoder digit scanning (`skip_ascii_digits`), whitespace skipping
//     (`skip_whitespace`): USE (B).
//     These scan long homogeneous runs (digit strings, whitespace between
//     tokens). The caller does NOT inspect individual bytes — it just needs
//     to know where the run ended. Partial-chunk precision avoids wasting
//     up to 15 bytes of work. Benchmarked +64% on large integers, +5-7%
//     on whitespace-heavy JSON.
//
//   - Decoder escape scanning (`find_escape_json`): USE (B).
//     Called from decode_escaped_string for bulk copy. The returned position
//     is used directly as a slice boundary (extend_from_slice), not for
//     byte inspection. Precision matters here.
//
// ### Dual-mode structural indexing — DO NOT ATTEMPT
//
// We tried replacing the three-loop structural index (AVX2 32-byte / 16-byte
// / scalar tail) with a dual-mode approach: use `skip_non_structural()` to
// SIMD-skip chunks with no structural chars, then fall back to
// `skip_plain_string_bytes()` inside strings. This regressed ~200% because:
//
//   1. Dense JSON has structural chars in nearly every 16-byte chunk, so the
//      skip function enters and exits immediately on every call — pure
//      overhead.
//   2. The function call + branch overhead per chunk exceeded the cost of
//      the simple `chunk_has_structural()` bool check + inline scalar loop.
//   3. The existing three-loop structure (bool check → skip or process) is
//      already optimal for the structural index's access pattern.
//
// The structural index should remain as: SIMD bool check per chunk to decide
// whether to skip or process, with an inline scalar state machine for chunks
// that contain structural characters. Do not try to merge the skip/process
// decision into a single SIMD function.

use std::simd::prelude::*;

/// Number of bytes processed per baseline SIMD iteration.
pub const CHUNK: usize = 16;

/// Wide chunk size for AVX2 targets.
#[cfg(target_feature = "avx2")]
const WIDE: usize = 32;

// ---------------------------------------------------------------------------
// Pattern A: Skip plain string bytes (no `"`, `\`, or control < 0x20)
// ---------------------------------------------------------------------------

/// Advance `pos` past contiguous chunks of plain string bytes (no `"`, `\`,
/// or control characters < 0x20). After return, `pos` points to the first
/// byte that needs byte-at-a-time handling (or is past the SIMD-able region).
///
/// Uses `.any()` + `break` — the caller (decoder string parser) immediately
/// inspects input[pos] after return, so bitmask precision is wasted overhead.
/// Benchmarked: `to_bitmask` variant regressed ~300% on escaped strings.
#[inline]
pub fn skip_plain_string_bytes(input: &[u8], pos: &mut usize) {
    #[cfg(target_feature = "avx2")]
    {
        let quote = Simd::<u8, WIDE>::splat(b'"');
        let backslash = Simd::<u8, WIDE>::splat(b'\\');
        let control_bound = Simd::<u8, WIDE>::splat(0x20);

        while *pos + WIDE <= input.len() {
            let chunk = Simd::<u8, WIDE>::from_slice(&input[*pos..*pos + WIDE]);
            let combined =
                chunk.simd_eq(quote) | chunk.simd_eq(backslash) | chunk.simd_lt(control_bound);
            if combined.any() {
                break;
            }
            *pos += WIDE;
        }
    }

    let quote = Simd::<u8, CHUNK>::splat(b'"');
    let backslash = Simd::<u8, CHUNK>::splat(b'\\');
    let control_bound = Simd::<u8, CHUNK>::splat(0x20);

    while *pos + CHUNK <= input.len() {
        let chunk = Simd::<u8, CHUNK>::from_slice(&input[*pos..*pos + CHUNK]);
        let combined =
            chunk.simd_eq(quote) | chunk.simd_eq(backslash) | chunk.simd_lt(control_bound);
        if combined.any() {
            break;
        }
        *pos += CHUNK;
    }
}

// ---------------------------------------------------------------------------
// Pattern A2: Skip contiguous ASCII digits ('0'..='9')
// ---------------------------------------------------------------------------

/// Advance `pos` past contiguous ASCII digit bytes using SIMD.
/// Handles partial chunks: if a 16/32-byte chunk contains some digits followed
/// by a non-digit, advances to the exact position of the first non-digit.
/// After return, `pos` points to the first non-digit or past the SIMD-able region.
///
/// Uses `to_bitmask().trailing_zeros()` — the caller needs the exact end-of-run
/// position (for number parsing), not a byte to inspect. Precision avoids
/// wasting up to 15 digits of scalar work. Benchmarked: +64% on large integers.
#[inline]
pub fn skip_ascii_digits(input: &[u8], pos: &mut usize) {
    #[cfg(target_feature = "avx2")]
    {
        let zero = Simd::<u8, WIDE>::splat(b'0');
        let nine = Simd::<u8, WIDE>::splat(b'9');

        while *pos + WIDE <= input.len() {
            let chunk = Simd::<u8, WIDE>::from_slice(&input[*pos..*pos + WIDE]);
            let mask = chunk.simd_ge(zero) & chunk.simd_le(nine);
            if mask.all() {
                *pos += WIDE;
            } else {
                let bitmask = mask.to_bitmask();
                *pos += (!bitmask).trailing_zeros() as usize;
                return;
            }
        }
    }

    let zero = Simd::<u8, CHUNK>::splat(b'0');
    let nine = Simd::<u8, CHUNK>::splat(b'9');

    while *pos + CHUNK <= input.len() {
        let chunk = Simd::<u8, CHUNK>::from_slice(&input[*pos..*pos + CHUNK]);
        let mask = chunk.simd_ge(zero) & chunk.simd_le(nine);
        if mask.all() {
            *pos += CHUNK;
        } else {
            let bitmask = mask.to_bitmask();
            *pos += (!bitmask).trailing_zeros() as usize;
            return;
        }
    }
}

// ---------------------------------------------------------------------------
// Pattern B: Chunk has structural JSON character
// ---------------------------------------------------------------------------

/// Returns `true` if the chunk at `input[pos..]` contains any structural
/// JSON character (`{`, `}`, `[`, `]`, `:`, `,`, `"`, `\`).
/// Caller must ensure `pos + CHUNK <= input.len()`.
#[inline]
pub fn chunk_has_structural(input: &[u8], pos: usize) -> bool {
    let chunk = Simd::<u8, CHUNK>::from_slice(&input[pos..pos + CHUNK]);
    let combined = chunk.simd_eq(Simd::splat(b'"'))
        | chunk.simd_eq(Simd::splat(b'\\'))
        | chunk.simd_eq(Simd::splat(b'{'))
        | chunk.simd_eq(Simd::splat(b'}'))
        | chunk.simd_eq(Simd::splat(b'['))
        | chunk.simd_eq(Simd::splat(b']'))
        | chunk.simd_eq(Simd::splat(b':'))
        | chunk.simd_eq(Simd::splat(b','));
    combined.any()
}

/// 32-byte structural check for the wide path in `build_structural_index`.
/// Caller must ensure `pos + 32 <= input.len()`.
#[cfg(target_feature = "avx2")]
#[inline]
pub fn chunk_has_structural_wide(input: &[u8], pos: usize) -> bool {
    let chunk = Simd::<u8, WIDE>::from_slice(&input[pos..pos + WIDE]);
    let combined = chunk.simd_eq(Simd::splat(b'"'))
        | chunk.simd_eq(Simd::splat(b'\\'))
        | chunk.simd_eq(Simd::splat(b'{'))
        | chunk.simd_eq(Simd::splat(b'}'))
        | chunk.simd_eq(Simd::splat(b'['))
        | chunk.simd_eq(Simd::splat(b']'))
        | chunk.simd_eq(Simd::splat(b':'))
        | chunk.simd_eq(Simd::splat(b','));
    combined.any()
}

// ---------------------------------------------------------------------------
// Pattern C: All whitespace check
// ---------------------------------------------------------------------------

/// Advance `pos` past contiguous JSON whitespace bytes (` `, `\t`, `\n`, `\r`).
/// Handles partial chunks: advances to the exact first non-whitespace byte.
///
/// Uses `to_bitmask().trailing_zeros()` — the caller needs the exact position
/// (for token parsing), not a byte to inspect. Benchmarked: +5-7%.
#[inline]
pub fn skip_whitespace(input: &[u8], pos: &mut usize) {
    #[cfg(target_feature = "avx2")]
    {
        while *pos + WIDE <= input.len() {
            let chunk = Simd::<u8, WIDE>::from_slice(&input[*pos..*pos + WIDE]);
            let ws = chunk.simd_eq(Simd::splat(b' '))
                | chunk.simd_eq(Simd::splat(b'\t'))
                | chunk.simd_eq(Simd::splat(b'\n'))
                | chunk.simd_eq(Simd::splat(b'\r'));
            if ws.all() {
                *pos += WIDE;
            } else {
                let bitmask = ws.to_bitmask();
                *pos += (!bitmask).trailing_zeros() as usize;
                return;
            }
        }
    }

    while *pos + CHUNK <= input.len() {
        let chunk = Simd::<u8, CHUNK>::from_slice(&input[*pos..*pos + CHUNK]);
        let ws = chunk.simd_eq(Simd::splat(b' '))
            | chunk.simd_eq(Simd::splat(b'\t'))
            | chunk.simd_eq(Simd::splat(b'\n'))
            | chunk.simd_eq(Simd::splat(b'\r'));
        if ws.all() {
            *pos += CHUNK;
        } else {
            let bitmask = ws.to_bitmask();
            *pos += (!bitmask).trailing_zeros() as usize;
            return;
        }
    }
}

// ---------------------------------------------------------------------------
// Pattern D: Find first byte needing escape (4 modes)
// ---------------------------------------------------------------------------

/// Find the index of the first byte in `bytes[pos..]` needing JSON escape
/// (control char < 0x20, `"`, or `\`). Returns `bytes.len()` if none found.
///
/// Uses `to_bitmask().trailing_zeros()` because the decoder's bulk copy
/// (decode_escaped_string) needs the exact position for extend_from_slice.
/// The encoder also calls this but only checks 3 conditions, so the bitmask
/// overhead is acceptable. The other escape modes (html/unicode/javascript)
/// are encoder-only and use `.any()` + `break` instead.
#[inline]
pub fn find_escape_json(bytes: &[u8], mut pos: usize) -> usize {
    #[cfg(target_feature = "avx2")]
    {
        let ctrl_max = Simd::<u8, WIDE>::splat(0x20);
        let quote = Simd::<u8, WIDE>::splat(b'"');
        let backslash = Simd::<u8, WIDE>::splat(b'\\');

        while pos + WIDE <= bytes.len() {
            let chunk = Simd::<u8, WIDE>::from_slice(&bytes[pos..pos + WIDE]);
            let combined =
                chunk.simd_lt(ctrl_max) | chunk.simd_eq(quote) | chunk.simd_eq(backslash);
            if combined.any() {
                let mask = combined.to_bitmask();
                return pos + mask.trailing_zeros() as usize;
            }
            pos += WIDE;
        }
    }

    let ctrl_max = Simd::<u8, CHUNK>::splat(0x20);
    let quote = Simd::<u8, CHUNK>::splat(b'"');
    let backslash = Simd::<u8, CHUNK>::splat(b'\\');

    while pos + CHUNK <= bytes.len() {
        let chunk = Simd::<u8, CHUNK>::from_slice(&bytes[pos..pos + CHUNK]);
        let combined = chunk.simd_lt(ctrl_max) | chunk.simd_eq(quote) | chunk.simd_eq(backslash);
        if combined.any() {
            let mask = combined.to_bitmask();
            return pos + mask.trailing_zeros() as usize;
        }
        pos += CHUNK;
    }
    find_escape_json_scalar(bytes, pos)
}

/// Find the next byte needing escape in HtmlSafe mode.
/// Flags: control chars, `"`, `\`, `<`, `>`, `&`, `/`, bytes >= 0xE2.
///
/// The SIMD loop uses `.any()` + `break` (not `to_bitmask`) because this is
/// only called from the encoder's tight escape loop, which immediately inspects
/// `bytes[pos]` after return. The scalar tail finds the exact byte cheaply.
#[inline]
pub fn find_escape_html(bytes: &[u8], mut pos: usize) -> usize {
    #[cfg(target_feature = "avx2")]
    {
        let ctrl_max = Simd::<u8, WIDE>::splat(0x20);
        let quote = Simd::<u8, WIDE>::splat(b'"');
        let backslash = Simd::<u8, WIDE>::splat(b'\\');
        let lt = Simd::<u8, WIDE>::splat(b'<');
        let gt = Simd::<u8, WIDE>::splat(b'>');
        let amp = Simd::<u8, WIDE>::splat(b'&');
        let slash = Simd::<u8, WIDE>::splat(b'/');
        let e2_threshold = Simd::<u8, WIDE>::splat(0xE2);

        while pos + WIDE <= bytes.len() {
            let chunk = Simd::<u8, WIDE>::from_slice(&bytes[pos..pos + WIDE]);
            let combined = chunk.simd_lt(ctrl_max)
                | chunk.simd_eq(quote)
                | chunk.simd_eq(backslash)
                | chunk.simd_eq(lt)
                | chunk.simd_eq(gt)
                | chunk.simd_eq(amp)
                | chunk.simd_eq(slash)
                | chunk.simd_ge(e2_threshold);
            if combined.any() {
                break;
            }
            pos += WIDE;
        }
    }

    let ctrl_max = Simd::<u8, CHUNK>::splat(0x20);
    let quote = Simd::<u8, CHUNK>::splat(b'"');
    let backslash = Simd::<u8, CHUNK>::splat(b'\\');
    let lt = Simd::<u8, CHUNK>::splat(b'<');
    let gt = Simd::<u8, CHUNK>::splat(b'>');
    let amp = Simd::<u8, CHUNK>::splat(b'&');
    let slash = Simd::<u8, CHUNK>::splat(b'/');
    let e2_threshold = Simd::<u8, CHUNK>::splat(0xE2);

    while pos + CHUNK <= bytes.len() {
        let chunk = Simd::<u8, CHUNK>::from_slice(&bytes[pos..pos + CHUNK]);
        let combined = chunk.simd_lt(ctrl_max)
            | chunk.simd_eq(quote)
            | chunk.simd_eq(backslash)
            | chunk.simd_eq(lt)
            | chunk.simd_eq(gt)
            | chunk.simd_eq(amp)
            | chunk.simd_eq(slash)
            | chunk.simd_ge(e2_threshold);
        if combined.any() {
            break;
        }
        pos += CHUNK;
    }
    find_escape_html_scalar(bytes, pos)
}

/// Find the next byte needing escape in UnicodeSafe mode.
/// Flags: control chars, `"`, `\`, all bytes >= 0x80.
///
/// Uses `.any()` + `break` — encoder-only, scalar tail finds exact byte.
#[inline]
pub fn find_escape_unicode(bytes: &[u8], mut pos: usize) -> usize {
    #[cfg(target_feature = "avx2")]
    {
        let ctrl_max = Simd::<u8, WIDE>::splat(0x20);
        let quote = Simd::<u8, WIDE>::splat(b'"');
        let backslash = Simd::<u8, WIDE>::splat(b'\\');
        let high_threshold = Simd::<u8, WIDE>::splat(0x80);

        while pos + WIDE <= bytes.len() {
            let chunk = Simd::<u8, WIDE>::from_slice(&bytes[pos..pos + WIDE]);
            let combined = chunk.simd_lt(ctrl_max)
                | chunk.simd_eq(quote)
                | chunk.simd_eq(backslash)
                | chunk.simd_ge(high_threshold);
            if combined.any() {
                break;
            }
            pos += WIDE;
        }
    }

    let ctrl_max = Simd::<u8, CHUNK>::splat(0x20);
    let quote = Simd::<u8, CHUNK>::splat(b'"');
    let backslash = Simd::<u8, CHUNK>::splat(b'\\');
    let high_threshold = Simd::<u8, CHUNK>::splat(0x80);

    while pos + CHUNK <= bytes.len() {
        let chunk = Simd::<u8, CHUNK>::from_slice(&bytes[pos..pos + CHUNK]);
        let combined = chunk.simd_lt(ctrl_max)
            | chunk.simd_eq(quote)
            | chunk.simd_eq(backslash)
            | chunk.simd_ge(high_threshold);
        if combined.any() {
            break;
        }
        pos += CHUNK;
    }
    find_escape_unicode_scalar(bytes, pos)
}

/// Find the next byte needing escape in JavaScriptSafe mode.
/// Flags: control chars, `"`, `\`, bytes >= 0xE2.
///
/// Uses `.any()` + `break` — encoder-only, scalar tail finds exact byte.
#[inline]
pub fn find_escape_javascript(bytes: &[u8], mut pos: usize) -> usize {
    #[cfg(target_feature = "avx2")]
    {
        let ctrl_max = Simd::<u8, WIDE>::splat(0x20);
        let quote = Simd::<u8, WIDE>::splat(b'"');
        let backslash = Simd::<u8, WIDE>::splat(b'\\');
        let e2_threshold = Simd::<u8, WIDE>::splat(0xE2);

        while pos + WIDE <= bytes.len() {
            let chunk = Simd::<u8, WIDE>::from_slice(&bytes[pos..pos + WIDE]);
            let combined = chunk.simd_lt(ctrl_max)
                | chunk.simd_eq(quote)
                | chunk.simd_eq(backslash)
                | chunk.simd_ge(e2_threshold);
            if combined.any() {
                break;
            }
            pos += WIDE;
        }
    }

    let ctrl_max = Simd::<u8, CHUNK>::splat(0x20);
    let quote = Simd::<u8, CHUNK>::splat(b'"');
    let backslash = Simd::<u8, CHUNK>::splat(b'\\');
    let e2_threshold = Simd::<u8, CHUNK>::splat(0xE2);

    while pos + CHUNK <= bytes.len() {
        let chunk = Simd::<u8, CHUNK>::from_slice(&bytes[pos..pos + CHUNK]);
        let combined = chunk.simd_lt(ctrl_max)
            | chunk.simd_eq(quote)
            | chunk.simd_eq(backslash)
            | chunk.simd_ge(e2_threshold);
        if combined.any() {
            break;
        }
        pos += CHUNK;
    }
    find_escape_javascript_scalar(bytes, pos)
}

// ---------------------------------------------------------------------------
// Scalar tails — called for the last < 16 bytes
// ---------------------------------------------------------------------------

/// Table for checking if a byte needs escaping in JSON mode.
/// 0 = safe, 1 = needs escape.
static ESCAPE_TABLE: [u8; 256] = {
    let mut table = [0u8; 256];
    let mut i = 0;
    while i < 32 {
        table[i] = 1;
        i += 1;
    }
    table[b'"' as usize] = 1;
    table[b'\\' as usize] = 1;
    table
};

#[inline]
fn find_escape_json_scalar(bytes: &[u8], mut pos: usize) -> usize {
    while pos < bytes.len() {
        if ESCAPE_TABLE[bytes[pos] as usize] == 1 {
            return pos;
        }
        pos += 1;
    }
    pos
}

#[inline]
fn find_escape_html_scalar(bytes: &[u8], mut pos: usize) -> usize {
    while pos < bytes.len() {
        let b = bytes[pos];
        if ESCAPE_TABLE[b as usize] == 1
            || b == b'<'
            || b == b'>'
            || b == b'&'
            || b == b'/'
            || b >= 0xE2
        {
            return pos;
        }
        pos += 1;
    }
    pos
}

#[inline]
fn find_escape_unicode_scalar(bytes: &[u8], mut pos: usize) -> usize {
    while pos < bytes.len() {
        let b = bytes[pos];
        if ESCAPE_TABLE[b as usize] == 1 || b >= 0x80 {
            return pos;
        }
        pos += 1;
    }
    pos
}

#[inline]
fn find_escape_javascript_scalar(bytes: &[u8], mut pos: usize) -> usize {
    while pos < bytes.len() {
        let b = bytes[pos];
        if ESCAPE_TABLE[b as usize] == 1 || b >= 0xE2 {
            return pos;
        }
        pos += 1;
    }
    pos
}
