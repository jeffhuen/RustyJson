defmodule RustyJson.PhoenixLiveViewJSTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.JS

  describe "Phoenix.LiveView.JS encoding" do
    test "encodes a top-level JS command through to_encodable/1" do
      js = JS.toggle_class("is-active", to: "#target")

      assert RustyJson.decode!(RustyJson.encode!(js)) == [
               ["toggle_class", %{"names" => ["is-active"], "to" => "#target"}]
             ]
    end

    test "encodes a JS command nested in a push_event-style payload" do
      payload = %{toggle: JS.toggle_class("is-active", to: "#target")}

      assert RustyJson.decode!(RustyJson.encode!(payload)) == %{
               "toggle" => [["toggle_class", %{"names" => ["is-active"], "to" => "#target"}]]
             }
    end
  end
end
