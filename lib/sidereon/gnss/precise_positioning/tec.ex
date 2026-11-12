defmodule Sidereon.GNSS.PrecisePositioning.TEC do
  @moduledoc "Dual-frequency slant and vertical TEC estimation delegated to the core."
  alias Sidereon.NIF

  defmodule Error do
    @moduledoc "A TEC refusal with a stable core variant and display text."
    @enforce_keys [:kind, :message]
    defstruct [:kind, :field, :reason, :message]

    defimpl String.Chars, for: __MODULE__ do
      def to_string(error), do: error.message
    end
  end

  @doc "Return all core TEC constants."
  def constants do
    {height, electrons, coefficient} = NIF.pp_tec_constants()

    %{
      default_ionospheric_shell_height_m: height,
      electrons_per_tecu_m2: electrons,
      tec_group_delay_coefficient: coefficient
    }
  end

  @doc "Return the core default thin-shell configuration."
  def config do
    {height, radius} = NIF.pp_tec_config_default()
    %{shell_height_m: height, earth_radius_m: radius}
  end

  @doc "Compute `P1 - P2` in metres."
  def code_geometry_free_m(observation), do: normalize(NIF.pp_tec_code_geometry_free(observation_term(observation)))
  @doc "Compute `L1 - L2` in metres."
  def phase_geometry_free_m(observation), do: normalize(NIF.pp_tec_phase_geometry_free(observation_term(observation)))
  @doc "Convert a code geometry-free value to slant TECU."
  def slant_tec_from_code_geometry_free_m(value, f1_hz, f2_hz),
    do: normalize(NIF.pp_tec_slant_from_code(value / 1, f1_hz / 1, f2_hz / 1))

  @doc "Convert a phase geometry-free value to slant TECU."
  def slant_tec_from_phase_geometry_free_m(value, f1_hz, f2_hz),
    do: normalize(NIF.pp_tec_slant_from_phase(value / 1, f1_hz / 1, f2_hz / 1))

  @doc "Estimate code-derived slant TEC."
  def estimate_code_slant_tec(observation),
    do: map_estimate(NIF.pp_tec_estimate_code(observation_term(observation)), :code_geometry_free_m)

  @doc "Estimate phase-derived slant TEC."
  def estimate_phase_slant_tec(observation),
    do: map_estimate(NIF.pp_tec_estimate_phase(observation_term(observation)), :phase_geometry_free_m)

  @doc "Compute the core thin-shell mapping function."
  def thin_shell_mapping_function(elevation_rad, config \\ config()),
    do: normalize(NIF.pp_tec_mapping(elevation_rad / 1, config_term(config)))

  @doc "Map slant TECU to vertical TECU."
  def vertical_tec_from_slant_tec(slant, elevation_rad, config \\ config()),
    do: normalize(NIF.pp_tec_vertical(slant / 1, elevation_rad / 1, config_term(config)))

  @doc "Level one continuous code/phase TEC arc."
  def level_slant_tec_arc(samples, config \\ config()) do
    terms = Enum.map(samples, &{&1.code_slant_tec_tecu / 1, &1.phase_slant_tec_tecu / 1, &1.elevation_rad / 1})

    case NIF.pp_tec_level(terms, config_term(config)) do
      {:ok, {bias, rows}} ->
        {:ok,
         %{
           phase_bias_tecu: bias,
           samples:
             Enum.map(rows, fn {c, p, l, m, v} ->
               %{
                 code_slant_tec_tecu: c,
                 phase_slant_tec_tecu: p,
                 leveled_slant_tec_tecu: l,
                 mapping_function: m,
                 vertical_tec_tecu: v
               }
             end)
         }}

      {:error, detail} ->
        {:error, decode_error(detail)}
    end
  end

  @doc "Compute an ionospheric pierce point on the configured shell."
  def ionospheric_pierce_point(lat, lon, elevation, azimuth, config \\ config()) do
    case NIF.pp_tec_pierce_point(lat / 1, lon / 1, elevation / 1, azimuth / 1, config_term(config)) do
      {:ok, {latr, lonr, latd, lond, angle, height}} ->
        {:ok,
         %{
           latitude_rad: latr,
           longitude_rad: lonr,
           latitude_deg: latd,
           longitude_deg: lond,
           earth_central_angle_rad: angle,
           shell_height_m: height
         }}

      {:error, detail} ->
        {:error, decode_error(detail)}
    end
  end

  @doc "Estimate leveled slant and vertical TEC over ordered epochs."
  def estimate_tec(epochs, config \\ config()) do
    terms =
      Enum.map(epochs, fn epoch ->
        {epoch.time_s / 1, epoch.receiver_latitude_rad / 1, epoch.receiver_longitude_rad / 1,
         Enum.map(epoch.observations, fn row ->
           {observation_term(row.observation), row.elevation_rad / 1, row.azimuth_rad / 1}
         end)}
      end)

    case NIF.pp_tec_estimate(terms, config_term(config)) do
      {:ok, arcs} -> {:ok, %{arcs: Enum.map(arcs, &decode_arc/1)}}
      {:error, detail} -> {:error, decode_error(detail)}
    end
  end

  defp decode_arc({sat, ambiguity, bias, samples}),
    do: %{
      satellite_id: sat,
      ambiguity_id: ambiguity,
      phase_bias_tecu: bias,
      samples: Enum.map(samples, &decode_sample/1)
    }

  defp decode_sample(
         {{time, elevation, azimuth}, {code_gf, phase_gf}, {code, phase, leveled}, {mapping, vertical}, point}
       ),
       do: %{
         time_s: time,
         elevation_rad: elevation,
         azimuth_rad: azimuth,
         code_geometry_free_m: code_gf,
         phase_geometry_free_m: phase_gf,
         code_slant_tec_tecu: code,
         phase_slant_tec_tecu: phase,
         leveled_slant_tec_tecu: leveled,
         mapping_function: mapping,
         vertical_tec_tecu: vertical,
         pierce_point: decode_point(point)
       }

  defp decode_point({latr, lonr, latd, lond, angle, height}),
    do: %{
      latitude_rad: latr,
      longitude_rad: lonr,
      latitude_deg: latd,
      longitude_deg: lond,
      earth_central_angle_rad: angle,
      shell_height_m: height
    }

  defp map_estimate({:ok, {sat, ambiguity, combination, tec}}, key),
    do: {:ok, %{key => combination, satellite_id: sat, ambiguity_id: ambiguity, slant_tec_tecu: tec}}

  defp map_estimate({:error, detail}, _key), do: {:error, decode_error(detail)}
  defp config_term(c), do: {c.shell_height_m / 1, c.earth_radius_m / 1}

  defp observation_term(o),
    do:
      {o.satellite_id, o.ambiguity_id, {o.p1_m / 1, o.p2_m / 1, o.phi1_cyc / 1, o.phi2_cyc / 1},
       {o.f1_hz / 1, o.f2_hz / 1}, {Map.get(o, :lli1), Map.get(o, :lli2)}}

  defp normalize({:error, detail}), do: {:error, decode_error(detail)}
  defp normalize(result), do: result

  defp decode_error({kind, field, reason, message}),
    do: %Error{kind: tec_kind(kind), field: field, reason: reason, message: message}

  defp tec_kind("non_finite_observation"), do: :non_finite_observation
  defp tec_kind("invalid_shell_height"), do: :invalid_shell_height
  defp tec_kind("invalid_earth_radius"), do: :invalid_earth_radius
  defp tec_kind("invalid_frequency"), do: :invalid_frequency
  defp tec_kind("equal_frequencies"), do: :equal_frequencies
  defp tec_kind("invalid_receiver_latitude"), do: :invalid_receiver_latitude
  defp tec_kind("invalid_receiver_longitude"), do: :invalid_receiver_longitude
  defp tec_kind("invalid_elevation"), do: :invalid_elevation
  defp tec_kind("invalid_azimuth"), do: :invalid_azimuth
  defp tec_kind("non_finite_tec"), do: :non_finite_tec
  defp tec_kind("empty_arc"), do: :empty_arc
  defp tec_kind("no_epochs"), do: :no_epochs
  defp tec_kind("no_observations"), do: :no_observations
  defp tec_kind("non_finite_epoch_time"), do: :non_finite_epoch_time
  defp tec_kind("epochs_not_ordered"), do: :epochs_not_ordered
  defp tec_kind("insufficient_arc_samples"), do: :insufficient_arc_samples
end
