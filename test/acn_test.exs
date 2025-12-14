defmodule AcnTest do
  use ExUnit.Case
  doctest Acn

  test "greets the world" do
    assert Acn.hello() == :world
  end
end
