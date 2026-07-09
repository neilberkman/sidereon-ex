defmodule Sidereon.GNSS.SPP do
  @moduledoc """
  RINEX observation convenience entry points for GNSS single-point positioning.

  This module exposes the RINEX OBS plus broadcast NAV helpers from the core
  facade. It assembles each usable observation epoch into the same SPP inputs
  consumed by `Sidereon.GNSS.Positioning`, and can serially solve every assembled
  epoch in one native call.
  """

  alias Sidereon.Constants
  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.Positioning.Decode
  alias Sidereon.GNSS.Positioning.Solution
  alias Sidereon.GNSS.RINEX.Observations
  alias Sidereon.NIF

  @default_huber_k 1.345
  @default_huber_sigma 1.0
  @default_huber_max_iter 5

  defmodule EpochInputs do
    @moduledoc """
    One RINEX observation epoch assembled into SPP solve inputs.
    """

    @enforce_keys [
      :epoch_index,
      :epoch,
      :observations,
      :t_rx_j2000_s,
      :t_rx_second_of_day_s,
      :day_of_year,
      :initial_guess,
      :corrections,
      :glonass_channels
    ]
    defstruct [
      :epoch_index,
      :epoch,
      :observations,
      :t_rx_j2000_s,
      :t_rx_second_of_day_s,
      :day_of_year,
      :initial_guess,
      :corrections,
      :glonass_channels
    ]

    @type t :: %__MODULE__{
            epoch_index: non_neg_integer(),
            epoch: tuple(),
            observations: [{String.t(), float()}],
            t_rx_j2000_s: float(),
            t_rx_second_of_day_s: float(),
            day_of_year: float(),
            initial_guess: {float(), float(), float(), float()},
            corrections: %{ionosphere: boolean(), troposphere: boolean()},
            glonass_channels: %{non_neg_integer() => integer()}
          }
  end

  defmodule EpochSolution do
    @moduledoc """
    One assembled RINEX observation epoch paired with its SPP solve result.
    """

    @enforce_keys [:epoch_index, :epoch, :solution, :solved?]
    defstruct [:epoch_index, :epoch, :solution, :solved?]

    @type t :: %__MODULE__{
            epoch_index: non_neg_integer(),
            epoch: tuple(),
            solution: {:ok, Solution.t()} | {:error, term()},
            solved?: boolean()
          }
  end

  @typedoc "Options used while assembling RINEX observation epochs into SPP inputs."
  @type rinex_option ::
          {:codes, %{String.t() => [String.t()]}}
          | {:ionosphere, boolean()}
          | {:troposphere, boolean()}
          | {:initial_guess, {number(), number(), number(), number()} | [number()]}
          | {:satellites, [String.t()]}
          | {:pressure_hpa, number()}
          | {:temperature_k, number()}
          | {:relative_humidity, number()}
          | {:huber, boolean()}
          | {:huber_k, number()}
          | {:huber_sigma, number()}
          | {:huber_max_iter, pos_integer()}

  @typedoc "Solve policy options for `solve_spp_from_rinex_obs/3`."
  @type solve_option ::
          rinex_option()
          | {:with_geodetic, boolean()}
          | {:max_pdop, number()}
          | {:coarse_search_seeds, pos_integer()}

  @doc """
  Assemble usable RINEX OBS epochs into SPP inputs using a broadcast NAV product.

  `source` is a parsed `Sidereon.GNSS.Broadcast` product and `obs` is a parsed
  `Sidereon.GNSS.RINEX.Observations` product. The returned list has one element
  per usable non-event RINEX epoch with at least one selected pseudorange.

  Options:

    * `:codes` - per-system pseudorange code policy, e.g. `%{"G" => ["C1C"]}`;
      omitted means the core default for the RINEX version.
    * `:ionosphere` / `:troposphere` - requested corrections, both default `true`.
    * `:initial_guess` - optional `{x_m, y_m, z_m, b_m}`; omitted uses the RINEX
      `APPROX POSITION XYZ` with zero clock.
    * `:satellites` - optional satellite id allow-list.
    * `:pressure_hpa`, `:temperature_k`, `:relative_humidity` - surface met
      values for the troposphere model.
    * `:huber` plus `:huber_k`, `:huber_sigma`, `:huber_max_iter` - optional
      robust reweighting for each assembled solve.
  """
  @spec spp_inputs_from_rinex_obs(Broadcast.t(), Observations.t(), [rinex_option()]) ::
          {:ok, [EpochInputs.t()]} | {:error, term()}
  def spp_inputs_from_rinex_obs(source, obs, opts \\ [])

  def spp_inputs_from_rinex_obs(%Broadcast{handle: source}, %Observations{handle: obs}, opts) when is_list(opts) do
    source
    |> call_inputs(obs, opts)
  end

  def spp_inputs_from_rinex_obs(%Observations{} = obs, %Broadcast{} = source, opts) when is_list(opts) do
    spp_inputs_from_rinex_obs(source, obs, opts)
  end

  @doc """
  Assemble RINEX OBS epochs and solve each epoch serially with SPP.

  The source and RINEX observation arguments match `spp_inputs_from_rinex_obs/3`.
  Per-epoch solve failures are retained in the returned list as
  `%EpochSolution{solution: {:error, reason}}`.

  Additional solve options:

    * `:with_geodetic` - include geodetic output in successful solutions,
      default `true`.
    * `:max_pdop` - optional positive PDOP ceiling.
    * `:coarse_search_seeds` - optional positive cold-start search seed count.
  """
  @spec solve_spp_from_rinex_obs(Broadcast.t(), Observations.t(), [solve_option()]) ::
          {:ok, [EpochSolution.t()]} | {:error, term()}
  def solve_spp_from_rinex_obs(source, obs, opts \\ [])

  def solve_spp_from_rinex_obs(%Broadcast{handle: source}, %Observations{handle: obs}, opts) when is_list(opts) do
    with {:ok, max_pdop} <- optional_positive_float(Keyword.get(opts, :max_pdop), :max_pdop),
         {:ok, coarse_search_seeds} <-
           optional_positive_integer(Keyword.get(opts, :coarse_search_seeds), :coarse_search_seeds) do
      args = rinex_args(source, obs, opts) ++ [Keyword.get(opts, :with_geodetic, true), max_pdop, coarse_search_seeds]

      case apply(NIF, :solve_spp_from_rinex_obs, args) do
        {:ok, epochs} -> {:ok, Enum.map(epochs, &decode_epoch_solution/1)}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, nif_error_reason(e)}
  end

  def solve_spp_from_rinex_obs(%Observations{} = obs, %Broadcast{} = source, opts) when is_list(opts) do
    solve_spp_from_rinex_obs(source, obs, opts)
  end

  defp call_inputs(source, obs, opts) do
    case apply(NIF, :spp_inputs_from_rinex_obs, rinex_args(source, obs, opts)) do
      {:ok, epochs} -> {:ok, Enum.map(epochs, &decode_epoch_inputs/1)}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, nif_error_reason(e)}
  end

  defp rinex_args(source, obs, opts) do
    [
      source,
      obs,
      codes_arg(Keyword.get(opts, :codes)),
      Keyword.get(opts, :ionosphere, true),
      Keyword.get(opts, :troposphere, true),
      initial_guess_arg(Keyword.get(opts, :initial_guess)),
      Keyword.get(opts, :satellites, []),
      Keyword.get(opts, :pressure_hpa, Constants.surface_met_pressure_hpa()) / 1.0,
      Keyword.get(opts, :temperature_k, Constants.surface_met_temperature_k()) / 1.0,
      Keyword.get(opts, :relative_humidity, Constants.surface_met_relative_humidity()) / 1.0,
      robust_arg(opts)
    ]
  end

  defp codes_arg(nil), do: nil

  defp codes_arg(codes) when is_map(codes) do
    codes
    |> Map.to_list()
    |> Enum.map(fn {system, selected} -> {to_string(system), Enum.map(selected, &to_string/1)} end)
    |> Enum.sort()
  end

  defp initial_guess_arg(nil), do: nil
  defp initial_guess_arg({a, b, c, d}), do: {a / 1.0, b / 1.0, c / 1.0, d / 1.0}
  defp initial_guess_arg([a, b, c, d]), do: {a / 1.0, b / 1.0, c / 1.0, d / 1.0}

  defp robust_arg(opts) do
    cond do
      Keyword.get(opts, :huber, false) == true ->
        {
          Keyword.get(opts, :huber_k, @default_huber_k) / 1.0,
          Keyword.get(opts, :huber_sigma, @default_huber_sigma) / 1.0,
          Keyword.get(opts, :huber_max_iter, @default_huber_max_iter)
        }

      tuple_size_safe(Keyword.get(opts, :robust)) == 3 ->
        Keyword.fetch!(opts, :robust)

      true ->
        nil
    end
  end

  defp tuple_size_safe(value) when is_tuple(value), do: tuple_size(value)
  defp tuple_size_safe(_value), do: 0

  defp optional_positive_float(nil, _key), do: {:ok, nil}
  defp optional_positive_float(value, _key) when is_number(value) and value > 0.0, do: {:ok, value / 1.0}
  defp optional_positive_float(_value, key), do: {:error, {:invalid_option, key}}

  defp optional_positive_integer(nil, _key), do: {:ok, nil}
  defp optional_positive_integer(value, _key) when is_integer(value) and value > 0, do: {:ok, value}
  defp optional_positive_integer(_value, key), do: {:error, {:invalid_option, key}}

  defp decode_epoch_inputs(
         {epoch_index, epoch, observations, t_rx_j2000_s, t_rx_second_of_day_s, day_of_year, initial_guess,
          {ionosphere, troposphere}, glonass_channels}
       ) do
    %EpochInputs{
      epoch_index: epoch_index,
      epoch: epoch,
      observations: observations,
      t_rx_j2000_s: t_rx_j2000_s,
      t_rx_second_of_day_s: t_rx_second_of_day_s,
      day_of_year: day_of_year,
      initial_guess: initial_guess,
      corrections: %{ionosphere: ionosphere, troposphere: troposphere},
      glonass_channels: Map.new(glonass_channels)
    }
  end

  defp decode_epoch_solution({epoch_index, epoch, solution_term}) do
    solution = Decode.decode(solution_term)
    %EpochSolution{epoch_index: epoch_index, epoch: epoch, solution: solution, solved?: match?({:ok, _}, solution)}
  end

  defp nif_error_reason(error), do: Map.get(error, :original, Exception.message(error))
end
