defmodule RustyJson.LibraryGuidelinesTest do
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)

  test "library defaults are not read from RustyJson application config" do
    source =
      Path.join(@root, "lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.map_join("\n", &File.read!/1)

    refute source =~ "Application.compile_env(:rustyjson"
    refute source =~ "Application.get_env(:rustyjson"
    refute source =~ "Application.fetch_env(:rustyjson"
  end
end
