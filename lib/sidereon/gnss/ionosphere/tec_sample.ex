defmodule Sidereon.GNSS.Ionosphere.TecSample do
  @moduledoc """
  One IONEX vertical-TEC grid-node sample.

  The epoch is a split Julian date with a time-scale tag. Latitude and longitude
  are in degrees, vertical TEC and optional RMS are in TECU.
  """

  @enforce_keys [:epoch, :lat_deg, :lon_deg, :vtec_tecu]
  defstruct [:epoch, :lat_deg, :lon_deg, :vtec_tecu, :rms_tecu]

  @typedoc "Epoch as `%{time_scale:, jd_whole:, jd_fraction:}`."
  @type epoch :: %{time_scale: String.t(), jd_whole: float(), jd_fraction: float()}

  @type t :: %__MODULE__{
          epoch: epoch(),
          lat_deg: float(),
          lon_deg: float(),
          vtec_tecu: float(),
          rms_tecu: float() | nil
        }

  @doc false
  @spec to_nif_tuple(t()) :: {:ok, tuple()} | {:error, term()}
  def to_nif_tuple(%__MODULE__{
        epoch: %{time_scale: time_scale, jd_whole: jd_whole, jd_fraction: jd_fraction},
        lat_deg: lat_deg,
        lon_deg: lon_deg,
        vtec_tecu: vtec_tecu,
        rms_tecu: rms_tecu
      })
      when is_binary(time_scale) and is_number(jd_whole) and is_number(jd_fraction) and is_number(lat_deg) and
             is_number(lon_deg) and is_number(vtec_tecu) and (is_number(rms_tecu) or is_nil(rms_tecu)) do
    rms = if !is_nil(rms_tecu), do: rms_tecu / 1.0
    {:ok, {{time_scale, jd_whole / 1.0, jd_fraction / 1.0}, lat_deg / 1.0, lon_deg / 1.0, vtec_tecu / 1.0, rms}}
  end

  def to_nif_tuple(%__MODULE__{}), do: {:error, :bad_tec_sample}

  @doc false
  @spec from_nif_tuple(tuple()) :: t()
  def from_nif_tuple({{time_scale, jd_whole, jd_fraction}, lat_deg, lon_deg, vtec_tecu, rms_tecu}) do
    %__MODULE__{
      epoch: %{time_scale: time_scale, jd_whole: jd_whole, jd_fraction: jd_fraction},
      lat_deg: lat_deg,
      lon_deg: lon_deg,
      vtec_tecu: vtec_tecu,
      rms_tecu: rms_tecu
    }
  end
end
