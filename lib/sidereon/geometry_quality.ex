defmodule Sidereon.GeometryQuality do
  @moduledoc """
  Geometry observability and covariance-validation diagnostics.

  The `tier` field classifies the solve design as:

    * `:rank_deficient` - at least one parameter is not observable.
    * `:zero_redundancy` - full rank, but no residual degrees of freedom.
    * `:weak` - full rank with residual degrees of freedom, but above a condition-number or GDOP cutoff.
    * `:nominal` - full rank and within the configured cutoffs.

  `:zero_redundancy` bounds are not validated unless `covariance_validated` is
  true. `:weak` bounds are reported without clamping.
  """

  @typedoc "Observability tier returned by the core geometry classifier."
  @type observability_tier :: :rank_deficient | :zero_redundancy | :weak | :nominal

  @typedoc "Geometry observability and covariance-validation diagnostics."
  @type t :: %__MODULE__{
          tier: observability_tier(),
          redundancy: integer(),
          rank: non_neg_integer(),
          condition_number: float(),
          gdop: float(),
          raim_checkable: boolean(),
          covariance_validated: boolean()
        }

  @enforce_keys [
    :tier,
    :redundancy,
    :rank,
    :condition_number,
    :gdop,
    :raim_checkable,
    :covariance_validated
  ]
  defstruct [
    :tier,
    :redundancy,
    :rank,
    :condition_number,
    :gdop,
    :raim_checkable,
    :covariance_validated
  ]

  @doc """
  Decode the NIF tuple representation into a geometry diagnostics struct.
  """
  @spec from_nif({atom(), integer(), non_neg_integer(), float(), float(), boolean(), boolean()}) :: t()
  def from_nif({tier, redundancy, rank, condition_number, gdop, raim_checkable, covariance_validated}) do
    %__MODULE__{
      tier: tier,
      redundancy: redundancy,
      rank: rank,
      condition_number: condition_number,
      gdop: gdop,
      raim_checkable: raim_checkable,
      covariance_validated: covariance_validated
    }
  end

  @doc """
  Encode a geometry diagnostics struct into the tuple representation used by the NIF.
  """
  @spec to_nif(t()) :: {atom(), integer(), non_neg_integer(), float(), float(), boolean(), boolean()}
  def to_nif(%__MODULE__{} = quality) do
    {
      quality.tier,
      quality.redundancy,
      quality.rank,
      quality.condition_number,
      quality.gdop,
      quality.raim_checkable,
      quality.covariance_validated
    }
  end
end
