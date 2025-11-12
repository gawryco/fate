defmodule FateTest do
  use ExUnit.Case
  doctest Fate

  test "greets the world" do
    assert Fate.hello() == :world
  end
end
