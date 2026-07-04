defmodule Sidereon.Geodesic do
  @moduledoc """
  WGS84 geodesic direct and inverse solves.

  Angles are degrees and distances are metres at this boundary. The underlying
  solver is Karney's WGS84 geodesic implementation from `sidereon-core`.
  """

  alias Sidereon.NIF

  defmodule GeodesicError do
    @moduledoc """
    Invalid-input detail returned by geodesic solves.
    """

    @enforce_keys [:field, :reason]
    defstruct [:field, :reason]

    @type t :: %__MODULE__{field: String.t(), reason: String.t()}
  end

  @typedoc "Inverse geodesic result."
  @type inverse_result :: %{s12_m: float(), azi1_deg: float(), azi2_deg: float()}

  @typedoc "Direct geodesic result."
  @type direct_result :: %{lat2_deg: float(), lon2_deg: float(), azi2_deg: float()}

  @doc """
  Solve the WGS84 inverse geodesic problem.

  Inputs are point 1 latitude and longitude followed by point 2 latitude and
  longitude, all in degrees. Returns geodesic distance and forward azimuths.
  """
  @spec inverse(number(), number(), number(), number()) ::
          {:ok, inverse_result()} | {:error, GeodesicError.t()}
  def inverse(lat1_deg, lon1_deg, lat2_deg, lon2_deg) do
    case NIF.geodesic_inverse(lat1_deg / 1.0, lon1_deg / 1.0, lat2_deg / 1.0, lon2_deg / 1.0) do
      {:ok, {s12_m, azi1_deg, azi2_deg}} ->
        {:ok, %{s12_m: s12_m, azi1_deg: azi1_deg, azi2_deg: azi2_deg}}

      {:error, error} ->
        {:error, error(error)}
    end
  end

  @doc """
  Solve the WGS84 direct geodesic problem.

  Inputs are point 1 latitude, longitude, forward azimuth, and geodesic distance.
  Returns point 2 latitude, longitude, and forward azimuth.
  """
  @spec direct(number(), number(), number(), number()) ::
          {:ok, direct_result()} | {:error, GeodesicError.t()}
  def direct(lat1_deg, lon1_deg, azi1_deg, s12_m) do
    case NIF.geodesic_direct(lat1_deg / 1.0, lon1_deg / 1.0, azi1_deg / 1.0, s12_m / 1.0) do
      {:ok, {lat2_deg, lon2_deg, azi2_deg}} ->
        {:ok, %{lat2_deg: lat2_deg, lon2_deg: lon2_deg, azi2_deg: azi2_deg}}

      {:error, error} ->
        {:error, error(error)}
    end
  end

  defp error(%{field: field, reason: reason}) do
    %GeodesicError{field: field, reason: reason}
  end
end
