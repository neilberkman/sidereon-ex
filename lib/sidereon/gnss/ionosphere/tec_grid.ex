defmodule Sidereon.GNSS.Ionosphere.TecGrid do
  @moduledoc """
  A standalone regular-grid vertical TEC source.

  This is the regular-grid variant `sidereon-core` exposes beside the IONEX
  product: vertical TEC in TECU on strictly increasing epoch, latitude and
  longitude axes, each with at least two nodes.

  ## Axes and value order

  The epoch axis is floating-point Unix nanoseconds, which is what the core
  stores; adjacent nanoseconds are not distinguishable at large magnitudes, and
  the axis is reported back exactly as stored. This is a different origin from
  the IONEX product surface, whose `Sidereon.GNSS.Ionosphere.Epoch` counts
  nanoseconds from J2000; neither is converted into the other. Latitudes and
  longitudes are degrees. `values` is flat `[epoch][latitude][longitude]` with
  longitude varying fastest.

  A node without a value is `nil`; a node holding `0.0` has a value of zero.

  ## Queries

  `vtec_at_pierce_point/5` takes `longitude_deg` before `latitude_deg`, matching
  the core signature, and an exact integer Unix-nanosecond epoch. A query
  interpolates the eight corners of the surrounding cell: bilinearly within each
  of the two bracketing epochs, then linearly in time. Latitudes outside
  `[-87.5, 87.5]` are clamped to that interval by the core.

  ## XYZ evaluation

  `tec_xyz/6` and `iono_delay_xyz/7` evaluate the grid along the line of sight
  from an ECEF receiver position to an ECEF satellite position, both in meters:
  vertical and slant TEC in TECU, or the group delay in meters on a carrier. The
  core intersects the line of sight with a thin spherical shell, interpolates
  the grid at the longitude and latitude of that pierce point, and maps the
  vertical TEC to slant TEC with the elevation. The longitude and latitude come
  from the caller: the evaluation asks a converter, a function of one argument,
  for the geodetic coordinates of an ECEF position `{x, y, z}` in meters, and
  the converter answers `{lon_deg, lat_deg, alt}`.

  The converter is asked for the pierce point first. An answer with a NaN in any
  component, the altitude included, makes the core ask for the receiver position
  exactly as given, and the evaluation then uses the receiver's longitude and
  latitude. The altitude of that second answer is not read, so a NaN there asks
  for nothing further, and a NaN longitude or latitude there is refused rather
  than asked about again. An evaluation therefore calls the converter once, or
  twice after a NaN answer.

  The core checks its inputs before the first conversion, in this order: the
  carrier for a delay, then the positions, the options and the geometry they
  give. A refusal there leaves the converter uncalled. The elevation is checked
  when the pierce-point answer arrives, before the core looks for a NaN in it,
  so a refused elevation ends the evaluation after one call even when that
  answer held a NaN. The grid is read only after the last conversion, so an
  epoch outside the grid, a pierce point outside it or a missing node is refused
  after the converter has been called, as are the checks on the slant mapping
  and, for a delay, on the delay itself.

  The converter runs in the calling process as an ordinary function call,
  between steps of the evaluation that each return to Elixir; no native code
  calls it. Whatever it raises, throws or exits with reaches the caller
  unchanged, with its own stacktrace, and the evaluation stops there. It may
  itself query this grid or any other. Every step holds the grid the evaluation
  was prepared on, so the caller's own reference to the grid can be dropped
  while the evaluation runs, and no step can be continued on another grid.

  ### Non-finite doubles

  An Erlang float is always finite, while the positions the core asks about and
  the answers it reads need not be: a line of sight that misses the shell gives
  a pierce point whose components are NaN, and that position is still passed to
  the converter, as the core passes it to its own callback. So every double of
  these two functions, in either direction, is a `t:double/0`: a float where it
  is finite, and otherwise `{:nonfinite, bits}`, `bits` being its IEEE 754
  binary64 bit pattern as an unsigned integer, sign and NaN payload included.
  `nan/0`, `infinity/0` and `neg_infinity/0` give the usual three.

  The converter receives its position in this form and may answer in it, and a
  position, the carrier or an option may be given in it. An integer is read onto
  its double. The tag only carries the bits: the double reaches the core bit for
  bit, and the core's own NaN and finiteness checks apply to it as to any other.
  A latitude of either infinity is clamped to 87.5 degrees of the same sign like
  any latitude beyond that, while an infinite longitude is refused. The pattern
  under the tag must be an integer from 0 to 2^64 - 1 with every exponent bit
  set, which is a NaN or an infinity. A finite pattern is refused, because a
  finite value crosses as a float.
  """

  alias Sidereon.GNSS.Ionosphere.Boundary
  alias Sidereon.GNSS.Ionosphere.NodeGap
  alias Sidereon.GNSS.Ionosphere.Numeric
  alias Sidereon.GNSS.Ionosphere.Refusal
  alias Sidereon.NIF
  alias Sidereon.NifCall

  @enforce_keys [:handle]
  defstruct [:handle]

  @type t :: %__MODULE__{handle: reference()}

  @typedoc """
  A double of the XYZ evaluations: a float where it is finite, and otherwise
  `{:nonfinite, bits}` with its IEEE 754 binary64 bit pattern.
  """
  @type double :: float() | {:nonfinite, non_neg_integer()}

  @typedoc "A double as a caller may give it: a number or a `t:double/0`."
  @type component :: number() | double()

  @typedoc "An ECEF position in meters, `{x, y, z}`."
  @type xyz :: {component(), component(), component()}

  @typedoc """
  Converts an ECEF position in meters to `{lon_deg, lat_deg, alt}`.
  """
  @type converter :: ({double(), double(), double()} -> {component(), component(), component()})

  @option_keys [:missing_nodes]
  @missing_node_choices [:strict, :renormalize]
  @xyz_double_options [:min_elevation_rad, :nan_pierce_point_height_m, :earth_radius_m, :shell_height_m]
  @xyz_option_keys [:missing_nodes | @xyz_double_options]

  @i64_min -9_223_372_036_854_775_808
  @i64_max 9_223_372_036_854_775_807

  # IEEE 754 binary64: a pattern with every exponent bit set is a NaN or an
  # infinity.
  @exponent_bits 0x7FF0_0000_0000_0000
  @u64_max 0xFFFF_FFFF_FFFF_FFFF

  defmodule Evaluation do
    @moduledoc """
    A regular-grid value with the nodes a renormalizing query interpolated
    around.

    `value` is vertical TEC in TECU from
    `Sidereon.GNSS.Ionosphere.TecGrid.vtec_at_pierce_point/5`, the pair
    `{vtec_tecu, stec_tecu}` from `Sidereon.GNSS.Ionosphere.TecGrid.tec_xyz/6`,
    and the group delay in meters from
    `Sidereon.GNSS.Ionosphere.TecGrid.iono_delay_xyz/7`.

    `degraded` is a `Sidereon.GNSS.Ionosphere.NodeGap` naming every weighted node
    that held no value, or `nil` where they all held one. A value with
    `degraded` set rests on fewer nodes than the cell has.
    """

    @enforce_keys [:value]
    defstruct [:value, :degraded]

    @type t :: %__MODULE__{value: float() | {float(), float()}, degraded: NodeGap.t() | nil}

    @doc false
    @spec from_nif_map(map()) :: t()
    def from_nif_map(%{value: value, degraded: degraded}) do
      %__MODULE__{value: value, degraded: if(degraded, do: NodeGap.from_nif_map(degraded))}
    end
  end

  @doc """
  Builds a grid from its three axes and a flat list of TECU values in
  `[epoch][latitude][longitude]` order.

  `epochs_ns` is floating-point Unix nanoseconds. Each axis must hold at least
  two strictly increasing entries, and `values` must hold exactly
  `length(epochs_ns) * length(latitudes_deg) * length(longitudes_deg)` entries.
  A node without a value is `nil`.

  Returns `{:ok, grid}` or `{:error, reason}`, where `reason` names the failed
  invariant. The core names `:axes_too_short`, `:axes_not_increasing`,
  `:dimensions_overflow`, `{:value_count_mismatch, actual, expected}`,
  `{:invalid_field, field, reason}` with the core's own field and reason text,
  and `{:unhandled, message}` for a variant this binding predates.

  This binding names two of its own, which stay apart from the core's
  `:invalid_field`:

    * `{:invalid_grid_field, field, value}` - an axis entry or a node value that
      is not a number, carrying the value that is not.
    * `{:value_out_of_range, field, value}` - an axis entry or a node value that
      is an integer larger in magnitude than the largest finite double, which
      has no double to be read onto, carrying that integer.
  """
  @spec new([number()], [number()], [number()], [number() | nil]) :: {:ok, t()} | {:error, term()}
  def new(epochs_ns, latitudes_deg, longitudes_deg, values)
      when is_list(epochs_ns) and is_list(latitudes_deg) and is_list(longitudes_deg) and is_list(values) do
    with {:ok, epochs} <- axis(epochs_ns, :epochs_ns),
         {:ok, latitudes} <- axis(latitudes_deg, :latitudes_deg),
         {:ok, longitudes} <- axis(longitudes_deg, :longitudes_deg),
         {:ok, cells} <- cells(values) do
      case NIF.tec_grid_new(epochs, latitudes, longitudes, cells) do
        {:ok, handle} -> {:ok, %__MODULE__{handle: handle}}
        {:error, reason} -> Refusal.error(reason)
      end
    end
  rescue
    # This call takes no resource, so it has no wrong-handle failure to name;
    # only a decoder that names its own field can raise out of it.
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :tec_grid_new)
  end

  @doc """
  Vertical TEC interpolated at a pierce point, in TECU.

  `unix_nanos` is an exact integer Unix-nanosecond epoch. `lon_deg` comes before
  `lat_deg`, matching the core signature; both are degrees.

  `opts` is a keyword list taking one key, `:missing_nodes`, either `:strict`
  (the default, which refuses a query weighting a node that holds no value) or
  `:renormalize` (which interpolates from the weighted nodes holding values and
  names the rest in the result's `degraded` field).

  Returns `{:ok, %Evaluation{}}`, or `{:error, reason}`:

    * `{:nodes_not_available, %Sidereon.GNSS.Ionosphere.NodeGap{}}` - a weighted
      node holds no value and the policy is `:strict`.
    * `{:out_of_bounds, axis, value}` - the query is past an axis endpoint;
      `axis` is the core's own name for it.
    * `{:invalid_field, field, reason}` - the core refused an input, with its own
      field and reason text.
    * `{:unhandled, message}` - a core variant this binding predates, with the
      core's own text.
    * `{:invalid_policy_value, :missing_nodes, value}` - a choice the key does
      not name.
    * `{:unknown_option_key, key}` - a key other than `:missing_nodes`. The key
      is returned as given and no atom is created for it.
    * `{:duplicate_option_key, key}` - a key stated twice, whether the two
      choices agree or not; collapsing it would drop the earlier statement.
    * `{:invalid_options, opts}` - `opts` is not a keyword list.
    * `{:value_out_of_range, field, value}` - `:unix_nanos` past the 64-bit range
      the boundary carries it in, or `:lon_deg` or `:lat_deg` given as an
      integer larger in magnitude than the largest finite double, which has no
      double to be read onto.
    * `{:bad_tec_grid, value}` - the first argument is neither a grid nor a
      handle.
    * `{:invalid_resource, :tec_grid}` - the handle is not a reference to a
      standalone TEC grid, such as a reference to another resource kind. The
      boundary refuses a reference it cannot read as `:badarg`, which names no
      field and which Elixir raises as `ArgumentError`; every other argument of
      this call is checked here first, so the resource the call expected is
      named in its place.
  """
  @spec vtec_at_pierce_point(t() | reference(), integer(), number(), number(), keyword()) ::
          {:ok, Evaluation.t()} | {:error, term()}
  def vtec_at_pierce_point(grid, unix_nanos, lon_deg, lat_deg, opts \\ [])
      when is_integer(unix_nanos) and is_number(lon_deg) and is_number(lat_deg) do
    with {:ok, missing_nodes} <- missing_node_policy(opts),
         {:ok, epoch} <- epoch_nanos(unix_nanos),
         {:ok, lon_deg} <- coordinate(lon_deg, :lon_deg),
         {:ok, lat_deg} <- coordinate(lat_deg, :lat_deg),
         {:ok, handle} <- handle(grid) do
      case Boundary.result(:tec_grid, fn ->
             NIF.tec_grid_vtec_at_pierce_point(handle, epoch, lon_deg, lat_deg, missing_nodes)
           end) do
        {:ok, evaluation} -> {:ok, Evaluation.from_nif_map(evaluation)}
        {:error, reason} -> Refusal.error(reason)
      end
    end
  end

  @doc """
  Vertical and slant TEC along the line of sight from `receiver_xyz` to
  `satellite_xyz`, in TECU.

  `unix_nanos` is an exact integer Unix-nanosecond epoch, as for
  `vtec_at_pierce_point/5`; an epoch that is not an integer raises
  `FunctionClauseError`, as it does there. `satellite_xyz` and `receiver_xyz` are ECEF positions
  in meters, `{x, y, z}`. `converter` is a function of one argument that takes an
  ECEF position `{x, y, z}` in meters and returns `{lon_deg, lat_deg, alt}`.
  "XYZ evaluation" in the module documentation describes when the converter is
  called and the form every double takes.

  `opts` is a keyword list. A key left out takes the core's default:

    * `:missing_nodes` - `:strict` (the default) or `:renormalize`, as for
      `vtec_at_pierce_point/5`.
    * `:min_elevation_rad` - the floor the elevation is raised to before the
      slant mapping, in radians; 5 degrees by default.
    * `:earth_radius_m` and `:shell_height_m` - the thin shell, whose radius is
      their sum, in meters; 6,371,000 and 450,000 by default.
    * `:nan_pierce_point_height_m` - the altitude that stands in for the
      receiver answer's own after a NaN answer, in meters; 450,000 by default,
      and left as it is when `:shell_height_m` is given. The core requires it to
      be finite, and interpolates the grid in longitude and latitude only.

  Returns `{:ok, %Evaluation{value: {vtec_tecu, stec_tecu}}}`, with `degraded`
  as for `vtec_at_pierce_point/5`, or `{:error, reason}`. The core's reasons are
  those of `vtec_at_pierce_point/5` - `{:invalid_field, field, reason}`,
  `{:out_of_bounds, axis, value}`, `{:nodes_not_available, node_gap}` and
  `{:unhandled, message}` - with the XYZ inputs among the fields it names, such
  as `{:invalid_field, "receiver radius_m", "not positive"}` for a receiver at
  the origin. This binding names its own before the core reads anything:

    * `{:invalid_converter, value}` - `converter` is not a function of one
      argument.
    * `{:invalid_position, field, value}` - `:satellite_xyz` or `:receiver_xyz`
      is not a three-element tuple of numbers and `t:double/0` values, carrying
      the argument as given.
    * `{:invalid_double, key, value}` - a double option is neither a number nor
      a `t:double/0`.
    * `{:value_out_of_range, field, value}` - an integer larger in magnitude
      than the largest finite double, which has no double to be read onto, as a
      position component (`field` names the position), a double option or an
      answer component (`:lon_deg`, `:lat_deg` or `:alt`); or `:unix_nanos` past
      the 64-bit range the boundary carries it in.
    * `{:invalid_conversion, answer}` - the converter returned something other
      than a three-element tuple of numbers and `t:double/0` values, carrying
      what it returned. This is named after the call, and the evaluation stops.
    * `{:invalid_policy_value, :missing_nodes, value}`,
      `{:unknown_option_key, key}`, `{:duplicate_option_key, key}` and
      `{:invalid_options, opts}`, as for `vtec_at_pierce_point/5`.
    * `{:bad_tec_grid, value}` and `{:invalid_resource, :tec_grid}`, as for
      `vtec_at_pierce_point/5`.
  """
  @spec tec_xyz(t() | reference(), integer(), xyz(), xyz(), converter(), keyword()) ::
          {:ok, Evaluation.t()} | {:error, term()}
  def tec_xyz(grid, unix_nanos, satellite_xyz, receiver_xyz, converter, opts \\ []) when is_integer(unix_nanos) do
    with {:ok, options} <- xyz_options(opts),
         {:ok, epoch} <- epoch_nanos(unix_nanos),
         {:ok, satellite} <- position(satellite_xyz, :satellite_xyz),
         {:ok, receiver} <- position(receiver_xyz, :receiver_xyz),
         {:ok, converter} <- converter(converter),
         {:ok, handle} <- handle(grid) do
      evaluate(
        fn -> NIF.tec_grid_tec_xyz_prepare(handle, epoch, satellite, receiver, options) end,
        &NIF.tec_grid_tec_xyz_resume/2,
        converter
      )
    end
  end

  @doc """
  The ionospheric group delay along the line of sight from `receiver_xyz` to
  `satellite_xyz` on the carrier `frequency_hz`, in positive meters.

  `frequency_hz` is in hertz, a number or a `t:double/0`. The core checks the
  carrier before the positions and the geometry: a carrier that is not finite
  and positive is refused ahead of them, and the converter is not called. Every
  other argument and option is as for `tec_xyz/6`. A finished evaluation
  converts its slant TEC to a delay on the carrier, which the core refuses
  unless finite; a carrier whose square underflows to zero is refused there,
  after the converter has been called.

  Returns `{:ok, %Evaluation{value: delay_m}}`, with `degraded` as for
  `vtec_at_pierce_point/5`, or `{:error, reason}` with the reasons `tec_xyz/6`
  names, and `{:invalid_double, :frequency_hz, value}` or
  `{:value_out_of_range, :frequency_hz, value}` for a carrier this binding cannot
  read as a double.
  """
  @spec iono_delay_xyz(t() | reference(), integer(), component(), xyz(), xyz(), converter(), keyword()) ::
          {:ok, Evaluation.t()} | {:error, term()}
  def iono_delay_xyz(grid, unix_nanos, frequency_hz, satellite_xyz, receiver_xyz, converter, opts \\ [])
      when is_integer(unix_nanos) do
    with {:ok, options} <- xyz_options(opts),
         {:ok, epoch} <- epoch_nanos(unix_nanos),
         {:ok, frequency} <- double(frequency_hz, :frequency_hz),
         {:ok, satellite} <- position(satellite_xyz, :satellite_xyz),
         {:ok, receiver} <- position(receiver_xyz, :receiver_xyz),
         {:ok, converter} <- converter(converter),
         {:ok, handle} <- handle(grid) do
      evaluate(
        fn -> NIF.tec_grid_iono_delay_xyz_prepare(handle, epoch, frequency, satellite, receiver, options) end,
        &NIF.tec_grid_iono_delay_xyz_resume/2,
        converter
      )
    end
  end

  @doc """
  NaN as a `t:double/0`: the quiet NaN without a payload.

  A converter answers with a NaN component to have the evaluation fall back to
  the receiver position; see "XYZ evaluation" in the module documentation. Every
  NaN pattern is read as NaN, whatever its sign or payload.
  """
  @spec nan() :: double()
  def nan, do: {:nonfinite, 0x7FF8_0000_0000_0000}

  @doc """
  Positive infinity as a `t:double/0`.
  """
  @spec infinity() :: double()
  def infinity, do: {:nonfinite, 0x7FF0_0000_0000_0000}

  @doc """
  Negative infinity as a `t:double/0`.
  """
  @spec neg_infinity() :: double()
  def neg_infinity, do: {:nonfinite, 0xFFF0_0000_0000_0000}

  @doc """
  The grid's epoch axis, as the floating-point Unix nanoseconds the core stores.

  Returns `{:error, {:bad_tec_grid, value}}` for an argument that is neither a
  grid nor a handle, and `{:error, {:invalid_resource, :tec_grid}}` for a
  reference the boundary cannot read as a standalone TEC grid. Both are the same
  for the other three accessors.
  """
  @spec epochs_ns(t() | reference()) :: {:ok, [float()]} | {:error, term()}
  def epochs_ns(grid), do: slice(grid, &NIF.tec_grid_epochs_ns/1)

  @doc """
  The grid's latitude axis in degrees.
  """
  @spec latitudes_deg(t() | reference()) :: {:ok, [float()]} | {:error, term()}
  def latitudes_deg(grid), do: slice(grid, &NIF.tec_grid_latitudes_deg/1)

  @doc """
  The grid's longitude axis in degrees.
  """
  @spec longitudes_deg(t() | reference()) :: {:ok, [float()]} | {:error, term()}
  def longitudes_deg(grid), do: slice(grid, &NIF.tec_grid_longitudes_deg/1)

  @doc """
  The grid's TECU values, flat in `[epoch][latitude][longitude]` order with
  longitude varying fastest. A node without a value is `nil`.
  """
  @spec values(t() | reference()) :: {:ok, [float() | nil]} | {:error, term()}
  def values(grid), do: slice(grid, &NIF.tec_grid_values/1)

  defp slice(grid, reader) do
    with {:ok, handle} <- handle(grid) do
      Boundary.call(:tec_grid, fn -> reader.(handle) end)
    end
  end

  defp handle(%__MODULE__{handle: handle}), do: {:ok, handle}
  defp handle(handle) when is_reference(handle), do: {:ok, handle}
  defp handle(other), do: {:error, {:bad_tec_grid, other}}

  # Prepares an XYZ evaluation and drives it to its end. The prepare call is the
  # one that reads the caller's grid handle, so it alone is wrapped, to name a
  # reference of another resource kind. The stages it returns are this binding's
  # own, so the resume calls are not wrapped, and neither is the converter.
  defp evaluate(prepare, resume, converter) do
    case Boundary.result(:tec_grid, prepare) do
      {:ok, step} -> drive(step, converter, resume)
      {:error, reason} -> Refusal.error(reason)
    end
  end

  defp drive({:complete, evaluation}, _converter, _resume), do: {:ok, Evaluation.from_nif_map(evaluation)}

  defp drive({:convert, stage, xyz}, converter, resume) do
    # A plain call outside any rescue: whatever the converter raises, throws or
    # exits with reaches the caller as itself, with its own stacktrace, and no
    # stage is resumed after it.
    answer = converter.(xyz)

    with {:ok, lonlatalt} <- conversion(answer) do
      case resume.(stage, lonlatalt) do
        {:ok, step} -> drive(step, converter, resume)
        {:error, reason} -> Refusal.error(reason)
      end
    end
  end

  defp converter(fun) when is_function(fun, 1), do: {:ok, fun}
  defp converter(other), do: {:error, {:invalid_converter, other}}

  defp position({x, y, z} = xyz, field) do
    invalid = {:invalid_position, field, xyz}

    with {:ok, x} <- component(x, field, invalid),
         {:ok, y} <- component(y, field, invalid),
         {:ok, z} <- component(z, field, invalid) do
      {:ok, {x, y, z}}
    end
  end

  defp position(value, field), do: {:error, {:invalid_position, field, value}}

  defp conversion({lon, lat, alt} = answer) do
    invalid = {:invalid_conversion, answer}

    with {:ok, lon} <- component(lon, :lon_deg, invalid),
         {:ok, lat} <- component(lat, :lat_deg, invalid),
         {:ok, alt} <- component(alt, :alt, invalid) do
      {:ok, {lon, lat, alt}}
    end
  end

  defp conversion(answer), do: {:error, {:invalid_conversion, answer}}

  defp double(value, field), do: component(value, field, {:invalid_double, field, value})

  # One double of the XYZ surface, read onto what the boundary carries. An
  # integer no double holds is named with its own field; any other value that is
  # not a double is refused as `invalid`, which names what holds it.
  defp component(value, field, invalid) do
    case transported(value) do
      {:ok, double} -> {:ok, double}
      {:out_of_range, value} -> {:error, {:value_out_of_range, field, value}}
      :invalid -> {:error, invalid}
    end
  end

  # A float crosses as itself and an integer as the double it is read onto. A
  # `{:nonfinite, bits}` crosses as given where `bits` is the 64-bit pattern of a
  # NaN or an infinity, and the boundary reads it back with `f64::from_bits`.
  # Nothing here interprets the value a pattern names.
  defp transported({:nonfinite, bits} = value) when is_integer(bits) and bits >= 0 and bits <= @u64_max do
    if Bitwise.band(bits, @exponent_bits) == @exponent_bits, do: {:ok, value}, else: :invalid
  end

  defp transported(value) do
    case Numeric.float(value) do
      {:ok, float} -> {:ok, float}
      {:out_of_range, value} -> {:out_of_range, value}
      :not_a_number -> :invalid
    end
  end

  # The XYZ options are read as the missing-node policy is. Every double option
  # crosses the boundary, `nil` where the caller left it out, and the boundary
  # starts from the core's defaults and sets only the ones given.
  defp xyz_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      with :ok <- reject_unknown_keys(keys, @xyz_option_keys),
           :ok <- reject_duplicate_keys(keys),
           {:ok, missing_nodes} <- choice(Keyword.get(opts, :missing_nodes, :strict)) do
        double_options(opts, %{missing_nodes: missing_nodes})
      end
    else
      {:error, {:invalid_options, opts}}
    end
  end

  defp xyz_options(opts), do: {:error, {:invalid_options, opts}}

  defp double_options(opts, options) do
    Enum.reduce_while(@xyz_double_options, {:ok, options}, fn key, {:ok, acc} ->
      case double_option(opts, key) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp double_option(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> double(value, key)
      :error -> {:ok, nil}
    end
  end

  # The one option this query takes is read the way the slant policy reads its
  # three: an unknown key, a key stated twice and an unknown choice are each
  # named, and nothing falls back to the default for a name the query does not
  # recognize. A key is unknown by what it is, not by what it holds, so a list
  # keyed by `nil` is an unknown key named `nil`.
  defp missing_node_policy(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      with :ok <- reject_unknown_keys(keys, @option_keys),
           :ok <- reject_duplicate_keys(keys) do
        choice(Keyword.get(opts, :missing_nodes, :strict))
      end
    else
      {:error, {:invalid_options, opts}}
    end
  end

  defp missing_node_policy(opts), do: {:error, {:invalid_options, opts}}

  defp reject_unknown_keys(keys, allowed) do
    case Enum.reject(keys, &(&1 in allowed)) do
      [] -> :ok
      [key | _rest] -> {:error, {:unknown_option_key, key}}
    end
  end

  defp reject_duplicate_keys(keys) do
    case keys -- Enum.uniq(keys) do
      [] -> :ok
      [key | _rest] -> {:error, {:duplicate_option_key, key}}
    end
  end

  defp choice(value) when value in @missing_node_choices, do: {:ok, value}
  defp choice(value), do: {:error, {:invalid_policy_value, :missing_nodes, value}}

  # The epoch crosses as an `i64`; a count past that range is named here rather
  # than reaching the boundary as an opaque decode error.
  defp epoch_nanos(value) when value >= @i64_min and value <= @i64_max, do: {:ok, value}
  defp epoch_nanos(value), do: {:error, {:value_out_of_range, :unix_nanos, value}}

  defp axis(values, field) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case Numeric.float(value) do
        {:ok, float} -> {:cont, {:ok, [float | acc]}}
        {:out_of_range, value} -> {:halt, {:error, {:value_out_of_range, field, value}}}
        :not_a_number -> {:halt, {:error, {:invalid_grid_field, field, value}}}
      end
    end)
    |> case do
      {:ok, converted} -> {:ok, Enum.reverse(converted)}
      {:error, _reason} = error -> error
    end
  end

  defp cells(values) do
    Enum.reduce_while(values, {:ok, []}, fn
      nil, {:ok, acc} ->
        {:cont, {:ok, [nil | acc]}}

      value, {:ok, acc} ->
        case Numeric.float(value) do
          {:ok, float} -> {:cont, {:ok, [float | acc]}}
          {:out_of_range, value} -> {:halt, {:error, {:value_out_of_range, :values, value}}}
          :not_a_number -> {:halt, {:error, {:invalid_grid_field, :values, value}}}
        end
    end)
    |> case do
      {:ok, converted} -> {:ok, Enum.reverse(converted)}
      {:error, _reason} = error -> error
    end
  end

  # The query's two degree arguments cross as doubles; an integer no double
  # holds is named before it is divided rather than raising out of the division.
  defp coordinate(value, field) do
    case Numeric.float(value) do
      {:ok, float} -> {:ok, float}
      {:out_of_range, value} -> {:error, {:value_out_of_range, field, value}}
      :not_a_number -> {:error, {:invalid_grid_field, field, value}}
    end
  end
end
