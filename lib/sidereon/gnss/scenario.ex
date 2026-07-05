defmodule Sidereon.GNSS.Scenario do
  @moduledoc """
  Deterministic synthetic GNSS observable scenarios.

  Scenarios may be supplied as core-schema JSON text or as Elixir maps. The
  simulator returns deterministic JSON bytes plus the core fingerprint, or a
  decoded map with receiver truth, observable arrays, and ground-truth term
  arrays.
  """

  alias Sidereon.NIF

  @typedoc "Synthetic scenario map or JSON text."
  @type scenario :: map() | keyword() | String.t()

  @typedoc "Simulation result decoded from the deterministic core bytes."
  @type result :: %{
          schema_version: integer(),
          engine_version: String.t(),
          seed: integer(),
          receiver_truth: [map()],
          observations: map(),
          truth_terms: map(),
          determinism_fingerprint: non_neg_integer()
        }

  @doc """
  Simulate a scenario and return decoded arrays.

  The `:observations` and `:truth_terms` entries contain contiguous arrays from
  the core scenario engine. For exact byte-for-byte determinism checks, use
  `simulate_bytes/1`.
  """
  @spec simulate(scenario()) :: {:ok, result()} | {:error, term()}
  def simulate(scenario) do
    with {:ok, bytes, fingerprint} <- simulate_bytes(scenario),
         {:ok, decoded} <- Jason.decode(bytes, keys: :atoms) do
      {:ok, Map.put(decoded, :determinism_fingerprint, fingerprint)}
    end
  end

  @doc """
  Simulate a scenario and return deterministic JSON bytes.

  Repeating this call with the same scenario and seed returns identical bytes
  from the core engine.
  """
  @spec simulate_bytes(scenario()) :: {:ok, binary(), non_neg_integer()} | {:error, term()}
  def simulate_bytes(scenario) do
    with {:ok, json} <- scenario_json(scenario) do
      NIF.scenario_simulate_json(json)
    end
  end

  defp scenario_json(text) when is_binary(text), do: {:ok, text}

  defp scenario_json(scenario) when is_map(scenario) or is_list(scenario) do
    scenario
    |> normalize_scenario()
    |> Jason.encode()
  end

  defp normalize_scenario(scenario) do
    %{
      schema_version: field(scenario, :schema_version, 1),
      seed: field(scenario, :seed, 0x515C1E7E0B5EA11D),
      epochs: normalize_epochs(field!(scenario, :epochs)),
      receiver: normalize_receiver(field!(scenario, :receiver)),
      constellation: normalize_constellation(field!(scenario, :constellation)),
      signals: Enum.map(field!(scenario, :signals), &normalize_signal/1),
      error_budget: normalize_error_budget(field(scenario, :error_budget, %{}))
    }
  end

  defp normalize_epochs(epochs) do
    %{
      start_j2000_s: field!(epochs, :start_j2000_s) / 1.0,
      count: field!(epochs, :count),
      cadence_s: field!(epochs, :cadence_s) / 1.0
    }
  end

  defp normalize_receiver(receiver) do
    case kind(receiver) do
      :static_geodetic ->
        %{kind: "static_geodetic", position: normalize_position(field!(receiver, :position))}

      :kinematic_waypoints ->
        %{
          kind: "kinematic_waypoints",
          waypoints: Enum.map(field!(receiver, :waypoints), &normalize_waypoint/1)
        }
    end
  end

  defp normalize_position(position) do
    if has_field?(position, :lat_deg) and has_field?(position, :lon_deg) do
      normalize_position_degrees(position)
    else
      normalize_position_radians(position)
    end
  end

  defp normalize_position_degrees(position) do
    %{
      lat_rad: deg_to_rad(field!(position, :lat_deg)),
      lon_rad: deg_to_rad(field!(position, :lon_deg)),
      height_m: field(position, :height_m, 0.0) / 1.0
    }
  end

  defp normalize_position_radians(position) do
    %{
      lat_rad: field!(position, :lat_rad) / 1.0,
      lon_rad: field!(position, :lon_rad) / 1.0,
      height_m: field(position, :height_m, 0.0) / 1.0
    }
  end

  defp normalize_waypoint(waypoint) do
    %{
      offset_s: field!(waypoint, :offset_s) / 1.0,
      position: normalize_position(field!(waypoint, :position)),
      velocity_ecef_m_s: optional_vec3(field(waypoint, :velocity_ecef_m_s, nil))
    }
  end

  defp normalize_constellation(constellation) do
    case kind(constellation) do
      :synthetic_keplerian ->
        %{
          kind: "synthetic_keplerian",
          satellites: Enum.map(field!(constellation, :satellites), &normalize_kepler_orbit/1)
        }

      :external_products ->
        %{
          kind: "external_products",
          source: normalize_external_product(field!(constellation, :source)),
          satellites: Enum.map(field!(constellation, :satellites), &satellite_id/1)
        }
    end
  end

  defp normalize_kepler_orbit(orbit) do
    %{
      satellite_id: satellite_id(field!(orbit, :satellite_id)),
      semi_major_axis_m: field!(orbit, :semi_major_axis_m) / 1.0,
      eccentricity: field!(orbit, :eccentricity) / 1.0,
      inclination_rad: angle_field(orbit, :inclination),
      raan_rad: angle_field(orbit, :raan),
      arg_perigee_rad: angle_field(orbit, :arg_perigee),
      mean_anomaly_rad: angle_field(orbit, :mean_anomaly),
      epoch_j2000_s: field!(orbit, :epoch_j2000_s) / 1.0,
      clock_bias_s: field(orbit, :clock_bias_s, 0.0) / 1.0,
      clock_drift_s_s: field(orbit, :clock_drift_s_s, 0.0) / 1.0
    }
  end

  defp normalize_signal(signal) do
    system = field!(signal, :system)

    %{
      system: system_name(system),
      code_observable: field(signal, :code_observable, "C1C"),
      phase_observable: field(signal, :phase_observable, "L1C"),
      doppler_observable: field(signal, :doppler_observable, "D1C"),
      carrier_hz: field(signal, :carrier_hz, 1_575_420_000.0) / 1.0,
      carrier_phase_bias_cycles: field(signal, :carrier_phase_bias_cycles, 0.0) / 1.0
    }
  end

  defp normalize_error_budget(error_budget) do
    %{
      receiver_clock: normalize_clock(field(error_budget, :receiver_clock, %{})),
      satellite_clock: normalize_clock(field(error_budget, :satellite_clock, %{})),
      ionosphere: normalize_media_model(field(error_budget, :ionosphere, %{kind: :off})),
      troposphere: normalize_media_model(field(error_budget, :troposphere, %{kind: :off})),
      thermal_noise: normalize_thermal(field(error_budget, :thermal_noise, %{})),
      multipath: normalize_multipath(field(error_budget, :multipath, %{})),
      elevation_mask_deg: field(error_budget, :elevation_mask_deg, 0.0) / 1.0
    }
  end

  defp normalize_clock(clock) do
    %{
      enabled: field(clock, :enabled, false),
      bias_s: field(clock, :bias_s, 0.0) / 1.0,
      drift_s_s: field(clock, :drift_s_s, 0.0) / 1.0,
      power_law_coefficients:
        clock
        |> field(:power_law_coefficients, [0.0, 0.0, 0.0, 0.0, 0.0])
        |> Enum.map(&(&1 / 1.0))
    }
  end

  defp normalize_media_model(model) do
    case kind(model) do
      :off -> %{kind: "off"}
      :klobuchar -> %{kind: "klobuchar", alpha: vec4(field!(model, :alpha)), beta: vec4(field!(model, :beta))}
      :supplied_ionex -> %{kind: "supplied_ionex", source: normalize_external_product(field!(model, :source))}
      :saastamoinen -> %{kind: "saastamoinen"}
    end
  end

  defp normalize_thermal(thermal) do
    %{
      enabled: field(thermal, :enabled, false),
      pseudorange_sigma_m: field(thermal, :pseudorange_sigma_m, 0.0) / 1.0,
      carrier_phase_sigma_m: field(thermal, :carrier_phase_sigma_m, 0.0) / 1.0,
      doppler_sigma_hz: field(thermal, :doppler_sigma_hz, 0.0) / 1.0
    }
  end

  defp normalize_multipath(multipath) do
    %{
      enabled: field(multipath, :enabled, false),
      amplitude_m: field(multipath, :amplitude_m, 0.0) / 1.0,
      reflector_height_m: field(multipath, :reflector_height_m, 0.0) / 1.0,
      phase_rad: field(multipath, :phase_rad, 0.0) / 1.0
    }
  end

  defp normalize_external_product(product) do
    %{
      kind: product |> field!(:kind) |> label(),
      product_id: field!(product, :product_id),
      content_digest: field!(product, :content_digest)
    }
  end

  defp satellite_id(satellite) when is_map(satellite) or is_list(satellite) do
    %{system: satellite |> field!(:system) |> system_name(), prn: field!(satellite, :prn)}
  end

  defp satellite_id(<<letter::binary-size(1), prn::binary>>) do
    %{system: system_name(letter), prn: String.to_integer(String.trim(prn))}
  end

  defp system_name(:gps), do: "Gps"
  defp system_name(:glonass), do: "Glonass"
  defp system_name(:galileo), do: "Galileo"
  defp system_name(:beidou), do: "BeiDou"
  defp system_name(:qzss), do: "Qzss"
  defp system_name(:navic), do: "Navic"
  defp system_name(:sbas), do: "Sbas"
  defp system_name("gps"), do: "Gps"
  defp system_name("glonass"), do: "Glonass"
  defp system_name("galileo"), do: "Galileo"
  defp system_name("beidou"), do: "BeiDou"
  defp system_name("qzss"), do: "Qzss"
  defp system_name("navic"), do: "Navic"
  defp system_name("sbas"), do: "Sbas"
  defp system_name("G"), do: "Gps"
  defp system_name("R"), do: "Glonass"
  defp system_name("E"), do: "Galileo"
  defp system_name("C"), do: "BeiDou"
  defp system_name("J"), do: "Qzss"
  defp system_name("I"), do: "Navic"
  defp system_name("S"), do: "Sbas"
  defp system_name(other) when is_binary(other), do: other

  defp kind(map) do
    value = field!(map, :kind)
    if is_binary(value), do: String.to_atom(value), else: value
  end

  defp angle_field(map, base) do
    cond do
      has_field?(map, :"#{base}_rad") -> field!(map, :"#{base}_rad") / 1.0
      has_field?(map, :"#{base}_deg") -> deg_to_rad(field!(map, :"#{base}_deg"))
    end
  end

  defp deg_to_rad(degrees), do: degrees / 1.0 * :math.pi() / 180.0

  defp optional_vec3(nil), do: nil
  defp optional_vec3(value), do: vec3(value)
  defp vec3(value), do: Enum.map(value, &(&1 / 1.0))
  defp vec4(value), do: Enum.map(value, &(&1 / 1.0))
  defp label(value) when is_atom(value), do: Atom.to_string(value)
  defp label(value) when is_binary(value), do: value

  defp field!(map, key) do
    case fetch(map, key) do
      {:ok, value} -> value
      :error -> raise KeyError, key: key, term: map
    end
  end

  defp field(map, key, default) do
    case fetch(map, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp has_field?(map, key), do: match?({:ok, _value}, fetch(map, key))

  defp fetch(map, key) when is_map(map) do
    Map.fetch(map, key)
    |> case do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp fetch(keyword, key) when is_list(keyword) do
    Keyword.fetch(keyword, key)
  end
end
