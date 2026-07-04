defmodule Sidereon.GNSS.ARAIM do
  @moduledoc """
  ARAIM snapshot integrity protection levels.

  This module binds the core ARAIM multi-hypothesis snapshot solver. Callers
  provide receiver geometry and integrity support message records. Returned HPL,
  VPL, EMT, and accuracy sigmas are meters.
  """

  alias __MODULE__.{ConstellationIsm, FaultMode, Geometry, IntegrityAllocation, Ism, Result, Row, SatelliteIsm}
  alias Sidereon.GNSS.ARAIM
  alias Sidereon.GNSS.Core.Types
  alias Sidereon.NIF

  defmodule Row do
    @moduledoc """
    One satellite row in an ARAIM geometry snapshot.

    `:line_of_sight` is an ECEF receiver-to-satellite unit vector, and
    `:elevation_rad` is the receiver elevation angle in radians.
    """

    @enforce_keys [:id, :line_of_sight, :system, :elevation_rad]
    defstruct [:id, :line_of_sight, :system, :elevation_rad]

    @type t :: %__MODULE__{
            id: String.t(),
            line_of_sight: {float(), float(), float()},
            system: String.t(),
            elevation_rad: float()
          }

    @doc """
    Build a satellite geometry row.

    `line_of_sight` is dimensionless ECEF `{e_x, e_y, e_z}` and
    `elevation_rad` is radians. If `system` is omitted, it is derived from the
    satellite token's leading letter.
    """
    @spec new(String.t(), {number(), number(), number()}, number(), atom() | String.t() | nil) :: t()
    def new(id, line_of_sight, elevation_rad, system \\ nil) do
      %__MODULE__{
        id: id,
        line_of_sight: line_of_sight,
        system: system || String.first(id),
        elevation_rad: elevation_rad / 1.0
      }
    end

    @doc false
    @spec to_nif_tuple(t()) :: {:ok, tuple()} | {:error, term()}
    def to_nif_tuple(%__MODULE__{id: id, line_of_sight: los, system: system, elevation_rad: elevation_rad}) do
      with {:ok, {e_x, e_y, e_z}} <- Types.normalize_ecef(los, :bad_line_of_sight),
           {:ok, system} <- ARAIM.system_letter(system) do
        {:ok, {id, {e_x, e_y, e_z}, system, elevation_rad / 1.0}}
      end
    end
  end

  defmodule Geometry do
    @moduledoc """
    ARAIM snapshot geometry.

    `:receiver` is `{lat_rad, lon_rad, height_m}`. `:clock_systems` is the
    ordered receiver-clock column list, encoded as GNSS system letters.
    """

    alias Sidereon.GNSS.ARAIM.Row

    @enforce_keys [:rows, :receiver, :clock_systems]
    defstruct [:rows, :receiver, :clock_systems]

    @type receiver :: {float(), float(), float()}
    @type t :: %__MODULE__{
            rows: [Row.t()],
            receiver: receiver(),
            clock_systems: [String.t()]
          }

    @doc """
    Build an ARAIM geometry snapshot.

    Receiver latitude and longitude are radians, receiver height is meters, and
    clock systems use GNSS letters or supported atoms such as `:gps`.
    """
    @spec new([Row.t()], {number(), number(), number()}, [atom() | String.t()]) :: t()
    def new(rows, {lat_rad, lon_rad, height_m}, clock_systems) when is_list(rows) and is_list(clock_systems) do
      %__MODULE__{
        rows: rows,
        receiver: {lat_rad / 1.0, lon_rad / 1.0, height_m / 1.0},
        clock_systems: clock_systems
      }
    end

    @doc false
    @spec to_nif_terms(t()) :: {:ok, {[tuple()], tuple(), [String.t()]}} | {:error, term()}
    def to_nif_terms(%__MODULE__{rows: rows, receiver: receiver, clock_systems: clock_systems}) do
      with {:ok, row_terms} <- rows(rows),
           {:ok, clock_terms} <- systems(clock_systems) do
        {:ok, {row_terms, receiver, clock_terms}}
      end
    end

    defp rows(rows) do
      rows
      |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
        case Row.to_nif_tuple(row) do
          {:ok, tuple} -> {:cont, {:ok, [tuple | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)
      |> case do
        {:ok, values} -> {:ok, Enum.reverse(values)}
        {:error, _} = err -> err
      end
    end

    defp systems(clock_systems) do
      clock_systems
      |> Enum.reduce_while({:ok, []}, fn system, {:ok, acc} ->
        case ARAIM.system_letter(system) do
          {:ok, letter} -> {:cont, {:ok, [letter | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)
      |> case do
        {:ok, values} -> {:ok, Enum.reverse(values)}
        {:error, _} = err -> err
      end
    end
  end

  defmodule SatelliteIsmModel do
    @moduledoc """
    Per-satellite integrity and accuracy model without a satellite identity.

    Sigmas and nominal bias are meters. Optional effective sigmas let callers
    pass already-computed local integrity and accuracy range sigmas. `:p_sat` is
    the prior satellite-fault probability.
    """

    @enforce_keys [:sigma_ura_m, :sigma_ure_m, :b_nom_m, :p_sat]
    defstruct [:sigma_ura_m, :sigma_ure_m, :effective_sigma_int_m, :effective_sigma_acc_m, :b_nom_m, :p_sat]

    @type t :: %__MODULE__{
            sigma_ura_m: float(),
            sigma_ure_m: float(),
            effective_sigma_int_m: float() | nil,
            effective_sigma_acc_m: float() | nil,
            b_nom_m: float(),
            p_sat: float()
          }

    @doc """
    Build a per-satellite ISM model.

    Sigma and bias inputs are meters. `opts` may include
    `:effective_sigma_int_m` and `:effective_sigma_acc_m`; supply both or omit
    both.
    """
    @spec new(number(), number(), number(), number(), keyword()) :: t()
    def new(sigma_ura_m, sigma_ure_m, b_nom_m, p_sat, opts \\ []) do
      %__MODULE__{
        sigma_ura_m: sigma_ura_m / 1.0,
        sigma_ure_m: sigma_ure_m / 1.0,
        effective_sigma_int_m: optional_float(Keyword.get(opts, :effective_sigma_int_m)),
        effective_sigma_acc_m: optional_float(Keyword.get(opts, :effective_sigma_acc_m)),
        b_nom_m: b_nom_m / 1.0,
        p_sat: p_sat / 1.0
      }
    end

    @doc false
    @spec to_nif_tuple(t()) :: tuple()
    def to_nif_tuple(%__MODULE__{} = model) do
      {
        model.sigma_ura_m,
        model.sigma_ure_m,
        model.effective_sigma_int_m,
        model.effective_sigma_acc_m,
        model.b_nom_m,
        model.p_sat
      }
    end

    defp optional_float(nil), do: nil
    defp optional_float(value), do: value / 1.0
  end

  defmodule ConstellationIsm do
    @moduledoc """
    Per-constellation ARAIM ISM defaults.

    `:p_const` is the constellation-wide fault prior. The default satellite
    model uses meters for sigma and bias fields.
    """

    alias Sidereon.GNSS.ARAIM.SatelliteIsmModel

    @enforce_keys [:system, :p_const, :default_sat]
    defstruct [:system, :p_const, :default_sat]

    @type t :: %__MODULE__{
            system: String.t(),
            p_const: float(),
            default_sat: SatelliteIsmModel.t()
          }

    @doc """
    Build a per-constellation ISM record.
    """
    @spec new(atom() | String.t(), number(), SatelliteIsmModel.t()) :: t()
    def new(system, p_const, %SatelliteIsmModel{} = default_sat) do
      %__MODULE__{system: system, p_const: p_const / 1.0, default_sat: default_sat}
    end

    @doc false
    @spec to_nif_tuple(t()) :: {:ok, tuple()} | {:error, term()}
    def to_nif_tuple(%__MODULE__{} = ism) do
      with {:ok, system} <- ARAIM.system_letter(ism.system) do
        {:ok, {system, ism.p_const, SatelliteIsmModel.to_nif_tuple(ism.default_sat)}}
      end
    end
  end

  defmodule SatelliteIsm do
    @moduledoc """
    Per-satellite ARAIM ISM override.

    Sigma and nominal-bias fields are meters. Optional effective sigmas let
    callers pass already-computed local integrity and accuracy range sigmas.
    `:p_sat` is the prior satellite-fault probability.
    """

    @enforce_keys [:id, :sigma_ura_m, :sigma_ure_m, :b_nom_m, :p_sat]
    defstruct [:id, :sigma_ura_m, :sigma_ure_m, :effective_sigma_int_m, :effective_sigma_acc_m, :b_nom_m, :p_sat]

    @type t :: %__MODULE__{
            id: String.t(),
            sigma_ura_m: float(),
            sigma_ure_m: float(),
            effective_sigma_int_m: float() | nil,
            effective_sigma_acc_m: float() | nil,
            b_nom_m: float(),
            p_sat: float()
          }

    @doc """
    Build a satellite-specific ISM override.

    Sigma and bias inputs are meters. `opts` may include
    `:effective_sigma_int_m` and `:effective_sigma_acc_m`; supply both or omit
    both.
    """
    @spec new(String.t(), number(), number(), number(), number(), keyword()) :: t()
    def new(id, sigma_ura_m, sigma_ure_m, b_nom_m, p_sat, opts \\ []) do
      %__MODULE__{
        id: id,
        sigma_ura_m: sigma_ura_m / 1.0,
        sigma_ure_m: sigma_ure_m / 1.0,
        effective_sigma_int_m: optional_float(Keyword.get(opts, :effective_sigma_int_m)),
        effective_sigma_acc_m: optional_float(Keyword.get(opts, :effective_sigma_acc_m)),
        b_nom_m: b_nom_m / 1.0,
        p_sat: p_sat / 1.0
      }
    end

    @doc false
    @spec to_nif_tuple(t()) :: tuple()
    def to_nif_tuple(%__MODULE__{} = ism) do
      {
        ism.id,
        ism.sigma_ura_m,
        ism.sigma_ure_m,
        ism.effective_sigma_int_m,
        ism.effective_sigma_acc_m,
        ism.b_nom_m,
        ism.p_sat
      }
    end

    defp optional_float(nil), do: nil
    defp optional_float(value), do: value / 1.0
  end

  defmodule Ism do
    @moduledoc """
    ARAIM integrity support message input.

    The message contains per-constellation defaults and optional per-satellite
    overrides.
    """

    alias Sidereon.GNSS.ARAIM.ConstellationIsm
    alias Sidereon.GNSS.ARAIM.SatelliteIsm

    @enforce_keys [:constellations, :satellites]
    defstruct [:constellations, :satellites]

    @type t :: %__MODULE__{
            constellations: [ConstellationIsm.t()],
            satellites: [SatelliteIsm.t()]
          }

    @doc """
    Build an ISM input.
    """
    @spec new([ConstellationIsm.t()], [SatelliteIsm.t()]) :: t()
    def new(constellations, satellites \\ []) when is_list(constellations) and is_list(satellites) do
      %__MODULE__{constellations: constellations, satellites: satellites}
    end

    @doc false
    @spec to_nif_terms(t()) :: {:ok, {[tuple()], [tuple()]}} | {:error, term()}
    def to_nif_terms(%__MODULE__{constellations: constellations, satellites: satellites}) do
      with {:ok, constellation_terms} <- constellations(constellations) do
        {:ok, {constellation_terms, Enum.map(satellites, &SatelliteIsm.to_nif_tuple/1)}}
      end
    end

    defp constellations(values) do
      values
      |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
        case ConstellationIsm.to_nif_tuple(value) do
          {:ok, tuple} -> {:cont, {:ok, [tuple | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)
      |> case do
        {:ok, tuples} -> {:ok, Enum.reverse(tuples)}
        {:error, _} = err -> err
      end
    end
  end

  defmodule IntegrityAllocation do
    @moduledoc """
    ARAIM integrity and continuity risk allocation.

    PHMI and false-alert fields are probabilities. Protection levels returned by
    the solver are meters.
    """

    @enforce_keys [
      :phmi_total,
      :phmi_vert,
      :phmi_hor,
      :pfa_vert,
      :pfa_hor,
      :p_threshold_unmonitored,
      :max_fault_order
    ]
    defstruct [
      :phmi_total,
      :phmi_vert,
      :phmi_hor,
      :pfa_vert,
      :pfa_hor,
      :p_threshold_unmonitored,
      :max_fault_order,
      p_emt: 1.0e-5
    ]

    @type t :: %__MODULE__{
            phmi_total: float(),
            phmi_vert: float(),
            phmi_hor: float(),
            pfa_vert: float(),
            pfa_hor: float(),
            p_threshold_unmonitored: float(),
            p_emt: float(),
            max_fault_order: non_neg_integer()
          }

    @doc """
    Return the core LPV-200 ARAIM allocation.
    """
    @spec lpv_200() :: t()
    def lpv_200 do
      from_nif_tuple(NIF.araim_lpv_200_allocation())
    end

    @doc false
    @spec to_nif_tuple(t()) :: tuple()
    def to_nif_tuple(%__MODULE__{} = allocation) do
      {
        allocation.phmi_total,
        allocation.phmi_vert,
        allocation.phmi_hor,
        allocation.pfa_vert,
        allocation.pfa_hor,
        allocation.p_threshold_unmonitored,
        {allocation.p_emt || 1.0e-5, allocation.max_fault_order}
      }
    end

    @doc false
    @spec from_nif_tuple(tuple()) :: t()
    def from_nif_tuple(
          {phmi_total, phmi_vert, phmi_hor, pfa_vert, pfa_hor, p_threshold_unmonitored, {p_emt, max_fault_order}}
        ) do
      %__MODULE__{
        phmi_total: phmi_total,
        phmi_vert: phmi_vert,
        phmi_hor: phmi_hor,
        pfa_vert: pfa_vert,
        pfa_hor: pfa_hor,
        p_threshold_unmonitored: p_threshold_unmonitored,
        p_emt: p_emt,
        max_fault_order: max_fault_order
      }
    end

    def from_nif_tuple(
          {phmi_total, phmi_vert, phmi_hor, pfa_vert, pfa_hor, p_threshold_unmonitored, p_emt, max_fault_order}
        ) do
      from_nif_tuple(
        {phmi_total, phmi_vert, phmi_hor, pfa_vert, pfa_hor, p_threshold_unmonitored, {p_emt, max_fault_order}}
      )
    end

    def from_nif_tuple({phmi_total, phmi_vert, phmi_hor, pfa_vert, pfa_hor, p_threshold_unmonitored, max_fault_order}) do
      from_nif_tuple(
        {phmi_total, phmi_vert, phmi_hor, pfa_vert, pfa_hor, p_threshold_unmonitored, {1.0e-5, max_fault_order}}
      )
    end
  end

  defmodule FaultMode do
    @moduledoc """
    Per-hypothesis ARAIM monitor data.

    Sigma, bias, and threshold vectors are local `{east_m, north_m, up_m}` in
    meters.
    """

    @enforce_keys [
      :excluded,
      :excluded_constellation,
      :prior,
      :sigma_int_enu_m,
      :bias_enu_m,
      :threshold_enu_m,
      :monitorable
    ]
    defstruct [
      :excluded,
      :excluded_constellation,
      :prior,
      :sigma_int_enu_m,
      :bias_enu_m,
      :threshold_enu_m,
      :monitorable
    ]

    @type t :: %__MODULE__{
            excluded: [String.t()],
            excluded_constellation: String.t() | nil,
            prior: float(),
            sigma_int_enu_m: {float(), float(), float()},
            bias_enu_m: {float(), float(), float()},
            threshold_enu_m: {float(), float(), float()},
            monitorable: boolean()
          }
  end

  defmodule Result do
    @moduledoc """
    ARAIM protection-level result.

    `:hpl_m`, `:vpl_m`, `:emt_m`, and sigma fields are meters. `:availability`
    is true when the protection-level solve met the supplied allocation.
    """

    alias Sidereon.GNSS.ARAIM.FaultMode

    @enforce_keys [
      :hpl_m,
      :vpl_m,
      :sigma_acc_h_m,
      :sigma_acc_v_m,
      :emt_m,
      :fault_modes,
      :p_unmonitored,
      :availability
    ]
    defstruct [
      :hpl_m,
      :vpl_m,
      :sigma_acc_h_m,
      :sigma_acc_v_m,
      :emt_m,
      :fault_modes,
      :p_unmonitored,
      :availability
    ]

    @type t :: %__MODULE__{
            hpl_m: float(),
            vpl_m: float(),
            sigma_acc_h_m: float(),
            sigma_acc_v_m: float(),
            emt_m: float(),
            fault_modes: [FaultMode.t()],
            p_unmonitored: float(),
            availability: boolean()
          }
  end

  @type araim_error ::
          :insufficient_geometry
          | :unmonitorable_fault_mass
          | :numerical_failure
          | :invalid_ism
          | :invalid_allocation
          | term()

  @doc """
  Run ARAIM for a geometry snapshot, ISM input, and integrity allocation.

  Returned HPL, VPL, EMT, and accuracy sigma values are meters.
  """
  @spec araim(Geometry.t(), Ism.t(), IntegrityAllocation.t()) :: {:ok, Result.t()} | {:error, araim_error()}
  def araim(%Geometry{} = geometry, %Ism{} = ism, %IntegrityAllocation{} = allocation) do
    with {:ok, {rows, receiver, clock_systems}} <- Geometry.to_nif_terms(geometry),
         {:ok, {constellations, satellites}} <- Ism.to_nif_terms(ism) do
      case NIF.araim_solve(
             rows,
             receiver,
             clock_systems,
             constellations,
             satellites,
             IntegrityAllocation.to_nif_tuple(allocation)
           ) do
        {:ok, result} -> {:ok, result(result)}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc false
  @spec system_letter(atom() | String.t()) :: {:ok, String.t()} | {:error, term()}
  def system_letter(:gps), do: {:ok, "G"}
  def system_letter(:glonass), do: {:ok, "R"}
  def system_letter(:galileo), do: {:ok, "E"}
  def system_letter(:beidou), do: {:ok, "C"}
  def system_letter(:qzss), do: {:ok, "J"}
  def system_letter(:navic), do: {:ok, "I"}
  def system_letter(:sbas), do: {:ok, "S"}

  def system_letter(<<letter::binary-size(1)>>) do
    {:ok, String.upcase(letter)}
  end

  def system_letter(_other), do: {:error, :bad_system}

  defp result(fields) do
    %Result{
      hpl_m: fields.hpl_m,
      vpl_m: fields.vpl_m,
      sigma_acc_h_m: fields.sigma_acc_h_m,
      sigma_acc_v_m: fields.sigma_acc_v_m,
      emt_m: fields.emt_m,
      fault_modes: Enum.map(fields.fault_modes, &fault_mode/1),
      p_unmonitored: fields.p_unmonitored,
      availability: fields.availability
    }
  end

  defp fault_mode(fields) do
    %FaultMode{
      excluded: fields.excluded,
      excluded_constellation: fields.excluded_constellation,
      prior: fields.prior,
      sigma_int_enu_m: fields.sigma_int_enu_m,
      bias_enu_m: fields.bias_enu_m,
      threshold_enu_m: fields.threshold_enu_m,
      monitorable: fields.monitorable
    }
  end
end
