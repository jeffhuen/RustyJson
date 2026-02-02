#![no_main]
use libfuzzer_sys::fuzz_target;
use rustyjson::direct_decode::bench_helpers;

fuzz_target!(|data: &[u8]| {
    // scan_string expects input starting with opening quote
    // Test both with and without quote prefix
    let _ = bench_helpers::scan_string(data, 0);

    // Also test with a quote prefix (normal parse entry)
    if data.len() < 65536 {
        let mut quoted = Vec::with_capacity(data.len() + 2);
        quoted.push(b'"');
        quoted.extend_from_slice(data);
        quoted.push(b'"');
        let _ = bench_helpers::scan_string(&quoted, 0);
    }
});
