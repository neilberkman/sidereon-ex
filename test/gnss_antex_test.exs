defmodule Sidereon.GNSS.AntexTest do
  use ExUnit.Case

  alias Sidereon.GNSS.Antex

  @atx_path Path.join(__DIR__, "fixtures/antex/igs20_pasa_scoa_gps.atx")
  @golden_path Path.join(__DIR__, "fixtures/antex/antex_golden.json")
  @golden File.read!(@golden_path) |> Jason.decode!()
  @antennas @golden["antennas"]

  setup do
    {:ok, antex} = Antex.load(@atx_path)

    matching_antennas =
      Enum.filter(@antennas, fn antenna -> Map.has_key?(antex.antennas, antenna["id"]) end)

    {:ok, antex: antex, matching_antennas: matching_antennas}
  end

  test "load parses and matches golden-backed subset", %{
    antex: antex,
    matching_antennas: matching_antennas
  } do
    parsed_total = map_size(antex.antennas)
    expected_matching = length(matching_antennas)

    assert parsed_total > expected_matching
    assert expected_matching > 0

    expected_frequency_blocks =
      Enum.reduce(matching_antennas, 0, fn antenna, acc ->
        acc + length(antenna["frequencies"])
      end)

    parsed_frequency_blocks =
      Enum.reduce(matching_antennas, 0, fn antenna, acc ->
        acc + map_size(antex.antennas[antenna["id"]].frequencies)
      end)

    assert parsed_frequency_blocks == expected_frequency_blocks
  end

  test "antenna(), pco/2, and sampled pcv/4 agree with golden", %{
    antex: antex,
    matching_antennas: matching_antennas
  } do
    for antenna_golden <- matching_antennas do
      antenna = Antex.antenna(antex, antenna_golden["id"])
      assert %Antex.Antenna{} = antenna
      assert antenna.id == antenna_golden["id"]

      for frequency_golden <- antenna_golden["frequencies"] do
        frequency = frequency_golden["frequency"]
        {:ok, pco} = Antex.pco(antenna, frequency)
        expected_pco = frequency_golden["pco_neu_mm"]

        assert_in_delta elem(pco, 0), expected_pco["north"] / 1000.0, 1.0e-9
        assert_in_delta elem(pco, 1), expected_pco["east"] / 1000.0, 1.0e-9
        assert_in_delta elem(pco, 2), expected_pco["up"] / 1000.0, 1.0e-9

        for sample <- frequency_golden["pcv_samples_mm"] do
          zenith = sample["zenith_deg"]

          value =
            if is_nil(sample["azimuth_deg"]) do
              {:ok, value} = Antex.pcv(antenna, frequency, zenith)
              value
            else
              {:ok, value} = Antex.pcv(antenna, frequency, zenith, sample["azimuth_deg"])
              value
            end

          assert_in_delta value, sample["value"] / 1000.0, 1.0e-12
        end
      end
    end
  end

  test "pcv interpolates linearly in zenith", %{
    antex: antex,
    matching_antennas: matching_antennas
  } do
    {antenna, frequency} =
      Enum.find_value(matching_antennas, fn antenna_golden ->
        parsed_antenna = Antex.antenna(antex, antenna_golden["id"])

        Enum.find_value(parsed_antenna.frequencies, fn {name, frequency_data} ->
          has_noazi = Enum.any?(frequency_data.pcv_samples, &(&1.grid == :noazi))

          if has_noazi, do: {parsed_antenna, name}
        end)
      end)

    parsed = antenna.frequencies[frequency]

    noazi =
      parsed.pcv_samples |> Enum.filter(&(&1.grid == :noazi)) |> Enum.sort_by(& &1.zenith_deg)

    low = Enum.at(noazi, 0)
    high = Enum.at(noazi, 1)
    zenith_mid = (low.zenith_deg + high.zenith_deg) / 2.0
    expected = (low.value_m + high.value_m) / 2.0

    assert {:ok, pcv_mid} = Antex.pcv(antenna, frequency, zenith_mid)
    assert {:ok, pcv_low} = Antex.pcv(antenna, frequency, -10.0)
    assert {:ok, pcv_high} = Antex.pcv(antenna, frequency, 999.0)

    assert_in_delta pcv_mid, expected, 1.0e-12
    assert_in_delta pcv_low, hd(noazi).value_m, 1.0e-12
    assert_in_delta pcv_high, List.last(noazi).value_m, 1.0e-12
  end

  test "pcv interpolates azimuth with wrap", %{antex: antex} do
    {antenna, frequency} =
      Enum.find_value(antex.antennas, fn {_id, parsed_antenna} ->
        Enum.find_value(parsed_antenna.frequencies, fn {name, frequency_data} ->
          azimuth_samples = frequency_data.pcv_samples |> Enum.any?(&(&1.grid == :azi))

          if azimuth_samples, do: {parsed_antenna, name}
        end)
      end)

    parsed = antenna.frequencies[frequency]

    azimuth_samples =
      parsed.pcv_samples
      |> Enum.filter(&(&1.grid == :azi))
      |> Enum.group_by(& &1.azimuth_deg)

    [{_, first_row}, {_, second_row}] =
      azimuth_samples
      |> Map.to_list()
      |> Enum.sort_by(fn {az, _samples} -> az end)
      |> Enum.take(2)

    sample_zenith = hd(first_row).zenith_deg
    first_sample = Enum.find(first_row, fn s -> s.zenith_deg == sample_zenith end)
    second_sample = Enum.find(second_row, fn s -> s.zenith_deg == sample_zenith end)

    zenith = sample_zenith
    az_mid = (first_sample.azimuth_deg + second_sample.azimuth_deg) / 2.0
    expected = (first_sample.value_m + second_sample.value_m) / 2.0

    assert {:ok, pcv_mid} = Antex.pcv(antenna, frequency, zenith, az_mid)
    assert {:ok, pcv_wrapped_high} = Antex.pcv(antenna, frequency, zenith, 359.0)
    assert {:ok, pcv_wrapped_low} = Antex.pcv(antenna, frequency, zenith, -1.0)

    assert_in_delta pcv_mid, expected, 1.0e-12
    assert_in_delta pcv_wrapped_high, pcv_wrapped_low, 1.0e-12
  end

  test "missing antenna and frequency produce explicit errors", %{
    antex: antex,
    matching_antennas: matching_antennas
  } do
    assert nil == Antex.antenna(antex, "MISSING ANTENNA")
    first_antenna = antex.antennas[hd(matching_antennas)["id"]]

    assert Antex.pco(first_antenna, "UNKNOWN") == {:error, :unknown_frequency}
    assert Antex.pcv(first_antenna, "UNKNOWN", 0.0) == {:error, :unknown_frequency}

    assert_raise ArgumentError, fn -> Antex.pco!(first_antenna, "UNKNOWN") end
    assert_raise ArgumentError, fn -> Antex.pcv!(first_antenna, "UNKNOWN", 0.0) end
  end

  test "load! raises on missing file" do
    assert {:error, _} = Antex.load("/tmp/does_not_exist_antenna.atx")
    assert_raise ArgumentError, fn -> Antex.load!("/tmp/does_not_exist_antenna_atx") end
  end
end
