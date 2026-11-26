defmodule Sidereon.Iers2010EarthOrientationProvider do
  @moduledoc "IERS 2010 Earth orientation from daily EOP samples and subdaily corrections."

  alias Sidereon.NIF

  @enforce_keys [:handle]
  defstruct [:handle]
  @opaque t :: %__MODULE__{handle: reference()}

  defmodule Iers2010EopSample do
    @moduledoc """
    Daily Earth orientation at midnight UTC MJD. Polar motion and celestial pole
    offsets are in arcseconds, UT1−UTC and excess length of day are in seconds,
    and optional polar rates are in radians per second. This struct compares by value.
    """
    @enforce_keys [:mjd_utc, :xp_arcsec, :yp_arcsec, :ut1_minus_utc_s, :lod_s, :dx_arcsec, :dy_arcsec]
    defstruct [:mjd_utc, :xp_arcsec, :yp_arcsec, :ut1_minus_utc_s, :lod_s, :dx_arcsec, :dy_arcsec, :pole_rates_rad_s]

    @type t :: %__MODULE__{
            mjd_utc: integer(),
            xp_arcsec: float(),
            yp_arcsec: float(),
            ut1_minus_utc_s: float(),
            lod_s: float(),
            dx_arcsec: float(),
            dy_arcsec: float(),
            pole_rates_rad_s: {float(), float()} | nil
          }
  end

  defmodule EarthOrientation do
    @moduledoc """
    Earth orientation at a single epoch. Rotation matrices are row-major.
    The quaternion represents GCRF to ITRF with the scalar component first.
    This struct compares by value.
    """
    @enforce_keys [
      :iers2010_quaternion,
      :earth_rotation_vector_itrf_rad_s,
      :ut1_degraded,
      :gcrf_to_itrf_matrix,
      :itrf_to_gcrf_matrix,
      :gcrf_to_itrf_rotation_rate_matrix,
      :itrf_to_gcrf_rotation_rate_matrix
    ]
    defstruct @enforce_keys

    @type vector :: {float(), float(), float()}
    @type t :: %__MODULE__{
            iers2010_quaternion: {float(), float(), float(), float()} | nil,
            earth_rotation_vector_itrf_rad_s: vector(),
            ut1_degraded: :before_coverage | :after_coverage | nil,
            gcrf_to_itrf_matrix: [vector()],
            itrf_to_gcrf_matrix: [vector()],
            gcrf_to_itrf_rotation_rate_matrix: [vector()],
            itrf_to_gcrf_rotation_rate_matrix: [vector()]
          }
  end

  defmodule FrameTransformError do
    @moduledoc "An orientation evaluation refusal with its details."
    defstruct [:kind, :detail, :message]
    @type t :: %__MODULE__{kind: atom(), detail: map(), message: String.t()}

    defimpl String.Chars do
      def to_string(error), do: error.message
    end
  end

  @doc "Build a strict provider from daily samples in increasing MJD order."
  @spec new([Iers2010EopSample.t()]) :: {:ok, t()} | {:error, FrameTransformError.t()}
  def new(samples) do
    case NIF.iers2010_new(samples) do
      {:ok, handle} -> {:ok, %__MODULE__{handle: handle}}
      {:error, details} -> {:error, struct!(FrameTransformError, details)}
    end
  end

  @doc "Return a provider using the requested validity policy outside its daily series."
  @spec with_validity(t(), :strict | :permissive) :: t()
  def with_validity(%__MODULE__{handle: handle}, validity) when validity in [:strict, :permissive] do
    %__MODULE__{handle: NIF.iers2010_with_validity(handle, validity)}
  end

  @doc "Compare daily inputs and validity policy by value."
  @spec equal?(t(), t()) :: boolean()
  def equal?(%__MODULE__{handle: first}, %__MODULE__{handle: second}), do: NIF.iers2010_equal(first, second)

  @doc "Evaluate orientation at seconds within the given UTC MJD, including leap seconds."
  @spec orientation_at_utc_mjd(t(), integer(), number()) ::
          {:ok, EarthOrientation.t()} | {:error, FrameTransformError.t()}
  def orientation_at_utc_mjd(%__MODULE__{handle: handle}, mjd, seconds) do
    decode(NIF.iers2010_orientation_at_utc_mjd(handle, mjd, seconds / 1.0))
  end

  @doc "Evaluate orientation at TDB seconds past J2000."
  @spec orientation_at_tdb_seconds(t(), number()) :: {:ok, EarthOrientation.t()} | {:error, FrameTransformError.t()}
  def orientation_at_tdb_seconds(%__MODULE__{handle: handle}, epoch) do
    decode(NIF.iers2010_orientation_at_tdb_seconds(handle, epoch / 1.0))
  end

  defp decode({:ok, orientation}), do: {:ok, struct!(EarthOrientation, orientation)}
  defp decode({:error, details}), do: {:error, struct!(FrameTransformError, details)}
end
