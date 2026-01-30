# Struct definitions for stress benchmarks.
# Loaded via Code.require_file before the benchmark runner.

defmodule BenchUser do
  @derive RustyJson.Encoder
  @derive Jason.Encoder
  defstruct [:name, :age, :email]
end

defmodule BenchAddress do
  @derive RustyJson.Encoder
  @derive Jason.Encoder
  defstruct [:street, :city, :zip]
end

defmodule BenchProfile do
  @derive RustyJson.Encoder
  @derive Jason.Encoder
  defstruct [:name, :email, :bio, :city, :country, :age, :active]
end

defmodule BenchEvent do
  @derive RustyJson.Encoder
  @derive Jason.Encoder
  defstruct [:title, :description, :venue, :organizer, :category,
             :url, :location, :date, :capacity, :sold]
end
