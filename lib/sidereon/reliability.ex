defmodule Sidereon.Reliability do
  @moduledoc """
  Classical Baarda/Teunissen reliability diagnostics.

  This module exposes pre-data reliability design and ARAIM reliability reports
  from the Rust core. Inputs are range design rows or ARAIM geometry plus an
  integrity support model. Outputs include redundancy numbers, minimal
  detectable bias, external effects, and aggregate degrees of freedom.
  """

  alias __MODULE__.{
    ObservationReliability,
    RangeReliabilityRow,
    ReliabilityOptions,
    ReliabilityReport,
    ReliabilitySummary
  }

  alias Sidereon.GNSS.ARAIM
  alias Sidereon.NIF

  defmodule ReliabilityOptions do
    @moduledoc """
    Options for classical reliability calculations.

    `:alpha` is the two-sided false-alarm probability for the w-test. `:power`
    is the target detection power. `:lambda0_override` may supply a precomputed
    noncentrality parameter. `:min_redundancy` is the reporting floor below
    which an observation is marked uncheckable.
    """

    @enforce_keys [:alpha, :power, :lambda0_override, :min_redundancy]
    defstruct [:alpha, :power, :lambda0_override, :min_redundancy]

    @type t :: %__MODULE__{
            alpha: float(),
            power: float(),
            lambda0_override: float() | nil,
            min_redundancy: float()
          }

    @doc """
    Return the core default reliability options.
    """
    @spec default() :: t()
    def default do
      {alpha, power, lambda0_override, min_redundancy} = NIF.reliability_default_options()

      %__MODULE__{
        alpha: alpha,
        power: power,
        lambda0_override: lambda0_override,
        min_redundancy: min_redundancy
      }
    end

    @doc """
    Build reliability options from a keyword list.
    """
    @spec new(keyword()) :: t()
    def new(opts \\ []) when is_list(opts) do
      default = default()

      %__MODULE__{
        alpha: Keyword.get(opts, :alpha, default.alpha) / 1.0,
        power: Keyword.get(opts, :power, default.power) / 1.0,
        lambda0_override: optional_float(Keyword.get(opts, :lambda0_override, default.lambda0_override)),
        min_redundancy: Keyword.get(opts, :min_redundancy, default.min_redundancy) / 1.0
      }
    end

    @doc false
    @spec to_nif_tuple(t()) :: tuple()
    def to_nif_tuple(%__MODULE__{} = options) do
      {
        options.alpha,
        options.power,
        options.lambda0_override,
        options.min_redundancy
      }
    end

    defp optional_float(nil), do: nil
    defp optional_float(value), do: value / 1.0
  end

  defmodule RangeReliabilityRow do
    @moduledoc """
    One range row for pre-data reliability design.

    `:design_row` is the linearized measurement row for the estimated state.
    `:sigma_m` is the supplied one-sigma range model in meters.
    """

    @enforce_keys [:id, :design_row, :sigma_m]
    defstruct [:id, :design_row, :sigma_m]

    @type t :: %__MODULE__{
            id: String.t(),
            design_row: [float()],
            sigma_m: float()
          }

    @doc """
    Build a range reliability row.
    """
    @spec new(String.t(), [number()], number()) :: t()
    def new(id, design_row, sigma_m) when is_binary(id) and is_list(design_row) do
      %__MODULE__{
        id: id,
        design_row: Enum.map(design_row, &(&1 / 1.0)),
        sigma_m: sigma_m / 1.0
      }
    end

    @doc false
    @spec to_nif_tuple(t()) :: tuple()
    def to_nif_tuple(%__MODULE__{} = row) do
      {row.id, row.design_row, row.sigma_m}
    end
  end

  defmodule ObservationReliability do
    @moduledoc """
    Reliability diagnostics for one observation.

    When `:uncheckable` is true, `:mdb_m`, `:external_enu_m`, and
    `:bias_to_noise` are `nil`.
    """

    @enforce_keys [:id, :redundancy, :mdb_m, :external_enu_m, :bias_to_noise, :uncheckable]
    defstruct [:id, :redundancy, :mdb_m, :external_enu_m, :bias_to_noise, :uncheckable]

    @type t :: %__MODULE__{
            id: String.t(),
            redundancy: float(),
            mdb_m: float() | nil,
            external_enu_m: {float(), float(), float()} | nil,
            bias_to_noise: float() | nil,
            uncheckable: boolean()
          }
  end

  defmodule ReliabilitySummary do
    @moduledoc """
    Aggregate reliability diagnostics for a design.
    """

    @enforce_keys [
      :n_obs,
      :n_params,
      :dof,
      :sum_redundancy,
      :lambda0,
      :max_mdb_m,
      :min_redundancy,
      :n_uncheckable
    ]
    defstruct [
      :n_obs,
      :n_params,
      :dof,
      :sum_redundancy,
      :lambda0,
      :max_mdb_m,
      :min_redundancy,
      :n_uncheckable
    ]

    @type t :: %__MODULE__{
            n_obs: non_neg_integer(),
            n_params: non_neg_integer(),
            dof: non_neg_integer(),
            sum_redundancy: float(),
            lambda0: float(),
            max_mdb_m: {String.t(), float()} | nil,
            min_redundancy: {String.t(), float()},
            n_uncheckable: non_neg_integer()
          }
  end

  defmodule ReliabilityReport do
    @moduledoc """
    Full reliability report.
    """

    @enforce_keys [:per_observation, :summary]
    defstruct [:per_observation, :summary]

    @type t :: %__MODULE__{
            per_observation: [ObservationReliability.t()],
            summary: ReliabilitySummary.t()
          }
  end

  @type reliability_error ::
          :invalid_probability
          | :invalid_weight
          | :invalid_reliability_parameter
          | :invalid_design
          | :singular_geometry
          | :insufficient_geometry
          | :invalid_ism
          | :invalid_allocation
          | :numerical_failure
          | term()

  @doc """
  Compute Baarda's W-test noncentrality from false-alarm probability and power.

  Returns `{:ok, %{delta0: delta0, lambda0: lambda0}}`.
  """
  @spec wtest_noncentrality(number(), number()) ::
          {:ok, %{delta0: float(), lambda0: float()}} | {:error, reliability_error()}
  def wtest_noncentrality(alpha, power) do
    case NIF.reliability_wtest_noncentrality(alpha / 1.0, power / 1.0) do
      {:ok, result} -> {:ok, result}
      {:error, _reason} = err -> err
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Compute reliability from caller-supplied range design rows.
  """
  @spec reliability_design([RangeReliabilityRow.t()], ReliabilityOptions.t() | keyword()) ::
          {:ok, ReliabilityReport.t()} | {:error, reliability_error()}
  def reliability_design(rows, options \\ ReliabilityOptions.default()) when is_list(rows) do
    case NIF.reliability_design(Enum.map(rows, &RangeReliabilityRow.to_nif_tuple/1), options_tuple(options)) do
      {:ok, report} -> {:ok, report(report)}
      {:error, _reason} = err -> err
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Compute reliability for ARAIM geometry using the supplied ISM range model.
  """
  @spec reliability_araim(ARAIM.Geometry.t(), ARAIM.Ism.t(), ReliabilityOptions.t() | keyword()) ::
          {:ok, ReliabilityReport.t()} | {:error, reliability_error()}
  def reliability_araim(%ARAIM.Geometry{} = geometry, %ARAIM.Ism{} = ism, options \\ ReliabilityOptions.default()) do
    with {:ok, {rows, receiver, clock_systems}} <- ARAIM.Geometry.to_nif_terms(geometry),
         {:ok, {constellations, satellites}} <- ARAIM.Ism.to_nif_terms(ism) do
      case NIF.reliability_araim(
             rows,
             receiver,
             clock_systems,
             constellations,
             satellites,
             options_tuple(options)
           ) do
        {:ok, result} -> {:ok, report(result)}
        {:error, _reason} = err -> err
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp options_tuple(%ReliabilityOptions{} = options), do: ReliabilityOptions.to_nif_tuple(options)

  defp options_tuple(options) when is_list(options),
    do: options |> ReliabilityOptions.new() |> ReliabilityOptions.to_nif_tuple()

  defp report(fields) do
    %ReliabilityReport{
      per_observation: Enum.map(fields.per_observation, &observation/1),
      summary: summary(fields.summary)
    }
  end

  defp observation(fields) do
    %ObservationReliability{
      id: fields.id,
      redundancy: fields.redundancy,
      mdb_m: fields.mdb_m,
      external_enu_m: fields.external_enu_m,
      bias_to_noise: fields.bias_to_noise,
      uncheckable: fields.uncheckable
    }
  end

  defp summary(fields) do
    %ReliabilitySummary{
      n_obs: fields.n_obs,
      n_params: fields.n_params,
      dof: fields.dof,
      sum_redundancy: fields.sum_redundancy,
      lambda0: fields.lambda0,
      max_mdb_m: fields.max_mdb_m,
      min_redundancy: fields.min_redundancy,
      n_uncheckable: fields.n_uncheckable
    }
  end
end
