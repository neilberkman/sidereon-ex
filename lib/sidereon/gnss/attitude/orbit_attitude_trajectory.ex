defmodule Sidereon.GNSS.Attitude.OrbitAttitudeTrajectory do
  @moduledoc """
  A satellite orbit and Sun ephemeris for GNSS yaw laws.

  Samples use TDB seconds past J2000. Satellite position, velocity and Sun
  position are returned in GCRF in metres and metres per second. Earth-fixed
  sources must be aligned with the orientation provider's ITRF.
  """

  alias Sidereon.DeEphemeris
  alias Sidereon.GNSS.Attitude.AttitudeSample
  alias Sidereon.GNSS.Attitude.GnssAttitudeError
  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.SP3
  alias Sidereon.Iers2010EarthOrientationProvider
  alias Sidereon.NIF
  alias Sidereon.NifCall
  alias Sidereon.OrbitScoring
  alias Sidereon.OrbitScoring.BroadcastOrbit
  alias Sidereon.OrbitScoring.OrbitScoreError
  alias Sidereon.OrbitScoring.OrbitTrajectory
  alias Sidereon.OrbitScoring.PredictedSp3
  alias Sidereon.Propagator.Analytic.BrouwerLyddanePropagator
  alias Sidereon.Propagator.Analytic.EcksteinHechlerPropagator
  alias Sidereon.Propagator.DenseOutput

  @enforce_keys [:source]
  defstruct [:source, :de_ephemeris, :velocity_half_step_s]

  @typedoc """
  Use `:tdb` for the core's default UT1 validity policy, `{:tdb, mode}` for
  an explicit policy, or a provider with supplied IERS 2010 samples.
  """
  @type orientation :: :tdb | {:tdb, :strict | :permissive} | Iers2010EarthOrientationProvider.t()

  @opaque t :: %__MODULE__{
            source: tuple(),
            de_ephemeris: DeEphemeris.t() | nil,
            velocity_half_step_s: float() | nil
          }

  @doc "Select a satellite from a parsed SP3 product."
  @spec from_sp3(SP3.t(), OrbitScoring.satellite_id(), orientation()) :: {:ok, t()} | {:error, OrbitScoreError.t()}
  def from_sp3(%SP3{} = source, satellite, orientation \\ :tdb),
    do: from_earth_fixed(:sp3, source, satellite, orientation)

  @doc "Select a satellite from a broadcast navigation set."
  @spec from_broadcast(Broadcast.t(), OrbitScoring.satellite_id(), orientation()) ::
          {:ok, t()} | {:error, OrbitScoreError.t()}
  def from_broadcast(%Broadcast{} = source, satellite, orientation \\ :tdb),
    do: from_earth_fixed(:broadcast, source, satellite, orientation)

  @doc "Select a satellite from a predicted SP3, broadcast or sampled scoring source."
  @spec from_orbit_source(OrbitScoring.source(), OrbitScoring.satellite_id(), orientation()) ::
          {:ok, t()} | {:error, OrbitScoreError.t()}
  def from_orbit_source(%module{} = source, satellite, orientation \\ :tdb)
      when module in [PredictedSp3, BroadcastOrbit, OrbitTrajectory],
      do: from_earth_fixed(:orbit_source, source, satellite, orientation)

  @doc "Use an Eckstein–Hechler propagator whose states are in GCRF."
  @spec from_eckstein_hechler(EcksteinHechlerPropagator.t()) :: t()
  def from_eckstein_hechler(%EcksteinHechlerPropagator{} = source),
    do: %__MODULE__{source: {:eckstein_hechler, source.handle}}

  @doc "Use a Brouwer–Lyddane propagator whose states are in GCRF."
  @spec from_brouwer_lyddane(BrouwerLyddanePropagator.t()) :: t()
  def from_brouwer_lyddane(%BrouwerLyddanePropagator{} = source),
    do: %__MODULE__{source: {:brouwer_lyddane, source.handle}}

  @doc "Use the continuous GCRF output of a DP5(4) integration arc."
  @spec from_dense_output(DenseOutput.t()) :: t()
  def from_dense_output(%DenseOutput{} = source), do: %__MODULE__{source: {:dense_output, source.handle}}

  @doc "Use a JPL DE ephemeris for the Sun instead of the default analytic ephemeris."
  @spec with_de_ephemeris(t(), DeEphemeris.t()) :: t()
  def with_de_ephemeris(%__MODULE__{} = trajectory, %DeEphemeris{} = ephemeris),
    do: %{trajectory | de_ephemeris: ephemeris}

  @doc """
  Set the half step for differencing Earth-fixed positions, in seconds on the source's time axis.

  For a node-only source, choose a step that reaches adjacent nodes. The core
  refuses a step below its minimum and reports when a sample is unavailable.
  """
  @spec with_velocity_half_step_s(t(), number()) :: {:ok, t()} | {:error, OrbitScoreError.t()}
  def with_velocity_half_step_s(%__MODULE__{} = trajectory, half_step_s) do
    candidate = %{trajectory | velocity_half_step_s: half_step_s / 1.0}

    with {:ok, _} <- OrbitScoring.decode(NIF.attitude_trajectory_validate(native(candidate))),
         do: {:ok, candidate}
  end

  @doc "Sample the satellite and Sun in GCRF at TDB seconds past J2000."
  @spec sample(t(), number()) :: {:ok, AttitudeSample.t()} | {:error, GnssAttitudeError.t()}
  def sample(%__MODULE__{} = trajectory, t_s) do
    case NIF.attitude_trajectory_sample(native(trajectory), t_s / 1.0) do
      {:ok, value} -> {:ok, struct!(AttitudeSample, value)}
      {:error, _} = error -> NifCall.decode(error, GnssAttitudeError)
    end
  end

  @doc false
  @spec native(t()) :: map()
  def native(trajectory) do
    %{trajectory | de_ephemeris: if(trajectory.de_ephemeris, do: trajectory.de_ephemeris.handle)}
  end

  defp from_earth_fixed(kind, source, satellite, orientation) do
    with {:ok, satellite} <- OrbitScoring.native_satellite(satellite),
         {:ok, provider} <- native_orientation(orientation) do
      {:ok, %__MODULE__{source: {kind, source.handle, satellite, provider}}}
    else
      {:error, _} = error -> OrbitScoring.decode(error)
    end
  end

  defp native_orientation(:tdb), do: {:ok, :tdb}
  defp native_orientation({:tdb, mode} = provider) when mode in [:strict, :permissive], do: {:ok, provider}
  defp native_orientation(%Iers2010EarthOrientationProvider{handle: handle}), do: {:ok, handle}
  defp native_orientation(provider), do: {:error, {:invalid_input, {:orientation, provider}}}
end
