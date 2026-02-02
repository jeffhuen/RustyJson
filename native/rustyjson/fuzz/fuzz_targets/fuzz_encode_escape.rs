#![no_main]
use libfuzzer_sys::fuzz_target;
use rustyjson::direct_json::bench_helpers as encode_helpers;

fuzz_target!(|data: &[u8]| {
    // Only fuzz valid UTF-8 (encode requires &str)
    if let Ok(s) = std::str::from_utf8(data) {
        let _ = encode_helpers::escape_string_json(s);
        let _ = encode_helpers::escape_string_html(s);
        let _ = encode_helpers::escape_string_unicode(s);
        let _ = encode_helpers::escape_string_javascript(s);
    }
});
