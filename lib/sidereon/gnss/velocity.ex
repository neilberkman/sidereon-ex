defmodule Sidereon.GNSS.Velocity do
  @moduledoc """
  Recover receiver velocity and clock drift from one epoch of range-rate or
  Doppler observations against a precise SP3 or broadcast ephemeris source.

  The numerical model and least-squares solve live in the Rust GNSS core. This
  module preserves the Elixir API shape: input normalization, per-satellite
  option resolution, and public result/error maps.
  """

  alias Sidereon.GNSS.{Broadcast, SP3, Time}
  alias Sidereon.GNSS.Core.Constants
  alias Sidereon.GNSS.Core.Types
  alias Sidereon.NIF

  @type vec3 :: {float(), float(), float()}
  @type receiver :: vec3() | %{x_m: number(), y_m: number(), z_m: number()}
  @type observation :: {String.t(), number()}

  @type result :: %{
          velocity_m_s: vec3(),
          speed_m_s: float(),
          clock_drift_s_s: float(),
          residuals_m_s: %{String.t() => float()},
          used_sats: [String.t()],
          n_satellites: non_neg_integer()
        }

  @doc """
  Solve for receiver velocity and clock drift at one receive epoch.

  `observations` are `{satellite_id, value}` pairs. Values are pseudorange rates
  in m/s by default, or Doppler shifts in Hz with `observable: :doppler`.
  """
  @spec solve(SP3.t() | Broadcast.t(), [observation()], NaiveDateTime.t(), receiver(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def solve(source, observations, epoch, receiver_position, opts \\ [])

  def solve(%SP3{} = source, observations, %NaiveDateTime{} = epoch, receiver_position, opts)
      when is_list(observations) do
    do_solve(source, observations, epoch, receiver_position, opts)
  end

  def solve(%Broadcast{} = source, observations, %NaiveDateTime{} = epoch, receiver_position, opts)
      when is_list(observations) do
    do_solve(source, observations, epoch, receiver_position, opts)
  end

  def solve(%SP3{}, observations, %NaiveDateTime{}, _receiver, _opts) when not is_list(observations),
    do: {:error, :no_observations}

  def solve(%Broadcast{}, observations, %NaiveDateTime{}, _receiver, _opts) when not is_list(observations),
    do: {:error, :no_observations}

  defp do_solve(source, observations, epoch, receiver_position, opts) do
    observable = Keyword.get(opts, :observable, :range_rate)
    carrier_hz = Keyword.get(opts, :carrier_hz, Constants.gps_l1_hz()) * 1.0
    carrier_fun = carrier_hz_fun(Keyword.get(opts, :carrier_hz_by_sat), carrier_hz)
    sat_drift_fun = sat_clock_drift_fun(Keyword.get(opts, :sat_clock_drift))
    light_time? = Keyword.get(opts, :light_time, true)
    sagnac? = Keyword.get(opts, :sagnac, true)

    with :ok <- ensure_nonempty(observations),
         {:ok, receiver} <- Types.normalize_ecef(receiver_position),
         {:ok, normalized} <- normalize_observations(observations, observable, carrier_fun),
         terms = observation_terms(normalized, sat_drift_fun),
         {:ok, core_result} <-
           core_solve(source, terms, epoch, receiver, observable, light_time?, sagnac?) do
      {:ok, to_result_map(core_result)}
    end
  end

  @doc """
  Convert a Doppler shift in Hz to a pseudorange rate in m/s.
  """
  @spec doppler_to_range_rate(number(), number()) :: float()
  def doppler_to_range_rate(doppler_hz, carrier_hz \\ Constants.gps_l1_hz()) do
    NIF.velocity_doppler_to_range_rate(doppler_hz * 1.0, carrier_hz * 1.0)
  end

  @doc """
  Convert a pseudorange rate in m/s to a Doppler shift in Hz.
  """
  @spec range_rate_to_doppler(number(), number()) :: float()
  def range_rate_to_doppler(rho_dot_m_s, carrier_hz \\ Constants.gps_l1_hz()) do
    NIF.velocity_range_rate_to_doppler(rho_dot_m_s * 1.0, carrier_hz * 1.0)
  end

  defp ensure_nonempty([]), do: {:error, :no_observations}
  defp ensure_nonempty(_), do: :ok

  defp normalize_observations(observations, observable, carrier_fun) do
    Enum.reduce_while(observations, {:ok, [], MapSet.new()}, fn entry, {:ok, acc, seen} ->
      case normalize_one(entry, observable, carrier_fun) do
        {:ok, {sat, _system_letter, _prn, _value, _carrier} = normalized} ->
          if MapSet.member?(seen, sat) do
            {:halt, {:error, {:duplicate_observation, sat}}}
          else
            {:cont, {:ok, [normalized | acc], MapSet.put(seen, sat)}}
          end

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, acc, _seen} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp normalize_one({sat, value}, :range_rate, _carrier_fun) when is_binary(sat) and is_number(value) do
    with {:ok, system_letter, prn} <- Types.parse_sat_id(sat) do
      {:ok, {sat, system_letter, prn, value * 1.0, Constants.gps_l1_hz()}}
    end
  end

  defp normalize_one({sat, value}, :doppler, carrier_fun) when is_binary(sat) and is_number(value) do
    with {:ok, system_letter, prn} <- Types.parse_sat_id(sat),
         {:ok, carrier} <- carrier_fun.(sat) do
      {:ok, {sat, system_letter, prn, value * 1.0, carrier}}
    end
  end

  defp normalize_one(entry, _observable, _carrier_fun), do: {:error, {:invalid_observation, entry}}

  defp observation_terms(normalized, sat_drift_fun) do
    Enum.map(normalized, fn {sat, system_letter, prn, value, carrier_hz} ->
      {system_letter, prn, value, carrier_hz, sat_drift_fun.(sat)}
    end)
  end

  defp core_solve(_source, [], _epoch, _receiver, _observable, _light_time?, _sagnac?),
    do: {:error, {:too_few_satellites, 0, 4}}

  defp core_solve(%SP3{handle: handle}, terms, epoch, receiver, observable, light_time?, sagnac?) do
    {jd_whole, jd_fraction} = Time.epoch_to_split_jd(epoch)

    case NIF.sp3_velocity_solve(
           handle,
           terms,
           jd_whole,
           jd_fraction,
           receiver,
           Atom.to_string(observable),
           light_time?,
           sagnac?
         ) do
      {:ok, result} -> {:ok, result}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp core_solve(%Broadcast{handle: handle}, terms, epoch, receiver, observable, light_time?, sagnac?) do
    with {:ok, t_j2000_s} <- Time.epoch_to_j2000_seconds_fractional(epoch) do
      case NIF.broadcast_velocity_solve(
             handle,
             terms,
             t_j2000_s,
             receiver,
             Atom.to_string(observable),
             light_time?,
             sagnac?
           ) do
        {:ok, result} -> {:ok, result}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp to_result_map({velocity, speed, clock_drift, residuals, used_sats}) do
    %{
      velocity_m_s: velocity,
      speed_m_s: speed,
      clock_drift_s_s: clock_drift,
      residuals_m_s: Map.new(residuals),
      used_sats: used_sats,
      n_satellites: length(used_sats)
    }
  end

  defp carrier_hz_fun(nil, default_hz) do
    fn sat -> normalize_carrier(default_hz, sat) end
  end

  defp carrier_hz_fun(map, _default_hz) when is_map(map) do
    fn sat ->
      case Map.fetch(map, sat) do
        {:ok, nil} -> {:error, {:missing_carrier, sat}}
        {:ok, hz} -> normalize_carrier(hz, sat)
        :error -> {:error, {:missing_carrier, sat}}
      end
    end
  end

  defp carrier_hz_fun(fun, _default_hz) when is_function(fun, 1) do
    fn sat ->
      case fun.(sat) do
        nil -> {:error, {:missing_carrier, sat}}
        hz -> normalize_carrier(hz, sat)
      end
    end
  end

  defp normalize_carrier(carrier, _sat) when is_number(carrier) and carrier > 0, do: {:ok, carrier * 1.0}

  defp normalize_carrier(_carrier, sat), do: {:error, {:invalid_carrier, sat}}

  defp sat_clock_drift_fun(nil), do: fn _sat -> 0.0 end

  defp sat_clock_drift_fun(map) when is_map(map), do: fn sat -> (map[sat] || 0.0) * 1.0 end

  defp sat_clock_drift_fun(fun) when is_function(fun, 1), do: fn sat -> fun.(sat) * 1.0 end
end
