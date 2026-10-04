defmodule Sidereon.GNSS.SP3.AccuracyCodeGroup do
  @moduledoc "Signed SP3 exponent fields and the bases that interpret them."

  @enforce_keys [:axis_exponents, :clock_exponent, :position_velocity_base, :clock_rate_base]
  defstruct [:axis_exponents, :clock_exponent, :position_velocity_base, :clock_rate_base]

  @type t :: %__MODULE__{
          axis_exponents: {integer() | nil, integer() | nil, integer() | nil},
          clock_exponent: integer() | nil,
          position_velocity_base: float() | nil,
          clock_rate_base: float() | nil
        }

  @doc false
  def from_nif_tuple({axis_x, axis_y, axis_z, clock, position_velocity_base, clock_rate_base}) do
    %__MODULE__{
      axis_exponents: {axis_x, axis_y, axis_z},
      clock_exponent: clock,
      position_velocity_base: position_velocity_base,
      clock_rate_base: clock_rate_base
    }
  end
end

defmodule Sidereon.GNSS.SP3.RawRecordAccuracy do
  @moduledoc "Raw P/V accuracy groups, preserving absent groups and blank codes."

  alias Sidereon.GNSS.SP3.AccuracyCodeGroup

  @enforce_keys [:p, :v]
  defstruct [:p, :v]

  @type t :: %__MODULE__{p: AccuracyCodeGroup.t() | nil, v: AccuracyCodeGroup.t() | nil}

  @doc false
  def from_nif_tuple({p, v}) do
    %__MODULE__{p: decode_group(p), v: decode_group(v)}
  end

  defp decode_group(nil), do: nil
  defp decode_group(tuple), do: AccuracyCodeGroup.from_nif_tuple(tuple)
end

defmodule Sidereon.GNSS.SP3.AccuracyValue do
  @moduledoc "Typed SP3 accuracy outcome: known sigma or a preserved source status."

  @type t :: {:known, float()} | :unknown | :too_large | :invalid_base | :overflow

  @spec variance(t()) :: t()
  def variance({:known, value}) when value == 0.0, do: {:known, 0.0}

  def variance({:known, value}) do
    result = value * value
    if result > 0.0, do: {:known, result}, else: :overflow
  rescue
    ArithmeticError -> :overflow
  end

  def variance(status) when status in [:unknown, :too_large, :invalid_base, :overflow], do: status

  @doc false
  def normalize({:known, value}) when is_number(value) and value >= 0, do: {:ok, {:known, value / 1.0}}
  def normalize(value) when value in [:unknown, :too_large, :invalid_base, :overflow], do: {:ok, value}
  def normalize(_), do: {:error, :invalid_accuracy_value}
end

defmodule Sidereon.GNSS.SP3.PositionClockAccuracy do
  @moduledoc "Decoded P-record position and clock standard deviations."

  alias Sidereon.GNSS.SP3.AccuracyValue

  @enforce_keys [:position_sigma_m, :clock_sigma_m]
  defstruct [:position_sigma_m, :clock_sigma_m]

  @type t :: %__MODULE__{
          position_sigma_m: {AccuracyValue.t(), AccuracyValue.t(), AccuracyValue.t()},
          clock_sigma_m: AccuracyValue.t()
        }

  @doc false
  def from_nif_tuple({{axis_x, axis_y, axis_z}, clock}),
    do: %__MODULE__{position_sigma_m: {axis_x, axis_y, axis_z}, clock_sigma_m: clock}

  @spec position_variance_m2(t()) :: {AccuracyValue.t(), AccuracyValue.t(), AccuracyValue.t()}
  def position_variance_m2(%__MODULE__{position_sigma_m: {axis_x, axis_y, axis_z}}),
    do: {AccuracyValue.variance(axis_x), AccuracyValue.variance(axis_y), AccuracyValue.variance(axis_z)}

  @spec clock_variance_m2(t()) :: AccuracyValue.t()
  def clock_variance_m2(%__MODULE__{clock_sigma_m: sigma}), do: AccuracyValue.variance(sigma)
end

