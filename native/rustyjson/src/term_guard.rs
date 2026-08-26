//! Diagnostic guard for the `enif_make_map_from_arrays` segfault investigation.
//!
//! # Why this exists
//!
//! Three `beam.smp` crashes (2026-08-25) share an identical signature:
//!
//! ```text
//! EXC_BAD_ACCESS (SIGSEGV) at 0xfffffffffffffffe
//!   erts_cmp+236                          <- ldur x8, [x0, #-2]   with x0 == 0
//!   erts_validate_and_sort_flatmap+100
//!   erts_map_from_ks_and_vs+300
//!   enif_make_map_from_arrays+172
//!   rustler::Term::map_from_term_arrays+472
//!   rustyjson::DirectParser::parse_object+4152
//! ```
//!
//! `erts_cmp` reaches `boxed_val(x)` after testing only bit 0 of the term, so a
//! raw term word of `0` (`THE_NON_VALUE`) is dereferenced at address `0 - 2`,
//! i.e. `0xfffffffffffffffe`. The faulting registers say the map had exactly
//! three keys and that `keys[0]` and `keys[1]` were both `0`.
//!
//! `enif_make_map_from_arrays` performs **no validation whatsoever** on the
//! arrays it is handed — it passes the caller's pointers straight to
//! `erts_map_from_ks_and_vs`, which `memcpy`s them onto the process heap and
//! sorts them. Any invalid word is an immediate, unrecoverable VM crash.
//!
//! # What this guard answers
//!
//! Static analysis of RustyJson 0.4.0 found **no** path that can yield a zero
//! key term: every key comes from `enif_make_new_binary` or
//! `enif_make_sub_binary`, neither of which can return `THE_NON_VALUE`. So the
//! open question is *producer vs victim*, and this module is built to answer it
//! with two checkpoints at different points in time:
//!
//! * [`check_produced`] runs the instant a key term is created.
//! * [`check_arrays`] runs immediately before the arrays are handed to ERTS.
//!
//! | Which checkpoint fires | Conclusion |
//! |---|---|
//! | `produced` | RustyJson emitted an invalid term. **RustyJson defect.** |
//! | `arrays` only | The term was valid when created and became invalid while sitting in the `Vec`. **External corruption; RustyJson is a victim.** |
//! | neither, VM still dies | The bad word is not `0`, or it is written between this check and the FFI call (a window of a few hundred nanoseconds). |
//!
//! # Cost
//!
//! The whole module compiles to nothing unless the `term_guard` cargo feature
//! is enabled, so the shipped artifact is bit-identical with it off.

/// A raw `ERL_NIF_TERM` word that is never a legal term.
///
/// `THE_NON_VALUE` is `0` on this build; verified by disassembling
/// `enif_make_badarg`/`enif_raise_exception` in `beam.smp` (both are
/// `mov x0, #0; ret`).
// Referenced by the guard implementation and the unit tests; both are compiled
// out of a default release build.
#[allow(dead_code)]
pub const THE_NON_VALUE: u64 = 0;

/// Returns the index of the first word that cannot be a valid term.
///
/// Deliberately arithmetic-only: it must never call back into ERTS. `enif_is_*`
/// predicates are *not* safe here — `enif_is_binary` and `enif_is_number` also
/// test only bit 0 before dereferencing `boxed_val`, so handing them a zero word
/// reproduces the very crash we are trying to catch (verified experimentally).
///
/// A term word is rejected when it is `THE_NON_VALUE`, or when its primary tag
/// is `TAG_PRIMARY_HEADER` (`0b00`). A header word is only ever legal as the
/// first word of a boxed object on the heap, never as a standalone term, and
/// `erts_cmp` would dereference it at a misaligned address.
#[allow(dead_code)]
#[inline(always)]
pub fn first_invalid(words: &[u64]) -> Option<usize> {
    words.iter().position(|&w| !is_plausible_term(w))
}

/// Cheap validity screen for one raw term word. Arithmetic only, no FFI.
#[allow(dead_code)]
#[inline(always)]
pub fn is_plausible_term(word: u64) -> bool {
    // _TAG_PRIMARY_MASK = 0b11; TAG_PRIMARY_HEADER = 0b00.
    // Rejects THE_NON_VALUE (0) as a side effect, since 0 & 0b11 == 0b00.
    word & 0b11 != 0
}

#[cfg(feature = "term_guard")]
mod imp {
    use super::{first_invalid, is_plausible_term};
    use rustler::Term;
    use std::io::Write;

