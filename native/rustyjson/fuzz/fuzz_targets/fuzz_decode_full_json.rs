#![no_main]
use libfuzzer_sys::fuzz_target;
use rustyjson::direct_decode::bench_helpers;

fuzz_target!(|data: &[u8]| {
    // Exercise the full JSON validation path:
    // structural index, whitespace skip, string scan, number scan,
    // bracket matching, and value routing
    let _ = bench_helpers::validate_json(data);

    // Also exercise structural index independently
    let _ = bench_helpers::build_structural_index(data);
});
