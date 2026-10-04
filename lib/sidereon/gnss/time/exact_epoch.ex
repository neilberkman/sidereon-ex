defmodule Sidereon.GNSS.Time.ExactEpoch do
  @moduledoc """
  Exact civil epoch label backed by the core epoch representation.

  Civil seconds are interpreted by their shortest decimal spelling. Use
  `Sidereon.GNSS.Time.ExactEpochQuery.from_binary_j2000_seconds/1` when an
  existing floating-point value denotes a binary query offset instead.
  """

  alias Sidereon.GNSS.Time.ExactEpochQuery
  alias Sidereon.NIF
  alias Sidereon.NifCall

  @enforce_keys [:handle, :whole_seconds, :attoseconds, :sub_attosecond, :j2000_seconds]
  defstruct [:handle, :whole_seconds, :attoseconds, :sub_attosecond, :j2000_seconds]

  @type t :: %__MODULE__{
          handle: reference(),
          whole_seconds: integer(),
          attoseconds: non_neg_integer(),
          sub_attosecond: {integer(), non_neg_integer()},
          j2000_seconds: float()
        }

  @spec attoseconds_per_second() :: 1_000_000_000_000_000_000
  def attoseconds_per_second, do: 1_000_000_000_000_000_000

  @spec j2000() :: t()
  def j2000 do
    {:ok, epoch} = new(0, 0)
    epoch
  end

  @doc "Construct an exact epoch from whole seconds and attoseconds since J2000."
  @spec new(integer(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  def new(seconds, attoseconds) when is_integer(seconds) and is_integer(attoseconds) and attoseconds >= 0 do
    with {:ok, handle} <- NIF.exact_epoch_new(seconds, attoseconds) do
      {:ok, from_handle(handle)}
    end
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :exact_epoch_new)
  end

  def new(_seconds, _attoseconds), do: {:error, :invalid_exact_epoch}

  @spec from_civil(integer(), integer(), integer(), integer(), integer(), number()) ::
          {:ok, t()} | {:error, term()}
  def from_civil(year, month, day, hour, minute, second)
      when is_integer(year) and is_integer(month) and is_integer(day) and is_integer(hour) and is_integer(minute) and
             is_number(second) do
    with {:ok, handle} <- NIF.exact_epoch_from_civil(year, month, day, hour, minute, second / 1.0) do
      {:ok, from_handle(handle)}
    end
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :exact_epoch_from_civil)
  end

  def from_civil(_year, _month, _day, _hour, _minute, _second), do: {:error, :invalid_exact_epoch}

  @spec from_j2000_seconds(number()) :: {:ok, t()} | {:error, term()}
  def from_j2000_seconds(seconds) when is_number(seconds) do
    with {:ok, handle} <- NIF.exact_epoch_from_j2000_seconds(seconds / 1.0) do
      {:ok, from_handle(handle)}
    end
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :exact_epoch_from_j2000_seconds)
  end

  def from_j2000_seconds(_seconds), do: {:error, :invalid_exact_epoch}

  @doc "Add seconds interpreted as their shortest decimal representation."
  @spec checked_add_seconds(t(), number()) :: {:ok, t()} | {:error, term()}
  def checked_add_seconds(%__MODULE__{handle: handle}, seconds) when is_number(seconds) do
    with {:ok, result} <- NIF.exact_epoch_checked_add_seconds(handle, seconds / 1.0) do
      {:ok, from_handle(result)}
    end
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :exact_epoch_checked_add_seconds)
  end

  def checked_add_seconds(_epoch, _seconds), do: {:error, :invalid_exact_epoch}

  @doc "Subtract seconds interpreted as their shortest decimal representation."
  @spec checked_sub_seconds(t(), number()) :: {:ok, t()} | {:error, term()}
  def checked_sub_seconds(%__MODULE__{handle: handle}, seconds) when is_number(seconds) do
    with {:ok, result} <- NIF.exact_epoch_checked_sub_seconds(handle, seconds / 1.0) do
      {:ok, from_handle(result)}
    end
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :exact_epoch_checked_sub_seconds)
  end

  def checked_sub_seconds(_epoch, _seconds), do: {:error, :invalid_exact_epoch}

  @spec compare(t(), t()) :: :less | :equal | :greater
  def compare(%__MODULE__{handle: left}, %__MODULE__{handle: right}), do: NIF.exact_epoch_compare(left, right)

  @spec equal?(t(), t()) :: boolean()
  def equal?(left, right), do: compare(left, right) == :equal

  @spec seconds_since(t(), t()) :: float()
  def seconds_since(%__MODULE__{handle: later}, %__MODULE__{handle: earlier}),
    do: NIF.exact_epoch_seconds_since(later, earlier)

  @spec j2000_seconds(t()) :: float()
  def j2000_seconds(%__MODULE__{j2000_seconds: seconds}), do: seconds

  @spec split_julian_date(t()) :: {float(), float()}
  def split_julian_date(%__MODULE__{handle: handle}), do: NIF.exact_epoch_split_julian_date(handle)

  @spec query(t()) :: ExactEpochQuery.t()
  def query(%__MODULE__{handle: handle}) do
    struct(ExactEpochQuery, handle: NIF.exact_epoch_query(handle))
  end

  @doc false
  @spec from_handle(reference()) :: t()
  def from_handle(handle) do
    {whole_seconds, attoseconds, sub_attosecond, j2000_seconds} = NIF.exact_epoch_fields(handle)

    %__MODULE__{
      handle: handle,
      whole_seconds: whole_seconds,
      attoseconds: attoseconds,
      sub_attosecond: sub_attosecond,
      j2000_seconds: j2000_seconds
    }
  end
