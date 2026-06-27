defmodule Sidereon.Conjunction do
  @moduledoc """
  Find close approaches between two satellites.

  Uses coarse-fine search: scans at a configurable step size, then
  refines with golden-section search within each candidate interval.

  ## Examples

      {:ok, el1} = Sidereon.Format.TLE.parse(line1a, line2a)
      {:ok, el2} = Sidereon.Format.TLE.parse(line1b, line2b)

      approaches = Sidereon.Conjunction.find(el1, el2,
        start_min: 0.0,
        end_min: 1440.0,
        step_min: 1.0,
        threshold_km: 50.0
      )

      for {tca_min, distance_km} <- approaches do
        IO.puts("TCA: +\#{Float.round(tca_min / 60, 1)}h, miss: \#{Float.round(distance_km, 2)} km")
      end
  """

  alias Sidereon.Elements

  @allowed_options [:start_min, :end_min, :step_min, :threshold_km]

  @type find_error ::
          {:missing_option, :end_min}
          | {:invalid_option, atom()}
          | {:invalid_tle, :primary | :secondary, term()}
          | term()

  @doc """
  Find all close approaches between two satellites within a time window.

  Times are in minutes from the first satellite's epoch.

  ## Options

    * `:start_min` - start of search window in minutes (default: 0.0)
    * `:end_min` - end of search window in minutes (required)
    * `:step_min` - coarse scan step size in minutes (default: 1.0)
    * `:threshold_km` - only report approaches closer than this (default: 50.0)

  ## Returns

  List of `{tca_min, distance_km}` tuples, sorted by time, or
  `{:error, reason}` for malformed options, invalid elements, or NIF failures.
  """
  @spec find(Elements.t(), Elements.t(), keyword()) ::
          [{float(), float()}] | {:error, find_error()}
  def find(%Elements{} = el1, %Elements{} = el2, opts) do
    with {:ok, options} <- validate_options(opts),
         {:ok, {l1a, l2a}} <- encode_tle(el1, :primary),
         {:ok, {l1b, l2b}} <- encode_tle(el2, :secondary) do
      case Sidereon.NIF.find_conjunctions(
             l1a,
             l2a,
             l1b,
             l2b,
             options.start_min,
             options.end_min,
             options.step_min,
             options.threshold_km
           ) do
        {:ok, results} -> results
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp validate_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      with :ok <- validate_option_keys(opts),
           {:ok, end_min} <- required_number(opts, :end_min),
           {:ok, start_min} <- optional_number(opts, :start_min, 0.0),
           {:ok, step_min} <- optional_positive_number(opts, :step_min, 1.0),
           {:ok, threshold_km} <- optional_non_negative_number(opts, :threshold_km, 50.0) do
        {:ok,
         %{
           start_min: start_min,
           end_min: end_min,
           step_min: step_min,
           threshold_km: threshold_km
         }}
      end
    else
      {:error, {:invalid_option, :opts}}
    end
  end

  defp validate_options(_opts), do: {:error, {:invalid_option, :opts}}

  defp validate_option_keys(opts) do
    case Enum.find(opts, fn {key, _value} -> key not in @allowed_options end) do
      nil -> :ok
      {key, _value} -> {:error, {:invalid_option, key}}
    end
  end

  defp required_number(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_number(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp optional_number(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_number(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error -> {:ok, default}
    end
  end

  defp optional_positive_number(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_number(value) and value > 0.0 -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error -> {:ok, default}
    end
  end

  defp optional_non_negative_number(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_number(value) and value >= 0.0 -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error -> {:ok, default}
    end
  end

  defp encode_tle(%Elements{} = el, label) do
    case Sidereon.Format.TLE.encode(el) do
      {:ok, lines} -> {:ok, lines}
      {:error, reason} -> {:error, {:invalid_tle, label, reason}}
    end
  end
end
