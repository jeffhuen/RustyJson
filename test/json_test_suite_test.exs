defmodule JsonTestSuiteTest do
  @moduledoc """
  Validates RustyJson against the comprehensive JSONTestSuite by Nicolas Seriot.
  https://github.com/nst/JSONTestSuite

  Test categories:
  - y_* (95 tests): Valid JSON that parsers MUST accept
  - n_* (188 tests): Invalid JSON that parsers MUST reject
  - i_* (35 tests): Implementation-defined behavior

  The test fixtures are downloaded on first run and stored in test/fixtures/
  (gitignored to keep the package small).
  """

  use ExUnit.Case, async: true

  @fixtures_dir Path.join([__DIR__, "fixtures", "JSONTestSuite"])
  @test_parsing_dir Path.join(@fixtures_dir, "test_parsing")
  @archive_url "https://github.com/nst/JSONTestSuite/archive/refs/heads/master.zip"

  # Implementation-defined tests (i_*) - document our choices
  # These are edge cases where the JSON spec doesn't mandate behavior
  @implementation_accepts [
    # Numbers that underflow to zero or convert to large integers
    "i_number_double_huge_neg_exp.json",
    "i_number_real_underflow.json",
    "i_number_too_big_neg_int.json",
    "i_number_too_big_pos_int.json",
    "i_number_very_big_negative_int.json",
    # Invalid UTF-8 sequences passed through (not validated)
    "i_string_UTF-8_invalid_sequence.json",
    "i_string_UTF8_surrogate_U+D800.json",
    "i_string_invalid_utf-8.json",
    "i_string_iso_latin_1.json",
    "i_string_lone_utf8_continuation_byte.json",
    "i_string_not_in_unicode_range.json",
    "i_string_overlong_sequence_2_bytes.json",
    "i_string_overlong_sequence_6_bytes.json",
    "i_string_overlong_sequence_6_bytes_null.json",
    "i_string_truncated-utf-8.json"
  ]

  @implementation_rejects [
    # Numbers with exponents that overflow
    "i_number_huge_exp.json",
    "i_number_neg_int_huge_exp.json",
    "i_number_pos_double_huge_exp.json",
    "i_number_real_neg_overflow.json",
    "i_number_real_pos_overflow.json",
    # Lone surrogates in \uXXXX escapes (per RFC 7493 I-JSON)
    "i_object_key_lone_2nd_surrogate.json",
    "i_string_1st_surrogate_but_2nd_missing.json",
    "i_string_1st_valid_surrogate_2nd_invalid.json",
    "i_string_incomplete_surrogate_and_escape_valid.json",
    "i_string_incomplete_surrogate_pair.json",
    "i_string_incomplete_surrogates_escape_valid.json",
    "i_string_invalid_lonely_surrogate.json",
    "i_string_invalid_surrogate.json",
    "i_string_inverted_surrogates_U+1D11E.json",
    "i_string_lone_second_surrogate.json",
    # Non-UTF-8 encodings (UTF-16, BOM)
    "i_string_UTF-16LE_with_BOM.json",
    "i_string_utf16BE_no_BOM.json",
    "i_string_utf16LE_no_BOM.json",
    "i_structure_UTF-8_BOM_empty_object.json",
    # Exceeds 128-level nesting limit
    "i_structure_500_nested_arrays.json"
  ]

  setup_all do
    ensure_fixtures_downloaded()
    :ok
  end

  describe "y_* tests (MUST accept)" do
    test "accepts all valid JSON" do
      results = run_tests_matching("y_*.json")

      failures =
        results
        |> Enum.filter(fn {_file, result} -> result != :ok end)
        |> Enum.map(fn {file, {:error, reason}} -> "#{file}: #{reason}" end)

      assert failures == [],
             "Failed to accept valid JSON:\n#{Enum.join(failures, "\n")}"

      # Report count
      assert length(results) >= 90, "Expected at least 90 y_* tests, got #{length(results)}"
    end

    test "accepts all valid JSON with keys: :intern" do
      results = run_tests_matching("y_*.json", keys: :intern)

      failures =
        results
        |> Enum.filter(fn {_file, result} -> result != :ok end)
        |> Enum.map(fn {file, {:error, reason}} -> "#{file}: #{reason}" end)

      assert failures == [],
             "Failed to accept valid JSON with keys: :intern:\n#{Enum.join(failures, "\n")}"
    end
  end

  describe "n_* tests (MUST reject)" do
    test "rejects all invalid JSON" do
      results = run_tests_matching("n_*.json")

      failures =
        results
        |> Enum.filter(fn {_file, result} -> result == :ok end)
        |> Enum.map(fn {file, _} -> file end)

      assert failures == [],
             "Incorrectly accepted invalid JSON:\n#{Enum.join(failures, "\n")}"

      # Report count
      assert length(results) >= 180, "Expected at least 180 n_* tests, got #{length(results)}"
    end
  end

  describe "i_* tests (implementation-defined)" do
    test "handles implementation-defined cases consistently" do
      results = run_tests_matching("i_*.json")

      # Check that our documented accepts actually accept
      for file <- @implementation_accepts do
        case List.keyfind(results, file, 0) do
          {^file, :ok} ->
            :ok

          {^file, {:error, reason}} ->
            flunk("Expected to accept #{file} but got error: #{reason}")

          nil ->
            # File might not exist in current version of test suite
            :ok
        end
      end

      # Check that our documented rejects actually reject
      for file <- @implementation_rejects do
        case List.keyfind(results, file, 0) do
          {^file, {:error, _}} ->
            :ok

          {^file, :ok} ->
            flunk("Expected to reject #{file} but it was accepted")

          nil ->
            :ok
        end
      end

      # Report stats
      {accepts, rejects} = Enum.split_with(results, fn {_, r} -> r == :ok end)

      IO.puts(
        "\n  Implementation-defined: #{length(accepts)} accepted, #{length(rejects)} rejected"
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Helper Functions
  # ---------------------------------------------------------------------------

  defp run_tests_matching(pattern, opts \\ []) do
    Path.wildcard(Path.join(@test_parsing_dir, pattern))
    |> Enum.map(fn path ->
      filename = Path.basename(path)
      content = File.read!(path)

      result =
        case RustyJson.decode(content, opts) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {filename, result}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp ensure_fixtures_downloaded do
    if File.exists?(@test_parsing_dir) do
      :ok
    else
      IO.puts("\nDownloading JSONTestSuite fixtures...")
      download_fixtures()
    end
  end

  defp download_fixtures do
    # Create fixtures directory
    File.mkdir_p!(Path.join(__DIR__, "fixtures"))

    # Download and extract
    zip_path = Path.join([__DIR__, "fixtures", "jsontestsuite.zip"])

    # Use curl to download
    {_, 0} = System.cmd("curl", ["-L", "-o", zip_path, @archive_url], stderr_to_stdout: true)

    # Extract
    {_, 0} =
      System.cmd("unzip", ["-q", "-o", zip_path, "-d", Path.join(__DIR__, "fixtures")],
        stderr_to_stdout: true
      )

    # Rename extracted folder
    extracted_dir = Path.join([__DIR__, "fixtures", "JSONTestSuite-master"])

    if File.exists?(extracted_dir) do
      File.rename!(extracted_dir, @fixtures_dir)
    end

    # Cleanup zip
    File.rm(zip_path)

    IO.puts("JSONTestSuite fixtures downloaded to #{@fixtures_dir}")
  end
end
