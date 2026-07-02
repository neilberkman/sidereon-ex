defmodule Sidereon.Drag do
  @moduledoc """
  Atmospheric drag parameters, acceleration, and decay estimates.
  """

  alias Sidereon.Astro.Relative.State
  alias Sidereon.NIF

  defmodule SpaceWeather do
    @moduledoc """
    Space-weather inputs for the core drag model.
    """
    @enforce_keys [:f107, :f107a, :ap]
    defstruct [:f107, :f107a, :ap]
    @type t :: %__MODULE__{f107: float(), f107a: float(), ap: float()}
  end

  defmodule Parameters do
    @moduledoc """
    Ballistic drag settings passed to propagation and drag-force calculations.
    """
    @enforce_keys [:bc_factor_m2_kg, :space_weather, :cutoff_altitude_km]
    defstruct [:bc_factor_m2_kg, :space_weather, :cutoff_altitude_km]

    @type t :: %__MODULE__{
            bc_factor_m2_kg: float(),
            space_weather: SpaceWeather.t(),
            cutoff_altitude_km: float()
          }
  end

  defmodule DecayEstimate do
    @moduledoc """
    Estimated decay time and reentry state.
    """
    @enforce_keys [:time_to_decay_s, :reentry_state, :reentry_altitude_km]
    defstruct [:time_to_decay_s, :reentry_state, :reentry_altitude_km]

    @type t :: %__MODULE__{
            time_to_decay_s: float(),
            reentry_state: State.t(),
            reentry_altitude_km: float()
          }
  end

  @default_cutoff_altitude_km 100.0

  @spec default_space_weather() :: SpaceWeather.t()
  def default_space_weather do
    fields = NIF.drag_space_weather_default()
    %SpaceWeather{f107: fields.f107, f107a: fields.f107a, ap: fields.ap}
  end

  @spec from_area_mass(number(), number(), number(), keyword()) :: {:ok, Parameters.t()} | {:error, atom()}
  def from_area_mass(cd, area_m2, mass_kg, opts \\ []) do
    call_params(:drag_parameters_from_area_mass, [
      cd / 1.0,
      area_m2 / 1.0,
      mass_kg / 1.0,
      space_weather_map(Keyword.get(opts, :space_weather, default_space_weather())),
      Keyword.get(opts, :cutoff_altitude_km, @default_cutoff_altitude_km) / 1.0
    ])
  end

  @spec from_bc_factor(number(), keyword()) :: {:ok, Parameters.t()} | {:error, atom()}
  def from_bc_factor(bc_factor_m2_kg, opts \\ []) do
    call_params(:drag_parameters_from_bc_factor, [
      bc_factor_m2_kg / 1.0,
      space_weather_map(Keyword.get(opts, :space_weather, default_space_weather())),
      Keyword.get(opts, :cutoff_altitude_km, @default_cutoff_altitude_km) / 1.0
    ])
  end

  @spec from_ballistic_coefficient(number(), keyword()) :: {:ok, Parameters.t()} | {:error, atom()}
  def from_ballistic_coefficient(bc_kg_m2, opts \\ []) do
    call_params(:drag_parameters_from_ballistic_coefficient, [
      bc_kg_m2 / 1.0,
      space_weather_map(Keyword.get(opts, :space_weather, default_space_weather())),
      Keyword.get(opts, :cutoff_altitude_km, @default_cutoff_altitude_km) / 1.0
    ])
  end

  @spec acceleration(Parameters.t(), State.t()) :: {:ok, {float(), float(), float()}} | {:error, atom()}
  def acceleration(%Parameters{} = params, %State{} = state) do
    NIF.drag_force_acceleration(params_map(params), Map.from_struct(state))
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @spec estimate_decay(State.t(), Parameters.t(), keyword()) :: {:ok, DecayEstimate.t()} | {:error, term()}
  def estimate_decay(%State{} = state, %Parameters{} = params, opts \\ []) do
    case NIF.drag_estimate_decay(
           Map.from_struct(state),
           params_map(params),
           Keyword.get(opts, :force_model, :twobody) |> Atom.to_string(),
           Keyword.get(opts, :abs_tol, 1.0e-9) / 1.0,
           Keyword.get(opts, :rel_tol, 1.0e-12) / 1.0,
           Keyword.get(opts, :reentry_altitude_km, @default_cutoff_altitude_km) / 1.0,
           Keyword.get(opts, :scan_step_s, 60.0) / 1.0,
           Keyword.get(opts, :crossing_tolerance_s, 1.0) / 1.0,
           Keyword.get(opts, :max_duration_s, 12_000_000.0) / 1.0,
           Keyword.get(opts, :max_scan_samples, 200_000)
         ) do
      {:ok, fields} -> {:ok, to_decay(fields)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  def from_area_mass!(cd, area_m2, mass_kg, opts \\ []), do: bang(from_area_mass(cd, area_m2, mass_kg, opts))
  def from_bc_factor!(bc_factor_m2_kg, opts \\ []), do: bang(from_bc_factor(bc_factor_m2_kg, opts))
  def from_ballistic_coefficient!(bc_kg_m2, opts \\ []), do: bang(from_ballistic_coefficient(bc_kg_m2, opts))
  def acceleration!(params, state), do: bang(acceleration(params, state))
  def estimate_decay!(state, params, opts \\ []), do: bang(estimate_decay(state, params, opts))

  defp call_params(fun, args) do
    case apply(NIF, fun, args) do
      {:ok, fields} -> {:ok, to_params(fields)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp to_params(fields) do
    %Parameters{
      bc_factor_m2_kg: fields.bc_factor_m2_kg,
      space_weather: %SpaceWeather{f107: fields.f107, f107a: fields.f107a, ap: fields.ap},
      cutoff_altitude_km: fields.cutoff_altitude_km
    }
  end

  defp to_decay(fields) do
    state = fields.reentry_state

    %DecayEstimate{
      time_to_decay_s: fields.time_to_decay_s,
      reentry_altitude_km: fields.reentry_altitude_km,
      reentry_state: %State{
        epoch_tdb_seconds: state.epoch_tdb_seconds,
        position_km: state.position_km,
        velocity_km_s: state.velocity_km_s
      }
    }
  end

  defp params_map(%Parameters{} = params) do
    %{
      bc_factor_m2_kg: params.bc_factor_m2_kg,
      f107: params.space_weather.f107,
      f107a: params.space_weather.f107a,
      ap: params.space_weather.ap,
      cutoff_altitude_km: params.cutoff_altitude_km
    }
  end

  defp space_weather_map(%SpaceWeather{} = sw), do: Map.from_struct(sw)
  defp bang({:ok, value}), do: value
  defp bang({:error, reason}), do: raise(ArgumentError, "drag calculation failed: #{inspect(reason)}")
end
