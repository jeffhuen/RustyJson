# Memory Benchmark: RustyJson vs Jason
#
# This script measures BEAM heap memory usage accurately by:
# 1. Running GC before measurements
# 2. Measuring :erlang.memory(:total) delta
# 3. Averaging multiple runs
#
# Usage: mix run bench/memory_bench.exs

defmodule MemoryBench do
  def run do
    datasets = [
      {"canada.json", "bench/data/canada.json"},
      {"citm_catalog.json", "bench/data/citm_catalog.json"},
      {"twitter.json", "bench/data/twitter.json"}
    ]

    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("Memory Benchmark: RustyJson vs Jason")
    IO.puts(String.duplicate("=", 70))

    for {name, path} <- datasets do
      case File.read(path) do
        {:ok, json} ->
          IO.puts("\n## #{name} (#{format_size(byte_size(json))})")
          IO.puts(String.duplicate("-", 50))

          # Decode to get Elixir data structure
          {:ok, data} = RustyJson.decode(json)

          # Measure encode
          IO.puts("\n### Encode (Elixir map -> JSON string)")
          measure_encode(data)

          # Measure decode
          IO.puts("\n### Decode (JSON string -> Elixir map)")
          measure_decode(json)

          # Measure roundtrip
          IO.puts("\n### Roundtrip (decode + encode)")
          measure_roundtrip(json)

        {:error, _} ->
          IO.puts("\nSkipping #{name} - file not found")
          IO.puts("Run: curl -LO https://raw.githubusercontent.com/miloyip/nativejson-benchmark/master/data/#{name}")
      end
    end

    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("Note: Memory measured via :erlang.memory(:total) delta")
    IO.puts("RustyJson also uses Rust heap memory (not visible to BEAM)")
    IO.puts(String.duplicate("=", 70) <> "\n")
  end

  defp measure_encode(data) do
    runs = 10

    rusty_mem = measure_memory(runs, fn -> RustyJson.encode!(data) end)
    jason_mem = measure_memory(runs, fn -> Jason.encode!(data) end)

    print_comparison("RustyJson", rusty_mem, "Jason", jason_mem)
  end

  defp measure_decode(json) do
    runs = 10

    rusty_mem = measure_memory(runs, fn -> RustyJson.decode!(json) end)
    jason_mem = measure_memory(runs, fn -> Jason.decode!(json) end)

    print_comparison("RustyJson", rusty_mem, "Jason", jason_mem)
  end

  defp measure_roundtrip(json) do
    runs = 10

    rusty_mem = measure_memory(runs, fn ->
      data = RustyJson.decode!(json)
      RustyJson.encode!(data)
    end)

    jason_mem = measure_memory(runs, fn ->
      data = Jason.decode!(json)
      Jason.encode!(data)
    end)

    print_comparison("RustyJson", rusty_mem, "Jason", jason_mem)
  end

  defp measure_memory(runs, fun) do
    # Warm up
    for _ <- 1..3, do: fun.()

    # Measure multiple runs
    measurements =
      for _ <- 1..runs do
        :erlang.garbage_collect()
        Process.sleep(10)

        before = :erlang.memory(:total)
        result = fun.()
        after_mem = :erlang.memory(:total)

        # Keep result alive to prevent premature GC
        :erlang.phash2(result)

        max(0, after_mem - before)
      end

    # Return average, excluding outliers
    measurements
    |> Enum.sort()
    |> Enum.drop(2)  # Drop 2 lowest
    |> Enum.reverse()
    |> Enum.drop(2)  # Drop 2 highest
    |> then(fn list ->
      if length(list) > 0 do
        Enum.sum(list) / length(list)
      else
        Enum.sum(measurements) / length(measurements)
      end
    end)
    |> round()
  end

  defp print_comparison(name1, mem1, name2, mem2) do
    IO.puts("  #{name1}: #{format_size(mem1)}")
    IO.puts("  #{name2}: #{format_size(mem2)}")

    cond do
      mem1 == 0 and mem2 == 0 ->
        IO.puts("  Ratio: N/A (both negligible)")

      mem1 == 0 ->
        IO.puts("  Ratio: #{name1} uses negligible BEAM memory")

      mem2 == 0 ->
        IO.puts("  Ratio: #{name2} uses negligible BEAM memory")

      mem1 < mem2 ->
        ratio = Float.round(mem2 / mem1, 1)
        IO.puts("  Ratio: #{name1} uses #{ratio}x less BEAM memory")

      mem2 < mem1 ->
        ratio = Float.round(mem1 / mem2, 1)
        IO.puts("  Ratio: #{name2} uses #{ratio}x less BEAM memory")

      true ->
        IO.puts("  Ratio: roughly equal")
    end
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 2)} MB"
end

MemoryBench.run()
