defmodule Sidereon.Propagator.PropagationContext do
  @moduledoc """
  Shared Earth orientation and body ephemeris inputs for propagation.
  A context and its derived contexts share the same record of UT1 departures.
  """

  alias Sidereon.DeEphemeris
  alias Sidereon.Iers2010EarthOrientationProvider
  alias Sidereon.NIF

  @enforce_keys [:handle]
  defstruct [:handle, :de_ephemeris]
  @opaque t :: %__MODULE__{handle: reference(), de_ephemeris: DeEphemeris.t() | nil}

  @doc "Return a context with analytic Sun and Moon positions and no configured orientation provider."
  @spec new() :: t()
  def new, do: %__MODULE__{handle: NIF.propagation_context_new()}

  @doc "Return a context with the given JPL DE body ephemeris."
  @spec with_de_ephemeris(t(), DeEphemeris.t()) :: t()
  def with_de_ephemeris(%__MODULE__{handle: handle} = context, %DeEphemeris{handle: de} = ephemeris) do
    %{context | handle: NIF.propagation_context_with_de_ephemeris(handle, de), de_ephemeris: ephemeris}
  end

  @doc "Return the configured JPL DE ephemeris, if present."
  @spec de_ephemeris(t()) :: DeEphemeris.t() | nil
  def de_ephemeris(%__MODULE__{de_ephemeris: ephemeris}), do: ephemeris

  @doc """
  Return a context with the given Earth orientation provider. Use `:tdb` for
  the built-in provider with strict UT1 validity.
  """
  @spec with_body_fixed_frame_provider(t(), :tdb | Iers2010EarthOrientationProvider.t()) :: t()
  def with_body_fixed_frame_provider(%__MODULE__{handle: handle} = context, :tdb) do
    %{context | handle: NIF.propagation_context_with_body_fixed_frame_provider(handle, :tdb)}
  end

  def with_body_fixed_frame_provider(%__MODULE__{handle: handle} = context, %Iers2010EarthOrientationProvider{
        handle: provider
      }) do
    %{context | handle: NIF.propagation_context_with_body_fixed_frame_provider(handle, provider)}
  end

  @doc """
  Return a context with the built-in TDB Earth orientation provider and the
  given UT1 validity mode. A permissive provider evaluates epochs outside
  UT1 coverage and records the departure on the context.
  """
  @spec with_body_fixed_frame_provider(t(), :tdb, :strict | :permissive) :: t()
  def with_body_fixed_frame_provider(%__MODULE__{handle: handle} = context, :tdb, validity)
      when validity in [:strict, :permissive] do
    %{context | handle: NIF.propagation_context_with_body_fixed_frame_provider(handle, {:tdb, validity})}
  end

  @doc "Return the first departure from UT1 coverage recorded during a computation."
  @spec ut1_departure(t()) :: :before_coverage | :after_coverage | nil
  def ut1_departure(%__MODULE__{handle: handle}), do: NIF.propagation_context_ut1_departure(handle)
end
