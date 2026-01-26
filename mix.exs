defmodule RustyJson.MixProject do
  use Mix.Project

  @version "0.2.0"

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
      dialyzer: dialyzer()
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
      {:rustler, "~> 0.37.0", optional: true, runtime: false},
      {:decimal, "~> 2.0", optional: true},
      {:ex_doc, "~> 0.30", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
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
    "High-performance JSON encoding/decoding for Elixir. A drop-in Jason replacement that's 2-3x faster with 2-4x less memory. Full RFC 8259 compliance and memory safety. Purpose-built Rust NIFs, no serde."
  end

  defp package() do
    [
      maintainers: ["Jeff Huen"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/jeffhuen/rustyjson"},
      files: [
        "lib",
        "mix.exs",
        "README*",
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
        "LICENSE",
        "docs/ARCHITECTURE.md"
      ]
    ]
  end
end
