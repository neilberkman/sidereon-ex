defmodule Sidereon.OrbitDetermination do
  @moduledoc """
  Precise orbit fitting and residual ledgers.

  Positions supplied through SP3 or precise ephemeris samples are ECEF metres.
  Fitted initial states are GCRS kilometres and kilometres per second.
  """

  alias __MODULE__.OrbitFitCovariance
  alias __MODULE__.OrbitFitReport
  alias __MODULE__.OrbitFitSolution
  alias __MODULE__.OrbitResidualLedger
  alias __MODULE__.OrbitResidualStats
  alias Sidereon.GNSS.PreciseEphemerisSample
  alias Sidereon.GNSS.SP3
  alias Sidereon.NIF

  defmodule OrbitFitCovariance do
    @moduledoc """
    Fitted state covariance or an unbounded marker.
    """

    @enforce_keys [:kind]
    defstruct [:kind, :matrix]

    @type t :: %__MODULE__{kind: :estimated | :unbounded, matrix: [[float()]] | nil}
  end

  defmodule OrbitFitSolution do
    @moduledoc """
    Initial-state orbit fit for one satellite.
    """

    @enforce_keys [
      :satellite,
      :initial_state,
      :covariance,
      :geometry_quality,
      :seed_rms_3d_m,
      :fit_rms_3d_m,
      :iterations
    ]
    defstruct [
      :satellite,
      :initial_state,
      :covariance,
      :geometry_quality,
      :seed_rms_3d_m,
      :fit_rms_3d_m,
      :iterations
    ]

    @type t :: %__MODULE__{
            satellite: String.t(),
            initial_state: map(),
            covariance: OrbitFitCovariance.t(),
            geometry_quality: map(),
            seed_rms_3d_m: float(),
            fit_rms_3d_m: float(),
            iterations: non_neg_integer()
          }
  end

  defmodule OrbitResidualStats do
    @moduledoc """
    RTN residual RMS summary.
    """

    @enforce_keys [:radial_rms_m, :along_rms_m, :cross_rms_m, :rms_3d_m, :n, :low_sample_count]
    defstruct [:radial_rms_m, :along_rms_m, :cross_rms_m, :rms_3d_m, :n, :low_sample_count]

    @type t :: %__MODULE__{
            radial_rms_m: float(),
            along_rms_m: float(),
            cross_rms_m: float(),
            rms_3d_m: float(),
            n: non_neg_integer(),
            low_sample_count: boolean()
          }
  end

  defmodule OrbitResidualLedger do
    @moduledoc """
    Residual summary grouped by satellite and constellation.
    """

    @enforce_keys [:per_sat, :per_constellation, :arc_span]
    defstruct [:per_sat, :per_constellation, :arc_span]

    @type t :: %__MODULE__{
            per_sat: %{String.t() => OrbitResidualStats.t()},
            per_constellation: %{String.t() => OrbitResidualStats.t()},
            arc_span: map()
          }
  end

  defmodule OrbitFitReport do
    @moduledoc """
    Batch orbit-fit report.
    """

    @enforce_keys [:fits, :ledger]
    defstruct [:fits, :ledger]

    @type t :: %__MODULE__{fits: [OrbitFitSolution.t()], ledger: OrbitResidualLedger.t()}
  end

  @type satellite_id :: String.t() | {String.t(), pos_integer()} | {atom(), pos_integer()}
  @type error_reason ::
          :empty_selection
          | :invalid_option
          | :too_few_samples
          | :non_monotonic_epochs
          | :mixed_timescales
          | :invalid_epoch
          | :invalid_observation
          | :frame
          | :propagation
          | :least_squares
          | :singular_geometry
          | :did_not_converge
          | :rtn_frame
          | term()

  @doc """
  Fit one satellite from a parsed SP3 product.
  """
  @spec fit_sp3_precise_orbit(SP3.t(), satellite_id(), keyword()) ::
          {:ok, OrbitFitReport.t()} | {:error, error_reason()}
  def fit_sp3_precise_orbit(%SP3{handle: handle}, satellite_id, opts \\ []) do
    {letter, prn} = satellite(satellite_id)

    case NIF.orbit_fit_sp3_precise_orbit(handle, letter, prn, options(opts)) do
      {:ok, report} -> {:ok, report(report)}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Fit one satellite from a parsed ECEF SP3 product.

  The Earth-orientation provider is supplied by the core side of the binding.
  """
  @spec fit_sp3_ecef_precise_orbit(SP3.t(), satellite_id(), keyword()) ::
          {:ok, OrbitFitReport.t()} | {:error, error_reason()}
  def fit_sp3_ecef_precise_orbit(%SP3{handle: handle}, satellite_id, opts \\ []) do
    {letter, prn} = satellite(satellite_id)

    case NIF.orbit_fit_sp3_ecef_precise_orbit(handle, letter, prn, options(opts)) do
      {:ok, report} -> {:ok, report(report)}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Fit selected satellites from a parsed ECEF SP3 product.
  """
  @spec fit_sp3_ecef_precise_orbits(SP3.t(), [satellite_id()], keyword()) ::
          {:ok, OrbitFitReport.t()} | {:error, error_reason()}
  def fit_sp3_ecef_precise_orbits(%SP3{handle: handle}, satellite_ids, opts \\ []) when is_list(satellite_ids) do
    case NIF.orbit_fit_sp3_ecef_precise_orbits(handle, Enum.map(satellite_ids, &satellite/1), options(opts)) do
      {:ok, report} -> {:ok, report(report)}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Fit every satellite declared in a parsed ECEF SP3 product.
  """
  @spec fit_all_sp3_ecef_precise_orbits(SP3.t(), keyword()) ::
          {:ok, OrbitFitReport.t()} | {:error, error_reason()}
  def fit_all_sp3_ecef_precise_orbits(%SP3{handle: handle}, opts \\ []) do
    case NIF.orbit_fit_all_sp3_ecef_precise_orbits(handle, options(opts)) do
      {:ok, report} -> {:ok, report(report)}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Fit one satellite from a precise-ephemeris sample slice.
  """
  @spec fit_precise_ephemeris_sample_orbit([PreciseEphemerisSample.t()], satellite_id(), keyword()) ::
          {:ok, OrbitFitReport.t()} | {:error, error_reason()}
  def fit_precise_ephemeris_sample_orbit(samples, satellite_id, opts \\ []) do
    {letter, prn} = satellite(satellite_id)

    with {:ok, sample_terms} <- sample_terms(samples) do
      case NIF.orbit_fit_precise_ephemeris_sample_orbit(sample_terms, letter, prn, options(opts)) do
        {:ok, report} -> {:ok, report(report)}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp options(opts) do
    tolerance = Keyword.get(opts, :tolerance, 1.0e-12) / 1.0

    {
      Keyword.get(opts, :forces, [:earth_phase_a]) |> Enum.map(&force_token/1),
      Keyword.get(opts, :abs_tol, tolerance) / 1.0,
      Keyword.get(opts, :rel_tol, tolerance) / 1.0,
      Keyword.get(opts, :max_nfev, 500),
      Keyword.get(opts, :min_ledger_samples, 3)
    }
  end

  defp force_token({:srp, cr, area_to_mass_m2_kg}) when is_number(cr) and is_number(area_to_mass_m2_kg) do
    "srp:#{cr / 1.0}:#{area_to_mass_m2_kg / 1.0}"
  end

  defp force_token({:geopotential, degree, order}) when is_integer(degree) and is_integer(order) do
    "geopotential:#{degree}:#{order}"
  end

  defp force_token({:spherical_harmonic, degree, order}) when is_integer(degree) and is_integer(order) do
    "spherical_harmonic:#{degree}:#{order}"
  end

  defp force_token({:egm96, degree, order}) when is_integer(degree) and is_integer(order) do
    "egm96:#{degree}:#{order}"
  end

  defp force_token({:earth_phase_b, degree, order}) when is_integer(degree) and is_integer(order) do
    "earth_phase_b:#{degree}:#{order}"
  end

  defp force_token(value), do: to_string(value)

  defp sample_terms(samples) do
    samples
    |> Enum.reduce_while({:ok, []}, fn sample, {:ok, acc} ->
      case PreciseEphemerisSample.to_nif_tuple(sample) do
        {:ok, tuple} -> {:cont, {:ok, [tuple | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _} = err -> err
    end
  end

  defp report(value) do
    %OrbitFitReport{
      fits: Enum.map(value.fits, &solution/1),
      ledger: ledger(value.ledger)
    }
  end

  defp solution(value) do
    %OrbitFitSolution{
      satellite: value.satellite,
      initial_state: value.initial_state,
      covariance: covariance(value.covariance),
      geometry_quality: value.geometry_quality,
      seed_rms_3d_m: value.seed_rms_3d_m,
      fit_rms_3d_m: value.fit_rms_3d_m,
      iterations: value.iterations
    }
  end

  defp covariance(value) do
    %OrbitFitCovariance{kind: String.to_atom(value.kind), matrix: value.matrix}
  end

  defp ledger(value) do
    %OrbitResidualLedger{
      per_sat: Map.new(value.per_sat, fn {sat, stats} -> {sat, stats(stats)} end),
      per_constellation: Map.new(value.per_constellation, fn {system, stats} -> {system, stats(stats)} end),
      arc_span: value.arc_span
    }
  end

  defp stats(value) do
    %OrbitResidualStats{
      radial_rms_m: value.radial_rms_m,
      along_rms_m: value.along_rms_m,
      cross_rms_m: value.cross_rms_m,
      rms_3d_m: value.rms_3d_m,
      n: value.n,
      low_sample_count: value.low_sample_count
    }
  end

  defp satellite(<<letter::binary-size(1), prn_text::binary>>) do
    {letter, String.to_integer(prn_text)}
  end

  defp satellite({system, prn}) when is_integer(prn), do: {system_letter(system), prn}

  defp system_letter(:gps), do: "G"
  defp system_letter(:glonass), do: "R"
  defp system_letter(:galileo), do: "E"
  defp system_letter(:beidou), do: "C"
  defp system_letter(:bds), do: "C"
  defp system_letter(:qzss), do: "J"
  defp system_letter(:navic), do: "I"
  defp system_letter(:sbas), do: "S"
  defp system_letter(<<letter::binary-size(1)>>), do: letter
  defp system_letter(system) when is_binary(system), do: system
  defp system_letter(system) when is_atom(system), do: system |> Atom.to_string() |> system_letter()
end
