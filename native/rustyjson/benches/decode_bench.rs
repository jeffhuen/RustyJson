use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion, Throughput};
use rustyjson::direct_decode::bench_helpers;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

// ---------------------------------------------------------------------------
// Test data generators
// ---------------------------------------------------------------------------

fn ascii_string(len: usize) -> Vec<u8> {
    let mut s = Vec::with_capacity(len + 2);
    s.push(b'"');
    for i in 0..len {
        s.push(b'a' + (i % 26) as u8);
    }
    s.push(b'"');
    s
}

fn utf8_string(len: usize) -> Vec<u8> {
    // Mix of ASCII and multi-byte UTF-8 (CJK characters)
    let mut s = Vec::with_capacity(len * 3 + 2);
    s.push(b'"');
    let chars = [
        'a', 'b', '\u{4e16}', '\u{754c}', 'c', '\u{3053}', '\u{3093}',
    ];
    let mut total = 0;
    let mut idx = 0;
    while total < len {
        let mut buf = [0u8; 4];
        let encoded = chars[idx % chars.len()].encode_utf8(&mut buf);
        if total + encoded.len() > len {
            break;
        }
        s.extend_from_slice(encoded.as_bytes());
        total += encoded.len();
        idx += 1;
    }
    s.push(b'"');
    s
}

fn escaped_string(len: usize) -> Vec<u8> {
    // Heavily escaped: every other char is an escape sequence
    let mut s = Vec::with_capacity(len * 2 + 2);
    s.push(b'"');
    let escapes: &[&[u8]] = &[b"\\n", b"\\t", b"\\\"", b"\\\\", b"\\/", b"\\r"];
    let mut total = 0;
    let mut idx = 0;
    while total < len {
        let esc = escapes[idx % escapes.len()];
        s.extend_from_slice(esc);
        total += esc.len();
        if total < len {
            s.push(b'x');
            total += 1;
        }
        idx += 1;
    }
    s.push(b'"');
    s
}

fn whitespace_block(len: usize) -> Vec<u8> {
    // Typical pretty-printed whitespace
    let pattern = b"  \n    \t  \r\n        ";
    let mut ws = Vec::with_capacity(len + 1);
    while ws.len() < len {
        let remaining = len - ws.len();
        let take = remaining.min(pattern.len());
        ws.extend_from_slice(&pattern[..take]);
    }
    ws.push(b'{'); // terminator so skip_whitespace stops
    ws
}

fn integer_sequence(count: usize) -> Vec<u8> {
    let mut s = String::new();
    for i in 0..count {
        if i > 0 {
            s.push(',');
        }
        s.push_str(&(i as i64 * 1234567).to_string());
    }
    s.into_bytes()
}

fn float_sequence(count: usize) -> Vec<u8> {
    let mut s = String::new();
    for i in 0..count {
        if i > 0 {
            s.push(',');
        }
        s.push_str(&format!("{:.6}", i as f64 * 3.14159265));
    }
    s.into_bytes()
}

// ---------------------------------------------------------------------------
// Benchmarks
// ---------------------------------------------------------------------------

fn bench_simd_string_scan(c: &mut Criterion) {
    let mut group = c.benchmark_group("string_scan");

    for size in [32, 128, 512, 4096, 65536] {
        let ascii = ascii_string(size);
        group.throughput(Throughput::Bytes(ascii.len() as u64));
        group.bench_with_input(BenchmarkId::new("ascii", size), &ascii, |b, data| {
            b.iter(|| bench_helpers::scan_string(black_box(data), 0))
        });

        let utf8 = utf8_string(size);
        group.throughput(Throughput::Bytes(utf8.len() as u64));
        group.bench_with_input(BenchmarkId::new("utf8", size), &utf8, |b, data| {
            b.iter(|| bench_helpers::scan_string(black_box(data), 0))
        });

        let escaped = escaped_string(size);
        group.throughput(Throughput::Bytes(escaped.len() as u64));
        group.bench_with_input(BenchmarkId::new("escaped", size), &escaped, |b, data| {
            b.iter(|| bench_helpers::scan_string(black_box(data), 0))
        });
    }
    group.finish();
}

fn bench_whitespace_skip(c: &mut Criterion) {
    let mut group = c.benchmark_group("whitespace_skip");

    for size in [16, 64, 256, 1024, 4096] {
        let ws = whitespace_block(size);
        group.throughput(Throughput::Bytes(ws.len() as u64));
        group.bench_with_input(BenchmarkId::new("mixed", size), &ws, |b, data| {
            b.iter(|| bench_helpers::skip_whitespace(black_box(data), 0))
        });
    }
    group.finish();
}

