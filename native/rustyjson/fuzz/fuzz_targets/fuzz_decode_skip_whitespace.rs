#![no_main]
use libfuzzer_sys::fuzz_target;
use rustyjson::direct_decode::bench_helpers;

fuzz_target!(|data: &[u8]| {
    let _ = bench_helpers::skip_whitespace(data, 0);

    // Also test starting from various offsets
    for offset in [1, 7, 8, 15, 16, 31, 32] {
        if offset < data.len() {
            let _ = bench_helpers::skip_whitespace(data, offset);
        }
    }
});
