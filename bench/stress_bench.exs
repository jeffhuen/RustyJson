# Stress Benchmark: RustyJson vs Jason
#
# Uses real-world datasets from nativejson-benchmark:
# - canada.json: Geographic coordinates (2.1MB, number-heavy)
# - citm_catalog.json: Event catalog (1.6MB, mixed types)
# - twitter.json: Social media with CJK (617KB, unicode-heavy)
#
# Run with: mix run bench/stress_bench.exs

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("STRESS BENCHMARK: RustyJson vs Jason")
IO.puts(String.duplicate("=", 60) <> "\n")

# Load test data
data_dir = Path.join(__DIR__, "data")

canada_json = File.read!(Path.join(data_dir, "canada.json"))
citm_json = File.read!(Path.join(data_dir, "citm_catalog.json"))
twitter_json = File.read!(Path.join(data_dir, "twitter.json"))

{:ok, canada_data} = RustyJson.decode(canada_json)
{:ok, citm_data} = RustyJson.decode(citm_json)
{:ok, twitter_data} = RustyJson.decode(twitter_json)

IO.puts("Test Data:")
IO.puts("  canada.json:      #{div(byte_size(canada_json), 1024)} KB (geographic, number-heavy)")
IO.puts("  citm_catalog.json: #{div(byte_size(citm_json), 1024)} KB (mixed types)")
IO.puts("  twitter.json:     #{div(byte_size(twitter_json), 1024)} KB (unicode/CJK)")

# Generate stress test data
large_list = Enum.map(1..50_000, fn i -> %{"id" => i, "name" => "item_#{i}", "active" => rem(i, 2) == 0} end)
{:ok, large_json} = RustyJson.encode(large_list)

deep_nested = Enum.reduce(1..100, %{"value" => 1}, fn _, acc -> %{"nested" => acc} end)
{:ok, deep_json} = RustyJson.encode(deep_nested)

wide_object = Map.new(1..5000, fn i -> {"key_#{i}", i} end)
{:ok, wide_json} = RustyJson.encode(wide_object)

IO.puts("  large_list:       #{div(byte_size(large_json), 1024)} KB (50k items)")
IO.puts("  deep_nested:      #{byte_size(deep_json)} bytes (100 levels)")
IO.puts("  wide_object:      #{div(byte_size(wide_json), 1024)} KB (5k keys)")
IO.puts("")

# Benchmark configuration
bench_config = [
  warmup: 2,
  time: 5,
  memory_time: 2,
  reduction_time: 0,
  print: [configuration: false],
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.HTML, file: "bench/output/stress_bench.html", auto_open: false},
    {Benchee.Formatters.Markdown, file: "bench/output/stress_bench.md"}
  ]
]

# ============================================================
# DECODE BENCHMARKS
# ============================================================
IO.puts(String.duplicate("-", 60))
IO.puts("DECODE BENCHMARKS")
IO.puts(String.duplicate("-", 60))

Benchee.run(
  %{
    "RustyJson" => fn input -> RustyJson.decode!(input) end,
    "Jason" => fn input -> Jason.decode!(input) end
  },
  Keyword.merge(bench_config, [
    inputs: %{
      "1. canada.json (2.1MB)" => canada_json,
      "2. citm_catalog.json (1.6MB)" => citm_json,
      "3. twitter.json (617KB)" => twitter_json,
      "4. large_list (50k items)" => large_json,
      "5. deep_nested (100 levels)" => deep_json,
      "6. wide_object (5k keys)" => wide_json
    }
  ])
)

# ============================================================
# ENCODE BENCHMARKS
# ============================================================
IO.puts("\n" <> String.duplicate("-", 60))
IO.puts("ENCODE BENCHMARKS")
IO.puts(String.duplicate("-", 60))

Benchee.run(
  %{
    "RustyJson" => fn input -> RustyJson.encode!(input) end,
    "Jason" => fn input -> Jason.encode!(input) end
  },
  Keyword.merge(bench_config, [
    inputs: %{
      "1. canada (2.1MB)" => canada_data,
      "2. citm_catalog (1.6MB)" => citm_data,
      "3. twitter (617KB)" => twitter_data,
      "4. large_list (50k items)" => large_list,
      "5. deep_nested (100 levels)" => deep_nested,
      "6. wide_object (5k keys)" => wide_object
    }
  ])
)

# ============================================================
# ROUNDTRIP BENCHMARKS
# ============================================================
IO.puts("\n" <> String.duplicate("-", 60))
IO.puts("ROUNDTRIP BENCHMARKS (decode -> encode)")
IO.puts(String.duplicate("-", 60))

Benchee.run(
  %{
    "RustyJson" => fn input -> input |> RustyJson.decode!() |> RustyJson.encode!() end,
    "Jason" => fn input -> input |> Jason.decode!() |> Jason.encode!() end
  },
  Keyword.merge(bench_config, [
    inputs: %{
      "1. canada.json (2.1MB)" => canada_json,
      "2. citm_catalog.json (1.6MB)" => citm_json,
      "3. twitter.json (617KB)" => twitter_json
    }
  ])
)

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("BENCHMARK COMPLETE")
IO.puts(String.duplicate("=", 60))
