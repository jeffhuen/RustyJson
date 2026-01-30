# Stress Benchmark: RustyJson vs Jason vs Jsonrs
#
# Comprehensive benchmark covering all encoding/decoding workloads:
# - Real-world JSON datasets (number-heavy, mixed, unicode)
# - Synthetic stress tests (large lists, deep nesting, wide objects)
# - Struct encoding (small structs, NIF-eligible structs, mixed)
#
# Run with: MIX_ENV=test mix run bench/stress_bench.exs
#
# MIX_ENV=test disables protocol consolidation, allowing runtime
# @derive to work for benchmark-only struct definitions.

# Load struct definitions from a separate file so they're compiled
# before this module references them.
Code.require_file("bench_structs.ex", Path.dirname(__ENV__.file))

defmodule StressBench do
  def run do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("STRESS BENCHMARK: RustyJson vs Jason vs Jsonrs")
    IO.puts(String.duplicate("=", 60) <> "\n")

    # Load real-world test data
    data_dir = Path.join(Path.dirname(__ENV__.file), "data")

    canada_json = File.read!(Path.join(data_dir, "canada.json"))
    citm_json = File.read!(Path.join(data_dir, "citm_catalog.json"))
    twitter_json = File.read!(Path.join(data_dir, "twitter.json"))

    {:ok, canada_data} = RustyJson.decode(canada_json)
    {:ok, citm_data} = RustyJson.decode(citm_json)
    {:ok, twitter_data} = RustyJson.decode(twitter_json)

    # Generate synthetic plain-data inputs
    large_list = Enum.map(1..50_000, fn i ->
      %{"id" => i, "name" => "item_#{i}", "active" => rem(i, 2) == 0}
    end)
    {:ok, large_json} = RustyJson.encode(large_list)

    deep_nested = Enum.reduce(1..100, %{"value" => 1}, fn _, acc -> %{"nested" => acc} end)
    {:ok, deep_json} = RustyJson.encode(deep_nested)

    wide_object = Map.new(1..5000, fn i -> {"key_#{i}", i} end)
    {:ok, wide_json} = RustyJson.encode(wide_object)

    # Generate struct inputs
    small_struct_list =
      Enum.map(1..10_000, fn i ->
        %BenchUser{name: "user_#{i}", age: rem(i, 80) + 18, email: "user#{i}@test.com"}
      end)

    nif_struct_list =
      Enum.map(1..10_000, fn i ->
        %BenchProfile{
          name: "user_#{i}",
          email: "user#{i}@example.com",
          bio: "Software engineer from city #{i} who enjoys coding and hiking.",
          city: "City_#{rem(i, 100)}",
          country: "Country_#{rem(i, 20)}",
          age: rem(i, 60) + 18,
          active: rem(i, 3) != 0
        }
      end)

    large_nif_struct_list =
      Enum.map(1..5_000, fn i ->
        %BenchEvent{
          title: "Event #{i}: Annual Conference on Technology",
          description: "Join us for the #{i}th annual conference featuring keynotes, workshops, and networking.",
          venue: "Convention Center Hall #{rem(i, 10) + 1}, Building #{rem(i, 5) + 1}",
          organizer: "Organization #{rem(i, 50)}",
          category: "category_#{rem(i, 8)}",
          url: "https://events.example.com/event/#{i}/register",
          location: "#{rem(i, 200) + 1} Main Street, City #{rem(i, 100)}, State #{rem(i, 50)}",
          date: "2025-#{String.pad_leading("#{rem(i, 12) + 1}", 2, "0")}-#{String.pad_leading("#{rem(i, 28) + 1}", 2, "0")}",
          capacity: i * 10,
          sold: rem(i * 7, i * 10)
        }
      end)

    mixed_struct_list =
      Enum.map(1..5_000, fn i ->
        %{
          "id" => i,
          "label" => "item_#{i}",
          "active" => rem(i, 2) == 0,
          "user" => %BenchUser{name: "user_#{i}", age: 25, email: "u#{i}@test.com"},
          "address" => %BenchAddress{street: "#{i} Main St", city: "Springfield", zip: "0#{rem(i, 90000) + 10000}"}
        }
      end)

    struct_map_values =
      Map.new(1..10_000, fn i ->
        {"key_#{i}", %BenchUser{name: "user_#{i}", age: rem(i, 80) + 18, email: "user#{i}@test.com"}}
      end)

    IO.puts("Test Data:")
    IO.puts("  Real-world:")
    IO.puts("    canada.json:       #{div(byte_size(canada_json), 1024)} KB (geographic, number-heavy)")
    IO.puts("    citm_catalog.json: #{div(byte_size(citm_json), 1024)} KB (mixed types)")
    IO.puts("    twitter.json:      #{div(byte_size(twitter_json), 1024)} KB (unicode/CJK)")
    IO.puts("  Synthetic (plain data):")
    IO.puts("    large_list:        #{div(byte_size(large_json), 1024)} KB (50k map items)")
    IO.puts("    deep_nested:       #{byte_size(deep_json)} bytes (100 levels)")
    IO.puts("    wide_object:       #{div(byte_size(wide_json), 1024)} KB (5k keys)")
    IO.puts("  Structs:")
    IO.puts("    small_structs:     10k BenchUser (3 fields, inline iodata path)")
    IO.puts("    nif_structs:       10k BenchProfile (7 fields, NIF-eligible)")
    IO.puts("    large_nif_structs: 5k BenchEvent (10 fields, string-heavy, NIF-eligible)")
    IO.puts("    mixed_structs:     5k maps containing BenchUser + BenchAddress")
    IO.puts("    struct_map_values: 10k map entries with BenchUser values")
    IO.puts("")

    bench_config = [
      warmup: 2,
      time: 5,
      memory_time: 2,
      reduction_time: 0,
      print: [configuration: false],
      formatters: [Benchee.Formatters.Console]
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
        "Jason" => fn input -> Jason.decode!(input) end,
        "Jsonrs" => fn input -> Jsonrs.decode!(input) end
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
    # ENCODE BENCHMARKS — PLAIN DATA
    # ============================================================
    IO.puts("\n" <> String.duplicate("-", 60))
    IO.puts("ENCODE BENCHMARKS — PLAIN DATA (maps/lists)")
    IO.puts(String.duplicate("-", 60))

    Benchee.run(
      %{
        "RustyJson" => fn input -> RustyJson.encode!(input) end,
        "Jason" => fn input -> Jason.encode!(input) end,
        "Jsonrs" => fn input -> Jsonrs.encode!(input) end
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
    # ENCODE BENCHMARKS — STRUCTS
    # ============================================================
    IO.puts("\n" <> String.duplicate("-", 60))
    IO.puts("ENCODE BENCHMARKS — STRUCTS (protocol dispatch)")
    IO.puts(String.duplicate("-", 60))

    # Note: Jsonrs handles structs by stripping __struct__ and encoding as
    # plain maps (no protocol dispatch), so it's included for reference but
    # isn't doing the same work as RustyJson/Jason.

    Benchee.run(
      %{
        "RustyJson" => fn input -> RustyJson.encode!(input) end,
        "Jason" => fn input -> Jason.encode!(input) end,
        "Jsonrs" => fn input -> Jsonrs.encode!(input) end
      },
      Keyword.merge(bench_config, [
        inputs: %{
          "1. 10k small structs (3 fields)" => small_struct_list,
          "2. 10k NIF structs (7 fields)" => nif_struct_list,
          "3. 5k large NIF structs (10 fields)" => large_nif_struct_list,
          "4. 5k mixed maps+structs" => mixed_struct_list,
          "5. 10k struct map values" => struct_map_values
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
        "Jason" => fn input -> input |> Jason.decode!() |> Jason.encode!() end,
        "Jsonrs" => fn input -> input |> Jsonrs.decode!() |> Jsonrs.encode!() end
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
  end
end

StressBench.run()
