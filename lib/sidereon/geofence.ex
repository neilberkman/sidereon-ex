defmodule Sidereon.Geofence do
  @moduledoc """
  WGS84 geodesic polygon geofencing with position uncertainty.

  Fence vertices and query positions are supplied in geodetic degrees at this
  boundary. Boundary distances are metres, positive inside the fence and
  negative outside it. Probabilistic calls accept horizontal covariance or
  radius uncertainty and return inside probabilities from the core geofence
  model.
  """

  alias Sidereon.NIF

  defmodule Fence do
    @moduledoc """
    A constructed WGS84 geodesic polygon fence.

    `vertices` stores the public degree vertices supplied at construction. The
    `handle` field is an opaque native resource used for evaluation.
    """

    @enforce_keys [:handle, :vertices]
    defstruct [:handle, :vertices]

    @typedoc "Opaque geofence handle plus the normalized public vertices."
    @type t :: %__MODULE__{
            handle: reference(),
            vertices: [Sidereon.Geofence.vertex()]
          }
  end

  defmodule Hysteresis do
    @moduledoc """
    Confidence thresholds for probabilistic fence crossing.

    `enter_confidence` is the inside probability required before an entered
    event is emitted. `leave_confidence` is the outside probability required
    before a left event is emitted. Both values must be greater than `0.5` and
    less than `1.0`.
    """

    @enforce_keys [:enter_confidence, :leave_confidence]
    defstruct [:enter_confidence, :leave_confidence]

    @typedoc "Probability thresholds used by probabilistic crossing detection."
    @type t :: %__MODULE__{
            enter_confidence: float(),
            leave_confidence: float()
          }

    @doc """
    Build a probability hysteresis config.
    """
    @spec new(number(), number()) :: t()
    def new(enter_confidence \\ 0.95, leave_confidence \\ 0.95) do
      %__MODULE__{enter_confidence: enter_confidence / 1.0, leave_confidence: leave_confidence / 1.0}
    end
  end

  @typedoc "Geodetic position in public degree units."
  @type position ::
          {number(), number()}
          | {number(), number(), number()}
          | %{required(:lat_deg) => number(), required(:lon_deg) => number(), optional(:height_m) => number()}

  @typedoc "Fence vertex in public degree units."
  @type vertex :: {float(), float(), float()}

  @typedoc "Three-by-three covariance matrix in square metres."
  @type covariance_m2 :: [[number()]]

  @typedoc """
  Position uncertainty descriptor for probabilistic geofencing.

  Supported forms are `{:enu_covariance_m2, matrix}`,
  `{:ecef_covariance_m2, matrix}`, `{:cep_radius_m, radius_m}`, and
  `{:horizontal_radius_m, probability, radius_m}`.
  """
  @type uncertainty ::
          {:enu_covariance_m2, covariance_m2()}
          | {:ecef_covariance_m2, covariance_m2()}
          | {:cep_radius_m, number()}
          | {:horizontal_radius_m, number(), number()}
          | map()

  @typedoc "Probability integration method."
  @type probability_method :: :boundary_normal | :planar_quadrature

  @typedoc "Fence crossing event."
  @type crossing_event :: %{
          sample_index: non_neg_integer(),
          kind: :entered | :left,
          inside_probability: float()
        }

  @typedoc "Typed geofence error returned by this module."
  @type error_reason ::
          :too_few_vertices
          | :invalid_uncertainty
          | :invalid_probability_method
          | :covariance_rotation_failed
          | {:invalid_position, term()}
          | {:invalid_uncertainty, term()}
          | {:invalid_input, String.t(), String.t()}
          | {:geodesic, String.t()}
          | {:uncertainty_validation_failed, atom()}

  @doc """
  Construct a geodesic polygon fence from WGS84 degree vertices.

  A closing vertex equal to the first vertex is accepted. Height is retained in
  `Fence.vertices` but ignored by containment and distance calculations.
  """
  @spec new([position()]) :: {:ok, Fence.t()} | {:error, error_reason()}
  def new(vertices) when is_list(vertices) do
    with {:ok, normalized} <- normalize_positions(vertices) do
      case NIF.geofence_new(normalized) do
        {:ok, handle} when is_reference(handle) -> {:ok, %Fence{handle: handle, vertices: normalized}}
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Return whether `position` is contained by `fence`.

  Points within the core boundary tolerance are classified as contained.
  """
  @spec containment(Fence.t(), position()) :: {:ok, boolean()} | {:error, error_reason()}
  def containment(%Fence{handle: handle}, position) do
    with {:ok, normalized} <- normalize_position(position) do
      case NIF.geofence_contains(handle, normalized) do
        {:ok, inside?} -> {:ok, inside?}
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Return signed distance from `position` to the nearest fence boundary, metres.

  Positive distances are inside the fence, negative distances are outside, and
  values near zero are on the boundary.
  """
  @spec distance_to_boundary(Fence.t(), position()) :: {:ok, float()} | {:error, error_reason()}
  def distance_to_boundary(%Fence{handle: handle}, position) do
    with {:ok, normalized} <- normalize_position(position) do
      case NIF.geofence_distance_to_boundary(handle, normalized) do
        {:ok, distance_m} -> {:ok, distance_m}
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Return inside probability for one uncertain position.

  Options:

    * `:method` selects `:boundary_normal` or `:planar_quadrature`, default
      `:boundary_normal`.
  """
  @spec containment_probability(Fence.t(), position(), uncertainty(), keyword()) ::
          {:ok, float()} | {:error, error_reason()}
  def containment_probability(%Fence{handle: handle}, position, uncertainty, opts \\ []) do
    with {:ok, normalized_position} <- normalize_position(position),
         {:ok, normalized_uncertainty} <- normalize_uncertainty(uncertainty),
         {:ok, method} <- probability_method(Keyword.get(opts, :method, :boundary_normal)) do
      case NIF.geofence_containment_probability(handle, normalized_position, normalized_uncertainty, method) do
        {:ok, probability} -> {:ok, probability}
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Return boolean crossing events for a sequence of positions.

  The returned events identify the first sample index whose containment changed.
  """
  @spec crossing(Fence.t(), [position()]) :: {:ok, [crossing_event()]} | {:error, error_reason()}
  def crossing(%Fence{handle: handle}, positions) when is_list(positions) do
    with {:ok, normalized} <- normalize_positions(positions) do
      case NIF.geofence_crossing(handle, normalized) do
        {:ok, events} -> {:ok, Enum.map(events, &event_map/1)}
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Return probabilistic crossing events for uncertain position samples.

  Samples are `{position, uncertainty}` tuples or maps containing `:position`
  and `:uncertainty`. Options:

    * `:hysteresis` is a `Sidereon.Geofence.Hysteresis` struct or keyword list.
      Defaults to enter and leave confidence `0.95`.
    * `:method` selects `:boundary_normal` or `:planar_quadrature`, default
      `:boundary_normal`.
  """
  @spec crossing_probability(Fence.t(), [term()], keyword()) ::
          {:ok, [crossing_event()]} | {:error, error_reason()}
  def crossing_probability(%Fence{handle: handle}, samples, opts \\ []) when is_list(samples) do
    with {:ok, normalized_samples} <- normalize_probability_samples(samples),
         {:ok, method} <- probability_method(Keyword.get(opts, :method, :boundary_normal)),
         {:ok, hysteresis} <- normalize_hysteresis(Keyword.get(opts, :hysteresis, Hysteresis.new())) do
      case NIF.geofence_crossing_probability(
             handle,
             normalized_samples,
             hysteresis.enter_confidence,
             hysteresis.leave_confidence,
             method
           ) do
        {:ok, events} -> {:ok, Enum.map(events, &event_map/1)}
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp normalize_positions(positions) do
    positions
    |> Enum.reduce_while({:ok, []}, fn position, {:ok, acc} ->
      case normalize_position(position) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_position({lat_deg, lon_deg}), do: normalize_position({lat_deg, lon_deg, 0.0})

  defp normalize_position({lat_deg, lon_deg, height_m})
       when is_number(lat_deg) and is_number(lon_deg) and is_number(height_m),
       do: {:ok, {lat_deg / 1.0, lon_deg / 1.0, height_m / 1.0}}

  defp normalize_position(%{lat_deg: lat_deg, lon_deg: lon_deg} = position),
    do: normalize_position({lat_deg, lon_deg, Map.get(position, :height_m, 0.0)})

  defp normalize_position(other), do: {:error, {:invalid_position, other}}

  defp normalize_uncertainty({:enu_covariance_m2, matrix}) do
    with {:ok, matrix} <- normalize_matrix3(matrix) do
      {:ok, %{kind: "enu_covariance_m2", covariance_m2: matrix, probability: nil, radius_m: nil}}
    end
  end

  defp normalize_uncertainty({:ecef_covariance_m2, matrix}) do
    with {:ok, matrix} <- normalize_matrix3(matrix) do
      {:ok, %{kind: "ecef_covariance_m2", covariance_m2: matrix, probability: nil, radius_m: nil}}
    end
  end

  defp normalize_uncertainty({:cep_radius_m, radius_m}) when is_number(radius_m) do
    {:ok, %{kind: "cep_radius_m", covariance_m2: nil, probability: nil, radius_m: radius_m / 1.0}}
  end

  defp normalize_uncertainty({:horizontal_radius_m, probability, radius_m})
       when is_number(probability) and is_number(radius_m) do
    {:ok,
     %{
       kind: "horizontal_radius_m",
       covariance_m2: nil,
       probability: probability / 1.0,
       radius_m: radius_m / 1.0
     }}
  end

  defp normalize_uncertainty(%{kind: kind} = uncertainty) do
    normalize_uncertainty(
      case kind do
        :enu_covariance_m2 ->
          {:enu_covariance_m2, Map.get(uncertainty, :covariance_m2)}

        "enu_covariance_m2" ->
          {:enu_covariance_m2, Map.get(uncertainty, :covariance_m2)}

        :ecef_covariance_m2 ->
          {:ecef_covariance_m2, Map.get(uncertainty, :covariance_m2)}

        "ecef_covariance_m2" ->
          {:ecef_covariance_m2, Map.get(uncertainty, :covariance_m2)}

        :cep_radius_m ->
          {:cep_radius_m, Map.get(uncertainty, :radius_m)}

        "cep_radius_m" ->
          {:cep_radius_m, Map.get(uncertainty, :radius_m)}

        :horizontal_radius_m ->
          {:horizontal_radius_m, Map.get(uncertainty, :probability), Map.get(uncertainty, :radius_m)}

        "horizontal_radius_m" ->
          {:horizontal_radius_m, Map.get(uncertainty, :probability), Map.get(uncertainty, :radius_m)}

        _ ->
          :invalid
      end
    )
  end

  defp normalize_uncertainty(other), do: {:error, {:invalid_uncertainty, other}}

  defp normalize_matrix3(rows) when is_list(rows) and length(rows) == 3 do
    if Enum.all?(rows, &(is_list(&1) and length(&1) == 3 and Enum.all?(&1, fn value -> is_number(value) end))) do
      {:ok, Enum.map(rows, fn row -> Enum.map(row, &(&1 / 1.0)) end)}
    else
      {:error, {:invalid_uncertainty, rows}}
    end
  end

  defp normalize_matrix3(other), do: {:error, {:invalid_uncertainty, other}}

  defp normalize_probability_samples(samples) do
    samples
    |> Enum.reduce_while({:ok, []}, fn sample, {:ok, acc} ->
      case normalize_probability_sample(sample) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_probability_sample({position, uncertainty}) do
    with {:ok, position} <- normalize_position(position),
         {:ok, uncertainty} <- normalize_uncertainty(uncertainty) do
      {:ok, %{position: position, uncertainty: uncertainty}}
    end
  end

  defp normalize_probability_sample(%{position: position, uncertainty: uncertainty}),
    do: normalize_probability_sample({position, uncertainty})

  defp normalize_probability_sample(other), do: {:error, {:invalid_uncertainty, other}}

  defp normalize_hysteresis(%Hysteresis{} = hysteresis), do: {:ok, hysteresis}

  defp normalize_hysteresis(opts) when is_list(opts) do
    {:ok,
     Hysteresis.new(
       Keyword.get(opts, :enter_confidence, 0.95),
       Keyword.get(opts, :leave_confidence, 0.95)
     )}
  end

  defp normalize_hysteresis(other), do: {:error, {:invalid_input, "hysteresis", inspect(other)}}

  defp probability_method(method) when method in [:boundary_normal, "boundary_normal"], do: {:ok, "boundary_normal"}

  defp probability_method(method) when method in [:planar_quadrature, "planar_quadrature"],
    do: {:ok, "planar_quadrature"}

  defp probability_method(_method), do: {:error, :invalid_probability_method}

  defp event_map({sample_index, kind, inside_probability}) do
    %{sample_index: sample_index, kind: kind, inside_probability: inside_probability}
  end
end
