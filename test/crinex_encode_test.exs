defmodule Sidereon.GNSS.RINEX.CrinexEncodeTest do
  @moduledoc """
  CRINEX (Hatanaka) encoder round-trip tests: plain RINEX observation text
  encodes to CRINEX and decodes back to the same RINEX, completing the
  decode/encode round trip the binding already exposed in one direction.
  """
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.RINEX.Observations

  @rnx_path "test/fixtures/obs/WTZZ00DEU_R_20201770000_01D_30S_MO_120epoch.rnx"

  setup_all do
    %{rinex: File.read!(@rnx_path)}
  end

  test "encode_crinex/1 produces CRINEX that decodes back to the input RINEX", %{rinex: rinex} do
    assert {:ok, crinex} = Observations.encode_crinex(rinex)
    assert is_binary(crinex)
    assert String.contains?(crinex, "CRINEX VERS")

    assert {:ok, decoded} = Observations.decode_crinex(crinex)
    assert decoded == rinex
  end

  test "encode_crinex/1 output re-parses to the same epochs as the plain RINEX", %{rinex: rinex} do
    assert {:ok, plain} = Observations.parse(rinex)
    assert {:ok, crinex} = Observations.encode_crinex(rinex)
    assert {:ok, from_crinex} = Observations.parse_crinex(crinex)

    assert Observations.epochs(from_crinex) == Observations.epochs(plain)
    assert Observations.observation_codes(from_crinex) == Observations.observation_codes(plain)
  end

  test "encode_crinex/1 returns an error tuple for malformed RINEX" do
    assert {:error, _reason} = Observations.encode_crinex("not a rinex file\n")
  end
end
