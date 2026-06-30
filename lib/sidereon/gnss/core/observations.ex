defmodule Sidereon.GNSS.Core.Observations do
  @moduledoc false

  def normalize_code_phase(observations, opts) do
    dedupe_by_satellite(observations, &normalize_code_phase_entry(&1, opts), opts)
  end

  def normalize_dual_frequency(observations, opts) do
    dedupe_by_satellite(observations, &normalize_dual_frequency_entry(&1, opts), opts)
  end

  def dedupe_by_satellite(observations, normalize_entry, opts) do
    observations
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn entry, {:ok, acc, seen} ->
      case normalize_entry.(entry) do
        {:ok, %{satellite_id: sat} = obs} ->
          if MapSet.member?(seen, sat) do
            {:halt, {:error, {:duplicate_observation, sat}}}
          else
            {:cont, {:ok, [obs | acc], MapSet.put(seen, sat)}}
          end

        {:error, _reason} = err ->
          {:halt, normalize_error(err, entry, opts)}
      end
    end)
    |> case do
      {:ok, acc, _seen} ->
        observations =
          acc
          |> Enum.reverse()
          |> maybe_sort(Keyword.get(opts, :sort?, false))

        {:ok, container(observations, Keyword.get(opts, :container, :list))}

      {:error, _reason} = err ->
        err
    end
  end

  defp normalize_code_phase_entry(%{satellite_id: sat, code_m: code, phase_m: phase} = obs, opts)
       when is_binary(sat) and is_number(code) and is_number(phase) do
    with {:ok, ambiguity_id} <- ambiguity_id(obs, sat, opts),
         {:ok, lli} <- single_lli(obs, opts) do
      %{
        satellite_id: sat,
        ambiguity_id: ambiguity_id,
        code_m: code / 1.0,
        phase_m: phase / 1.0
      }
      |> maybe_put(:lli, lli, Keyword.get(opts, :lli) == :single)
      |> maybe_put(:raw, obs, Keyword.get(opts, :include_raw?, false))
      |> then(&{:ok, &1})
    end
  end

  defp normalize_code_phase_entry({sat, code, phase} = obs, opts)
       when is_binary(sat) and is_number(code) and is_number(phase) do
    %{
      satellite_id: sat,
      ambiguity_id: sat,
      code_m: code / 1.0,
      phase_m: phase / 1.0
    }
    |> maybe_put(:lli, nil, Keyword.get(opts, :lli) == :single)
    |> maybe_put(:raw, obs, Keyword.get(opts, :include_raw?, false))
    |> then(&{:ok, &1})
  end

  defp normalize_code_phase_entry(entry, _opts), do: {:error, {:invalid_observation, entry}}

  defp normalize_dual_frequency_entry(
         %{satellite_id: sat, p1_m: p1, p2_m: p2, phi1_cyc: phi1, phi2_cyc: phi2, f1_hz: f1, f2_hz: f2} = obs,
         opts
       )
       when is_binary(sat) and is_number(p1) and is_number(p2) and is_number(phi1) and is_number(phi2) and is_number(f1) and
              is_number(f2) and f1 > 0.0 and f2 > 0.0 do
    with {:ok, ambiguity_id} <- ambiguity_id(obs, sat, opts),
         {:ok, {lli1, lli2}} <- dual_lli(obs, opts) do
      %{
        satellite_id: sat,
        ambiguity_id: ambiguity_id,
        p1_m: p1 / 1.0,
        p2_m: p2 / 1.0,
        phi1_cyc: phi1 / 1.0,
        phi2_cyc: phi2 / 1.0,
        f1_hz: f1 / 1.0,
        f2_hz: f2 / 1.0
      }
      |> maybe_put(:lli1, lli1, Keyword.get(opts, :lli) == :dual)
      |> maybe_put(:lli2, lli2, Keyword.get(opts, :lli) == :dual)
      |> maybe_put(:raw, obs, Keyword.get(opts, :include_raw?, false))
      |> then(&{:ok, &1})
    end
  end

  defp normalize_dual_frequency_entry(entry, _opts), do: {:error, {:invalid_dual_frequency_observation, entry}}

  defp ambiguity_id(obs, sat, opts) do
    case Keyword.get(opts, :ambiguity_id, :from_observation) do
      :satellite ->
        {:ok, sat}

      :from_observation ->
        case Map.get(obs, :ambiguity_id, sat) do
          ambiguity_id when is_binary(ambiguity_id) -> {:ok, ambiguity_id}
          _other -> {:error, {:invalid_observation, obs}}
        end
    end
  end

  defp single_lli(obs, opts) do
    if Keyword.get(opts, :lli) == :single do
      lli = Map.get(obs, :lli, Map.get(obs, :loss_of_lock_indicator))
      validate_lli(lli, opts, {:invalid_observation, obs})
    else
      {:ok, nil}
    end
  end

  defp dual_lli(obs, opts) do
    if Keyword.get(opts, :lli) == :dual do
      with {:ok, lli1} <- validate_lli(Map.get(obs, :lli1), opts, {:invalid_observation, obs}),
           {:ok, lli2} <- validate_lli(Map.get(obs, :lli2), opts, {:invalid_observation, obs}) do
        {:ok, {lli1, lli2}}
      end
    else
      {:ok, {nil, nil}}
    end
  end

  defp validate_lli(lli, opts, error) do
    if Keyword.get(opts, :validate_lli?, false) do
      case lli do
        nil -> {:ok, nil}
        value when is_integer(value) -> {:ok, value}
        _other -> {:error, error}
      end
    else
      {:ok, lli}
    end
  end

  defp normalize_error({:error, _reason} = err, entry, opts) do
    case Keyword.get(opts, :error_tag) do
      nil -> err
      tag -> {:error, {tag, entry}}
    end
  end

  defp maybe_sort(observations, true), do: Enum.sort_by(observations, & &1.satellite_id)
  defp maybe_sort(observations, _false), do: observations

  defp container(observations, :map), do: Map.new(observations, &{&1.satellite_id, &1})
  defp container(observations, :list), do: observations

  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)
  defp maybe_put(map, _key, _value, _false), do: map
end
