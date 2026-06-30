defmodule Sidereon.GNSS.RINEX.ObservationsSerializeTest do
  @moduledoc """
  RINEX 3 observation serializer round-trip tests: parse -> to_rinex_string ->
  re-parse reproduces the same header and epochs.
  """
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.RINEX.Observations

  @rnx_path "test/fixtures/obs/WTZZ00DEU_R_20201770000_01D_30S_MO_120epoch.rnx"

  setup_all do
    {:ok, obs} = @rnx_path |> File.read!() |> Observations.parse()
    %{obs: obs}
  end

  test "to_rinex_string/1 returns deterministic RINEX text", %{obs: obs} do
    text = Observations.to_rinex_string(obs)
    assert is_binary(text)
    assert Observations.to_rinex_string(obs) == text
  end

  test "round-trips through parse with identical header and epochs", %{obs: obs} do
    text = Observations.to_rinex_string(obs)
    assert {:ok, reparsed} = Observations.parse(text)

    assert Observations.epochs(reparsed) == Observations.epochs(obs)
    assert Observations.observation_codes(reparsed) == Observations.observation_codes(obs)
    assert Observations.approx_position(reparsed) == Observations.approx_position(obs)
  end
end
