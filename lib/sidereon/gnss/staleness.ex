defmodule Sidereon.GNSS.Staleness do
  @moduledoc """
  Product-staleness graceful degradation for time-varying GNSS products.

  Time-varying products (IONEX vertical-TEC maps, rapid/predicted SP3 orbit and
  clock files) publish with latency and gaps, so the product for the exact
  requested epoch is not always on hand. This is the Elixir surface over the
  `sidereon-core` selection layer: given a SET of already-parsed products and a
  requested epoch (or epoch range), it returns a usable product plus a
  `Sidereon.GNSS.Staleness.StalenessMetadata` describing which source epoch was
  used and how stale it is, falling back to the most-recent product within a
  configurable staleness cap. A request that would rely on a product older than
  the cap fails with a typed error instead of returning data past the cap, so a
  degraded answer is never substituted silently.

  This layer is pure and does no networking: it selects among products the
  caller has already parsed (`Sidereon.GNSS.SP3.load/1`,
  `Sidereon.GNSS.Ionosphere.load_ionex/1`). Fetching the products is a separate,
  per-binding concern.

  ## Degradation paths

    * `:exact` - a product covers the requested epoch; it is returned untouched,
      so the downstream evaluation is bit-for-bit identical to querying it
      directly. Staleness is zero.
    * `:nearest_prior` (SP3) - no product covers the epoch, so the most-recent
      prior product is used as-is, with staleness measured from its last epoch.
    * `:diurnal_shift` (IONEX) - no product covers the requested day, so a prior
      day's grid is advanced by whole days onto the requested epoch (TEC is
      approximately 24-hour periodic). Only the epoch axis moves; grid values are
      unchanged.

  ## Epochs

  Epochs are a `NaiveDateTime` or `{{y, m, d}, {h, min, s}}` tuple, interpreted
  in the product's own time scale (no leap-second shifting), and converted to
  seconds since J2000 via `Sidereon.GNSS.Time`. The IONEX map-epoch axis is
  integer seconds, so an IONEX request must be a whole-second epoch.
  """

  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.Time
  alias Sidereon.NIF

  defmodule Policy do
    @moduledoc """
    Staleness cap for product selection.

    A selection that would rely on a product older than `max_staleness_s` fails
    with `{:beyond_staleness_cap, info}` rather than returning data past the cap.
    The default cap is three days, which spans the typical rapid/predicted
    product latency plus a weekend gap.
    """

    @enforce_keys [:max_staleness_s]
    defstruct [:max_staleness_s]

    @type t :: %__MODULE__{max_staleness_s: float()}

    @seconds_per_day 86_400.0
    @default_days 3.0

    @doc "A policy with the cap expressed in days."
    @spec days(number()) :: t()
    def days(days) when is_number(days), do: %__MODULE__{max_staleness_s: days * @seconds_per_day}

    @doc "A policy with the cap expressed in seconds."
    @spec seconds(number()) :: t()
    def seconds(seconds) when is_number(seconds), do: %__MODULE__{max_staleness_s: seconds / 1.0}

    @doc "The default policy: a three-day staleness cap."
    @spec default() :: t()
    def default, do: days(@default_days)
  end

  defmodule StalenessMetadata do
    @moduledoc """
    Structured description of the product staleness behind a selection result.

    Attached to every selection; a degraded result is never produced without it.
    Epoch fields are seconds since the J2000 epoch (2000-01-01 12:00:00 in the
    product's time scale). `staleness_s` is `requested - source` and is never
    negative. `kind` is the degradation path (`:exact`, `:nearest_prior`, or
    `:diurnal_shift`); `staleness_days` is `staleness_s / 86400` (the whole-day
    offset for a diurnal shift).
    """

    @enforce_keys [
      :kind,
      :requested_epoch_j2000_s,
      :source_epoch_j2000_s,
      :staleness_s,
      :staleness_days
    ]
    defstruct [
      :kind,
      :requested_epoch_j2000_s,
      :source_epoch_j2000_s,
      :staleness_s,
      :staleness_days
    ]

    @type kind :: :exact | :nearest_prior | :diurnal_shift

    @type t :: %__MODULE__{
            kind: kind(),
            requested_epoch_j2000_s: float(),
            source_epoch_j2000_s: float(),
            staleness_s: float(),
            staleness_days: float()
          }
  end

  defmodule Sp3Selection do
    @moduledoc """
    A selected SP3 product paired with its staleness metadata.

    `sp3` is a usable `Sidereon.GNSS.SP3` product: for an `:exact` or
    `:nearest_prior` result it is the caller's own input product, so feeding it
    to `Sidereon.GNSS.SP3.position/4` or `Sidereon.GNSS.Positioning.solve/4` is
    bit-for-bit identical to using that product directly. `metadata` reports the
    degradation kind and staleness.
    """

    alias Sidereon.GNSS.Staleness.StalenessMetadata

    @enforce_keys [:sp3, :metadata]
    defstruct [:sp3, :metadata]

    @type t :: %__MODULE__{
            sp3: SP3.t(),
            metadata: StalenessMetadata.t()
          }
  end

  defmodule IonexSelection do
    @moduledoc """
    A selected IONEX product paired with its staleness metadata.

    `handle` is a usable parsed-IONEX reference: for an `:exact` result it is the
    caller's own input handle (so `Sidereon.GNSS.Ionosphere.ionex_slant_delay/7`
    is bit-for-bit identical to using it directly); for a `:diurnal_shift` result
    it is a fresh handle wrapping the whole-day-advanced grid. `metadata` reports
    the degradation kind and staleness.
    """

    alias Sidereon.GNSS.Staleness.StalenessMetadata

    @enforce_keys [:handle, :metadata]
    defstruct [:handle, :metadata]

    @type t :: %__MODULE__{
            handle: reference(),
            metadata: StalenessMetadata.t()
          }
  end

  @typedoc "An epoch as a `NaiveDateTime` or `{{y, m, d}, {h, min, s}}` tuple."
  @type epoch :: NaiveDateTime.t() | tuple()

  @typedoc """
  A typed selection failure. `info` for `:beyond_staleness_cap` is a map with the
  requested/source epochs, the staleness, and the cap, all in J2000 seconds.
  """
  @type selection_error ::
          :empty_product_set
          | {:invalid_range, float(), float()}
          | {:no_prior_product, float()}
          | {:beyond_staleness_cap, map()}
          | {:invalid_product, String.t()}
          | {:invalid_policy, float()}
          | {:overflow, String.t()}

  @doc """
  Select the SP3 product to use for `epoch`, degrading to the most-recent prior
  product within `policy`.

  An `:exact` result covers `epoch`; a `:nearest_prior` result is the best
  in-cap candidate and may end before `epoch` (its coverage gap is the reported
  staleness), so a downstream solve against it can still fail to serve `epoch`.

  `products` is a list of parsed `Sidereon.GNSS.SP3` products. Returns
  `{:ok, %Sidereon.GNSS.Staleness.Sp3Selection{}}` or `{:error, reason}`.
  """
  @spec select_sp3([SP3.t()], epoch(), Policy.t()) ::
          {:ok, Sp3Selection.t()} | {:error, term()}
  def select_sp3(products, epoch, policy \\ Policy.default()) when is_list(products) do
    with {:ok, epoch_s} <- Time.epoch_to_j2000_seconds_fractional(epoch) do
      handles = Enum.map(products, & &1.handle)

      handles
      |> NIF.staleness_select_sp3(epoch_s, policy.max_staleness_s)
      |> decode_sp3_selection(products)
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Select an SP3 product usable across `[start_epoch, end_epoch]`.

  See `select_sp3/3`; this is the range case, where staleness is measured to the
  range end (the most-stale point).
  """
  @spec select_sp3_over_range([SP3.t()], epoch(), epoch(), Policy.t()) ::
          {:ok, Sp3Selection.t()} | {:error, term()}
  def select_sp3_over_range(products, start_epoch, end_epoch, policy \\ Policy.default()) when is_list(products) do
    with {:ok, start_s} <- Time.epoch_to_j2000_seconds_fractional(start_epoch),
         {:ok, end_s} <- Time.epoch_to_j2000_seconds_fractional(end_epoch) do
      handles = Enum.map(products, & &1.handle)

      handles
      |> NIF.staleness_select_sp3_over_range(start_s, end_s, policy.max_staleness_s)
      |> decode_sp3_selection(products)
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Select an IONEX product usable at `epoch`, degrading to a diurnal-shifted prior
  product within `policy`.

  `handles` is a list of parsed-IONEX references from
  `Sidereon.GNSS.Ionosphere.parse_ionex/1` or `load_ionex/1`. The IONEX axis is
  integer seconds, so `epoch` must be a whole-second epoch. Returns
  `{:ok, %Sidereon.GNSS.Staleness.IonexSelection{}}` or `{:error, reason}`.
  """
  @spec select_ionex([reference()], epoch(), Policy.t()) ::
          {:ok, IonexSelection.t()} | {:error, term()}
  def select_ionex(handles, epoch, policy \\ Policy.default()) when is_list(handles) do
    with {:ok, epoch_s} <- Time.epoch_to_j2000_seconds(epoch) do
      handles
      |> NIF.staleness_select_ionex(epoch_s, policy.max_staleness_s)
      |> decode_ionex_selection(handles)
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Select an IONEX product usable across `[start_epoch, end_epoch]`.

  See `select_ionex/3`; this is the range case.
  """
  @spec select_ionex_over_range([reference()], epoch(), epoch(), Policy.t()) ::
          {:ok, IonexSelection.t()} | {:error, term()}
  def select_ionex_over_range(handles, start_epoch, end_epoch, policy \\ Policy.default()) when is_list(handles) do
    with {:ok, start_s} <- Time.epoch_to_j2000_seconds(start_epoch),
         {:ok, end_s} <- Time.epoch_to_j2000_seconds(end_epoch) do
      handles
      |> NIF.staleness_select_ionex_over_range(start_s, end_s, policy.max_staleness_s)
      |> decode_ionex_selection(handles)
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  # --- decoding (shared with the precise-to-broadcast fallback source) ------

  @doc false
  @spec decode_metadata(tuple()) :: StalenessMetadata.t()
  def decode_metadata({kind, requested_s, source_s, staleness_s, staleness_days}) do
    %StalenessMetadata{
      kind: kind,
      requested_epoch_j2000_s: requested_s,
      source_epoch_j2000_s: source_s,
      staleness_s: staleness_s,
      staleness_days: staleness_days
    }
  end

  @doc false
  @spec decode_selection_error(term()) :: selection_error()
  def decode_selection_error(:empty_product_set), do: :empty_product_set
  def decode_selection_error({:invalid_range, _start, _end} = error), do: error
  def decode_selection_error({:no_prior_product, _requested} = error), do: error

  def decode_selection_error({:beyond_staleness_cap, requested, source, staleness, max}) do
    {:beyond_staleness_cap,
     %{
       requested_epoch_j2000_s: requested,
       source_epoch_j2000_s: source,
       staleness_s: staleness,
       max_staleness_s: max
     }}
  end

  def decode_selection_error({:invalid_product, _message} = error), do: error
  def decode_selection_error({:invalid_policy, _max} = error), do: error
  def decode_selection_error({:overflow, _context} = error), do: error
  def decode_selection_error(other), do: other

  defp decode_sp3_selection({:ok, {index, metadata}}, products) do
    {:ok, %Sp3Selection{sp3: Enum.at(products, index), metadata: decode_metadata(metadata)}}
  end

  defp decode_sp3_selection({:error, reason}, _products), do: {:error, decode_selection_error(reason)}

  defp decode_ionex_selection({:ok, {selection, metadata}}, handles) do
    handle =
      case selection do
        {:present, index} -> Enum.at(handles, index)
        {:shifted, handle} -> handle
      end

    {:ok, %IonexSelection{handle: handle, metadata: decode_metadata(metadata)}}
  end

  defp decode_ionex_selection({:error, reason}, _handles), do: {:error, decode_selection_error(reason)}
end
