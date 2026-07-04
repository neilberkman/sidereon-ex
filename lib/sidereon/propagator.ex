defmodule Sidereon.Propagator do
  @moduledoc """
  High-precision numerical orbit propagation.

  Supports high-order adaptive numerical integration (DP54)
  of orbital states using various force models via Rust NIF.
  """

  alias Sidereon.Drag.Parameters
  alias Sidereon.SpaceWeather

  @type vec3 :: {float(), float(), float()}
  @type state :: {r :: vec3(), v :: vec3()}
  @type covariance_node :: %{
          state: %{epoch_tdb_seconds: float(), position_km: vec3(), velocity_km_s: vec3()},
          covariance: [[float()]],
          frame: String.t()
        }

  @doc """
  Adaptive step propagation using Dormand-Prince 5(4) via Rust NIF.
  Returns the state at exactly `t_end`.

  ## Options
    * `:tolerance` - Integration tolerance (default: 1.0e-12)
    * `:forces` - List of active force models: `[:twobody, :j2]`,
      `[:composite, :j2_j6, :third_body, {:srp, cr, area_to_mass_m2_kg}, :relativity]`,
      or `[:earth_phase_a]` (default: `[:twobody]`)
    * `:drag` - optional `%Sidereon.Drag.Parameters{}` drag model
    * `:space_weather_table` - optional `%Sidereon.SpaceWeather{}` used with `:drag`
    * `:epoch_tdb_seconds` - initial epoch for table-backed drag (default: 0.0)
  """
  @spec propagate(state(), float(), keyword()) :: {:ok, state()} | {:error, any()}
  def propagate({r, v}, dt, opts \\ []) do
    tol = Keyword.get(opts, :tolerance, 1.0e-12)
    forces = Keyword.get(opts, :forces, [:twobody]) |> Enum.map(&force_token/1)

    case {Keyword.get(opts, :drag), Keyword.get(opts, :space_weather_table)} do
      {nil, nil} ->
        Sidereon.NIF.propagate_dp54(r, v, dt * 1.0, forces, tol, tol)

      {%Parameters{} = drag, nil} ->
        Sidereon.NIF.propagate_dp54_with_drag(r, v, dt * 1.0, forces, tol, tol, drag_map(drag))

      {%Parameters{} = drag, %SpaceWeather{handle: handle}} ->
        Sidereon.NIF.propagate_dp54_with_drag_and_space_weather(
          r,
          v,
          Keyword.get(opts, :epoch_tdb_seconds, 0.0) / 1.0,
          dt * 1.0,
          forces,
          tol,
          tol,
          drag_map(drag),
          handle
        )

      {nil, %SpaceWeather{}} ->
        {:error, :space_weather_source_without_drag}
    end
  end

  @doc """
  Propagate a Cartesian state and its 6x6 covariance to requested TDB epochs.

  `initial_state` is `{position_km, velocity_km_s}`. `epochs_tdb_seconds` are
  absolute TDB seconds in the same scale as `:epoch_tdb_seconds`.
  """
  @spec propagate_covariance(state(), [[number()]], [number()], keyword()) ::
          {:ok, [covariance_node()]} | {:error, term()}
  def propagate_covariance({r, v}, covariance, epochs_tdb_seconds, opts \\ [])
      when is_list(covariance) and is_list(epochs_tdb_seconds) do
    initial_epoch = Keyword.get(opts, :epoch_tdb_seconds, 0.0) / 1.0

    Sidereon.NIF.propagate_covariance(
      {initial_epoch, vec3(r), vec3(v)},
      rows(covariance),
      Enum.map(epochs_tdb_seconds, &(&1 / 1.0)),
      covariance_options(opts)
    )
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp drag_map(%Parameters{} = drag) do
    %{
      bc_factor_m2_kg: drag.bc_factor_m2_kg,
      f107: drag.space_weather.f107,
      f107a: drag.space_weather.f107a,
      ap: drag.space_weather.ap,
      cutoff_altitude_km: drag.cutoff_altitude_km
    }
  end

  defp covariance_options(opts) do
    tolerance = Keyword.get(opts, :tolerance, 1.0e-12) / 1.0

    %{
      input_frame: frame(Keyword.get(opts, :input_frame, :inertial)),
      output_frame: frame(Keyword.get(opts, :output_frame, :inertial)),
      process_noise: process_noise(Keyword.get(opts, :process_noise, :none)),
      forces: Keyword.get(opts, :forces, [:twobody]) |> Enum.map(&force_token/1),
      integrator: Keyword.get(opts, :integrator, :dp54) |> to_string(),
      abs_tol: Keyword.get(opts, :abs_tol, tolerance) / 1.0,
      rel_tol: Keyword.get(opts, :rel_tol, tolerance) / 1.0,
      min_step: Keyword.get(opts, :min_step, 1.0e-6) / 1.0,
      max_step: Keyword.get(opts, :max_step, 300.0) / 1.0,
      initial_step: Keyword.get(opts, :initial_step, 1.0) / 1.0,
      max_steps: Keyword.get(opts, :max_steps, 100_000),
      dense_output: Keyword.get(opts, :dense_output, false)
    }
  end

  defp frame(:eci), do: "inertial"
  defp frame(:inertial), do: "inertial"
  defp frame(:rtn), do: "rtn"
  defp frame(value) when is_binary(value), do: value

  defp process_noise(:none) do
    %{
      kind: "none",
      q_radial_km2_s3: nil,
      q_transverse_km2_s3: nil,
      q_normal_km2_s3: nil
    }
  end

  defp process_noise({:rtn_acceleration_psd, radial, transverse, normal}) do
    %{
      kind: "rtn_acceleration_psd",
      q_radial_km2_s3: radial / 1.0,
      q_transverse_km2_s3: transverse / 1.0,
      q_normal_km2_s3: normal / 1.0
    }
  end

  defp process_noise(%{kind: _} = noise), do: noise

  defp force_token({:srp, cr, area_to_mass_m2_kg}) when is_number(cr) and is_number(area_to_mass_m2_kg) do
    "srp:#{cr / 1.0}:#{area_to_mass_m2_kg / 1.0}"
  end

  defp force_token(value), do: to_string(value)

  defp rows(matrix), do: Enum.map(matrix, fn row -> Enum.map(row, &(&1 / 1.0)) end)
  defp vec3({x, y, z}), do: {x / 1.0, y / 1.0, z / 1.0}
end
