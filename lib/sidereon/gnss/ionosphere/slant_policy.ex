defmodule Sidereon.GNSS.Ionosphere.SlantPolicy do
  @moduledoc """
  The three independent policies an IONEX slant-delay evaluation applies.

    * `:coverage` - `:strict` refuses a query outside the product's epochs,
      latitudes or longitudes; `:hold` holds the nearest map or grid edge and
      names the miss in the result's `held` field. Default `:strict`.

    * `:missing_nodes` - `:strict` refuses a query whose interpolation weights a
      node the product gives as non-available; `:renormalize` interpolates from
      the weighted nodes that hold values, their weights renormalized to sum to
      one, and names every node it interpolated around in the result's
      `degraded` field. Default `:strict`.

    * `:mapping` - `:single_layer` applies `1/cos(z')` at the shell height
      whatever the product declares, naming what a product declaring anything
      but `COSZ` declares in the result's `assumed_mapping` field;
      `:declared` applies the factor the product's `MAPPING FUNCTION` defines
      and refuses the query where that record defines none. Default
      `:single_layer`.

  The three are independent, and all three status fields can be set on one
  value.

  ## What is refused

  Nothing here falls back to a default for a name it does not recognize:

    * `{:invalid_policy_value, field, value}` - a choice none of the three
      fields names.
    * `{:unknown_policy_key, key}` - a key that is not one of the three. The key
      is returned as it was given, whatever its type, and no atom is created for
      it.
    * `{:duplicate_policy_key, key}` - a keyword list stating one key twice.
      Collapsing it would silently drop the earlier statement, including an
      invalid one, so a list that states a key twice is refused whether the two
      choices agree or not.
    * `:bad_slant_policy` - an options container that is neither a keyword list
      nor a plain map.

  A key left out takes its documented default.
  """

  defstruct coverage: :strict, missing_nodes: :strict, mapping: :single_layer

  @type coverage_choice :: :strict | :hold
  @type missing_node_choice :: :strict | :renormalize
  @type mapping_choice :: :single_layer | :declared

  @type t :: %__MODULE__{
          coverage: coverage_choice(),
          missing_nodes: missing_node_choice(),
          mapping: mapping_choice()
        }

  @choices %{
    coverage: [:strict, :hold],
    missing_nodes: [:strict, :renormalize],
    mapping: [:single_layer, :declared]
  }

  @keys Map.keys(@choices)

  @doc """
  The default policy: strict coverage, strict missing nodes, single-layer
  mapping.
  """
  @spec strict() :: t()
  def strict, do: %__MODULE__{}

  @doc """
  The default policy with `:coverage` set to `:hold`.
  """
  @spec hold() :: t()
  def hold, do: %__MODULE__{coverage: :hold}

  @doc """
  The default policy with `:missing_nodes` set to `:renormalize`.
  """
  @spec renormalize() :: t()
  def renormalize, do: %__MODULE__{missing_nodes: :renormalize}

  @doc """
  Builds a policy from `opts`, which may set any of `:coverage`,
  `:missing_nodes` and `:mapping`.

  Returns `{:ok, policy}`, or one of the refusals the moduledoc lists. A key left
  out takes its documented default.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ [])

  def new(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      with :ok <- reject_duplicate_keys(Keyword.keys(opts)), do: from_map(Map.new(opts))
    else
      {:error, :bad_slant_policy}
    end
  end

  def new(%__MODULE__{} = policy), do: validate(policy)

  def new(opts) when is_map(opts) and not is_struct(opts), do: from_map(opts)

  def new(_other), do: {:error, :bad_slant_policy}

  @doc """
  Checks that every field of `policy` names a choice the binding recognizes.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{} = policy) do
    Enum.reduce_while(@keys, {:ok, policy}, fn field, acc ->
      case choice(Map.from_struct(policy), field) do
        {:ok, _value} -> {:cont, acc}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def validate(_other), do: {:error, :bad_slant_policy}

  @doc false
  @spec to_nif_map(t() | keyword() | map()) :: {:ok, map()} | {:error, term()}
  def to_nif_map(%__MODULE__{} = policy) do
    with {:ok, valid} <- validate(policy) do
      {:ok, %{coverage: valid.coverage, missing_nodes: valid.missing_nodes, mapping: valid.mapping}}
    end
  end

  def to_nif_map(opts) when is_list(opts) or is_map(opts) do
    with {:ok, policy} <- new(opts), do: to_nif_map(policy)
  end

  def to_nif_map(_other), do: {:error, :bad_slant_policy}

  defp from_map(opts) do
    with :ok <- reject_unknown_keys(opts),
         {:ok, coverage} <- choice(opts, :coverage),
         {:ok, missing_nodes} <- choice(opts, :missing_nodes),
         {:ok, mapping} <- choice(opts, :mapping) do
      {:ok, %__MODULE__{coverage: coverage, missing_nodes: missing_nodes, mapping: mapping}}
    end
  end

  # A key is unknown by what it is, not by what it holds: a map keyed by `nil`
  # is an unknown key whose name happens to be `nil`, so presence is decided by
  # filtering rather than by a search that reports absence as `nil` too.
  defp reject_unknown_keys(opts) do
    case Enum.reject(Map.keys(opts), &(&1 in @keys)) do
      [] -> :ok
      [key | _rest] -> {:error, {:unknown_policy_key, key}}
    end
  end

  defp reject_duplicate_keys(keys) do
    case keys -- Enum.uniq(keys) do
      [] -> :ok
      [key | _rest] -> {:error, {:duplicate_policy_key, key}}
    end
  end

  defp choice(opts, field) do
    allowed = Map.fetch!(@choices, field)
    value = Map.get(opts, field, hd(allowed))

    if value in allowed do
      {:ok, value}
    else
      {:error, {:invalid_policy_value, field, value}}
    end
  end
end
