defmodule Sidereon.GNSS.PreciseEphemerisSample do
  @moduledoc """
  One precise-ephemeris sample: a satellite's ECEF position (and optional clock)
  at one epoch, in SI units.

  This is the canonical, serialization-independent intermediate representation of
  a precise orbit/clock product. SP3 text is one serialization of it;
  `Sidereon.GNSS.SP3.precise_ephemeris_samples/1` extracts the same samples from a
  parsed product, and `Sidereon.GNSS.PreciseEphemeris.from_samples/1` rebuilds an
  interpolatable source from them, with no text in the loop.

  ## Fields

    * `:sat` - the canonical SP3/RINEX satellite token, e.g. `"G01"`.
    * `:epoch` - the sample epoch as either a split Julian date or exact
      nanoseconds since J2000, tagged with its time scale.
    * `:position_ecef_m` - satellite position in the ITRF/IGS ECEF frame, in
      meters, as `{x_m, y_m, z_m}`.
    * `:clock_s` - satellite clock offset in seconds, or `nil` when no clock
      estimate exists.
    * `:clock_event` - mirrors the SP3 `E` clock-event flag. When `true` this
      epoch marks a clock discontinuity and the interpolator splits the clock arc
      here (it never interpolates a clock across a reset). Defaults to `false`.
  """

  alias Sidereon.GNSS.Core.Types

  @enforce_keys [:sat, :epoch, :position_ecef_m]
  defstruct [:sat, :epoch, :position_ecef_m, :clock_s, clock_event: false]

  @type vec3 :: {float(), float(), float()}

  @type epoch ::
          %{time_scale: String.t(), jd_whole: float(), jd_fraction: float()}
          | %{time_scale: String.t(), nanos_since_j2000: integer()}

  @type t :: %__MODULE__{
          sat: String.t(),
          epoch: epoch(),
          position_ecef_m: vec3(),
          clock_s: float() | nil,
          clock_event: boolean()
        }

  @doc false
  @spec to_nif_tuple(t()) :: {:ok, tuple()} | {:error, term()}
  def to_nif_tuple(%__MODULE__{
        sat: sat,
        epoch: epoch,
        position_ecef_m: position,
        clock_s: clock_s,
        clock_event: clock_event
      })
      when is_map(epoch) and (is_number(clock_s) or is_nil(clock_s)) and is_boolean(clock_event) do
    with {:ok, {position_x, position_y, position_z}} <-
           Types.normalize_ecef(position, :bad_position),
         {:ok, letter, prn} <- Types.parse_sat_id(sat),
         {:ok, nif_epoch} <- epoch_to_nif(epoch) do
      clock = if !is_nil(clock_s), do: clock_s * 1.0
      {:ok, {letter, prn, nif_epoch, {position_x, position_y, position_z}, clock, clock_event}}
    end
  end

  def to_nif_tuple(%__MODULE__{}), do: {:error, :bad_sample}

  @doc false
  @spec from_nif_tuple(tuple()) :: t()
  def from_nif_tuple({letter, prn, epoch, position, clock_s, clock_event}) do
    %__MODULE__{
      sat: sat_token(letter, prn),
      epoch: epoch_from_nif(epoch),
      position_ecef_m: position,
      clock_s: clock_s,
      clock_event: clock_event
    }
  end

  defp epoch_to_nif(%{time_scale: scale, jd_whole: whole, jd_fraction: fraction} = epoch)
       when is_binary(scale) and is_number(whole) and is_number(fraction) and not is_map_key(epoch, :nanos_since_j2000) do
    {:ok, %{time_scale: scale, julian_date: {whole * 1.0, fraction * 1.0}, nanos_since_j2000: nil}}
  end

  defp epoch_to_nif(%{time_scale: scale, nanos_since_j2000: nanos} = epoch)
       when is_binary(scale) and is_integer(nanos) and not is_map_key(epoch, :jd_whole) and
              not is_map_key(epoch, :jd_fraction) do
    {:ok, %{time_scale: scale, julian_date: nil, nanos_since_j2000: Integer.to_string(nanos)}}
  end

  defp epoch_to_nif(_epoch), do: {:error, :bad_epoch}

  defp epoch_from_nif(%{time_scale: scale, julian_date: {whole, fraction}}),
    do: %{time_scale: scale, jd_whole: whole, jd_fraction: fraction}

  defp epoch_from_nif(%{time_scale: scale, nanos_since_j2000: nanos}) when is_binary(nanos),
    do: %{time_scale: scale, nanos_since_j2000: String.to_integer(nanos)}

  defp sat_token(letter, prn) do
    letter <> String.pad_leading(Integer.to_string(prn), 2, "0")
  end
end
