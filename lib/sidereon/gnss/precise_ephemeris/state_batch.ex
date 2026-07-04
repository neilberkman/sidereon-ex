defmodule Sidereon.GNSS.PreciseEphemeris.StateBatch do
  @moduledoc """
  Contiguous satellite-state arrays returned by a batched ephemeris query.

  The positions are ITRF/IGS ECEF metres and clocks are seconds. Element `i` of
  every field belongs to the same input satellite/epoch pair:

    * `:positions_ecef_m` - `{x_m, y_m, z_m}` tuples. Failed elements carry the
      sentinel returned by `missing_position_ecef_m/0`.
    * `:clocks_s` - satellite clock offsets in seconds, or `nil`.
    * `:statuses` - `:valid`, `:gap`, or `:error`.
    * `:results` - `:ok` or `{:error, reason}` with the core scalar reason.

  A `:gap` is a data gap such as an unknown satellite or an out-of-coverage
  epoch. Other failures are marked `:error`.
  """

  alias Sidereon.NIF

  @enforce_keys [:positions_ecef_m, :clocks_s, :statuses, :results]
  defstruct [:positions_ecef_m, :clocks_s, :statuses, :results]

  @type position_component :: float() | :nan
  @type vec3 :: {position_component(), position_component(), position_component()}
  @type status :: :valid | :gap | :error
  @type element_result :: :ok | {:error, term()}

  @type t :: %__MODULE__{
          positions_ecef_m: [vec3()],
          clocks_s: [float() | nil],
          statuses: [status()],
          results: [element_result()]
        }

  @doc """
  Position sentinel used when an element has no valid state.

  The core sentinel is a NaN vector. BEAM NIFs cannot transport NaN floats, so
  this binding represents it as `{:nan, :nan, :nan}`. Check `results` or
  `statuses` before using a position row.
  """
  @spec missing_position_ecef_m() :: vec3()
  def missing_position_ecef_m do
    NIF.observable_state_missing_position_ecef_m()
  end

  @doc """
  Number of elements in the batch.
  """
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{results: results}), do: length(results)

  @doc """
  Reconstruct one element as `{:ok, %{position_ecef_m, clock_s}}` or an error.

  Indexing is zero-based to match the core batch element contract. Returns
  `{:error, :out_of_range}` when `index` is outside the batch.
  """
  @spec element(t(), non_neg_integer()) ::
          {:ok, %{position_ecef_m: vec3(), clock_s: float() | nil}} | {:error, term()}
  def element(%__MODULE__{} = batch, index) when is_integer(index) and index >= 0 do
    with {:ok, result} <- at(batch.results, index),
         {:ok, position} <- at(batch.positions_ecef_m, index),
         {:ok, clock} <- at(batch.clocks_s, index) do
      case result do
        :ok -> {:ok, %{position_ecef_m: position, clock_s: clock}}
        {:error, _reason} = err -> err
      end
    end
  end

  def element(%__MODULE__{}, _index), do: {:error, :out_of_range}

  @doc false
  @spec from_nif_tuple(tuple()) :: t()
  def from_nif_tuple({positions_ecef_m, clocks_s, statuses, results}) do
    %__MODULE__{
      positions_ecef_m: positions_ecef_m,
      clocks_s: clocks_s,
      statuses: statuses,
      results: results
    }
  end

  defp at(list, index) do
    case Enum.fetch(list, index) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :out_of_range}
    end
  end
end
