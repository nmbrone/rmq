defmodule RMQ.UtilsTest do
  use ExUnit.Case, async: true
  import RMQ.Utils

  @params ["password", :password]

  defmodule Struct do
    defstruct password: "password"
  end

  describe "filter_values/1" do
    test "removes sensitive data from maps with binary keys" do
      values = %{"password" => "password", "other" => "other"}
      assert %{"password" => "[FILTERED]", "other" => "other"} == filter_values(values, @params)
    end

    test "removes sensitive data from maps with atom keys" do
      values = %{password: "password", other: "other"}
      assert %{password: "[FILTERED]", other: "other"} == filter_values(values, @params)
    end

    test "removes sensitive data from keywords lists" do
      values = [password: "password", other: "other"]
      assert [password: "[FILTERED]", other: "other"] == filter_values(values, @params)
    end

    test "removes sensitive data from lists" do
      values = [%{other: "other"}, %{password: "password", other: "other"}]

      assert [%{other: "other"}, %{password: "[FILTERED]", other: "other"}] ==
               filter_values(values, @params)
    end

    test "returns other data types untouched" do
      assert nil == filter_values(nil, @params)
      assert 1 == filter_values(1, @params)
      assert "string" == filter_values("string", @params)
      assert %Struct{} == filter_values(%Struct{}, @params)
    end
  end
end
