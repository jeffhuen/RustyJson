defmodule JasonCompatTest.UserWithJason do
  @derive {Jason.Encoder, only: [:id, :name]}
  defstruct [:id, :name, :password_hash]
end

defmodule JasonCompatTest.CustomEncoder do
  defstruct [:value]
end

defimpl Jason.Encoder, for: JasonCompatTest.CustomEncoder do
  def encode(%{value: v}, _opts) do
    [?", "custom:", to_string(v), ?"]
  end
end

defmodule JasonCompatTest do
  use ExUnit.Case, async: true

  alias JasonCompatTest.CustomEncoder
  alias JasonCompatTest.UserWithJason

  describe "Jason.Encoder fallback" do
    test "respects @derive Jason.Encoder" do
      user = %UserWithJason{id: 1, name: "Alice", password_hash: "secret"}

      # With protocol: true, should use Jason.Encoder fallback
      result = RustyJson.encode!(user, protocol: true)
      decoded = RustyJson.decode!(result)

      assert decoded["id"] == 1
      assert decoded["name"] == "Alice"
      refute Map.has_key?(decoded, "password_hash")
    end

    test "uses custom Jason.Encoder implementation" do
      custom = %CustomEncoder{value: 42}
      result = RustyJson.encode!(custom, protocol: true)

      assert result == ~s("custom:42")
    end
  end

  describe "Jason.Fragment support" do
    test "handles Jason.Fragment structs with function" do
      fragment = Jason.Fragment.new(~s({"from":"jason"}))
      assert is_function(fragment.encode, 1)

      result = RustyJson.encode!(%{data: fragment}, protocol: true)

      assert result == ~s({"data":{"from":"jason"}})
    end

    test "handles RustyJson.Fragment structs" do
      fragment = RustyJson.Fragment.new(~s({"from":"rusty"}))

      result = RustyJson.encode!(%{data: fragment})

      assert result == ~s({"data":{"from":"rusty"}})
    end

    test "handles iolist in fragments" do
      fragment = RustyJson.Fragment.new(["{", ~s("a":), "1", "}"])

      result = RustyJson.encode!(fragment)
      assert result == ~s({"a":1})
    end
  end
end
