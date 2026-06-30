defmodule Sidereon.GNSS.SerializeRoundTripTest do
  @moduledoc """
  Round-trip tests for the ANTEX and RINEX NAV serializers added for capability
  parity: parse -> encode -> re-parse reproduces the same product.
  """
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Antex
  alias Sidereon.GNSS.Broadcast

  @atx_path Path.join(__DIR__, "fixtures/ppp/igs20_zim2_gps.atx")
  @nav_path Path.join(__DIR__, "fixtures/nav/ESBC00DNK_R_20201770000_01D_MN.rnx")

  describe "Antex.encode/1" do
    setup do
      {:ok, antex} = @atx_path |> File.read!() |> Antex.parse()
      %{antex: antex}
    end

    test "returns deterministic ANTEX text", %{antex: antex} do
      text = Antex.encode(antex)
      assert is_binary(text)
      assert Antex.encode(antex) == text
    end

    test "round-trips through parse with identical antenna ids and PCO", %{antex: antex} do
      text = Antex.encode(antex)
      assert {:ok, reparsed} = Antex.parse(text)

      assert Map.keys(reparsed.antennas) == Map.keys(antex.antennas)

      id = antex.antennas |> Map.keys() |> List.first()
      original = Antex.antenna(antex, id)
      round_tripped = Antex.antenna(reparsed, id)
      freq = original.frequencies |> Map.keys() |> List.first()

      assert Antex.pco(round_tripped, freq) == Antex.pco(original, freq)
    end
  end

  describe "Broadcast.encode_nav/1" do
    setup do
      nav = Broadcast.load!(@nav_path)
      %{nav: nav}
    end

    test "returns deterministic RINEX NAV text", %{nav: nav} do
      text = Broadcast.encode_nav(nav)
      assert is_binary(text)
      assert Broadcast.encode_nav(nav) == text
    end

    test "round-trips through parse with identical records", %{nav: nav} do
      text = Broadcast.encode_nav(nav)
      assert {:ok, reparsed} = Broadcast.parse(text)

      assert Broadcast.record_count(reparsed) == Broadcast.record_count(nav)
      assert Broadcast.records(reparsed) == Broadcast.records(nav)
    end
  end
end
