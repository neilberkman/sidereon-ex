defmodule Sidereon.Forces.IcgemGravityField do
  @moduledoc "Static and time-variable gravity coefficients from ICGEM gravity field files."

  alias Sidereon.Forces.IcgemGravityField
  alias Sidereon.Forces.SphericalHarmonicGravity
  alias Sidereon.Forces.SphericalHarmonicGravity.SphericalHarmonicCoefficient
  alias Sidereon.NIF

  @enforce_keys [:handle]
  defstruct [:handle]
  @opaque t :: %__MODULE__{handle: reference()}

  @typedoc "Permanent-tide convention of the degree-two zonal coefficient."
  @type tide_system :: :tide_free | :zero_tide | :mean_tide

  defmodule IcgemErrors do
    @moduledoc "Uncertainty columns stated in the ICGEM header."
    @type t :: :no | :calibrated | :formal | :calibrated_and_formal
  end

  defmodule IcgemNormalization do
    @moduledoc "Normalization stated in the ICGEM header."
    @type t :: :fully_normalized | :unnormalized
  end

  defmodule IcgemFormat do
    @moduledoc "ICGEM format version."
    @type t :: :icgem1_0 | :icgem2_0
  end

  defmodule IcgemTermKind do
    @moduledoc "Time dependence of a coefficient term, with sinusoidal periods in Julian years."
    @type t :: :constant | :trend | {:cosine, float()} | {:sine, float()}
  end

  defmodule IcgemError do
    @moduledoc "An ICGEM parsing or evaluation refusal with its details."
    defstruct [:kind, :detail, :message]
    @type t :: %__MODULE__{kind: atom(), detail: map(), message: String.t()}

    defimpl String.Chars do
      def to_string(error), do: error.message
    end
  end

  defmodule IcgemHeader do
    @moduledoc "Model identifier, gravity constant in m³/s², radius in metres, and file metadata. This struct compares by value."
    @enforce_keys [
      :model_name,
      :gravity_constant_m3_s2,
      :radius_m,
      :max_degree,
      :errors,
      :normalization,
      :tide_system,
      :format
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            model_name: String.t(),
            gravity_constant_m3_s2: float(),
            radius_m: float(),
            max_degree: non_neg_integer(),
            errors: IcgemErrors.t(),
            normalization: IcgemNormalization.t(),
            tide_system: IcgemGravityField.tide_system() | nil,
            format: IcgemFormat.t()
          }
  end

  defmodule IcgemSigmas do
    @moduledoc "Fully normalized uncertainties for C and S, grouped by their source. This struct compares by value."
    defstruct [:calibrated, :formal]
    @type t :: %__MODULE__{calibrated: {float(), float()} | nil, formal: {float(), float()} | nil}
  end

  defmodule IcgemTimeVariableTerm do
    @moduledoc """
    One fully normalized time-variable coefficient. Epochs are TT seconds past J2000.
    An unbounded interval is represented by the atoms :negative_infinity and :infinity.
    This struct compares by value.
    """
    @enforce_keys [
      :line,
      :kind,
      :degree,
      :order,
      :c,
      :s,
      :sigmas,
      :reference_tt_seconds,
      :valid_from_tt_seconds,
      :valid_until_tt_seconds
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            line: pos_integer(),
            kind: IcgemTermKind.t(),
            degree: non_neg_integer(),
            order: non_neg_integer(),
            c: float(),
            s: float(),
            sigmas: IcgemSigmas.t(),
            reference_tt_seconds: float(),
            valid_from_tt_seconds: float() | :negative_infinity,
            valid_until_tt_seconds: float() | :infinity
          }
  end

  @doc "Parse ICGEM gravity field text."
  @spec parse(String.t()) :: {:ok, t()} | {:error, IcgemError.t()}
  def parse(text) do
    with {:ok, value} <- decode(NIF.icgem_parse(text)), do: {:ok, %__MODULE__{handle: value}}
  end

  @doc "Parse ICGEM gravity coefficients through the given degree and order."
  @spec parse_truncated(String.t(), non_neg_integer(), non_neg_integer()) :: {:ok, t()} | {:error, IcgemError.t()}
  def parse_truncated(text, degree, order) do
    with {:ok, value} <- decode(NIF.icgem_parse_truncated(text, degree, order)), do: {:ok, %__MODULE__{handle: value}}
  end

  @doc "Resolve an unspecified tide system or verify the stated convention."
  @spec with_assumed_tide_system(t(), tide_system()) :: {:ok, t()} | {:error, IcgemError.t()}
  def with_assumed_tide_system(%__MODULE__{handle: handle}, tide) do
    with {:ok, value} <- decode(NIF.icgem_with_assumed_tide_system(handle, tide)), do: {:ok, %__MODULE__{handle: value}}
  end

  @doc "Build a geopotential through the given degree and order in the stated tide system."
  @spec gravity(t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, SphericalHarmonicGravity.t()} | {:error, IcgemError.t()}
  def gravity(%__MODULE__{handle: handle}, degree, order) do
    with {:ok, value} <- decode(NIF.icgem_gravity(handle, degree, order)),
         do: {:ok, %SphericalHarmonicGravity{handle: value}}
  end

  @doc "Build a geopotential with the degree-two zonal coefficient in the requested tide system."
  @spec gravity_in_tide_system(t(), non_neg_integer(), non_neg_integer(), tide_system()) ::
          {:ok, SphericalHarmonicGravity.t()} | {:error, IcgemError.t()}
  def gravity_in_tide_system(%__MODULE__{handle: handle}, degree, order, tide) do
    with {:ok, value} <- decode(NIF.icgem_gravity_in_tide_system(handle, degree, order, tide)),
         do: {:ok, %SphericalHarmonicGravity{handle: value}}
  end

  @doc "Evaluate a coefficient at TT seconds past J2000."
  @spec coefficient_at(t(), non_neg_integer(), non_neg_integer(), number()) ::
          {:ok, SphericalHarmonicCoefficient.t() | nil} | {:error, IcgemError.t()}
  def coefficient_at(%__MODULE__{handle: handle}, degree, order, epoch) do
    with {:ok, value} <- decode(NIF.icgem_coefficient_at(handle, degree, order, epoch / 1.0)),
         do: {:ok, optional_struct(SphericalHarmonicCoefficient, value)}
  end

  @doc "Return the ICGEM header."
  @spec header(t()) :: IcgemHeader.t()
  def header(%__MODULE__{handle: handle}), do: struct!(IcgemHeader, NIF.icgem_header(handle))

  @doc "Return the maximum stored degree."
  @spec stored_max_degree(t()) :: non_neg_integer()
  def stored_max_degree(%__MODULE__{handle: handle}), do: NIF.icgem_stored_max_degree(handle)

  @doc "Return the maximum stored order."
  @spec stored_max_order(t()) :: non_neg_integer()
  def stored_max_order(%__MODULE__{handle: handle}), do: NIF.icgem_stored_max_order(handle)

  @doc "Return whether the field contains time-variable terms."
  @spec time_variable?(t()) :: boolean()
  def time_variable?(%__MODULE__{handle: handle}), do: NIF.icgem_is_time_variable(handle)

  @doc "Return the stored static coefficient, if present."
  @spec static_coefficient(t(), non_neg_integer(), non_neg_integer()) :: SphericalHarmonicCoefficient.t() | nil
  def static_coefficient(%__MODULE__{handle: handle}, degree, order),
    do: optional_struct(SphericalHarmonicCoefficient, NIF.icgem_static_coefficient(handle, degree, order))

  @doc "Return the stored static uncertainties, if present."
  @spec static_sigmas(t(), non_neg_integer(), non_neg_integer()) :: IcgemSigmas.t() | nil
  def static_sigmas(%__MODULE__{handle: handle}, degree, order),
    do: optional_struct(IcgemSigmas, NIF.icgem_static_sigmas(handle, degree, order))

  @doc "Return the stored time-variable coefficient terms."
  @spec time_variable_terms(t()) :: [IcgemTimeVariableTerm.t()]
  def time_variable_terms(%__MODULE__{handle: handle}) do
    Enum.map(NIF.icgem_time_variable_terms(handle), fn term ->
      struct!(IcgemTimeVariableTerm, %{term | sigmas: struct!(IcgemSigmas, term.sigmas)})
    end)
  end

  @doc "Compare gravity field contents and metadata by value."
  @spec equal?(t(), t()) :: boolean()
  def equal?(%__MODULE__{handle: first}, %__MODULE__{handle: second}), do: NIF.icgem_equal(first, second)

  defp optional_struct(_module, nil), do: nil
  defp optional_struct(module, content), do: struct!(module, content)

  defp decode({:ok, _value} = result), do: result
  defp decode({:error, details}), do: {:error, struct!(IcgemError, details)}
end
