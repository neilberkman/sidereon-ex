defmodule Sidereon.FrameCatalog do
  @moduledoc """
  Epoch-aware terrestrial reference-frame transforms.

  The built-in catalog contains published 14-parameter Helmert transforms for
  ITRF and ETRF realizations. Positions are geocentric Cartesian metres,
  velocities are metres per year, and epochs are decimal years.
  """

  alias Sidereon.NIF

  defmodule TerrestrialFrame do
    @moduledoc """
    Supported terrestrial frame labels.
    """

    @typedoc "A terrestrial frame accepted by the catalog functions."
    @type t :: :itrf2020 | :itrf2014 | :itrf2008 | :etrf2020 | String.t()
  end

  defmodule HelmertParameters do
    @moduledoc """
    Helmert parameters in the published table units.
    """

    @enforce_keys [:translation_mm, :scale_ppb, :rotation_mas]
    defstruct [:translation_mm, :scale_ppb, :rotation_mas]

    @type t :: %__MODULE__{
            translation_mm: Sidereon.vec3(),
            scale_ppb: float(),
            rotation_mas: Sidereon.vec3()
          }
  end

  defmodule HelmertRates do
    @moduledoc """
    Helmert parameter rates in the published table units.
    """

    @enforce_keys [:translation_mm_per_year, :scale_ppb_per_year, :rotation_mas_per_year]
    defstruct [:translation_mm_per_year, :scale_ppb_per_year, :rotation_mas_per_year]

    @type t :: %__MODULE__{
            translation_mm_per_year: Sidereon.vec3(),
            scale_ppb_per_year: float(),
            rotation_mas_per_year: Sidereon.vec3()
          }
  end

  defmodule HelmertTransform do
    @moduledoc """
    One published Helmert transform catalog entry.
    """

    @enforce_keys [:from, :to, :reference_epoch_year, :parameters, :rates, :provenance]
    defstruct [:from, :to, :reference_epoch_year, :parameters, :rates, :provenance]

    @type t :: %__MODULE__{
            from: atom(),
            to: atom(),
            reference_epoch_year: float(),
            parameters: HelmertParameters.t(),
            rates: HelmertRates.t(),
            provenance: String.t()
          }
  end

  defmodule TerrestrialState do
    @moduledoc """
    Transformed terrestrial position and optional station velocity.
    """

    @enforce_keys [:position_m]
    defstruct [:position_m, :velocity_m_per_year]

    @type t :: %__MODULE__{
            position_m: Sidereon.vec3(),
            velocity_m_per_year: Sidereon.vec3() | nil
          }
  end

  @typedoc "Frame catalog error detail."
  @type error_reason :: :invalid_frame | map()

  @doc """
  Return all built-in Helmert catalog entries.
  """
  @spec catalog() :: [HelmertTransform.t()]
  def catalog do
    NIF.frame_catalog()
    |> Enum.map(&transform_from_fields/1)
  end

  @doc """
  Return the direct published catalog entry for `from` to `to`.
  """
  @spec catalog_entry(TerrestrialFrame.t(), TerrestrialFrame.t()) ::
          {:ok, HelmertTransform.t()} | {:error, error_reason()}
  def catalog_entry(from, to) do
    case NIF.frame_catalog_entry(frame(from), frame(to)) do
      {:ok, transform} -> {:ok, transform_from_fields(transform)}
      {:error, reason} -> {:error, error(reason)}
    end
  end

  @doc """
  Propagate a station position from one decimal-year epoch to another.
  """
  @spec propagate_position(Sidereon.vec3(), Sidereon.vec3(), number(), number()) ::
          {:ok, Sidereon.vec3()} | {:error, error_reason()}
  def propagate_position(position_m, velocity_m_per_year, from_epoch_year, to_epoch_year) do
    case NIF.frame_catalog_propagate_position(
           vec3(position_m),
           vec3(velocity_m_per_year),
           from_epoch_year / 1.0,
           to_epoch_year / 1.0
         ) do
      {:ok, position} -> {:ok, position}
      {:error, reason} -> {:error, error(reason)}
    end
  end

  @doc """
  Transform a Cartesian station position and optional velocity between frames.
  """
  @spec transform(Sidereon.vec3(), Sidereon.vec3() | nil, TerrestrialFrame.t(), TerrestrialFrame.t(), number()) ::
          {:ok, TerrestrialState.t()} | {:error, error_reason()}
  def transform(position_m, velocity_m_per_year, from, to, epoch_year) do
    case NIF.frame_catalog_transform(
           vec3(position_m),
           optional_vec3(velocity_m_per_year),
           frame(from),
           frame(to),
           epoch_year / 1.0
         ) do
      {:ok, state} -> {:ok, state_from_fields(state)}
      {:error, reason} -> {:error, error(reason)}
    end
  end

  @doc """
  Propagate a station to `transform_epoch_year`, then transform it between frames.
  """
  @spec transform_from_epoch(
          Sidereon.vec3(),
          Sidereon.vec3(),
          number(),
          TerrestrialFrame.t(),
          TerrestrialFrame.t(),
          number()
        ) :: {:ok, TerrestrialState.t()} | {:error, error_reason()}
  def transform_from_epoch(position_m, velocity_m_per_year, position_epoch_year, from, to, transform_epoch_year) do
    case NIF.frame_catalog_transform_from_epoch(
           vec3(position_m),
           vec3(velocity_m_per_year),
           position_epoch_year / 1.0,
           frame(from),
           frame(to),
           transform_epoch_year / 1.0
         ) do
      {:ok, state} -> {:ok, state_from_fields(state)}
      {:error, reason} -> {:error, error(reason)}
    end
  end

  defp transform_from_fields(value) do
    %HelmertTransform{
      from: frame_atom(value.from_frame),
      to: frame_atom(value.to_frame),
      reference_epoch_year: value.reference_epoch_year,
      parameters: parameters_from_fields(value.parameters),
      rates: rates_from_fields(value.rates),
      provenance: value.provenance
    }
  end

  defp parameters_from_fields(value) do
    %HelmertParameters{
      translation_mm: value.translation_mm,
      scale_ppb: value.scale_ppb,
      rotation_mas: value.rotation_mas
    }
  end

  defp rates_from_fields(value) do
    %HelmertRates{
      translation_mm_per_year: value.translation_mm_per_year,
      scale_ppb_per_year: value.scale_ppb_per_year,
      rotation_mas_per_year: value.rotation_mas_per_year
    }
  end

  defp state_from_fields(value) do
    %TerrestrialState{
      position_m: value.position_m,
      velocity_m_per_year: value.velocity_m_per_year
    }
  end

  defp frame(:itrf2020), do: "ITRF2020"
  defp frame(:itrf2014), do: "ITRF2014"
  defp frame(:itrf2008), do: "ITRF2008"
  defp frame(:etrf2020), do: "ETRF2020"
  defp frame(value) when is_binary(value), do: value

  defp frame_atom("ITRF2020"), do: :itrf2020
  defp frame_atom("ITRF2014"), do: :itrf2014
  defp frame_atom("ITRF2008"), do: :itrf2008
  defp frame_atom("ETRF2020"), do: :etrf2020

  defp error(reason) when is_atom(reason), do: reason

  defp error(%{} = reason) do
    Map.update!(reason, :kind, &String.to_atom/1)
  end

  defp vec3({x, y, z}), do: {x / 1.0, y / 1.0, z / 1.0}
  defp optional_vec3(nil), do: nil
  defp optional_vec3(value), do: vec3(value)
end
