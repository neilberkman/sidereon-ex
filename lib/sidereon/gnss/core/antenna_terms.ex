defmodule Sidereon.GNSS.Core.AntennaTerms do
  @moduledoc false

  alias Sidereon.GNSS.Antex
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

  # Every satellite block in file order, each validity interval of one id
  # included, so the correction selects the interval valid at each epoch.
  def satellite_terms(%Antex{blocks: blocks}) do
    blocks
    |> Enum.filter(&(&1.kind == :satellite))
    |> Enum.map(fn ant ->
      {
        String.trim(ant.serial),
        validity_term(ant.valid_from),
        validity_term(ant.valid_until),
        noazi_frequency_terms(ant)
      }
    end)
  end

  def receiver_frequency_terms(%Antex.Antenna{frequencies: frequencies}) do
    Enum.map(frequencies, fn %Antex.Frequency{} = frequency ->
      samples =
        Enum.map(frequency.pcv_samples, fn sample ->
          {Map.get(sample, :azimuth_deg), sample.zenith_deg, sample.value_m}
        end)

      {frequency.frequency, frequency.pco_m, samples}
    end)
  end

  def noazi_frequency_terms(%Antex.Antenna{frequencies: frequencies}) do
    Enum.map(frequencies, fn %Antex.Frequency{} = frequency ->
      {frequency.frequency, frequency.pco_m, noazi_pcv_samples(frequency)}
    end)
  end

  # The section the label selects, refusing an ambiguous label as the lookup
  # does; the caller has checked the label resolves.
  def receiver_correction_term(%Antex.Antenna{} = antenna, frequency) when is_binary(frequency) do
    {:ok, frequency_block} = Antex.frequency(antenna, frequency)
    {noazi, azi} = split_pcv_samples(frequency_block)

    {frequency_block.pco_m, noazi, azi}
  end

  # A validity bound with its exact fraction of a second, `(digits, scale)`.
  defp validity_term(nil), do: nil

  defp validity_term(%Antex.Epoch{} = epoch) do
    {{epoch.year, epoch.month, epoch.day}, {epoch.hour, epoch.minute, epoch.second},
     {epoch.fraction_digits, epoch.fraction_scale}}
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

        %{grid: :azi, azimuth_deg: azimuth_deg, zenith_deg: zenith_deg, value_m: value_m}, {noazi, azi} ->
          {noazi, [{azimuth_deg, zenith_deg, value_m} | azi]}
      end)

    {Enum.reverse(noazi), Enum.reverse(azi)}
  end
end
