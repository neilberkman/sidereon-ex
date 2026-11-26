defmodule Sidereon.OrbitScoring do
  @moduledoc """
  Score a predicted SP3 product, broadcast orbit or sampled trajectory against
  a precise SP3 reference. Reports resolve errors in the radial, transverse and
  normal orbit frame, group them by prediction horizon, and track coverage.
  """

  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.PreciseEphemerisSample
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.System
  alias Sidereon.NIF
  alias Sidereon.NifCall

  @typedoc "A Cartesian vector in metres or metres per second, as specified by the operation."
  @type vector :: {number(), number(), number()}
  @typedoc "A satellite identifier accepted by the SP3 reader."
  @type satellite_id :: String.t() | {atom() | String.t(), pos_integer()}
  @typedoc "A time scale and split Julian date or integer nanosecond epoch."
  @type epoch :: PreciseEphemerisSample.epoch()

  defmodule OrbitScoreError do
    @moduledoc "An orbit scoring input, coverage or evaluation refusal with its details."
    defstruct [:kind, :detail, :message]
    @type t :: %__MODULE__{kind: atom(), detail: map(), message: String.t()}

    defimpl String.Chars do
      def to_string(error), do: error.message
    end
  end

  defmodule TriadVelocity do
    @moduledoc "Velocity used to form the radial, transverse and normal axes."
    @type t :: :inertial | :earth_fixed
  end

  defmodule ClockDatum do
    @moduledoc "Clock datum used before accumulating errors."
    @type t :: :epoch_system_median | :unadjusted
  end

  defmodule GapPolicy do
    @moduledoc "Whether to count or refuse an unscoreable epoch or satellite."
    @type t :: :count | :refuse
  end

  defmodule OrbitReferencePoint do
    @moduledoc "Point of a satellite to which its orbit positions refer."
    @type t :: :center_of_mass | :antenna_phase_center
  end

  defmodule OrbitFrame do
    @moduledoc "Terrestrial coordinate label or the constellation broadcast datums."
    @type t :: {:label, String.t()} | :broadcast_datums
  end

  defmodule ScoreEpochs do
    @moduledoc "Epochs at which to score the orbit source."
    @type t :: :reference_records | {:instants, [Sidereon.OrbitScoring.epoch()]}
  end

  defmodule SisreWeightSelection do
    @moduledoc "Published or caller-supplied signal-in-space range error weights."
    alias Sidereon.OrbitScoring.SisreWeights

    @type t :: :montenbruck2018 | {:fixed, SisreWeights.t()}
  end

  defmodule FrameAgreement do
    @moduledoc "How terrestrial coordinates were reconciled."
    @type t :: :same_label | :asserted_equivalent | :broadcast_datums | {:helmert, String.t(), String.t()}
  end

  defmodule ScoredProduct do
    @moduledoc "The orbit source or the reference data."
    @type t :: :source | :reference

    @doc "Return the display label of the scored product."
    @spec to_string(t()) :: String.t()
    def to_string(product), do: NIF.orbit_score_product_display(product)
  end

  defmodule OrbitRegime do
    @moduledoc "Orbit regime as distinguished by the SISRE weights."
    @type t :: :meo | :igso | :geo

    @doc "Classify a bound orbit using its inertial position and velocity in SI units."
    @spec from_inertial_state(Sidereon.OrbitScoring.vector(), Sidereon.OrbitScoring.vector()) :: t() | nil
    def from_inertial_state(position, velocity) do
      NIF.orbit_score_orbit_regime(
        Sidereon.OrbitScoring.native_vector(position),
        Sidereon.OrbitScoring.native_vector(velocity)
      )
    end

    @doc "Return the published name of the orbit regime."
    @spec to_string(t()) :: String.t()
    def to_string(regime), do: NIF.orbit_score_orbit_regime_display(regime)
  end

  defmodule RtnComponents do
    @moduledoc "Position difference resolved in the radial, transverse and normal frame, in metres. This struct compares by value."
    @enforce_keys [:radial_m, :transverse_m, :normal_m]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            radial_m: float(),
            transverse_m: float(),
            normal_m: float()
          }
  end

  defmodule OrbitSourceState do
    @moduledoc "Earth-fixed orbit position in metres and optional clock offset in seconds. This struct compares by value."
    @enforce_keys [:position_ecef_m, :clock_s]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            position_ecef_m: Sidereon.OrbitScoring.vector(),
            clock_s: float() | nil
          }
  end

  defmodule TrajectorySample do
    @moduledoc "Satellite Earth-fixed position and optional clock offset at an exact epoch. This struct compares by value."
    @enforce_keys [:satellite, :epoch, :position_ecef_m]
    defstruct [:satellite, :epoch, :position_ecef_m, clock_s: nil]

    @type t :: %__MODULE__{
            satellite: Sidereon.OrbitScoring.satellite_id(),
            epoch: Sidereon.OrbitScoring.epoch(),
            position_ecef_m: Sidereon.OrbitScoring.vector(),
            clock_s: float() | nil
          }
  end

  defmodule ErrorStats do
    @moduledoc "RMS, mean and largest absolute value in metres. This struct compares by value."
    @enforce_keys [:rms_m, :mean_m, :max_abs_m]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            rms_m: float(),
            mean_m: float(),
            max_abs_m: float()
          }
  end

  defmodule HorizonBinStats do
    @moduledoc "Errors in one prediction horizon bin. Missing metrics are nil. This struct compares by value."
    @enforce_keys [
      :horizon_start_s,
      :horizon_end_s,
      :count,
      :radial,
      :transverse,
      :normal,
      :orbit_3d,
      :sisre_orbit,
      :clock_count,
      :clock,
      :sisre
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            horizon_start_s: float(),
            horizon_end_s: float(),
            count: non_neg_integer(),
            radial: ErrorStats.t() | nil,
            transverse: ErrorStats.t() | nil,
            normal: ErrorStats.t() | nil,
            orbit_3d: ErrorStats.t() | nil,
            sisre_orbit: ErrorStats.t() | nil,
            clock_count: non_neg_integer(),
            clock: ErrorStats.t() | nil,
            sisre: ErrorStats.t() | nil
          }
  end

  defmodule ScoreCoverage do
    @moduledoc "Counts accounting for every requested satellite and epoch. This struct compares by value."
    defstruct epochs: 0,
              scored: 0,
              clocked: 0,
              outside_horizon_bins: 0,
              no_prediction_origin: 0,
              source_satellite_missing: 0,
              source_epoch_missing: 0,
              reference_satellite_missing: 0,
              reference_epoch_missing: 0

    @type t :: %__MODULE__{
            epochs: non_neg_integer(),
            scored: non_neg_integer(),
            clocked: non_neg_integer(),
            outside_horizon_bins: non_neg_integer(),
            no_prediction_origin: non_neg_integer(),
            source_satellite_missing: non_neg_integer(),
            source_epoch_missing: non_neg_integer(),
            reference_satellite_missing: non_neg_integer(),
            reference_epoch_missing: non_neg_integer()
          }
  end

  defmodule SatelliteScore do
    @moduledoc "Binned errors and coverage for one satellite. This struct compares by value."
    @enforce_keys [:satellite, :prediction_origin_j2000_s, :orbit_regime, :sisre_weights, :bins, :coverage]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            satellite: String.t(),
            prediction_origin_j2000_s: float() | nil,
            orbit_regime: OrbitRegime.t() | nil,
            sisre_weights: SisreWeights.t() | nil,
            bins: [HorizonBinStats.t()],
            coverage: ScoreCoverage.t()
          }
  end

  defmodule SystemScore do
    @moduledoc "Binned errors and coverage for one constellation. This struct compares by value."
    @enforce_keys [:system, :bins, :coverage]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            system: String.t(),
            bins: [HorizonBinStats.t()],
            coverage: ScoreCoverage.t()
          }
  end

  defmodule OrbitScoreReport do
    @moduledoc "Binned errors and coverage by satellite and constellation. This struct compares by value."
    @enforce_keys [:horizon_bin_edges_s, :frame, :source_reference_point, :per_satellite, :per_system, :coverage]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            horizon_bin_edges_s: [float()],
            frame: FrameAgreement.t(),
            source_reference_point: OrbitReferencePoint.t(),
            per_satellite: [SatelliteScore.t()],
            per_system: [SystemScore.t()],
            coverage: ScoreCoverage.t()
          }
  end

  defmodule SisreWeights do
    @moduledoc "Radial and squared transverse and normal projection weights. This struct compares by value."
    alias Sidereon.OrbitScoring
    alias Sidereon.OrbitScoring.OrbitRegime
    alias Sidereon.OrbitScoring.OrbitScoreError
    alias Sidereon.OrbitScoring.RtnComponents

    @enforce_keys [:radial, :transverse_normal_squared]
    defstruct @enforce_keys
    @type t :: %__MODULE__{radial: float(), transverse_normal_squared: float()}

    @doc "Construct SISRE weights from two projections in the interval [0, 1]."
    @spec new(number(), number()) :: {:ok, t()} | {:error, OrbitScoreError.t()}
    def new(radial, transverse_normal_squared) do
      with {:ok, weights} <-
             OrbitScoring.decode(NIF.orbit_score_sisre_weights(radial / 1.0, transverse_normal_squared / 1.0)),
           do: {:ok, struct!(__MODULE__, weights)}
    end

    @doc "Look up published SISRE weights by constellation and orbit regime."
    @spec montenbruck_2018(atom() | String.t(), OrbitRegime.t()) :: t() | nil | {:error, OrbitScoreError.t()}
    def montenbruck_2018(system, regime) do
      case System.letter(system) do
        {:ok, letter} ->
          case NIF.orbit_score_sisre_montenbruck_2018(letter, regime) do
            nil -> nil
            weights -> struct!(__MODULE__, weights)
          end

        {:error, _} = error ->
          OrbitScoring.decode(error)
      end
    end

    @doc "Evaluate orbit-only signal-in-space range error in metres."
    @spec orbit_only_m(t(), RtnComponents.t()) :: {:ok, float()} | {:error, OrbitScoreError.t()}
    def orbit_only_m(%__MODULE__{} = weights, %RtnComponents{} = components),
      do: OrbitScoring.decode(NIF.orbit_score_sisre_orbit_only_m(weights, components))

    @doc "Evaluate signal-in-space range error with a clock difference in metres."
    @spec with_clock_m(t(), RtnComponents.t(), number()) :: {:ok, float()} | {:error, OrbitScoreError.t()}
    def with_clock_m(%__MODULE__{} = weights, %RtnComponents{} = components, clock_m),
      do: OrbitScoring.decode(NIF.orbit_score_sisre_with_clock_m(weights, components, clock_m / 1.0))
  end

  defmodule Sp3FrameReconciliationOptions do
    @moduledoc "Optional label equivalences and catalog Helmert transformations. This struct compares by value."
    defstruct asserted_equivalent_label_sets: [], helmert: false
    @type t :: %__MODULE__{asserted_equivalent_label_sets: [[String.t()]], helmert: boolean()}
  end

  defmodule OrbitScoreOptions do
    @moduledoc """
    Orbit comparison controls. Each horizon bin includes its upper edge.
    A nil option uses the core default.
    This struct compares by value.
    """
    @enforce_keys [:horizon_bin_edges_s]
    defstruct [
      :horizon_bin_edges_s,
      epochs: nil,
      triad: nil,
      velocity_half_step_s: nil,
      sisre_weights: nil,
      clock_datum: nil,
      gaps: nil,
      frame_reconciliation: nil
    ]

    @type t :: %__MODULE__{
            horizon_bin_edges_s: [number()],
            epochs: ScoreEpochs.t() | nil,
            triad: TriadVelocity.t() | nil,
            velocity_half_step_s: number() | nil,
            sisre_weights: SisreWeightSelection.t() | nil,
            clock_datum: ClockDatum.t() | nil,
            gaps: GapPolicy.t() | nil,
            frame_reconciliation: Sp3FrameReconciliationOptions.t() | nil
          }
  end

  defmodule PredictedSp3 do
    @moduledoc "A predicted orbit from an SP3 product with a prediction origin."
    alias Sidereon.OrbitScoring
    alias Sidereon.OrbitScoring.OrbitScoreError

    @enforce_keys [:handle, :product]
    defstruct @enforce_keys
    @opaque t :: %__MODULE__{handle: reference(), product: SP3.t()}

    @doc "Use the last fitted record before the orbit prediction flags as the origin."
    @spec from_prediction_flags(SP3.t()) :: {:ok, t()} | {:error, OrbitScoreError.t()}
    def from_prediction_flags(%SP3{handle: handle} = product),
      do: build(product, NIF.orbit_score_predicted_sp3(handle, nil))

    @doc "Use an explicit prediction origin in the SP3 product's time scale."
    @spec with_cutoff(SP3.t(), OrbitScoring.epoch()) :: {:ok, t()} | {:error, OrbitScoreError.t()}
    def with_cutoff(%SP3{handle: handle} = product, cutoff) do
      case PreciseEphemerisSample.epoch_to_nif(cutoff) do
        {:ok, cutoff} -> build(product, NIF.orbit_score_predicted_sp3(handle, cutoff))
        {:error, _} = error -> OrbitScoring.decode(error)
      end
    end

    @doc "Return the underlying SP3 product."
    @spec product(t()) :: SP3.t()
    def product(%__MODULE__{product: product}), do: product

    defp build(product, result) do
      with {:ok, handle} <- OrbitScoring.decode(result), do: {:ok, %__MODULE__{handle: handle, product: product}}
    end
  end

  defmodule BroadcastOrbit do
    @moduledoc "A broadcast ephemeris with an explicit prediction origin in GPS time."
    alias Sidereon.OrbitScoring
    alias Sidereon.OrbitScoring.OrbitScoreError

    @enforce_keys [:handle]
    defstruct @enforce_keys
    @opaque t :: %__MODULE__{handle: reference()}

    @doc "Construct a scoreable broadcast orbit from an ephemeris and a GPS-time origin."
    @spec new(Broadcast.t(), OrbitScoring.epoch()) :: {:ok, t()} | {:error, OrbitScoreError.t()}
    def new(%Broadcast{handle: handle}, origin) do
      with {:ok, origin} <- PreciseEphemerisSample.epoch_to_nif(origin),
           {:ok, source} <- OrbitScoring.decode(NIF.orbit_score_broadcast(handle, origin)) do
        {:ok, %__MODULE__{handle: source}}
      else
        {:error, _} = error -> OrbitScoring.decode(error)
      end
    end
  end

  defmodule OrbitTrajectory do
    @moduledoc "A scoreable trajectory with exact sampled epochs and a terrestrial frame label."
    alias Sidereon.OrbitScoring
    alias Sidereon.OrbitScoring.OrbitScoreError
    alias Sidereon.OrbitScoring.TrajectorySample

    @enforce_keys [:handle]
    defstruct @enforce_keys
    @opaque t :: %__MODULE__{handle: reference()}

    @doc "Construct a trajectory from Earth-fixed samples on the prediction origin's time axis."
    @spec new(String.t(), OrbitScoring.epoch(), [TrajectorySample.t()]) :: {:ok, t()} | {:error, OrbitScoreError.t()}
    def new(frame_label, prediction_origin, samples) do
      with {:ok, origin} <- PreciseEphemerisSample.epoch_to_nif(prediction_origin),
           {:ok, samples} <- OrbitScoring.convert_all(samples, &native_sample/1),
           {:ok, handle} <- OrbitScoring.decode(NIF.orbit_score_trajectory(frame_label, origin, samples)) do
        {:ok, %__MODULE__{handle: handle}}
      else
        {:error, _} = error -> OrbitScoring.decode(error)
      end
    end

    @doc "Return the same trajectory with the stated clock relativity convention."
    @spec with_clock_relativity_included(t(), boolean()) :: t()
    def with_clock_relativity_included(%__MODULE__{handle: handle}, included) when is_boolean(included),
      do: %__MODULE__{handle: NIF.orbit_score_trajectory_configure(handle, included)}

    @doc "Return the unique trajectory epochs in increasing order."
    @spec epochs(t()) :: [OrbitScoring.epoch()]
    def epochs(%__MODULE__{handle: handle}) do
      Enum.map(NIF.orbit_score_trajectory_epochs(handle), &PreciseEphemerisSample.epoch_from_nif/1)
    end

    @doc "Return the satellites present in the trajectory."
    @spec satellites(t()) :: [String.t()]
    def satellites(%__MODULE__{handle: handle}), do: NIF.orbit_score_trajectory_satellites(handle)

    @doc "Compare trajectory samples and metadata by value."
    @spec equal?(t(), t()) :: boolean()
    def equal?(%__MODULE__{handle: first}, %__MODULE__{handle: second}),
      do: NIF.orbit_score_trajectory_equal(first, second)

    defp native_sample(%TrajectorySample{} = sample) do
      with {:ok, satellite} <- OrbitScoring.native_satellite(sample.satellite),
           {:ok, epoch} <- PreciseEphemerisSample.epoch_to_nif(sample.epoch) do
        {:ok,
         %{
           satellite: satellite,
           epoch: epoch,
           position_ecef_m: OrbitScoring.native_vector(sample.position_ecef_m),
           clock_s: if(sample.clock_s, do: sample.clock_s / 1.0)
         }}
      end
    end
  end

  @typedoc "A source of orbit states for scoring."
  @type source :: PredictedSp3.t() | BroadcastOrbit.t() | OrbitTrajectory.t()

  @doc "Score an orbit source against a reference SP3 product."
  @spec score_orbit(source(), SP3.t(), [satellite_id()], OrbitScoreOptions.t()) ::
          {:ok, OrbitScoreReport.t()} | {:error, OrbitScoreError.t()}
  def score_orbit(source, %SP3{handle: reference}, satellites, %OrbitScoreOptions{} = options) do
    with {:ok, satellites} <- convert_all(satellites, &native_satellite/1),
         {:ok, epochs} <- native_epochs(options.epochs),
         {:ok, report} <-
           decode(NIF.orbit_score_evaluate(source.handle, reference, satellites, native_options(options, epochs))) do
      {:ok, report(report)}
    else
      {:error, _} = error -> decode(error)
    end
  end

  @doc "Resolve a position difference onto the radial, transverse and normal axes, in metres."
  @spec rtn_components(vector(), vector(), vector()) :: {:ok, RtnComponents.t()} | {:error, OrbitScoreError.t()}
  def rtn_components(difference, position, velocity) do
    with {:ok, components} <-
           decode(
             NIF.orbit_score_rtn_components(native_vector(difference), native_vector(position), native_vector(velocity))
           ),
         do: {:ok, struct!(RtnComponents, components)}
  end

  @doc "Return inertial velocity in Earth-fixed axes from an Earth-fixed state in SI units."
  @spec inertial_velocity_from_earth_fixed(vector(), vector()) :: {:ok, vector()} | {:error, OrbitScoreError.t()}
  def inertial_velocity_from_earth_fixed(position, velocity) do
    decode(NIF.orbit_score_inertial_velocity_from_earth_fixed(native_vector(position), native_vector(velocity)))
  end

  @doc "Return the default half step for the reference velocity difference, in seconds."
  @spec default_velocity_half_step_s() :: float()
  def default_velocity_half_step_s, do: NIF.orbit_score_default_velocity_half_step_s()

  @doc "Return the minimum half step for the reference velocity difference, in seconds."
  @spec min_velocity_half_step_s() :: float()
  def min_velocity_half_step_s, do: NIF.orbit_score_min_velocity_half_step_s()

  @doc "Return the time scale abbreviation of the orbit source."
  @spec time_scale(source()) :: {:ok, String.t()} | {:error, OrbitScoreError.t()}
  def time_scale(source), do: metadata(source, 0)

  @doc "Return the stated SP3 time-system label when available."
  @spec sp3_time_system(source()) :: {:ok, String.t() | nil} | {:error, OrbitScoreError.t()}
  def sp3_time_system(source), do: metadata(source, 1)

  @doc "Return the coordinate frame of the orbit source."
  @spec frame(source()) :: {:ok, OrbitFrame.t()} | {:error, OrbitScoreError.t()}
  def frame(source), do: metadata(source, 2)

  @doc "Return the point of the satellite the positions refer to."
  @spec reference_point(source()) :: {:ok, OrbitReferencePoint.t()} | {:error, OrbitScoreError.t()}
  def reference_point(source), do: metadata(source, 3)

  @doc "Return whether source clocks include the periodic relativistic term."
  @spec clock_includes_relativity(source()) :: {:ok, boolean()} | {:error, OrbitScoreError.t()}
  def clock_includes_relativity(source), do: metadata(source, 4)

  @doc "Evaluate a source state at seconds past J2000 in the source's time scale."
  @spec state_at_j2000_s(source(), satellite_id(), number()) ::
          {:ok, OrbitSourceState.t()} | {:error, OrbitScoreError.t()}
  def state_at_j2000_s(source, satellite, epoch) do
    with {:ok, satellite} <- native_satellite(satellite),
         {:ok, state} <- decode(NIF.orbit_score_source_state(source.handle, satellite, epoch / 1.0)) do
      {:ok, struct!(OrbitSourceState, state)}
    else
      {:error, _} = error -> decode(error)
    end
  end

  @doc "Return the start of the orbit prediction in seconds past J2000 on the source's time axis."
  @spec prediction_origin_j2000_s(source(), satellite_id()) :: {:ok, float() | nil} | {:error, OrbitScoreError.t()}
  def prediction_origin_j2000_s(source, satellite) do
    case native_satellite(satellite) do
      {:ok, satellite} -> decode(NIF.orbit_score_source_origin(source.handle, satellite))
      {:error, _} = error -> decode(error)
    end
  end

  @doc false
  @spec native_satellite(satellite_id()) :: {:ok, {String.t(), String.t()}} | {:error, term()}
  def native_satellite({system, prn}) when is_integer(prn) do
    with {:ok, letter} <- System.letter(system), do: {:ok, {letter, Integer.to_string(prn)}}
  end

  def native_satellite(<<letter::binary-size(1), digits::binary>> = satellite) do
    with {prn, ""} <- Integer.parse(digits),
         {:ok, letter} <- System.letter(String.upcase(letter)) do
      {:ok, {letter, Integer.to_string(prn)}}
    else
      _ -> {:error, {:bad_sat_id, satellite}}
    end
  end

  def native_satellite(satellite), do: {:error, {:bad_sat_id, satellite}}

  @doc false
  @spec native_vector(vector()) :: {float(), float(), float()}
  def native_vector({x, y, z}), do: {x / 1.0, y / 1.0, z / 1.0}

  @doc false
  @spec decode(term()) :: term()
  def decode(result), do: NifCall.decode(result, OrbitScoreError)

  @doc false
  @spec convert_all(list(), (term() -> {:ok, term()} | {:error, term()})) :: {:ok, list()} | {:error, term()}
  def convert_all(values, convert) do
    result =
      Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
        case convert.(value) do
          {:ok, value} -> {:cont, {:ok, [value | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    with {:ok, values} <- result, do: {:ok, Enum.reverse(values)}
  end

  defp metadata(source, index) do
    with {:ok, values} <- decode(NIF.orbit_score_source_metadata(source.handle)),
         do: {:ok, elem(values, index)}
  end

  defp native_epochs(nil), do: {:ok, nil}
  defp native_epochs(:reference_records), do: {:ok, :reference_records}

  defp native_epochs({:instants, epochs}) do
    with {:ok, epochs} <- convert_all(epochs, &PreciseEphemerisSample.epoch_to_nif/1), do: {:ok, {:instants, epochs}}
  end

  defp native_options(opts, epochs) do
    %{
      opts
      | epochs: epochs,
        horizon_bin_edges_s: Enum.map(opts.horizon_bin_edges_s, &(&1 / 1.0)),
        velocity_half_step_s: if(opts.velocity_half_step_s, do: opts.velocity_half_step_s / 1.0)
    }
  end

  defp report(value) do
    struct!(OrbitScoreReport, %{
      value
      | per_satellite: Enum.map(value.per_satellite, &satellite_score/1),
        per_system: Enum.map(value.per_system, &system_score/1),
        coverage: struct!(ScoreCoverage, value.coverage)
    })
  end

  defp satellite_score(value) do
    struct!(SatelliteScore, %{
      value
      | bins: Enum.map(value.bins, &horizon_bin/1),
        coverage: struct!(ScoreCoverage, value.coverage),
        sisre_weights: optional_struct(SisreWeights, value.sisre_weights)
    })
  end

  defp system_score(value) do
    struct!(SystemScore, %{
      value
      | bins: Enum.map(value.bins, &horizon_bin/1),
        coverage: struct!(ScoreCoverage, value.coverage)
    })
  end

  defp horizon_bin(value) do
    value =
      Enum.reduce([:radial, :transverse, :normal, :orbit_3d, :clock, :sisre, :sisre_orbit], value, fn key, acc ->
        Map.update!(acc, key, &optional_struct(ErrorStats, &1))
      end)

    struct!(HorizonBinStats, value)
  end

  defp optional_struct(_module, nil), do: nil
  defp optional_struct(module, value), do: struct!(module, value)
end