fn bench_escape_decode(c: &mut Criterion) {
    let mut group = c.benchmark_group("escape_decode");

    for size in [32, 128, 512, 4096] {
        let escaped = escaped_string(size);
        // Find the content between quotes
        let (end, _) = bench_helpers::scan_string(&escaped, 0);
        let content_start = 1; // after opening quote
        let content_end = end - 1; // before closing quote

        group.throughput(Throughput::Bytes((content_end - content_start) as u64));
        group.bench_with_input(
            BenchmarkId::new("heavily_escaped", size),
            &escaped,
            |b, data| {
                b.iter(|| {
                    bench_helpers::decode_escaped_string(
                        black_box(data),
                        content_start,
                        content_end,
                    )
                })
            },
        );
    }

    // Unicode escape sequences
    let unicode_str = br#""Hello \u0048\u0065\u006C\u006C\u006F \u4E16\u754C""#;
    group.bench_function("unicode_escapes", |b| {
        let (end, _) = bench_helpers::scan_string(unicode_str.as_slice(), 0);
        b.iter(|| {
            bench_helpers::decode_escaped_string(black_box(unicode_str.as_slice()), 1, end - 1)
        })
    });

    // Surrogate pair
    let surrogate_str = br#""\uD83D\uDE00\uD83D\uDE01\uD83D\uDE02\uD83D\uDE03""#;
    group.bench_function("surrogate_pairs", |b| {
        let (end, _) = bench_helpers::scan_string(surrogate_str.as_slice(), 0);
        b.iter(|| {
            bench_helpers::decode_escaped_string(black_box(surrogate_str.as_slice()), 1, end - 1)
        })
    });

    group.finish();
}

fn bench_number_scan(c: &mut Criterion) {
    let mut group = c.benchmark_group("number_scan");

    let cases: &[(&str, &[u8])] = &[
        ("small_int", b"42"),
        ("large_int", b"1234567890123456789"),
        ("negative", b"-9876543210"),
        ("simple_float", b"3.14159265"),
        ("scientific", b"6.022e23"),
        ("neg_scientific", b"-1.23456789e-10"),
    ];

    for (name, data) in cases {
        group.bench_with_input(BenchmarkId::new("scan", *name), data, |b, data| {
            b.iter(|| bench_helpers::scan_number(black_box(*data), 0))
        });
    }
    group.finish();
}

fn bench_number_parse(c: &mut Criterion) {
    let mut group = c.benchmark_group("number_parse");

    // Integer parsing via lexical-core
    let int_cases: &[(&str, &[u8])] = &[
        ("small", b"42"),
        ("medium", b"1234567"),
        ("large", b"9223372036854775807"),
        ("negative", b"-1234567890"),
    ];
    for (name, data) in int_cases {
        group.bench_with_input(BenchmarkId::new("i64", *name), data, |b, data| {
            b.iter(|| lexical_core::parse::<i64>(black_box(*data)))
        });
    }

    // Float parsing via lexical-core
    let float_cases: &[(&str, &[u8])] = &[
        ("simple", b"3.14159265"),
        ("scientific", b"6.022e23"),
        ("precise", b"1.7976931348623157e308"),
        ("small", b"5e-324"),
    ];
    for (name, data) in float_cases {
        group.bench_with_input(BenchmarkId::new("f64", *name), data, |b, data| {
            b.iter(|| lexical_core::parse::<f64>(black_box(*data)))
        });
    }

    // Batch parsing from sequences
    let ints = integer_sequence(100);
    group.throughput(Throughput::Bytes(ints.len() as u64));
    group.bench_function("i64_batch_100", |b| {
        b.iter(|| {
            for segment in ints.split(|&b| b == b',') {
                let _ = lexical_core::parse::<i64>(black_box(segment));
            }
        })
    });

    let floats = float_sequence(100);
    group.throughput(Throughput::Bytes(floats.len() as u64));
    group.bench_function("f64_batch_100", |b| {
        b.iter(|| {
            for segment in floats.split(|&b| b == b',') {
                let _ = lexical_core::parse::<f64>(black_box(segment));
            }
        })
    });

    group.finish();
}

fn bench_fnv_hash(c: &mut Criterion) {
    let mut group = c.benchmark_group("fnv_hash");

    // FNV-1a implementation matching the one in direct_decode.rs
    #[inline]
    fn fnv1a(bytes: &[u8]) -> u64 {
        const FNV_OFFSET: u64 = 0xcbf29ce484222325;
        const FNV_PRIME: u64 = 0x100000001b3;
        let mut hash = FNV_OFFSET;
        for &byte in bytes {
            hash ^= byte as u64;
            hash = hash.wrapping_mul(FNV_PRIME);
        }
        hash
    }

    let key_sizes = [5, 10, 20, 50, 100];
    for size in key_sizes {
        let key: Vec<u8> = (0..size).map(|i| b'a' + (i % 26) as u8).collect();
        group.throughput(Throughput::Bytes(size as u64));

        group.bench_with_input(BenchmarkId::new("fnv1a", size), &key, |b, data| {
            b.iter(|| fnv1a(black_box(data)))
        });

        // Compare with std DefaultHasher (SipHash)
        group.bench_with_input(BenchmarkId::new("siphash", size), &key, |b, data| {
            b.iter(|| {
                let mut h = DefaultHasher::new();
                data.hash(&mut h);
                h.finish()
            })
        });
    }
    group.finish();
}

