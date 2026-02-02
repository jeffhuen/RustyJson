use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion, Throughput};
use rustyjson::direct_json::{write_json_string_escaped_pub, EscapeMode};

// ---------------------------------------------------------------------------
// Test data
// ---------------------------------------------------------------------------

fn plain_ascii(len: usize) -> String {
    (0..len).map(|i| (b'a' + (i % 26) as u8) as char).collect()
}

fn needs_escaping(len: usize) -> String {
    let pattern = "hello \"world\"\nnew\tline\\slash";
    pattern.chars().cycle().take(len).collect()
}

fn html_unsafe(len: usize) -> String {
    let pattern = "<script>alert('xss');</script>&foo<bar>";
    pattern.chars().cycle().take(len).collect()
}

fn unicode_heavy(len: usize) -> String {
    let chars = ['a', '\u{00e9}', '\u{4e16}', '\u{1f600}', 'z'];
    (0..len).map(|i| chars[i % chars.len()]).collect()
}

// ---------------------------------------------------------------------------
// Benchmarks
// ---------------------------------------------------------------------------

fn bench_string_escaping(c: &mut Criterion) {
    let mut group = c.benchmark_group("string_escape");

    for size in [16, 64, 256, 1024, 4096] {
        // Plain ASCII (fast path — no escaping needed)
        let plain = plain_ascii(size);
        group.throughput(Throughput::Bytes(plain.len() as u64));
        group.bench_with_input(BenchmarkId::new("ascii_json", size), &plain, |b, data| {
            let mut buf = Vec::with_capacity(data.len() + 16);
            b.iter(|| {
                buf.clear();
                write_json_string_escaped_pub(black_box(data), &mut buf, EscapeMode::Json)
            })
        });

        // Strings with escape sequences
        let escaped = needs_escaping(size);
        group.throughput(Throughput::Bytes(escaped.len() as u64));
        group.bench_with_input(
            BenchmarkId::new("escaped_json", size),
            &escaped,
            |b, data| {
                let mut buf = Vec::with_capacity(data.len() * 2 + 16);
                b.iter(|| {
                    buf.clear();
                    write_json_string_escaped_pub(black_box(data), &mut buf, EscapeMode::Json)
                })
            },
        );

        // HTML-safe mode
        let html = html_unsafe(size);
        group.throughput(Throughput::Bytes(html.len() as u64));
        group.bench_with_input(BenchmarkId::new("html_safe", size), &html, |b, data| {
            let mut buf = Vec::with_capacity(data.len() * 2 + 16);
            b.iter(|| {
                buf.clear();
                write_json_string_escaped_pub(black_box(data), &mut buf, EscapeMode::HtmlSafe)
            })
        });

        // Unicode-safe mode
        let uni = unicode_heavy(size);
        group.throughput(Throughput::Bytes(uni.len() as u64));
        group.bench_with_input(BenchmarkId::new("unicode_safe", size), &uni, |b, data| {
            let mut buf = Vec::with_capacity(data.len() * 6 + 16);
            b.iter(|| {
                buf.clear();
                write_json_string_escaped_pub(black_box(data), &mut buf, EscapeMode::UnicodeSafe)
            })
        });
    }
    group.finish();
}

fn bench_integer_format(c: &mut Criterion) {
    let mut group = c.benchmark_group("integer_format");

    let cases: &[(&str, i64)] = &[
        ("zero", 0),
        ("small", 42),
        ("medium", 1_234_567),
        ("large", 9_223_372_036_854_775_807),
        ("negative", -1_234_567_890),
        ("neg_large", -9_223_372_036_854_775_807),
    ];

    for (name, value) in cases {
        group.bench_with_input(BenchmarkId::new("itoa", *name), value, |b, &val| {
            b.iter(|| {
                let mut buf = itoa::Buffer::new();
                black_box(buf.format(val));
            })
        });
    }

    // Batch formatting
    group.bench_function("itoa_batch_100", |b| {
        let values: Vec<i64> = (0..100).map(|i| i * 1234567).collect();
        b.iter(|| {
            let mut buf = itoa::Buffer::new();
            for &v in &values {
                black_box(buf.format(v));
            }
        })
    });

    group.finish();
}

fn bench_float_format(c: &mut Criterion) {
    let mut group = c.benchmark_group("float_format");

    let cases: &[(&str, f64)] = &[
        ("zero", 0.0),
        ("simple", 3.14159265),
        ("scientific", 6.022e23),
        ("tiny", 5e-324),
        ("max", 1.7976931348623157e308),
        ("negative", -273.15),
        ("precise", 1.23456789012345),
    ];

    for (name, value) in cases {
        group.bench_with_input(BenchmarkId::new("ryu", *name), value, |b, &val| {
            b.iter(|| {
                let mut buf = ryu::Buffer::new();
                black_box(buf.format(val));
            })
        });
    }

    // Batch formatting
    group.bench_function("ryu_batch_100", |b| {
        let values: Vec<f64> = (0..100).map(|i| i as f64 * 3.14159265).collect();
        b.iter(|| {
            let mut buf = ryu::Buffer::new();
            for &v in &values {
                black_box(buf.format(v));
            }
        })
    });

    group.finish();
}

criterion_group!(
    benches,
    bench_string_escaping,
    bench_integer_format,
    bench_float_format,
);
criterion_main!(benches);
