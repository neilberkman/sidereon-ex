defmodule Sidereon.SpaceWeather do
  @moduledoc """
  Space-weather tables for drag and decay inputs.

  The parser and lookup policy are implemented in the core NIF. This module
  reads optional files, owns the Elixir structs, and forwards table operations to
  the parsed native resource.
  """

  alias Sidereon.Drag
  alias Sidereon.NIF
  alias Sidereon.NifCall

  @enforce_keys [:handle]
  defstruct [:handle]

  @type t :: %__MODULE__{handle: reference()}

  defmodule Sample do
    @moduledoc """
    Space-weather values plus source metadata for one lookup.
    """
    @enforce_keys [:space_weather, :class, :ap_defaulted]
    defstruct [:space_weather, :class, :ap_defaulted]

    @type t :: %__MODULE__{
            space_weather: Drag.SpaceWeather.t(),
            class: Sidereon.SpaceWeather.observation_class(),
            ap_defaulted: boolean()
          }
  end

  defmodule ApHistory do
    @moduledoc """
    The seven-element NRLMSISE-00 Ap history at one epoch, with the
    least-trusted row class consulted, whether the quiet default Ap stood in
    for a blank daily Ap (`ap_defaulted`), and how many three-hour bins were
    filled from a row's daily Ap (`bins_from_daily_ap`).
    """
    @enforce_keys [:ap, :class, :ap_defaulted, :bins_from_daily_ap]
    defstruct [:ap, :class, :ap_defaulted, :bins_from_daily_ap]

    @type t :: %__MODULE__{
            ap: [float()],
            class: Sidereon.SpaceWeather.observation_class(),
            ap_defaulted: boolean(),
            bins_from_daily_ap: non_neg_integer()
          }
  end

  defmodule Policy do
    @moduledoc """
    Lookup policy for lower-trust rows and for geomagnetic values the file does
    not state.

    The defaults match the core library's default policy: interpolated, daily
    predicted and monthly predicted rows are accepted and reported by class; a
    row whose flux qualifier states that the day had no observation is refused
    (`allow_not_observed: false`); and every Ap comes from the file
    (`require_geomagnetic: true`), so a blank daily Ap or a blank three-hour
    bin is refused rather than filled. `lenient/0` accepts every row class and
    fills blank geomagnetic values, reporting each substitution on the sample.
    """
    defstruct allow_interpolated: true,
              allow_not_observed: false,
              allow_daily_predicted: true,
              allow_monthly_predicted: true,
              require_geomagnetic: true

    @type t :: %__MODULE__{
            allow_interpolated: boolean(),
            allow_not_observed: boolean(),
            allow_daily_predicted: boolean(),
            allow_monthly_predicted: boolean(),
            require_geomagnetic: boolean()
          }

    @doc """
    Accept every row class and substitute the quiet default Ap, or the row's
    daily Ap for a blank three-hour bin, where the file leaves a geomagnetic
    value blank.
    """
    @spec lenient() :: t()
    def lenient do
      %__MODULE__{
        allow_interpolated: true,
        allow_not_observed: true,
        allow_daily_predicted: true,
        allow_monthly_predicted: true,
        require_geomagnetic: false
      }
    end
  end

  defmodule Coverage do
    @moduledoc """
    J2000-second coverage bounds for a parsed space-weather table.
    """
    @enforce_keys [:first_j2000_s, :end_j2000_s]
    defstruct [:first_j2000_s, :last_observed_j2000_s, :last_daily_predicted_j2000_s, :end_j2000_s]

    @type t :: %__MODULE__{
            first_j2000_s: float(),
            last_observed_j2000_s: float() | nil,
            last_daily_predicted_j2000_s: float() | nil,
            end_j2000_s: float()
          }
  end

  @typedoc """
  The class of a space-weather row: observed, interpolated by the source
  (flux qualifier 2 or 4, or `INT` in CSV), a day with no flux observation
  (flux qualifier 3), daily predicted, or monthly predicted.
  """
  @type observation_class ::
          :observed | :interpolated | :not_observed | :daily_predicted | :monthly_predicted

  @type error_reason ::
          :unrecognized_format
          | :not_text
          | {:malformed, non_neg_integer(), String.t()}
          | {:before_coverage, float(), float()}
          | {:after_coverage, float(), float()}
          | {:missing_data, integer(), integer(), integer(), String.t()}
          | {:rejected_by_policy, atom(), integer(), integer(), integer()}
          | {:invalid_epoch, float()}
          | term()

  @spec parse(binary()) :: {:ok, t()} | {:error, error_reason()}
  def parse(bytes) when is_binary(bytes) do
    case NIF.space_weather_parse(bytes) do
      {:ok, handle} when is_reference(handle) -> {:ok, %__MODULE__{handle: handle}}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :space_weather_parse)
  end

  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, bytes} <- File.read(path), do: parse(bytes)
  end

  @spec space_weather_at(t(), number()) :: {:ok, Drag.SpaceWeather.t()} | {:error, error_reason()}
  def space_weather_at(%__MODULE__{handle: handle}, epoch_j2000_s) when is_number(epoch_j2000_s) do
    case NIF.space_weather_space_weather_at(handle, epoch_j2000_s / 1.0) do
      {:ok, fields} -> {:ok, to_space_weather(fields)}
      {:error, _} = err -> err
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :space_weather_space_weather_at)
  end

  @spec sample_at(t(), number()) :: {:ok, Sample.t()} | {:error, error_reason()}
  def sample_at(%__MODULE__{handle: handle}, epoch_j2000_s) when is_number(epoch_j2000_s) do
    case NIF.space_weather_sample_at(handle, epoch_j2000_s / 1.0) do
      {:ok, fields} -> {:ok, to_sample(fields)}
      {:error, _} = err -> err
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :space_weather_sample_at)
  end

  @spec sample_at_with_policy(t(), number(), Policy.t() | keyword()) :: {:ok, Sample.t()} | {:error, error_reason()}
  def sample_at_with_policy(%__MODULE__{handle: handle}, epoch_j2000_s, policy) when is_number(epoch_j2000_s) do
    case NIF.space_weather_sample_at_with_policy(handle, epoch_j2000_s / 1.0, policy_map(policy)) do
      {:ok, fields} -> {:ok, to_sample(fields)}
      {:error, _} = err -> err
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :space_weather_sample_at_with_policy)
  end

  @spec ap_array_at(t(), number()) :: {:ok, [float()]} | {:error, error_reason()}
  def ap_array_at(%__MODULE__{handle: handle}, epoch_j2000_s) when is_number(epoch_j2000_s) do
    NIF.space_weather_ap_array_at(handle, epoch_j2000_s / 1.0)
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :space_weather_ap_array_at)
  end

  @doc """
  The NRLMSISE-00 Ap history array at `epoch_j2000_s` under `policy`, with the
  least-trusted row class consulted and the substitutions made.

  `ap_array_at/2` returns the array alone under the default policy.
  """
  @spec ap_history_at_with_policy(t(), number(), Policy.t() | keyword()) ::
          {:ok, ApHistory.t()} | {:error, error_reason()}
  def ap_history_at_with_policy(%__MODULE__{handle: handle}, epoch_j2000_s, policy) when is_number(epoch_j2000_s) do
    case NIF.space_weather_ap_history_at_with_policy(handle, epoch_j2000_s / 1.0, policy_map(policy)) do
      {:ok, fields} -> {:ok, struct!(ApHistory, fields)}
      {:error, _} = err -> err
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :space_weather_ap_history_at_with_policy)
  end

  @doc """
  The non-fatal findings of the parse that built the table: skipped lines
  (`:skips`, each with its line, reason and detail) and warnings (`:warnings`,
  each with its line and kind), such as a row out of date order, which is kept
  and sorted into place, a repeated date, of which the first row is kept, or a
  declared point count that differs from the rows read.
  """
  @spec diagnostics(t()) :: %{skips: [map()], warnings: [map()]}
  def diagnostics(%__MODULE__{handle: handle}), do: NIF.space_weather_diagnostics(handle)

  @spec coverage(t()) :: {:ok, Coverage.t()} | {:error, term()}
  def coverage(%__MODULE__{handle: handle}) do
    case NIF.space_weather_coverage(handle) do
      {:ok, fields} -> {:ok, struct!(Coverage, fields)}
      {:error, _} = err -> err
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :space_weather_coverage)
  end

  @spec to_csv_text(t()) :: {:ok, String.t()} | {:error, term()}
  def to_csv_text(%__MODULE__{handle: handle}), do: {:ok, NIF.space_weather_to_csv_text(handle)}

  @spec to_txt_text(t()) :: {:ok, String.t()} | {:error, term()}
  def to_txt_text(%__MODULE__{handle: handle}), do: {:ok, NIF.space_weather_to_txt_text(handle)}

  def parse!(bytes), do: bang(parse(bytes))
  def load!(path), do: bang(load(path))
  def space_weather_at!(table, epoch_j2000_s), do: bang(space_weather_at(table, epoch_j2000_s))
  def sample_at!(table, epoch_j2000_s), do: bang(sample_at(table, epoch_j2000_s))

  def sample_at_with_policy!(table, epoch_j2000_s, policy),
    do: bang(sample_at_with_policy(table, epoch_j2000_s, policy))

  def ap_array_at!(table, epoch_j2000_s), do: bang(ap_array_at(table, epoch_j2000_s))

  def ap_history_at_with_policy!(table, epoch_j2000_s, policy),
    do: bang(ap_history_at_with_policy(table, epoch_j2000_s, policy))

  def coverage!(table), do: bang(coverage(table))

  defp to_sample(fields) do
    %Sample{
      space_weather: to_space_weather(fields.space_weather),
      class: fields.class,
      ap_defaulted: fields.ap_defaulted
    }
  end

  defp to_space_weather(fields) do
    %Drag.SpaceWeather{f107: fields.f107, f107a: fields.f107a, ap: fields.ap}
  end

  @doc false
  # The native form of a policy, for `Sidereon.Drag.estimate_decay/3`.
  @spec policy_to_native(Policy.t() | keyword()) :: map()
  def policy_to_native(policy), do: policy_map(policy)

  defp policy_map(%Policy{} = policy), do: Map.from_struct(policy)

  defp policy_map(opts) when is_list(opts) do
    defaults = %Policy{}
    struct!(Policy, Keyword.take(opts, Map.keys(Map.from_struct(defaults)))) |> Map.from_struct()
  end

  defp bang({:ok, value}), do: value
  defp bang({:error, reason}), do: raise(ArgumentError, "space-weather operation failed: #{inspect(reason)}")
end
