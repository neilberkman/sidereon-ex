defmodule Sidereon.DocsVersionTest do
  @moduledoc """
  Drift guard: every `{:sidereon, "~> X.Y"}` install snippet shipped in the
  README, the NIF README, and the Livebooks must match the package version in
  `mix.exs`. The 0.35 -> 1.1 releases went out with the README still telling
  users to install `~> 0.35`; this test fails the suite the next time a bump
  skips the docs.
  """
  use ExUnit.Case, async: true

  @doc_files ["README.md", "native/sidereon_nif/README.md", "sidereon.livemd"] ++
               Path.wildcard("examples/*.livemd") ++ Path.wildcard("guides/*.md")

  test "install snippets pin the current major.minor" do
    version = Mix.Project.config()[:version]
    %Version{major: major, minor: minor} = Version.parse!(version)
    expected = "~> #{major}.#{minor}"

    stale =
      for file <- @doc_files,
          File.exists?(file),
          {line, index} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          [_, requirement] <- Regex.scan(~r/\{:sidereon,\s*"([^"]+)"/, line),
          requirement != expected,
          do: "#{file}:#{index} pins #{inspect(requirement)}"

    assert stale == [], """
    mix.exs is at #{version}, so install snippets must use #{inspect(expected)}:
    #{Enum.join(stale, "\n")}
    """
  end
end
