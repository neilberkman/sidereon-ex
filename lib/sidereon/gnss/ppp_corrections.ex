defmodule Sidereon.GNSS.PPPCorrections do
  @moduledoc """
  Precomputed, state-independent PPP per-range corrections for the static-arc
  float/fixed solve: solid-earth tide, carrier-phase wind-up, and satellite
  antenna PCO/PCV.

  All three depend only on epoch geometry (Sun/Moon direction, satellite
  position, and a fixed reference receiver position), not on the estimated
  receiver coordinates, so they are computed once before the Gauss-Newton loop
  at the seed/approx position and looked up by the row builders and the shared
  `range_corrections_m` chokepoint. The Rust core owns the modeling and
  orchestration; this module keeps the Sidereon API shape, marshals parsed ANTEX
  calibration data across the NIF, and rebuilds the unchanged public maps.
  """

  alias Sidereon.GNSS.Antex
  alias Sidereon.GNSS.Core.AntennaTerms
  alias Sidereon.GNSS.Core.Epoch
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.Time
  alias Sidereon.NIF

  @type vec3 :: {float(), float(), float()}

  @type t :: %{
          tide: %{optional(NaiveDateTime.t()) => vec3()},
          windup_m: %{optional({String.t(), NaiveDateTime.t()}) => float()},
          sat_pco_ecef: %{optional({String.t(), NaiveDateTime.t()}) => vec3()},
          sat_pcv_m: %{optional({String.t(), NaiveDateTime.t()}) => float()}
        }

  @doc """
  Build the precomputed correction tables for the arc.

  `config` keys (all optional; absent = that correction is off):

    * `:solid_earth_tide` - `true` to compute the per-epoch tide displacement.
    * `:phase_windup` - `true` to compute per-(sat,epoch) wind-up metres.
    * `:satellite_antenna` - `%{antex: %Antex{}, freq1: "G01", freq2: "G02"}` to
      compute per-(sat,epoch) satellite PCO (ECEF vector) and nadir PCV (metres).

  `ref_pos` is the reference receiver ECEF `{x,y,z}` (the solve seed/approx).
  """
  @spec build(SP3.t(), [map()], vec3(), keyword() | map()) :: {:ok, t()} | {:error, term()}
  def build(%SP3{handle: handle}, epochs, ref_pos, config) do
    with {:ok, config} <- normalize_config(config),
         {:ok, ref_pos} <- ecef_tuple(ref_pos, :ref_pos),
         {:ok, tide?} <- boolean_option(config, :solid_earth_tide, false),
         {:ok, windup?} <- boolean_option(config, :phase_windup, false),
         {:ok, sat_ant_term} <- satellite_antenna_term(Map.get(config, :satellite_antenna)),
         {:ok, core_epochs} <- epoch_terms(epochs, windup? and is_nil(sat_ant_term)) do
      if not tide? and not windup? and is_nil(sat_ant_term) do
        {:ok, empty()}
      else
        case NIF.ppp_corrections_build(
               handle,
               core_epochs,
               ref_pos,
               tide?,
               windup?,
               sat_ant_term
             ) do
          {:ok, {tide, windup_m, sat_pco_ecef, sat_pcv_m}} ->
            epoch_by_index = epoch_index(epochs)

            {:ok,
             %{
               tide: tide_map(tide, epoch_by_index),
               windup_m: sat_scalar_map(windup_m, epoch_by_index),
               sat_pco_ecef: sat_vector_map(sat_pco_ecef, epoch_by_index),
               sat_pcv_m: sat_scalar_map(sat_pcv_m, epoch_by_index)
             }}

          {:error, _reason} = err ->
            err
        end
      end
    end
  end

  def build(_sp3, _epochs, _ref_pos, _config), do: {:error, :invalid_arguments}

  @doc "Empty correction tables (no precomputed corrections)."
  @spec empty() :: t()
  def empty, do: %{tide: %{}, windup_m: %{}, sat_pco_ecef: %{}, sat_pcv_m: %{}}

  defp normalize_config(config) when is_map(config), do: {:ok, config}

  defp normalize_config(config) when is_list(config) do
    if Keyword.keyword?(config) do
      {:ok, Map.new(config)}
    else
      {:error, {:invalid_argument, :config}}
    end
  end

  defp normalize_config(_config), do: {:error, {:invalid_argument, :config}}

  defp boolean_option(config, key, default) do
    case Map.get(config, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _other -> {:error, {:invalid_option, key}}
    end
  end

  defp ecef_tuple({x, y, z}, _field) when is_number(x) and is_number(y) and is_number(z),
    do: {:ok, {x / 1.0, y / 1.0, z / 1.0}}

  defp ecef_tuple(value, field), do: {:error, {:invalid_field, field, value}}

  defp epoch_terms(epochs, needs_observation_frequency?) when is_list(epochs) do
    epochs
    |> Enum.reduce_while({:ok, []}, fn epoch, {:ok, acc} ->
      case epoch_term(epoch, needs_observation_frequency?) do
        {:ok, term} -> {:cont, {:ok, [term | acc]}}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, terms} -> {:ok, Enum.reverse(terms)}
      {:error, _reason} = err -> err
    end
  end

  defp epoch_terms(_epochs, _needs_observation_frequency?),
    do: {:error, {:invalid_argument, :epochs}}

  defp epoch_term(
         %{epoch: %NaiveDateTime{} = epoch, observations: observations},
         needs_frequency?
       )
       when is_list(observations) do
    with {:ok, observation_terms} <- observation_terms(observations, needs_frequency?) do
      {jd_whole, jd_fraction} = Time.epoch_to_split_jd(epoch)

      {:ok, {Epoch.datetime_tuple(epoch), jd_whole, jd_fraction, observation_terms}}
    end
  end

  defp epoch_term(epoch, _needs_frequency?), do: {:error, {:invalid_epoch, epoch}}

  defp observation_terms(observations, needs_frequency?) do
    observations
    |> Enum.reduce_while({:ok, []}, fn observation, {:ok, acc} ->
      case observation_term(observation, needs_frequency?) do
        {:ok, term} -> {:cont, {:ok, [term | acc]}}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, terms} -> {:ok, Enum.reverse(terms)}
      {:error, _reason} = err -> err
    end
  end

  defp observation_term(observation, needs_frequency?) when is_map(observation) do
    raw = Map.get(observation, :raw, observation)

    with {:ok, sat} <- satellite_id(observation),
         {:ok, f1} <- observation_frequency(raw, :f1_hz, needs_frequency?),
         {:ok, f2} <- observation_frequency(raw, :f2_hz, needs_frequency?) do
      {:ok, {sat, f1, f2}}
    end
  end

  defp observation_term(observation, _needs_frequency?),
    do: {:error, {:invalid_observation, observation}}

  defp satellite_id(observation) do
    case Map.fetch(observation, :satellite_id) do
      {:ok, sat} when is_binary(sat) ->
        if valid_satellite_id?(sat) do
          {:ok, sat}
        else
          {:error, {:invalid_field, :satellite_id, sat}}
        end

      {:ok, value} ->
        {:error, {:invalid_field, :satellite_id, value}}

      :error ->
        {:error, {:missing_field, :satellite_id}}
    end
  end

  defp valid_satellite_id?(<<system::binary-size(1), prn::binary>>)
       when system in ~w(G R E C J I S) do
    case Integer.parse(prn) do
      {value, ""} when value > 0 -> true
      _other -> false
    end
  end

  defp valid_satellite_id?(_sat), do: false

  defp observation_frequency(raw, key, true) when is_map(raw) do
    case Map.fetch(raw, key) do
      {:ok, value} when is_number(value) and value > 0.0 -> {:ok, value / 1.0}
      {:ok, value} -> {:error, {:invalid_field, key, value}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp observation_frequency(raw, key, false) when is_map(raw) do
    case Map.get(raw, key, 0.0) do
      value when is_number(value) -> {:ok, value / 1.0}
      value -> {:error, {:invalid_field, key, value}}
    end
  end

  defp observation_frequency(raw, _key, _required?), do: {:error, {:invalid_observation, raw}}

  defp satellite_antenna_term(nil), do: {:ok, nil}

  defp satellite_antenna_term(%{antex: %Antex{} = antex, freq1: freq1, freq2: freq2})
       when is_binary(freq1) and is_binary(freq2) do
    with {:ok, freq1_hz} <- AntennaTerms.frequency_hz(freq1),
         {:ok, freq2_hz} <- AntennaTerms.frequency_hz(freq2) do
      {:ok, {freq1, freq1_hz, freq2, freq2_hz, AntennaTerms.satellite_terms(antex)}}
    end
  end

  defp satellite_antenna_term(_sat_ant), do: {:error, {:invalid_option, :satellite_antenna}}

  defp epoch_index(epochs) do
    epochs
    |> Enum.with_index()
    |> Map.new(fn {%{epoch: epoch}, index} -> {index, epoch} end)
  end

  defp tide_map(entries, epoch_by_index) do
    Map.new(entries, fn {index, d_tide} -> {Map.fetch!(epoch_by_index, index), d_tide} end)
  end

  defp sat_scalar_map(entries, epoch_by_index) do
    Map.new(entries, fn {sat, index, value} ->
      {{sat, Map.fetch!(epoch_by_index, index)}, value}
    end)
  end

  defp sat_vector_map(entries, epoch_by_index) do
    Map.new(entries, fn {sat, index, vector} ->
      {{sat, Map.fetch!(epoch_by_index, index)}, vector}
    end)
  end
end
