defmodule Sidereon.GNSS.Ionosphere.TecSample do
  @moduledoc """
  One IONEX vertical-TEC sample at one grid node.

  `epoch` is a `Sidereon.GNSS.Ionosphere.Epoch`, which carries its own time
  scale and its own representation. Latitude and longitude are degrees, vertical
  TEC and RMS are TECU, and the height offset is kilometers.

  `vtec_tecu`, `rms_tecu` and `height_offset_km` are `nil` where the node has no
  such value. A node holding `0.0` is a node with a value of zero, which is not
  the same as a node without one.

  `height_offset_km` is the value the node's IONEX height map holds: an offset
  added to `HGT1` to give the single-layer height there, not a shell height.

  ## What is refused

    * `{:invalid_sample_field, field, value}` - a field that is neither a number
      nor, where the field is optional, `nil`.
    * `{:value_out_of_range, field, value}` - a field that is an integer larger
      in magnitude than the largest finite double, which has no double to be
      read onto.
    * the epoch refusals of `Sidereon.GNSS.Ionosphere.Epoch`.
  """

  alias Sidereon.GNSS.Ionosphere.Epoch
  alias Sidereon.GNSS.Ionosphere.Numeric

  @enforce_keys [:epoch, :lat_deg, :lon_deg]
  defstruct [:epoch, :lat_deg, :lon_deg, :vtec_tecu, :rms_tecu, :height_offset_km]

  @type t :: %__MODULE__{
          epoch: Epoch.t(),
          lat_deg: number(),
          lon_deg: number(),
          vtec_tecu: number() | nil,
          rms_tecu: number() | nil,
          height_offset_km: number() | nil
        }

  @doc """
  A sample at `epoch` and the node `{lat_deg, lon_deg}`.

  `opts` sets `:vtec_tecu`, `:rms_tecu` and `:height_offset_km`; each is `nil`
  when the node has no such value.

  The numbers are kept as they were given. Whether each one can be read onto the
  double the boundary takes is decided when the sample is converted, so a value
  that cannot be is a named refusal of the build rather than an exception out of
  this constructor.
  """
  @spec new(Epoch.t(), number(), number(), keyword()) :: t()
  def new(%Epoch{} = epoch, lat_deg, lon_deg, opts \\ []) when is_number(lat_deg) and is_number(lon_deg) do
    struct!(__MODULE__, Keyword.merge(opts, epoch: epoch, lat_deg: lat_deg, lon_deg: lon_deg))
  end

  @doc false
  @spec to_nif_map(t()) :: {:ok, map()} | {:error, term()}
  def to_nif_map(%__MODULE__{} = sample) do
    with {:ok, epoch} <- epoch_term(sample.epoch),
         {:ok, lat_deg} <- coordinate(sample.lat_deg, :lat_deg),
         {:ok, lon_deg} <- coordinate(sample.lon_deg, :lon_deg),
         {:ok, vtec_tecu} <- optional_value(sample.vtec_tecu, :vtec_tecu),
         {:ok, rms_tecu} <- optional_value(sample.rms_tecu, :rms_tecu),
         {:ok, height_offset_km} <- optional_value(sample.height_offset_km, :height_offset_km) do
      {:ok,
       %{
         epoch: epoch,
         lat_deg: lat_deg,
         lon_deg: lon_deg,
         vtec_tecu: vtec_tecu,
         rms_tecu: rms_tecu,
         height_offset_km: height_offset_km
       }}
    end
  end

  def to_nif_map(_other), do: {:error, :bad_tec_sample}

  @doc false
  @spec from_nif_map(map()) :: t()
  def from_nif_map(%{epoch: epoch} = fields) do
    struct!(__MODULE__, %{fields | epoch: Epoch.from_nif_term(epoch)})
  end

  defp epoch_term(%Epoch{} = epoch), do: Epoch.to_nif_term(epoch)
  defp epoch_term(_other), do: {:error, :bad_epoch}

  defp coordinate(value, field) do
    case Numeric.float(value) do
      {:ok, float} -> {:ok, float}
      {:out_of_range, value} -> {:error, {:value_out_of_range, field, value}}
      :not_a_number -> {:error, {:invalid_sample_field, field, value}}
    end
  end

  defp optional_value(nil, _field), do: {:ok, nil}
  defp optional_value(value, field), do: coordinate(value, field)
end
