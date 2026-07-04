defmodule Sidereon.SGP4 do
  @moduledoc """
  SGP4/SDP4 orbit propagation from Two-Line Element sets.
  """

  alias Sidereon.Elements
  alias Sidereon.TemeState

  defmodule Fit do
    @moduledoc """
    Result of inverse SGP4 TLE fitting.
    """
    @enforce_keys [:elements, :line1, :line2, :omm_kvn, :stats]
    defstruct [:elements, :line1, :line2, :omm_kvn, :stats]

    @type t :: %__MODULE__{
            elements: map(),
            line1: String.t(),
            line2: String.t(),
            omm_kvn: String.t(),
            stats: map()
          }
  end

  @required_float_fields [
    :bstar,
    :mean_motion_dot,
    :mean_motion_double_dot,
    :eccentricity,
    :arg_perigee_deg,
    :inclination_deg,
    :mean_anomaly_deg,
    :mean_motion,
    :raan_deg
  ]

  @type element_error ::
          {:missing_field, atom()}
          | {:invalid_field, atom(), term()}

  @type propagation_error ::
          element_error()
          | String.t()
          | {:nif_error, String.t()}

  @doc """
  Propagate a TLE to a specific datetime, returning a TEME state vector.

  Uses the sgp4 Rust crate in AFSPC compatibility mode. Elements are
  passed as individual fields, so this works for both TLE and OMM inputs.

  Returns `{:ok, %Sidereon.TemeState{}}` with position in km and velocity in km/s,
  or `{:error, reason}`.
  """
  @spec propagate(Elements.t(), DateTime.t()) ::
          {:ok, TemeState.t()} | {:error, propagation_error()}
  def propagate(%Elements{} = tle, %DateTime{} = datetime) do
    datetime_tuple =
      {{datetime.year, datetime.month, datetime.day},
       {datetime.hour, datetime.minute, datetime.second, elem(datetime.microsecond, 0)}}

    with {:ok, elements_map} <- to_nif_elements_map(tle),
         {:ok, {position, velocity}} <-
           propagate_with_elements(elements_map, datetime_tuple) do
      {:ok, %TemeState{position: position, velocity: velocity}}
    end
  end

  @doc """
  Propagate many satellites across a shared list of times, in one NIF call.

  Each time is **minutes since that satellite's own epoch** (the core batch
  convention), so element `i` of the result is the arc for `satellites |> Enum.at(i)`
  evaluated at every offset in `times_minutes`. This is the throughput primitive
  over `sidereon_core::astro::sgp4::propagate_batch`; one bad satellite never
  collapses the batch.

  `satellites` is a list of `%Sidereon.Elements{}`. Options:

    * `:opsmode` - `:afspc` (default, matching `propagate/2`) or `:improved`.
    * `:parallel` - when `true`, fans the per-satellite arcs across a thread pool
      (`propagate_batch_parallel`); the results are bit-identical to the serial
      path. Defaults to `false`.

  Returns `{:ok, arcs}` where each arc is `{:ok, [%Sidereon.TemeState{}, ...]}`
  (one state per time, in order) or `{:error, reason}` for a satellite that failed
  to propagate. Returns `{:error, {:invalid_elements, index, reason}}` if an input
  element set cannot be marshalled.
  """
  @spec propagate_batch([Elements.t()], [number()], keyword()) ::
          {:ok, [{:ok, [TemeState.t()]} | {:error, term()}]} | {:error, term()}
  def propagate_batch(satellites, times_minutes, opts \\ []) when is_list(satellites) and is_list(times_minutes) do
    opsmode = Keyword.get(opts, :opsmode, :afspc)
    parallel? = Keyword.get(opts, :parallel, false)

    with {:ok, maps} <- to_nif_elements_maps(satellites) do
      times = Enum.map(times_minutes, &(&1 / 1.0))

      result =
        if parallel? do
          Sidereon.NIF.sgp4_propagate_batch_parallel(maps, times, opsmode)
        else
          Sidereon.NIF.sgp4_propagate_batch(maps, times, opsmode)
        end

      case result do
        {:ok, arcs} -> {:ok, Enum.map(arcs, &decode_arc/1)}
        {:error, _} = err -> err
      end
    end
  rescue
    e in ErlangError -> {:error, {:nif_error, Exception.message(e)}}
  end

  @doc """
  Propagate one satellite through a stateful decay latch over ordered offsets.

  `times_minutes` are minutes since the TLE epoch. The latch is scoped to this
  call: after the first decay-like SGP4 failure, later requests at the same or a
  greater offset return `{:error, {:decayed, first_minutes, requested_minutes}}`
  instead of a raw post-failure state.
  """
  @spec propagate_with_decay_latch(Elements.t(), [number()], keyword()) ::
          {:ok, [{:ok, TemeState.t()} | {:error, term()}]} | {:error, term()}
  def propagate_with_decay_latch(%Elements{} = tle, times_minutes, opts \\ []) when is_list(times_minutes) do
    opsmode = Keyword.get(opts, :opsmode, :afspc)

    with {:ok, elements_map} <- to_nif_elements_map(tle) do
      case Sidereon.NIF.sgp4_propagate_with_decay_latch(elements_map, Enum.map(times_minutes, &(&1 / 1.0)), opsmode) do
        {:ok, results} -> {:ok, Enum.map(results, &decode_latched_result/1)}
        {:error, _} = err -> err
      end
    end
  rescue
    e in ErlangError -> {:error, {:nif_error, Exception.message(e)}}
  end

  @doc """
  Fit a TLE to TEME position samples using the core inverse-SGP4 solver.
  """
  @spec fit_tle([map()], keyword()) :: {:ok, Fit.t()} | {:error, term()}
  def fit_tle(samples, opts \\ []) when is_list(samples) do
    case Sidereon.NIF.sgp4_fit_tle(Enum.map(samples, &fit_sample/1), fit_config(opts)) do
      {:ok, fit} -> {:ok, decode_fit(fit)}
      {:error, {:did_not_converge, fit}} -> {:error, {:did_not_converge, decode_fit(fit)}}
      {:error, _reason} = err -> err
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp to_nif_elements_maps(satellites) do
    satellites
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {sat, index}, {:ok, acc} ->
      case to_nif_elements_map(sat) do
        {:ok, map} -> {:cont, {:ok, [map | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_elements, index, reason}}}
      end
    end)
    |> case do
      {:ok, maps} -> {:ok, Enum.reverse(maps)}
      {:error, _} = err -> err
    end
  end

  defp decode_arc({:ok, states}) do
    {:ok, Enum.map(states, fn {position, velocity} -> %TemeState{position: position, velocity: velocity} end)}
  end

  defp decode_arc({:error, reason}), do: {:error, reason}

  defp decode_latched_result({:ok, {position, velocity}}) do
    {:ok, %TemeState{position: position, velocity: velocity}}
  end

  defp decode_latched_result({:error, {:decayed, first_failing_minutes, requested_minutes}}) do
    {:error, {:decayed, first_failing_minutes, requested_minutes}}
  end

  defp decode_latched_result({:error, reason}), do: {:error, reason}

  defp fit_sample(sample) do
    %{
      epoch: epoch_jd(Map.fetch!(sample, :epoch)),
      position_teme_km: vec3(Map.fetch!(sample, :position_teme_km)),
      velocity_teme_km_s: optional_vec3(Map.get(sample, :velocity_teme_km_s))
    }
  end

  defp fit_config(opts) do
    {epoch_kind, epoch_jd, epoch_sample} = fit_epoch(Keyword.get(opts, :epoch, :midpoint))
    {x_scale_kind, x_scale_values} = x_scale(Keyword.get(opts, :x_scale, :default))

    %{
      epoch_kind: epoch_kind,
      epoch_jd: epoch_jd,
      epoch_sample: epoch_sample,
      fit_bstar: Keyword.get(opts, :fit_bstar, true),
      bstar_seed: Keyword.get(opts, :bstar_seed, 0.0) / 1.0,
      use_velocity: Keyword.get(opts, :use_velocity, true),
      velocity_weight_s: optional_float(Keyword.get(opts, :velocity_weight_s)),
      weights: optional_float_list(Keyword.get(opts, :weights)),
      opsmode: Keyword.get(opts, :opsmode, :improved) |> to_string(),
      ftol: optional_float(Keyword.get(opts, :ftol)),
      xtol: optional_float(Keyword.get(opts, :xtol)),
      gtol: optional_float(Keyword.get(opts, :gtol)),
      max_nfev: Keyword.get(opts, :max_nfev),
      x_scale_kind: x_scale_kind,
      x_scale_values: x_scale_values,
      loss: Keyword.get(opts, :loss, :linear) |> to_string(),
      f_scale: Keyword.get(opts, :f_scale, 1.0) / 1.0,
      metadata: fit_metadata(Keyword.get(opts, :metadata, []))
    }
  end

  defp decode_fit(fit) do
    %Fit{
      elements: fit.elements,
      line1: fit.line1,
      line2: fit.line2,
      omm_kvn: fit.omm_kvn,
      stats: fit.stats
    }
  end

  defp fit_epoch(:midpoint), do: {"midpoint", nil, nil}
  defp fit_epoch(:first), do: {"first", nil, nil}
  defp fit_epoch(:last), do: {"last", nil, nil}
  defp fit_epoch({:sample, index}), do: {"sample", nil, index}
  defp fit_epoch({:jd, jd}), do: {"jd", epoch_jd(jd), nil}

  defp x_scale(:default), do: {"default", nil}
  defp x_scale(:unit), do: {"unit", nil}
  defp x_scale(:jac), do: {"jac", nil}
  defp x_scale({:values, values}), do: {"values", Enum.map(values, &(&1 / 1.0))}

  defp fit_metadata(metadata) do
    %{
      catalog_number: get_opt(metadata, :catalog_number, 99_999),
      classification: get_opt(metadata, :classification, "U"),
      international_designator: get_opt(metadata, :international_designator, ""),
      element_set_number: get_opt(metadata, :element_set_number, 1),
      rev_at_epoch: get_opt(metadata, :rev_at_epoch, 0),
      object_name: get_opt(metadata, :object_name, "")
    }
  end

  defp get_opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  defp get_opt(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)

  defp epoch_jd({whole, fraction}), do: {whole / 1.0, fraction / 1.0}
  defp vec3({x, y, z}), do: {x / 1.0, y / 1.0, z / 1.0}
  defp optional_vec3(nil), do: nil
  defp optional_vec3(value), do: vec3(value)
  defp optional_float(nil), do: nil
  defp optional_float(value), do: value / 1.0
  defp optional_float_list(nil), do: nil
  defp optional_float_list(values), do: Enum.map(values, &(&1 / 1.0))

  @doc false
  @spec to_nif_elements_map(Elements.t()) :: {:ok, map()} | {:error, element_error()}
  def to_nif_elements_map(%Elements{} = tle) do
    with {:ok, fields} <- validate_elements(tle) do
      epoch = fields.epoch
      year = epoch.year

      epochdays =
        Sidereon.NIF.civil_day_of_year(
          year,
          epoch.month,
          epoch.day,
          epoch.hour,
          epoch.minute,
          epoch.second + elem(epoch.microsecond, 0) / 1_000_000
        )

      {:ok,
       %{
         catalog_number: fields.catalog_number,
         bstar: fields.bstar,
         mean_motion_dot: fields.mean_motion_dot,
         mean_motion_double_dot: fields.mean_motion_double_dot,
         eccentricity: fields.eccentricity,
         arg_perigee_deg: fields.arg_perigee_deg,
         inclination_deg: fields.inclination_deg,
         mean_anomaly_deg: fields.mean_anomaly_deg,
         mean_motion: fields.mean_motion,
         raan_deg: fields.raan_deg,
         epoch_year: year,
         epochdays: epochdays
       }}
    end
  end

  @doc false
  @spec validate_elements(Elements.t()) :: {:ok, map()} | {:error, element_error()}
  def validate_elements(%Elements{} = tle) do
    with {:ok, epoch} <- required_datetime(tle, :epoch),
         {:ok, catalog_number} <- required_catalog_number(tle, :catalog_number),
         {:ok, floats} <- required_float_fields(tle) do
      {:ok, Map.merge(%{epoch: epoch, catalog_number: catalog_number}, floats)}
    end
  end

  defp propagate_with_elements(elements_map, datetime_tuple) do
    Sidereon.NIF.propagate_with_elements(elements_map, datetime_tuple)
  rescue
    e in ErlangError -> {:error, {:nif_error, Exception.message(e)}}
  end

  defp required_datetime(tle, field) do
    case Map.fetch!(tle, field) do
      nil -> {:error, {:missing_field, field}}
      %DateTime{} = datetime -> {:ok, datetime}
      value -> {:error, {:invalid_field, field, value}}
    end
  end

  defp required_catalog_number(tle, field) do
    case Map.fetch!(tle, field) do
      nil ->
        {:error, {:missing_field, field}}

      value when is_binary(value) ->
        catalog_number = String.trim(value)

        if catalog_number == "" do
          {:error, {:invalid_field, field, value}}
        else
          {:ok, catalog_number}
        end

      value ->
        {:error, {:invalid_field, field, value}}
    end
  end

  defp required_float_fields(tle) do
    Enum.reduce_while(@required_float_fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case required_float(tle, field) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp required_float(tle, field) do
    case Map.fetch!(tle, field) do
      nil -> {:error, {:missing_field, field}}
      value when is_float(value) -> {:ok, value}
      value when is_integer(value) -> {:ok, value * 1.0}
      value -> {:error, {:invalid_field, field, value}}
    end
  end
end
