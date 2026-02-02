#![no_main]
use libfuzzer_sys::fuzz_target;
use rustyjson::direct_decode::bench_helpers;

fuzz_target!(|data: &[u8]| {
    if data.len() >= 2 {
        let _ = bench_helpers::decode_escaped_string(data, 0, data.len());
    }
});
