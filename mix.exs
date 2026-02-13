defmodule RustyJson.MixProject do
  use Mix.Project

  @version "0.3.8"

  def project do
    [
      app: :rustyjson,
      version: @version,
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: "https://github.com/jeffhuen/rustyjson",
      dialyzer: dialyzer(),
      test_paths: ["test"],
      test_ignore_filters: [~r"/fixtures/"]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:rustler_precompiled, "~> 0.8"},
      {:rustler, "~> 0.37", optional: true},
      {:decimal, "~> 2.0", optional: true},
      {:ex_doc, "~> 0.30", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ] ++ bench_deps()
  end

  # Benchmark-only deps — remove this block when no longer needed
  defp bench_deps do
    [
      {:benchee, "~> 1.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_apps: [:decimal],
      flags: [
        :unmatched_returns,
        :error_handling,
        :no_opaque,
        :unknown,
        :no_return
      ]
    ]
  end

  defp description() do
    "Ultra-fast JSON encoding/decoding for Elixir. A drop-in Jason replacement that's 2-3x faster with 2-4x less memory, plus key interning for up to 2x faster bulk decoding. Full RFC 8259 compliance and memory safety. Purpose-built Rust NIFs, no serde."
  end

  defp package() do
    [
      maintainers: ["Jeff Huen"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/jeffhuen/rustyjson",
        "Changelog" => "https://hexdocs.pm/rustyjson/changelog.html"
      },
      files: [
        "lib",
        "mix.exs",
        "README*",
        "CHANGELOG.md",
        "LICENSE",
        "docs",
        "native/rustyjson/src",
        "native/rustyjson/.cargo",
        "native/rustyjson/Cargo*",
        "checksum-*.exs"
      ]
    ]
  end

  defp docs() do
    [
      main: "readme",
      name: "RustyJson",
      source_ref: "v#{@version}",
      canonical: "http://hexdocs.pm/rustyjson",
      source_url: "https://github.com/jeffhuen/rustyjson",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "docs/ARCHITECTURE.md",
        "docs/BENCHMARKS.md",
        "LICENSE"
      ],
      groups_for_extras: [
        Overview: ["README.md", "CHANGELOG.md"],
        Internals: ["docs/ARCHITECTURE.md", "docs/BENCHMARKS.md"]
      ],
      groups_for_modules: [
        Encoding: [
          RustyJson,
          RustyJson.Encoder,
          RustyJson.Encode,
          RustyJson.Fragment,
          RustyJson.Helpers
        ],
        Decoding: [RustyJson.Decoder, RustyJson.OrderedObject],
        Formatting: [RustyJson.Formatter, RustyJson.Sigil],
        Errors: [RustyJson.EncodeError, RustyJson.DecodeError]
      ]
    ]
  end
end
