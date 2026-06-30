defmodule Sidereon.Conjunction do
  @moduledoc """
  Time-of-closest-approach and conjunction screening helpers.
  """

  alias Sidereon.NIF

  @default_coarse_step_seconds 60.0
  @default_time_tolerance_seconds 1.0e-3

  @type split_jd :: {number(), number()}
  @type vec3 :: {float(), float(), float()}
  @type tle_pair :: {String.t(), String.t()}
  @type tca_candidate :: %{
          tca_time_jd_whole: float(),
          tca_time_jd_fraction: float(),
          tca_time_jd: float(),
          tca_seconds_since_window_start: float(),
          miss_distance_km: float(),
          relative_position_km: vec3(),
          relative_velocity_km_s: vec3()
        }
  @type tca_conjunction :: %{
          candidate: tca_candidate(),
          pc: float(),
          miss_km: float(),
          relative_speed_km_s: float(),
          sigma_x_km: float(),
          sigma_z_km: float()
        }

  @doc """
  Find local TCA candidates between two TLE line pairs.
  """
  @spec find_tca_candidates(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          split_jd(),
          split_jd(),
          keyword()
        ) :: {:ok, [tca_candidate()]} | {:error, term()}
  def find_tca_candidates(
        primary_line1,
        primary_line2,
        secondary_line1,
        secondary_line2,
        window_start_jd,
        window_end_jd,
        opts \\ []
      )

  def find_tca_candidates(
        primary_line1,
        primary_line2,
        secondary_line1,
        secondary_line2,
        window_start_jd,
        window_end_jd,
        opts
      )
      when is_binary(primary_line1) and is_binary(primary_line2) and is_binary(secondary_line1) and
             is_binary(secondary_line2) and is_list(opts) do
    with {:ok, {start_whole, start_fraction}} <- split_jd(window_start_jd),
         {:ok, {end_whole, end_fraction}} <- split_jd(window_end_jd),
         {:ok, finder} <- finder_options(opts) do
      case NIF.tca_find_candidates(
             primary_line1,
             primary_line2,
             secondary_line1,
             secondary_line2,
             start_whole,
             start_fraction,
             end_whole,
             end_fraction,
             finder.coarse_step_seconds,
             finder.time_tolerance_seconds
           ) do
        {:ok, candidates} -> {:ok, Enum.map(candidates, &candidate/1)}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Find local TCA candidates and compute collision probability at each TCA.
  """
  @spec find_tca_conjunctions(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          split_jd(),
          split_jd(),
          number(),
          keyword()
        ) :: {:ok, [tca_conjunction()]} | {:error, term()}
  def find_tca_conjunctions(
        primary_line1,
        primary_line2,
        secondary_line1,
        secondary_line2,
        window_start_jd,
        window_end_jd,
        hard_body_radius_km,
        opts \\ []
      )

  def find_tca_conjunctions(
        primary_line1,
        primary_line2,
        secondary_line1,
        secondary_line2,
        window_start_jd,
        window_end_jd,
        hard_body_radius_km,
        opts
      )
      when is_binary(primary_line1) and is_binary(primary_line2) and is_binary(secondary_line1) and
             is_binary(secondary_line2) and is_number(hard_body_radius_km) and is_list(opts) do
    with {:ok, {start_whole, start_fraction}} <- split_jd(window_start_jd),
         {:ok, {end_whole, end_fraction}} <- split_jd(window_end_jd),
         {:ok, finder} <- finder_options(opts),
         {:ok, pc} <- pc_options(hard_body_radius_km, opts) do
      case NIF.tca_find_conjunctions(
             primary_line1,
             primary_line2,
             secondary_line1,
             secondary_line2,
             start_whole,
             start_fraction,
             end_whole,
             end_fraction,
             pc.hard_body_radius_km,
             pc.method,
             pc.primary_covariance_km2,
             pc.secondary_covariance_km2,
             finder.coarse_step_seconds,
             finder.time_tolerance_seconds
           ) do
        {:ok, conjunctions} -> {:ok, Enum.map(conjunctions, &conjunction/1)}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Screen one primary TLE against a secondary TLE catalog by miss-distance threshold.
  """
  @spec screen_tca_candidates(
          String.t(),
          String.t(),
          [tle_pair()],
          split_jd(),
          split_jd(),
          number(),
          keyword()
        ) :: {:ok, [%{secondary_index: non_neg_integer(), candidate: tca_candidate()}]} | {:error, term()}
  def screen_tca_candidates(
        primary_line1,
        primary_line2,
        secondaries,
        window_start_jd,
        window_end_jd,
        miss_distance_threshold_km,
        opts \\ []
      )

  def screen_tca_candidates(
        primary_line1,
        primary_line2,
        secondaries,
        window_start_jd,
        window_end_jd,
        miss_distance_threshold_km,
        opts
      )
      when is_binary(primary_line1) and is_binary(primary_line2) and is_list(secondaries) and
             is_number(miss_distance_threshold_km) and is_list(opts) do
    with {:ok, secondaries} <- tle_pairs(secondaries),
         {:ok, {start_whole, start_fraction}} <- split_jd(window_start_jd),
         {:ok, {end_whole, end_fraction}} <- split_jd(window_end_jd),
         {:ok, finder} <- finder_options(opts) do
      case NIF.tca_screen_candidates(
             primary_line1,
             primary_line2,
             secondaries,
             start_whole,
             start_fraction,
             end_whole,
             end_fraction,
             miss_distance_threshold_km / 1.0,
             finder.coarse_step_seconds,
             finder.time_tolerance_seconds
           ) do
        {:ok, hits} ->
          {:ok, Enum.map(hits, fn {idx, item} -> %{secondary_index: idx, candidate: candidate(item)} end)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Screen one primary TLE against a secondary TLE catalog and compute collision probability for each hit.
  """
  @spec screen_tca_conjunctions(
          String.t(),
          String.t(),
          [tle_pair()],
          split_jd(),
          split_jd(),
          number(),
          number(),
          keyword()
        ) ::
          {:ok, [%{secondary_index: non_neg_integer(), conjunction: tca_conjunction()}]}
          | {:error, term()}
  def screen_tca_conjunctions(
        primary_line1,
        primary_line2,
        secondaries,
        window_start_jd,
        window_end_jd,
        miss_distance_threshold_km,
        hard_body_radius_km,
        opts \\ []
      )

  def screen_tca_conjunctions(
        primary_line1,
        primary_line2,
        secondaries,
        window_start_jd,
        window_end_jd,
        miss_distance_threshold_km,
        hard_body_radius_km,
        opts
      )
      when is_binary(primary_line1) and is_binary(primary_line2) and is_list(secondaries) and
             is_number(miss_distance_threshold_km) and is_number(hard_body_radius_km) and is_list(opts) do
    with {:ok, secondaries} <- tle_pairs(secondaries),
         {:ok, {start_whole, start_fraction}} <- split_jd(window_start_jd),
         {:ok, {end_whole, end_fraction}} <- split_jd(window_end_jd),
         {:ok, finder} <- finder_options(opts),
         {:ok, pc} <- pc_options(hard_body_radius_km, opts) do
      case NIF.tca_screen_conjunctions(
             primary_line1,
             primary_line2,
             secondaries,
             start_whole,
             start_fraction,
             end_whole,
             end_fraction,
             miss_distance_threshold_km / 1.0,
             pc.hard_body_radius_km,
             pc.method,
             pc.primary_covariance_km2,
             pc.secondary_covariance_km2,
             finder.coarse_step_seconds,
             finder.time_tolerance_seconds
           ) do
        {:ok, hits} ->
          {:ok, Enum.map(hits, fn {idx, item} -> %{secondary_index: idx, conjunction: conjunction(item)} end)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp split_jd({whole, fraction}) when is_number(whole) and is_number(fraction),
    do: {:ok, {whole / 1.0, fraction / 1.0}}

  defp split_jd(value), do: {:error, {:invalid_julian_date, value}}

  defp finder_options(opts) do
    with {:ok, coarse_step_seconds} <-
           positive_number(opts, :coarse_step_seconds, @default_coarse_step_seconds),
         {:ok, time_tolerance_seconds} <-
           positive_number(opts, :time_tolerance_seconds, @default_time_tolerance_seconds) do
      {:ok,
       %{
         coarse_step_seconds: coarse_step_seconds,
         time_tolerance_seconds: time_tolerance_seconds
       }}
    end
  end

  defp pc_options(hard_body_radius_km, opts) do
    method = Keyword.get(opts, :method, :equal_area)

    if method in [:equal_area, :numerical, :alfano_2005, :foster_equal_area, :foster_numerical] do
      {:ok,
       %{
         hard_body_radius_km: hard_body_radius_km / 1.0,
         method: method,
         primary_covariance_km2: Keyword.get(opts, :primary_covariance_km2),
         secondary_covariance_km2: Keyword.get(opts, :secondary_covariance_km2)
       }}
    else
      {:error, {:invalid_option, :method}}
    end
  end

  defp positive_number(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_number(value) and value > 0.0,
      do: {:ok, value / 1.0},
      else: {:error, {:invalid_option, key}}
  end

  defp tle_pairs(secondaries) do
    secondaries
    |> Enum.reduce_while({:ok, []}, fn
      {line1, line2}, {:ok, acc} when is_binary(line1) and is_binary(line2) ->
        {:cont, {:ok, [{line1, line2} | acc]}}

      %{line1: line1, line2: line2}, {:ok, acc} when is_binary(line1) and is_binary(line2) ->
        {:cont, {:ok, [{line1, line2} | acc]}}

      other, _acc ->
        {:halt, {:error, {:invalid_tle_pair, other}}}
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      {:error, _reason} = error -> error
    end
  end

  defp candidate(
         {tca_whole, tca_fraction, tca_jd, seconds_since_start, miss_distance_km, relative_position, relative_velocity}
       ) do
    %{
      tca_time_jd_whole: tca_whole,
      tca_time_jd_fraction: tca_fraction,
      tca_time_jd: tca_jd,
      tca_seconds_since_window_start: seconds_since_start,
      miss_distance_km: miss_distance_km,
      relative_position_km: relative_position,
      relative_velocity_km_s: relative_velocity
    }
  end

  defp conjunction({candidate, pc, miss_km, relative_speed_km_s, sigma_x_km, sigma_z_km}) do
    %{
      candidate: candidate(candidate),
      pc: pc,
      miss_km: miss_km,
      relative_speed_km_s: relative_speed_km_s,
      sigma_x_km: sigma_x_km,
      sigma_z_km: sigma_z_km
    }
  end
end