    /// Where a captured violation is written. Overridable so a dev server can
    /// point it somewhere durable.
    fn dump_dir() -> std::path::PathBuf {
        std::env::var_os("RUSTYJSON_GUARD_DIR")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| std::path::PathBuf::from("/tmp/rustyjson-guard"))
    }

    /// Write a forensic record and flush it to disk before returning.
    ///
    /// The caller is about to raise rather than crash, but if this guard is
    /// wrong about the failure mode the VM may still die, so the dump is
    /// `fsync`ed rather than buffered.
    fn dump(checkpoint: &str, detail: &str, input: &[u8], pos: usize) {
        let dir = dump_dir();
        let _ = std::fs::create_dir_all(&dir);

        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let path = dir.join(format!("{nanos}-{checkpoint}.guard"));

        let Ok(mut f) = std::fs::File::create(&path) else {
            return;
        };
        let _ = writeln!(f, "checkpoint: {checkpoint}");
        let _ = writeln!(f, "detail: {detail}");
        let _ = writeln!(f, "position: {pos}");
        let _ = writeln!(f, "input_len: {}", input.len());
        let _ = writeln!(f, "thread: {:?}", std::thread::current().id());
        let _ = writeln!(f, "--- input begins ---");
        let _ = f.write_all(input);
        let _ = f.write_all(b"\n--- input ends ---\n");
        let _ = f.flush();
        let _ = f.sync_all();

        eprintln!("[rustyjson term_guard] {checkpoint}: {detail} (dumped to {})", path.display());
    }

    /// Producer checkpoint: validate a term the moment RustyJson creates it.
    #[inline]
    pub fn check_produced(what: &str, term: Term<'_>, input: &[u8], pos: usize) -> bool {
        let word = term.as_c_arg() as u64;
        if is_plausible_term(word) {
            return true;
        }
        dump(
            "produced",
            &format!("{what} yielded invalid term word 0x{word:016x}"),
            input,
            pos,
        );
        false
    }

    /// Consumer checkpoint: validate both arrays immediately before the FFI
    /// call that hands them to ERTS.
    #[inline]
    pub fn check_arrays(keys: &[Term<'_>], values: &[Term<'_>], input: &[u8], pos: usize) -> bool {
        let keys: Vec<u64> = keys.iter().map(|t| t.as_c_arg() as u64).collect();
        let values: Vec<u64> = values.iter().map(|t| t.as_c_arg() as u64).collect();
        let bad_key = first_invalid(&keys);
        let bad_value = first_invalid(&values);
        if bad_key.is_none() && bad_value.is_none() {
            return true;
        }
        let detail = format!(
            "n={} bad_key_index={:?} bad_value_index={:?} keys={:016x?} values={:016x?}",
            keys.len(),
            bad_key,
            bad_value,
            keys,
            values
        );
        dump("arrays", &detail, input, pos);
        false
    }
}

#[cfg(not(feature = "term_guard"))]
mod imp {
    use rustler::Term;

    #[inline(always)]
    pub fn check_produced(_what: &str, _term: Term<'_>, _input: &[u8], _pos: usize) -> bool {
        true
    }

    #[inline(always)]
    pub fn check_arrays(
        _keys: &[Term<'_>],
        _values: &[Term<'_>],
        _input: &[u8],
        _pos: usize,
    ) -> bool {
        true
    }
}

pub use imp::{check_arrays, check_produced};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_non_value_is_rejected() {
        assert!(!is_plausible_term(THE_NON_VALUE));
        assert_eq!(first_invalid(&[0, 0, 0x1234_5678_9abc_def2]), Some(0));
    }

    #[test]
    fn header_tagged_words_are_rejected() {
        // TAG_PRIMARY_HEADER (0b00) is never a standalone term. 0x12c is the
        // flatmap header word ERTS writes on the heap; seeing one in a keys
        // array means we are reading heap memory as terms.
        assert!(!is_plausible_term(0x12c));
        assert!(!is_plausible_term(0x58)); // HEADER_FLONUM
    }

    #[test]
    fn legal_tags_are_accepted() {
        assert!(is_plausible_term(0x0000_0001_1416_060a)); // boxed  (0b10)
        assert!(is_plausible_term(0x0000_0001_11df_7de1)); // list   (0b01)
        assert!(is_plausible_term(0x0000_0000_0000_000b)); // atom   (immed, 0b11)
        assert!(is_plausible_term(0xffff_ffff_ffff_ffff)); // small int
    }

    #[test]
    fn the_exact_crash_array_is_caught() {
        // Reconstructed from beam.smp-2026-08-25-083253.ips: three keys, the
        // first two of which were THE_NON_VALUE.
        let keys = [0u64, 0u64, 0x0000_0001_1416_060a];
        assert_eq!(first_invalid(&keys), Some(0));
    }

    #[test]
    fn a_clean_array_passes() {
        let keys = [0x1141_6060_au64 | 0b10, 0x1141_6061_au64 | 0b10, 0xffff_ffff_ffff_ffff];
        assert_eq!(first_invalid(&keys), None);
    }
}
