defmodule EscriptTool do
  @moduledoc """
  Documentation for `EscriptTool`.
  """

  @doc """
  Hello world.

  ## Examples

      iex> EscriptTool.hello()
      :world

  """
  def hello do
    :world
  end

  def main(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [help: :boolean], aliases: [h: :help])

    cond do
      opts[:help] ->
        IO.puts("Usage: escript_tool [--help]")

      invalid != [] ->
        IO.puts(:stderr, "Invalid options: #{inspect(invalid)}")
        System.halt(2)

      true ->
        IO.puts(hello())
    end
  end
end