fn bench_utf8_validation(c: &mut Criterion) {
    let mut group = c.benchmark_group("utf8_validation");

    for size in [32, 128, 512, 4096, 65536] {
        // Pure ASCII
        let ascii: Vec<u8> = (0..size).map(|i| b'a' + (i % 26) as u8).collect();
        group.throughput(Throughput::Bytes(size as u64));
        group.bench_with_input(BenchmarkId::new("ascii", size), &ascii, |b, data| {
            b.iter(|| std::str::from_utf8(black_box(data)))
        });

        // Mixed UTF-8
        let mixed: Vec<u8> = {
            let s: String = (0..size / 3)
                .map(|i| {
                    let chars = ['a', '\u{00e9}', '\u{4e16}', 'z', '\u{1f600}'];
                    chars[i % chars.len()]
                })
                .collect();
            s.into_bytes()
        };
        group.throughput(Throughput::Bytes(mixed.len() as u64));
        group.bench_with_input(BenchmarkId::new("mixed_utf8", size), &mixed, |b, data| {
            b.iter(|| std::str::from_utf8(black_box(data)))
        });
    }
    group.finish();
}

fn json_object(num_keys: usize, value_len: usize) -> Vec<u8> {
    let mut s = String::from("{");
    for i in 0..num_keys {
        if i > 0 {
            s.push(',');
        }
        s.push_str(&format!("\"key_{}\":", i));
        s.push('"');
        for j in 0..value_len {
            s.push((b'a' + (j % 26) as u8) as char);
        }
        s.push('"');
    }
    s.push('}');
    s.into_bytes()
}

fn json_array_of_objects(num_objects: usize, num_keys: usize) -> Vec<u8> {
    let mut s = String::from("[");
    for i in 0..num_objects {
        if i > 0 {
            s.push(',');
        }
        s.push('{');
        for j in 0..num_keys {
            if j > 0 {
                s.push(',');
            }
            s.push_str(&format!("\"key_{}\":\"val{}\"", j, i * num_keys + j));
        }
        s.push('}');
    }
    s.push(']');
    s.into_bytes()
}

fn pretty_printed_json(num_keys: usize) -> Vec<u8> {
    let mut s = String::from("{\n");
    for i in 0..num_keys {
        if i > 0 {
            s.push_str(",\n");
        }
        s.push_str(&format!("    \"key_{}\": \"value_{}\"", i, i));
    }
    s.push_str("\n}");
    s.into_bytes()
}

fn bench_structural_index(c: &mut Criterion) {
    let mut group = c.benchmark_group("structural_index");

    // Object with varying sizes
    for num_keys in [10, 50, 200] {
        let obj = json_object(num_keys, 20);
        group.throughput(Throughput::Bytes(obj.len() as u64));
        group.bench_with_input(
            BenchmarkId::new("object", format!("{}keys", num_keys)),
            &obj,
            |b, data| b.iter(|| bench_helpers::build_structural_index(black_box(data))),
        );
    }

    // Array of objects
    for num_objects in [10, 100] {
        let arr = json_array_of_objects(num_objects, 5);
        group.throughput(Throughput::Bytes(arr.len() as u64));
        group.bench_with_input(
            BenchmarkId::new("array_of_objects", format!("{}x5", num_objects)),
            &arr,
            |b, data| b.iter(|| bench_helpers::build_structural_index(black_box(data))),
        );
    }

    // Pretty-printed JSON (lots of whitespace)
    for num_keys in [20, 100] {
        let pp = pretty_printed_json(num_keys);
        group.throughput(Throughput::Bytes(pp.len() as u64));
        group.bench_with_input(
            BenchmarkId::new("pretty_printed", format!("{}keys", num_keys)),
            &pp,
            |b, data| b.iter(|| bench_helpers::build_structural_index(black_box(data))),
        );
    }

    group.finish();
}

criterion_group!(
    benches,
    bench_simd_string_scan,
    bench_whitespace_skip,
    bench_escape_decode,
    bench_number_scan,
    bench_number_parse,
    bench_fnv_hash,
    bench_utf8_validation,
    bench_structural_index,
);
criterion_main!(benches);
