defmodule Sidereon.GNSS.Core.AntennaTerms do
  @moduledoc false

  alias Sidereon.GNSS.Antex
  alias Sidereon.GNSS.Core.Epoch
  alias Sidereon.GNSS.Frequencies

  def frequency_hz(<<system::binary-size(1), "0", band::binary-size(1)>> = frequency),
    do: frequency_hz(system, band, frequency)

  def frequency_hz(<<system::binary-size(1), band::binary-size(1)>> = frequency),
    do: frequency_hz(system, band, frequency)

  def frequency_hz(frequency), do: {:error, {:unsupported_frequency, frequency}}

  def frequency_hz!(frequency) do
    {:ok, hz} = frequency_hz(frequency)
    hz
  end

  def satellite_terms(%Antex{antennas: antennas}) do
    antennas
    |> Map.values()
    |> Enum.filter(&(&1.kind == :satellite))
    |> Enum.map(fn ant ->
      {
        String.trim(ant.serial),
        Epoch.maybe_datetime_tuple(ant.valid_from),
        Epoch.maybe_datetime_tuple(ant.valid_until),
        noazi_frequency_terms(ant)
      }
    end)
  end

  def receiver_frequency_terms(%Antex.Antenna{frequencies: frequencies}) do
    Enum.map(frequencies, fn {label, %Antex.Frequency{} = frequency} ->
      samples =
        Enum.map(frequency.pcv_samples, fn sample ->
          {Map.get(sample, :azimuth_deg), sample.zenith_deg, sample.value_m}
        end)

      {label, frequency.pco_m, samples}
    end)
  end

  def noazi_frequency_terms(%Antex.Antenna{frequencies: frequencies}) do
    Enum.map(frequencies, fn {label, %Antex.Frequency{} = frequency} ->
      {label, frequency.pco_m, noazi_pcv_samples(frequency)}
    end)
  end

  def receiver_correction_term(%Antex.Antenna{} = antenna, frequency) when is_binary(frequency) do
    frequency_block = Map.fetch!(antenna.frequencies, String.trim(frequency))
    {noazi, azi} = split_pcv_samples(frequency_block)

    {frequency_block.pco_m, noazi, azi}
  end

  defp frequency_hz(system, band, frequency) do
    case Frequencies.rinex_band_frequency_hz(system, band, nil) do
      {:ok, hz} -> {:ok, hz}
      {:error, _reason} -> {:error, {:unsupported_frequency, frequency}}
    end
  end

  defp noazi_pcv_samples(%Antex.Frequency{pcv_samples: samples}) do
    samples
    |> Enum.filter(&(&1.grid == :noazi))
    |> Enum.map(&{&1.zenith_deg, &1.value_m})
  end

  defp split_pcv_samples(%Antex.Frequency{pcv_samples: samples}) do
    {noazi, azi} =
      Enum.reduce(samples, {[], []}, fn
        %{grid: :noazi, zenith_deg: zenith_deg, value_m: value_m}, {noazi, azi} ->
          {[{zenith_deg, value_m} | noazi], azi}

        %{grid: :azi, azimuth_deg: azimuth_deg, zenith_deg: zenith_deg, value_m: value_m},
        {noazi, azi} ->
          {noazi, [{azimuth_deg, zenith_deg, value_m} | azi]}
      end)

    {Enum.reverse(noazi), Enum.reverse(azi)}
  end
end
