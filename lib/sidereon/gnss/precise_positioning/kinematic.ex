defmodule Sidereon.GNSS.PrecisePositioning.Kinematic do
  @moduledoc "Kinematic PPP state prediction and sequential filtering."
  alias Sidereon.GNSS.PrecisePositioning
  alias Sidereon.NIF

  @doc "Return the complete core default kinematic configuration."
  def config, do: NIF.pp_kinematic_config_default() |> decode_config()
  @doc "Predict a kinematic state and covariance through the core."
  def predict_kinematic_state(state, covariance_m2, dt_s, ambiguity_ids, config \\ config()) do
    case NIF.pp_kinematic_predict(state_term(state), covariance_m2, dt_s / 1, ambiguity_ids, config_term(config)) do
      {:ok, {state, covariance}} -> {:ok, %{state: decode_state(state), covariance_m2: covariance}}
      {:error, detail} -> {:error, decode_error(detail)}
    end
  end

  @doc "Correct one kinematic state with an indexed epoch and its complete correction arc."
  def correct_kinematic_state(sp3, correction_epochs, epoch_index, state, covariance_m2, config \\ config(), opts \\ []) do
    case PrecisePositioning.__kinematic_ppp__(
           :correct,
           sp3,
           correction_epochs,
           epoch_index,
           state_term(state),
           covariance_m2,
           config_term(config),
           opts
         ) do
      {:ok, {next_state, covariance, summary}} ->
        {:ok, %{state: decode_state(next_state), covariance_m2: covariance, summary: decode_summary(summary)}}

      {:error, detail} ->
        {:error, decode_error(detail)}
    end
  end

  @doc "Solve an ordered epoch arc with the core kinematic PPP EKF."
  def solve_kinematic_ppp(sp3, epochs, config \\ config(), opts \\ []) do
    case PrecisePositioning.__kinematic_ppp__(:solve, sp3, epochs, 0, nil, nil, config_term(config), opts) do
      {:ok, values} -> {:ok, Enum.map(values, &decode_solution/1)}
      {:error, detail} -> {:error, decode_error(detail)}
    end
  end

  defp decode_summary({rms, used, exclusions, unplaced}),
    do: %{
      innovation_rms_m: rms,
      used_sats: used,
      ssr_bias_exclusions: exclusions,
      unplaced_observations: Enum.map(unplaced, &decode_unplaced/1)
    }

  defp decode_solution({state, covariance, used, rms, exclusions, unplaced, status}),
    do:
      Map.merge(decode_state(state), %{
        position_covariance_m2: covariance,
        used_sats: used,
        innovation_rms_m: rms,
        ssr_bias_exclusions: exclusions,
        unplaced_observations: Enum.map(unplaced, &decode_unplaced/1),
        status: status_atom(status)
      })

  defp decode_unplaced({index, satellite, ambiguity, reason}),
    do: %{epoch_index: index, satellite_id: satellite, ambiguity_id: ambiguity, reason: reason}

  defp status_atom("updated"), do: :updated
  defp status_atom("predicted_only"), do: :predicted_only

  defmodule Error do
    @moduledoc "A kinematic PPP refusal with complete core detail."
    @enforce_keys [:kind, :message]
    defstruct [:kind, :satellite_id, :field, :reason, :message]

    defimpl String.Chars, for: __MODULE__ do
      def to_string(error), do: error.message
    end
  end

  defp decode_error({kind, satellite, field, reason, message}),
    do: %Error{
      kind: error_kind(kind),
      satellite_id: satellite,
      field: field,
      reason: empty_to_nil(reason),
      message: message
    }

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp error_kind("no_ephemeris"), do: :no_ephemeris
  defp error_kind("singular_geometry"), do: :singular_geometry
  defp error_kind("invalid_solve_option"), do: :invalid_solve_option
  defp error_kind("invalid_input"), do: :invalid_input
  defp error_kind("missing_correction"), do: :missing_correction
  defp error_kind("ut1_outside_coverage"), do: :ut1_outside_coverage

  defp decode_config(
         {state, cov, {motion, velocity}, {position, density, clock, ztd, ambiguity}, new_variance, weights}
       ),
       do: %{
         initial_state: decode_state(state),
         initial_covariance_m2: cov,
         motion: %{model: model_atom(motion), velocity_m_s: velocity},
         process_noise: %{
           position: %{model: model_atom(position), spectral_density: density},
           clock_white_m2_s: clock,
           ztd_random_walk_m2_s: ztd,
           ambiguity_hold_m2_s: ambiguity
         },
         new_ambiguity_variance_m2: new_variance,
         weights: decode_weights(weights)
       }

  defp decode_state({position, clock, ztd, ambiguities}),
    do: %{position_m: position, clock_m: clock, ztd_residual_m: ztd, ambiguities_m: Map.new(ambiguities)}

  defp decode_weights({code, phase, elevation}), do: %{code: code, phase: phase, elevation_weighting: elevation}
  defp state_term(s), do: {s.position_m, s.clock_m / 1, s.ztd_residual_m / 1, Map.to_list(s.ambiguities_m)}

  defp config_term(c),
    do:
      {state_term(c.initial_state), c.initial_covariance_m2, {Atom.to_string(c.motion.model), c.motion.velocity_m_s},
       {Atom.to_string(c.process_noise.position.model), c.process_noise.position.spectral_density,
        c.process_noise.clock_white_m2_s, c.process_noise.ztd_random_walk_m2_s, c.process_noise.ambiguity_hold_m2_s},
       c.new_ambiguity_variance_m2, {c.weights.code, c.weights.phase, c.weights.elevation_weighting}}

  defp model_atom("hold"), do: :hold
  defp model_atom("constant_velocity"), do: :constant_velocity
  defp model_atom("random_walk"), do: :random_walk
  defp model_atom("white_noise_acceleration"), do: :white_noise_acceleration
end
