defmodule Sidereon.SpaceWeather do
  @moduledoc """
  Space-weather tables for drag and decay inputs.

  The parser and lookup policy are implemented in the core NIF. This module
  reads optional files, owns the Elixir structs, and forwards table operations to
  the parsed native resource.
  """

  alias Sidereon.Drag
  alias Sidereon.NIF

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
            class: :observed | :interpolated | :daily_predicted | :monthly_predicted,
            ap_defaulted: boolean()
          }
  end

  defmodule Policy do
    @moduledoc """
    Lookup policy for rejecting lower-trust rows or monthly Ap defaults.
    """
    defstruct allow_interpolated: true,
              allow_daily_predicted: true,
              allow_monthly_predicted: true,
              require_geomagnetic: false

    @type t :: %__MODULE__{
            allow_interpolated: boolean(),
            allow_daily_predicted: boolean(),
            allow_monthly_predicted: boolean(),
            require_geomagnetic: boolean()
          }
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
    e in ErlangError -> {:error, e.original}
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
    e in ErlangError -> {:error, e.original}
  end

  @spec sample_at(t(), number()) :: {:ok, Sample.t()} | {:error, error_reason()}
  def sample_at(%__MODULE__{handle: handle}, epoch_j2000_s) when is_number(epoch_j2000_s) do
    case NIF.space_weather_sample_at(handle, epoch_j2000_s / 1.0) do
      {:ok, fields} -> {:ok, to_sample(fields)}
      {:error, _} = err -> err
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @spec sample_at_with_policy(t(), number(), Policy.t() | keyword()) :: {:ok, Sample.t()} | {:error, error_reason()}
  def sample_at_with_policy(%__MODULE__{handle: handle}, epoch_j2000_s, policy) when is_number(epoch_j2000_s) do
    case NIF.space_weather_sample_at_with_policy(handle, epoch_j2000_s / 1.0, policy_map(policy)) do
      {:ok, fields} -> {:ok, to_sample(fields)}
      {:error, _} = err -> err
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @spec ap_array_at(t(), number()) :: {:ok, [float()]} | {:error, error_reason()}
  def ap_array_at(%__MODULE__{handle: handle}, epoch_j2000_s) when is_number(epoch_j2000_s) do
    NIF.space_weather_ap_array_at(handle, epoch_j2000_s / 1.0)
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @spec coverage(t()) :: {:ok, Coverage.t()} | {:error, term()}
  def coverage(%__MODULE__{handle: handle}) do
    case NIF.space_weather_coverage(handle) do
      {:ok, fields} -> {:ok, struct!(Coverage, fields)}
      {:error, _} = err -> err
    end
  rescue
    e in ErlangError -> {:error, e.original}
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

  defp policy_map(%Policy{} = policy), do: Map.from_struct(policy)

  defp policy_map(opts) when is_list(opts) do
    defaults = %Policy{}
    struct!(Policy, Keyword.take(opts, Map.keys(Map.from_struct(defaults)))) |> Map.from_struct()
  end

  defp bang({:ok, value}), do: value
  defp bang({:error, reason}), do: raise(ArgumentError, "space-weather operation failed: #{inspect(reason)}")
end