end

defmodule Sidereon.GNSS.Time.ExactEpochQuery do
  @moduledoc """
  Exact epoch query retaining a civil label and exact binary-second offsets.

  Query handles can be passed to precise-interpolant APIs without first
  rounding the absolute epoch to a floating-point J2000 value.
  """

  alias Sidereon.GNSS.Time.ExactEpoch
  alias Sidereon.NIF
  alias Sidereon.NifCall

  @enforce_keys [:handle]
  defstruct [:handle]

  @type t :: %__MODULE__{handle: reference()}

  @spec equal?(t(), t()) :: boolean()
  def equal?(%__MODULE__{handle: left}, %__MODULE__{handle: right}), do: NIF.exact_epoch_query_equal(left, right)

  @spec from_epoch(ExactEpoch.t()) :: t()
  def from_epoch(%ExactEpoch{} = epoch), do: ExactEpoch.query(epoch)

  @doc "Construct from an already-binary64 J2000-seconds query offset."
  @spec from_binary_j2000_seconds(float()) :: {:ok, t()} | {:error, term()}
  def from_binary_j2000_seconds(seconds) when is_float(seconds) do
    with {:ok, handle} <- NIF.exact_epoch_query_from_binary_j2000_seconds(seconds) do
      {:ok, %__MODULE__{handle: handle}}
    end
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :exact_epoch_query_from_binary_j2000_seconds)
  end

  def from_binary_j2000_seconds(_seconds), do: {:error, :invalid_exact_epoch}

  @doc "Add an already-binary64 offset to this query."
  @spec checked_add_binary_seconds(t(), float()) :: {:ok, t()} | {:error, term()}
  def checked_add_binary_seconds(%__MODULE__{handle: handle}, seconds) when is_float(seconds) do
    with {:ok, query} <- NIF.exact_epoch_query_add_binary_seconds(handle, seconds) do
      {:ok, %__MODULE__{handle: query}}
    end
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :exact_epoch_query_add_binary_seconds)
  end

  def checked_add_binary_seconds(_query, _seconds), do: {:error, :invalid_exact_epoch}

  @doc "Subtract an already-binary64 offset from this query."
  @spec checked_sub_binary_seconds(t(), float()) :: {:ok, t()} | {:error, term()}
  def checked_sub_binary_seconds(%__MODULE__{handle: handle}, seconds) when is_float(seconds) do
    with {:ok, query} <- NIF.exact_epoch_query_sub_binary_seconds(handle, seconds) do
      {:ok, %__MODULE__{handle: query}}
    end
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :exact_epoch_query_sub_binary_seconds)
  end

  def checked_sub_binary_seconds(_query, _seconds), do: {:error, :invalid_exact_epoch}

  @spec epoch(t()) :: ExactEpoch.t()
  def epoch(%__MODULE__{handle: handle}), do: handle |> NIF.exact_epoch_query_epoch() |> ExactEpoch.from_handle()

  @spec j2000_seconds(t()) :: float()
  def j2000_seconds(%__MODULE__{handle: handle}), do: NIF.exact_epoch_query_j2000_seconds(handle)

  @spec seconds_since(t(), ExactEpoch.t()) :: float()
  def seconds_since(%__MODULE__{handle: query}, %ExactEpoch{handle: earlier}),
    do: NIF.exact_epoch_query_seconds_since(query, earlier)

  @spec seconds_since_query(t(), t()) :: float()
  def seconds_since_query(%__MODULE__{handle: query}, %__MODULE__{handle: earlier}),
    do: NIF.exact_epoch_query_seconds_since_query(query, earlier)
end