defmodule Sidereon.GNSS.SP3.VelocityAccuracy do
  @moduledoc "Decoded V-record velocity and clock-rate standard deviations."

  alias Sidereon.GNSS.SP3.AccuracyValue

  @enforce_keys [:velocity_sigma_m_s, :clock_rate_sigma_m_s]
  defstruct [:velocity_sigma_m_s, :clock_rate_sigma_m_s]

  @type t :: %__MODULE__{
          velocity_sigma_m_s: {AccuracyValue.t(), AccuracyValue.t(), AccuracyValue.t()},
          clock_rate_sigma_m_s: AccuracyValue.t()
        }

  @doc false
  def from_nif_tuple({{axis_x, axis_y, axis_z}, clock_rate}),
    do: %__MODULE__{velocity_sigma_m_s: {axis_x, axis_y, axis_z}, clock_rate_sigma_m_s: clock_rate}

  @spec velocity_variance_m2_s2(t()) :: {AccuracyValue.t(), AccuracyValue.t(), AccuracyValue.t()}
  def velocity_variance_m2_s2(%__MODULE__{velocity_sigma_m_s: {axis_x, axis_y, axis_z}}),
    do: {AccuracyValue.variance(axis_x), AccuracyValue.variance(axis_y), AccuracyValue.variance(axis_z)}

  @spec clock_rate_variance_m2_s2(t()) :: AccuracyValue.t()
  def clock_rate_variance_m2_s2(%__MODULE__{clock_rate_sigma_m_s: sigma}), do: AccuracyValue.variance(sigma)
end

defmodule Sidereon.GNSS.SP3.RecordAccuracy do
  @moduledoc "Effective P/V sigma values retained for one SP3 satellite record."

  alias Sidereon.GNSS.SP3.PositionClockAccuracy
  alias Sidereon.GNSS.SP3.VelocityAccuracy

  @enforce_keys [:p, :v]
  defstruct [:p, :v]

  @type t :: %__MODULE__{p: PositionClockAccuracy.t() | nil, v: VelocityAccuracy.t() | nil}

  @doc false
  def from_nif_tuple({p, v}) do
    %__MODULE__{p: decode_p(p), v: decode_v(v)}
  end

  defp decode_p(nil), do: nil
  defp decode_p(tuple), do: PositionClockAccuracy.from_nif_tuple(tuple)
  defp decode_v(nil), do: nil
  defp decode_v(tuple), do: VelocityAccuracy.from_nif_tuple(tuple)
end

defmodule Sidereon.GNSS.PreciseEphemerisAccuracySample do
  @moduledoc "Variance sidecar aligned by satellite and epoch with a precise sample."

  alias Sidereon.GNSS.Core.Types
  alias Sidereon.GNSS.PreciseEphemerisSample
  alias Sidereon.GNSS.SP3.AccuracyValue

  @enforce_keys [:sat, :epoch, :position_variance_m2, :clock_variance_m2]
  defstruct [:sat, :epoch, :position_variance_m2, :clock_variance_m2]

  @type t :: %__MODULE__{
          sat: String.t(),
          epoch: PreciseEphemerisSample.epoch(),
          position_variance_m2: {AccuracyValue.t(), AccuracyValue.t(), AccuracyValue.t()},
          clock_variance_m2: AccuracyValue.t()
        }

  @doc false
  def to_nif_tuple(%__MODULE__{
        sat: sat,
        epoch: epoch,
        position_variance_m2: {axis_x, axis_y, axis_z},
        clock_variance_m2: clock
      }) do
    with {:ok, letter, prn} <- Types.parse_sat_id(sat),
         {:ok, axis_x} <- AccuracyValue.normalize(axis_x),
         {:ok, axis_y} <- AccuracyValue.normalize(axis_y),
         {:ok, axis_z} <- AccuracyValue.normalize(axis_z),
         {:ok, clock} <- AccuracyValue.normalize(clock) do
      with {:ok, nif_epoch} <- epoch_to_nif(epoch) do
        {:ok, {letter, prn, nif_epoch, {axis_x, axis_y, axis_z}, clock}}
      end
    end
  end

  @doc false
  def from_nif_tuple({letter, prn, epoch, {axis_x, axis_y, axis_z}, clock}) do
    %__MODULE__{
      sat: letter <> String.pad_leading(Integer.to_string(prn), 2, "0"),
      epoch: epoch_from_nif(epoch),
      position_variance_m2: {axis_x, axis_y, axis_z},
      clock_variance_m2: clock
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
end
