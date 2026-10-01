defmodule EscriptToolTest do
  use ExUnit.Case
  doctest EscriptTool

  test "greets the world" do
    assert EscriptTool.hello() == :world
  end
end
