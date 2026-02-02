#![no_main]
use libfuzzer_sys::fuzz_target;
use rustyjson::direct_decode::bench_helpers;

fuzz_target!(|data: &[u8]| {
    let _ = bench_helpers::build_structural_index(data);
});
