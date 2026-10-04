defmodule Sidereon.GNSS.Ionosphere.SlantRequest do
  @moduledoc """
  One query for `Sidereon.GNSS.Ionosphere.ionex_slant_batch/3`.

  The receiver geodetic latitude/longitude and the satellite azimuth/elevation
  are in degrees. `epoch` is a `NaiveDateTime` or `{{y, m, d}, {h, min, s}}`
  tuple on a whole second: the IONEX epoch axis is integer seconds, so a
  sub-second epoch is refused rather than rounded onto it. `frequency_hz` is the
  carrier the delay is reported on.

  The numeric fields are held as they were given, integer or float, and are read
  onto the `f64` the boundary takes only when the request is converted. An
  integer Elixir carries but a double cannot is refused as that row rather than
  raising out of the conversion of the batch it is in.

  ## What a row is refused for

  A request that cannot be put into the form the boundary takes fails as its own
  batch row, keeping its place in the result list:

    * `:non_integer_second_epoch` - the epoch is not on a whole second, or is
      not an epoch this binding reads.
    * `{:invalid_request_field, field, value}` - a field that is not a number.
    * `{:invalid_epoch_field, field, value}` - a date or clock field of a tuple
      epoch that is not an integer, such as an `hour` arrived at by division.
    * `{:value_out_of_range, field, value}` - a numeric field, a calendar field
      or a J2000 second past the range the boundary carries it in, with the
      value that was outside it. A numeric field is past that range when it is
      an integer larger in magnitude than the largest finite double.
    * `:bad_slant_request` - the row is not a `SlantRequest`.

  A request that converts but that the product refuses keeps its own reason
  instead; see `Sidereon.GNSS.Ionosphere.ionex_slant_evaluation/8`.
  """

  alias Sidereon.GNSS.Ionosphere.EpochAxis
  alias Sidereon.GNSS.Ionosphere.Numeric

  @enforce_keys [:lat_deg, :lon_deg, :azimuth_deg, :elevation_deg, :epoch, :frequency_hz]
  defstruct [:lat_deg, :lon_deg, :azimuth_deg, :elevation_deg, :epoch, :frequency_hz]

  @type t :: %__MODULE__{
          lat_deg: number(),
          lon_deg: number(),
          azimuth_deg: number(),
          elevation_deg: number(),
          epoch: NaiveDateTime.t() | tuple(),
          frequency_hz: number()
        }

  @doc """
  A slant query at the receiver `{lat_deg, lon_deg}` toward
  `{azimuth_deg, elevation_deg}`, on `frequency_hz`, at `epoch`.

  The numbers are kept as they were given. Whether each one can be read onto the
  double the boundary takes is decided when the request is converted, so a value
  that cannot be is that row's refusal and a request always exists to hold it.
  """
  @spec new(number(), number(), number(), number(), NaiveDateTime.t() | tuple(), number()) :: t()
  def new(lat_deg, lon_deg, azimuth_deg, elevation_deg, epoch, frequency_hz)
      when is_number(lat_deg) and is_number(lon_deg) and is_number(azimuth_deg) and is_number(elevation_deg) and
             is_number(frequency_hz) do
    %__MODULE__{
      lat_deg: lat_deg,
      lon_deg: lon_deg,
      azimuth_deg: azimuth_deg,
      elevation_deg: elevation_deg,
      epoch: epoch,
      frequency_hz: frequency_hz
    }
  end

  @doc false
  @spec to_nif_map(t()) :: {:ok, map()} | {:error, term()}
  def to_nif_map(%__MODULE__{} = request) do
    with {:ok, lat_deg} <- float_field(request.lat_deg, :lat_deg),
         {:ok, lon_deg} <- float_field(request.lon_deg, :lon_deg),
         {:ok, azimuth_deg} <- float_field(request.azimuth_deg, :azimuth_deg),
         {:ok, elevation_deg} <- float_field(request.elevation_deg, :elevation_deg),
         {:ok, frequency_hz} <- float_field(request.frequency_hz, :frequency_hz),
         {:ok, epoch_j2000_s} <- EpochAxis.j2000_seconds(request.epoch) do
      {:ok,
       %{
         lat_deg: lat_deg,
         lon_deg: lon_deg,
         azimuth_deg: azimuth_deg,
         elevation_deg: elevation_deg,
         epoch_j2000_s: epoch_j2000_s,
         frequency_hz: frequency_hz
       }}
    end
  end

  def to_nif_map(_other), do: {:error, :bad_slant_request}

  @doc false
  # The one place a *request* field is read onto the `f64` the boundary takes.
  # The scalar slant delay, the policy evaluation and every batch row convert
  # through here, so one value is refused the same way whichever call carries
  # it, and no call divides a caller's integer unchecked. The grid and sample
  # surfaces have their own fields and their own tags for them, and read the
  # same range through `Sidereon.GNSS.Ionosphere.Numeric` rather than arriving
  # here and being named as request fields.
  @spec float_field(term(), atom()) :: {:ok, float()} | {:error, term()}
  def float_field(value, field) do
    case Numeric.float(value) do
      {:ok, float} -> {:ok, float}
      {:out_of_range, value} -> {:error, {:value_out_of_range, field, value}}
      :not_a_number -> {:error, {:invalid_request_field, field, value}}
    end
  end
end
