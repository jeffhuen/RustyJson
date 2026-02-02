#![no_main]
use libfuzzer_sys::fuzz_target;
use rustyjson::direct_decode::bench_helpers;

fuzz_target!(|data: &[u8]| {
    // Exercise the fast integer parser
    let _ = bench_helpers::parse_integer_fast(data, 0);

    // Also exercise the scanner to ensure scanner and parser agree on boundaries
    let _ = bench_helpers::scan_number(data, 0);
});
