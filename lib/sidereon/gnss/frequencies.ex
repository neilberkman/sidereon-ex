defmodule Sidereon.GNSS.Frequencies do
  @moduledoc """
  Canonical GNSS carrier-frequency lookups.

  This module exposes the same carrier table used by the core GNSS algorithms.
  Fixed-frequency lookups use canonical band atoms such as `:l1`, `:e5a`, or
  `:b3i`. RINEX observation-band lookups use the one-character RINEX band digit
  and accept a GLONASS FDMA channel for G1/G2.

  Frequencies are returned in hertz and wavelengths in metres. All public
  functions return `{:ok, value}` or `{:error, reason}` and never raise for
  unknown systems or bands.
  """

  alias Sidereon.NIF

  @typedoc ~s(GNSS system letter such as `"G"`, `"E"`, `"C"`, or `"R"`.)
  @type system :: String.t()

  @typedoc """
  Canonical carrier band.

  Supported fixed-frequency bands are `:l1`, `:l2`, `:l5`, `:e1`, `:e5a`,
  `:e5b`, `:e5`, `:e6`, `:b1c`, `:b1i`, `:b2a`, `:b2b`, `:b2`, and `:b3i`.
  GLONASS `:g1` and `:g2` are channel-derived and are available through the
  RINEX band functions.
  """
  @type carrier_band ::
          :l1
          | :l2
          | :l5
          | :e1
          | :e5a
          | :e5b
          | :e5
          | :e6
          | :b1c
          | :b1i
          | :b2a
          | :b2b
          | :b2
          | :b3i
          | :g1
          | :g2

  @typedoc "One-character RINEX observation band digit, for example `\"1\"`."
  @type rinex_band :: String.t()

  @typedoc "Frequency lookup error."
  @type error ::
          {:unknown_system, term()}
          | {:unknown_band, term(), term()}
          | {:no_default_pair, term()}
          | {:missing_glonass_channel, term(), term()}
          | {:invalid_channel, term()}

  @doc """
  Return the fixed carrier frequency for `system` and canonical `band`.

  GLONASS G1/G2 frequencies depend on the satellite FDMA channel and therefore
  are not fixed carrier frequencies. Use `rinex_band_frequency_hz/3` with a
  channel for those carriers.
  """
  @spec carrier_frequency_hz(system(), carrier_band()) :: {:ok, float()} | {:error, error()}
  def carrier_frequency_hz(system, band) when is_binary(system) and is_atom(band) do
    case NIF.frequencies_carrier_frequency_hz(system, Atom.to_string(band)) do
      {:ok, frequency_hz} -> {:ok, frequency_hz}
      {:error, :unknown_system} -> {:error, {:unknown_system, system}}
      {:error, :unknown_band} -> {:error, {:unknown_band, system, band}}
    end
  end

  def carrier_frequency_hz(system, band), do: {:error, {:unknown_band, system, band}}

  @doc """
  Return the fixed carrier wavelength for `system` and canonical `band`.
  """
  @spec wavelength_m(system(), carrier_band()) :: {:ok, float()} | {:error, error()}
  def wavelength_m(system, band) when is_binary(system) and is_atom(band) do
    case NIF.frequencies_wavelength_m(system, Atom.to_string(band)) do
      {:ok, wavelength_m} -> {:ok, wavelength_m}
      {:error, :unknown_system} -> {:error, {:unknown_system, system}}
      {:error, :unknown_band} -> {:error, {:unknown_band, system, band}}
    end
  end

  def wavelength_m(system, band), do: {:error, {:unknown_band, system, band}}

  @doc """
  Return a RINEX observation-band frequency in hertz.

  `band` is the RINEX band digit from an observation code. For GLONASS band
  `"1"` (G1) and `"2"` (G2), pass the parsed FDMA channel from the observation
  file's `GLONASS SLOT / FRQ #` header records.
  """
  @spec rinex_band_frequency_hz(system(), rinex_band(), integer() | nil) ::
          {:ok, float()} | {:error, error()}
  def rinex_band_frequency_hz(system, band, glonass_channel)
      when is_binary(system) and is_binary(band) and
             (is_integer(glonass_channel) or is_nil(glonass_channel)) do
    case NIF.frequencies_rinex_band_frequency_hz(system, band, glonass_channel) do
      {:ok, frequency_hz} -> {:ok, frequency_hz}
      {:error, :unknown_system} -> {:error, {:unknown_system, system}}
      {:error, :unknown_band} -> {:error, {:unknown_band, system, band}}
      {:error, :missing_glonass_channel} -> {:error, {:missing_glonass_channel, system, band}}
      {:error, :invalid_channel} -> {:error, {:invalid_channel, glonass_channel}}
    end
  end

  def rinex_band_frequency_hz(system, band, _glonass_channel),
    do: {:error, {:unknown_band, system, band}}

  @doc """
  Return a RINEX observation-band wavelength in metres.

  This uses the same system, band, and GLONASS-channel rules as
  `rinex_band_frequency_hz/3`.
  """
  @spec rinex_band_wavelength_m(system(), rinex_band(), integer() | nil) ::
          {:ok, float()} | {:error, error()}
  def rinex_band_wavelength_m(system, band, glonass_channel)
      when is_binary(system) and is_binary(band) and
             (is_integer(glonass_channel) or is_nil(glonass_channel)) do
    case NIF.frequencies_rinex_band_wavelength_m(system, band, glonass_channel) do
      {:ok, wavelength_m} -> {:ok, wavelength_m}
      {:error, :unknown_system} -> {:error, {:unknown_system, system}}
      {:error, :unknown_band} -> {:error, {:unknown_band, system, band}}
      {:error, :missing_glonass_channel} -> {:error, {:missing_glonass_channel, system, band}}
      {:error, :invalid_channel} -> {:error, {:invalid_channel, glonass_channel}}
    end
  end

  def rinex_band_wavelength_m(system, band, _glonass_channel),
    do: {:error, {:unknown_band, system, band}}

  @doc """
  Return the standard dual-frequency ionosphere-free pair for `system`.

  GPS, Galileo, and BeiDou have standard pairs. GLONASS FDMA frequencies are
  channel-derived, so no constellation-wide default pair is returned.
  """
  @spec default_pair(system()) :: {:ok, {carrier_band(), carrier_band()}} | {:error, error()}
  def default_pair(system) when is_binary(system) do
    case NIF.frequencies_default_pair(system) do
      {:ok, {band1, band2}} -> {:ok, {String.to_atom(band1), String.to_atom(band2)}}
      {:error, :unknown_system} -> {:error, {:unknown_system, system}}
      {:error, :no_default_pair} -> {:error, {:no_default_pair, system}}
    end
  end

  def default_pair(system), do: {:error, {:unknown_system, system}}
end
