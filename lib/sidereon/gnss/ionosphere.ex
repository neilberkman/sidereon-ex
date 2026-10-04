defmodule Sidereon.GNSS.Ionosphere do
  @moduledoc """
  Single-frequency ionospheric group-delay corrections.

  Four models are exposed over the `sidereon-core` crate: the GPS broadcast
  Klobuchar model (eight alpha/beta coefficients, IS-GPS-200), the Galileo
  NeQuick-G model in both its compact single-layer and full three-dimensional
  forms, and an IONEX vertical-TEC-grid slant delay (single-layer model). Each
  returns the group delay in **positive meters**.

  The IONEX surface also reads and writes products: `parse_ionex/1` and
  `parse_ionex_with_warnings/1` read one, `ionex_to_string/1` writes one back,
  `from_samples/1` and `from_node_samples/5` build one from samples with no text
  in the loop, and `tec_grid_samples/1` and `tec_samples/1` read one back out.
  `ionex_header/1` reads the descriptive records and `skipped_records/1` reads
  what a forgiving parse passed over. `Sidereon.GNSS.Ionosphere.TecGrid` is the
  standalone regular-grid variant, queried at a pierce point or along the line
  of sight between ECEF receiver and satellite positions, as vertical and slant
  TEC or as a group delay.

  This is the ionosphere correction for a GNSS signal. It is **not**
  `Sidereon.Atmosphere`, which is NRLMSISE-00 neutral-atmosphere mass density for
  drag, a different quantity entirely.

  ## Sign convention

  The returned delay is a **group delay** and is **positive**: it increases the
  measured pseudorange (the signal arrives later than vacuum geometry would
  predict). The carrier-phase advance is the negation of this value. The
  ionosphere is dispersive, so the delay reported on a carrier other than the
  model's native L1 is the L1 delay scaled by `(f_L1 / f)^2`; pass the carrier
  via `frequency_hz`.

  ## Units at the boundary

  Public inputs are in degrees (`_deg`) and meters/hertz, per the Sidereon naming
  convention. Latitude is positive north, longitude positive east, azimuth
  clockwise from north.

  ## Handles

  Every function taking a product handle takes a reference from `parse_ionex/1`,
  `load_ionex/1`, `from_samples/1` or `from_node_samples/5`. A reference the
  boundary cannot read as an IONEX product - a
  `Sidereon.GNSS.Ionosphere.TecGrid` handle, or a reference to any other
  resource kind - is returned as `{:error, {:invalid_resource, :ionex}}` by every
  one of them, rather than raising `ArgumentError` out of a call whose contract
  is `{:ok, _} | {:error, _}`. The boundary refuses such a reference as
  `:badarg`, which names no field; every other argument of these calls is
  checked here first, each under its own name, so the resource the call expected
  is what is named in its place.
  """

  alias Sidereon.GNSS.Ionosphere.Boundary
  alias Sidereon.GNSS.Ionosphere.EpochAxis
  alias Sidereon.GNSS.Ionosphere.Header
  alias Sidereon.GNSS.Ionosphere.Numeric
  alias Sidereon.GNSS.Ionosphere.ParseResult
  alias Sidereon.GNSS.Ionosphere.Refusal
  alias Sidereon.GNSS.Ionosphere.SlantEvaluation
  alias Sidereon.GNSS.Ionosphere.SlantPolicy
  alias Sidereon.GNSS.Ionosphere.SlantRequest
  alias Sidereon.GNSS.Ionosphere.TecGridSamples
  alias Sidereon.GNSS.Ionosphere.TecSample
  alias Sidereon.GNSS.Ionosphere.Warning
  alias Sidereon.NIF
  alias Sidereon.NifCall

  @doc """
  GPS broadcast Klobuchar L1 ionospheric group delay, scaled to `frequency_hz`.

  `params` carries the eight broadcast coefficients as
  `%{alpha: {a0, a1, a2, a3}, beta: {b0, b1, b2, b3}}` (or lists). The receiver
  geodetic latitude/longitude and the satellite azimuth/elevation are in
  degrees; `epoch` is a `NaiveDateTime` or `{{y, m, d}, {h, min, s}}` tuple in
  GPS time. Returns `{:ok, delay_m}` (positive meters) or `{:error, reason}`.

  An argument the boundary cannot carry is named before the call:
  `{:invalid_double, field, value}` for a value that is not a number (a
  coefficient is named `:alpha` or `:beta`), `{:value_out_of_range, field, value}`
  for an integer no double holds, and the epoch refusals of
  `Sidereon.GNSS.Time.second_of_day/1`. A value the model refuses is
  `{:error, :invalid_input}`.
  """
  @spec klobuchar_delay(
          map(),
          number(),
          number(),
          number(),
          number(),
          NaiveDateTime.t() | tuple(),
          number()
        ) :: {:ok, float()} | {:error, term()}
  def klobuchar_delay(params, lat_deg, lon_deg, azimuth_deg, elevation_deg, epoch, frequency_hz) do
    # The model takes degrees and the GPS second-of-day directly. Passing the
    # degree inputs through unchanged and forming the second-of-day from the
    # epoch's integer clock fields (no split-Julian-date round trip) keeps the
    # result bit-for-bit identical to the reference recipe.
    with {:ok, alpha, beta} <- klobuchar_coeffs(params),
         {:ok, [lat, lon, azimuth, elevation, frequency]} <-
           doubles(
             lat_deg: lat_deg,
             lon_deg: lon_deg,
             azimuth_deg: azimuth_deg,
             elevation_deg: elevation_deg,
             frequency_hz: frequency_hz
           ),
         {:ok, t_gps_s} <- Sidereon.GNSS.Time.second_of_day(epoch) do
      delay_result(NIF.klobuchar_delay(lat, lon, azimuth, elevation, t_gps_s, frequency, alpha, beta))
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :klobuchar_delay)
  end

  @doc """
  Galileo NeQuick-G single-frequency ionospheric group delay, scaled to
  `frequency_hz`.

  `coeffs` carries the three Galileo broadcast effective-ionisation coefficients
  as `%{ai0: a0, ai1: a1, ai2: a2}`. The receiver geodetic latitude/longitude and
  the satellite azimuth/elevation are in degrees; `epoch` is a `NaiveDateTime` or
  `{{y, m, d}, {h, min, s}}` tuple in Galileo system time. The NeQuick-G arm maps
  the slant delay by elevation only, so `azimuth_deg` is accepted (to match the
  shared ionosphere-model boundary) but does not change the result. Returns
  `{:ok, delay_m}` (positive meters) or `{:error, reason}`, with the argument
  refusals `klobuchar_delay/7` names (a coefficient under its own name, `:ai0`,
  `:ai1` or `:ai2`) and the epoch refusals of
  `Sidereon.GNSS.Time.epoch_to_split_jd/1`.
  """
  @spec galileo_nequick_g_delay(
          map(),
          number(),
          number(),
          number(),
          number(),
          NaiveDateTime.t() | tuple(),
          number()
        ) :: {:ok, float()} | {:error, term()}
  def galileo_nequick_g_delay(coeffs, lat_deg, lon_deg, azimuth_deg, elevation_deg, epoch, frequency_hz) do
    # Pass the same split Julian date the SP3/IONEX path uses so the core kernel
    # derives the Galileo second-of-day and fractional day-of-year from one
    # instant (no separate second-of-day argument that could round differently).
    with {:ok, ai0, ai1, ai2} <- nequick_coeffs(coeffs),
         {:ok, [lat, lon, azimuth, elevation, frequency]} <-
           doubles(
             lat_deg: lat_deg,
             lon_deg: lon_deg,
             azimuth_deg: azimuth_deg,
             elevation_deg: elevation_deg,
             frequency_hz: frequency_hz
           ),
         {:ok, {jd_whole, jd_fraction}} <- Sidereon.GNSS.Time.epoch_to_split_jd(epoch) do
      delay_result(
        NIF.galileo_nequick_g_delay(lat, lon, elevation, azimuth, jd_whole, jd_fraction, frequency, ai0, ai1, ai2)
      )
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :galileo_nequick_g_delay)
  end

  @doc """
  Galileo NeQuick-G full three-dimensional slant total electron content (TECU).

  This is the reference-grade full 3D NeQuick-G integration, distinct from the
  compact single-layer `galileo_nequick_g_delay/7`. The `coeffs` map carries the
  broadcast effective-ionisation coefficients `%{ai0:, ai1:, ai2:}`. The `ray`
  map carries both endpoints of the receiver-to-satellite line of sight, in the
  reference algorithm's native units:

    * `:month` - month of the year, `1..12`
    * `:utc_hours` - UTC time of day in hours, `[0, 24]`
    * `:station_lon_deg`, `:station_lat_deg`, `:station_height_m`
    * `:satellite_lon_deg`, `:satellite_lat_deg`, `:satellite_height_m`

  Returns `{:ok, stec_tecu}` (slant TEC in TECU) or `{:error, reason}`. A
  coefficient or ray field the boundary cannot carry is named before the call:
  `{:invalid_double, field, value}` or `{:value_out_of_range, field, value}` for
  a double field, `{:invalid_integer, :month, value}` for a `month` that is not
  an integer and `{:value_out_of_range, :month, value}` for one outside `0..255`;
  a map missing a key is `:bad_nequick_params` or `:bad_nequick_ray`.
  """
  @spec nequick_g_stec(map(), map()) :: {:ok, float()} | {:error, term()}
  def nequick_g_stec(coeffs, ray) do
    with {:ok, ai0, ai1, ai2} <- nequick_coeffs(coeffs),
         {:ok, r} <- nequick_ray(ray) do
      case NIF.nequick_g_stec_tecu(
             ai0,
             ai1,
             ai2,
             r.month,
             r.utc_hours,
             r.station_lon_deg,
             r.station_lat_deg,
             r.station_height_m,
             r.satellite_lon_deg,
             r.satellite_lat_deg,
             r.satellite_height_m
           ) do
        {:error, reason} -> {:error, reason}
        stec when is_number(stec) -> {:ok, stec}
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :nequick_g_stec_tecu)
  end

  @doc """
  Galileo NeQuick-G full slant ionospheric group delay (positive meters).

  The full 3D slant TEC from `nequick_g_stec/2` mapped to a dispersive group
  delay on `frequency_hz`. `coeffs` and `ray` are as in `nequick_g_stec/2`, with
  the same refusals, and `frequency_hz` is named as a double field.

  Returns `{:ok, delay_m}` (positive meters) or `{:error, reason}`.
  """
  @spec nequick_g_delay(map(), map(), number()) :: {:ok, float()} | {:error, term()}
  def nequick_g_delay(coeffs, ray, frequency_hz) do
    with {:ok, ai0, ai1, ai2} <- nequick_coeffs(coeffs),
         {:ok, r} <- nequick_ray(ray),
         {:ok, frequency_hz} <- double(frequency_hz, :frequency_hz) do
      case NIF.nequick_g_delay_m(
             ai0,
             ai1,
             ai2,
             r.month,
             r.utc_hours,
             r.station_lon_deg,
             r.station_lat_deg,
             r.station_height_m,
             r.satellite_lon_deg,
             r.satellite_lat_deg,
             r.satellite_height_m,
             frequency_hz
           ) do
        {:error, reason} -> {:error, reason}
        delay when is_number(delay) -> {:ok, delay}
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :nequick_g_delay_m)
  end

  @doc """
  Parse an in-memory IONEX byte buffer into a product handle.

  Returns `{:ok, reference()}` or `{:error, reason}`. The buffer is parsed
  exactly once; the parsed grid is held as a resource handle.

  Findings the reader reports without refusing the file are not returned here.
  Use `parse_ionex_with_warnings/1` to keep them.
  """
  @spec parse_ionex(binary()) :: {:ok, reference()} | {:error, term()}
  def parse_ionex(bytes) when is_binary(bytes) do
    case NIF.ionex_parse(bytes) do
      handle when is_reference(handle) -> {:ok, handle}
      {:error, _reason} = error -> error
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :ionex_parse)
  end

  @doc """
  Parse an IONEX byte buffer, keeping what the reader reported about the file.

  Returns `{:ok, %ParseResult{}}` or `{:error, reason}`. The warnings are in
  reader order, and each carries every field its finding has alongside the
  core's formatted message. An empty list means the reader found nothing to
  report.

  `skipped_records` is the count of records the parse passed over, which is a
  separate thing from a warning: a skipped record raises no finding, so a parse
  can report no warnings and still have skipped something. See
  `skipped_records/1`.
  """
  @spec parse_ionex_with_warnings(binary()) :: {:ok, ParseResult.t()} | {:error, term()}
  def parse_ionex_with_warnings(bytes) when is_binary(bytes) do
    case NIF.ionex_parse_with_warnings(bytes) do
      {:ok, handle, warnings} ->
        {:ok,
         %ParseResult{
           handle: handle,
           warnings: Enum.map(warnings, &Warning.from_nif_map/1),
           skipped_records: NIF.ionex_skipped_records(handle)
         }}

      {:error, _reason} = error ->
        error
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :ionex_parse_with_warnings)
  end

  @doc """
  The number of records a forgiving parse passed over.

  The reader skips a block it does not support, such as `START OF AUX DATA`, and
  a header record whose field it cannot read, counting each rather than dropping
  it silently. A skip is not a warning and is not reported as one, so this is
  the only way to ask whether anything in the file was left out. A product built
  from samples has skipped nothing.
  """
  @spec skipped_records(reference()) :: {:ok, non_neg_integer()} | {:error, term()}
  def skipped_records(handle) when is_reference(handle) do
    Boundary.call(:ionex, fn -> NIF.ionex_skipped_records(handle) end)
  end

  @doc """
  Load and parse an IONEX file into a product handle.

  Returns `{:ok, reference()}` or `{:error, reason}`.
  """
  @spec load_ionex(String.t()) :: {:ok, reference()} | {:error, term()}
  def load_ionex(path) when is_binary(path) do
    with {:ok, bytes} <- File.read(path) do
      parse_ionex(bytes)
    end
  end

  @doc """
  The descriptive header records a parsed or sample-built product carries.

  Returns `{:ok, %Header{}}`. `mapping_function` is `nil` where the product
  declares no `MAPPING FUNCTION` record, one of `:none`, `:cosz` or `:qfac` for
  the codes IONEX 1 names, and the code's own text for any other.
  """
  @spec ionex_header(reference()) :: {:ok, Header.t()} | {:error, term()}
  def ionex_header(handle) when is_reference(handle) do
    with {:ok, fields} <- Boundary.call(:ionex, fn -> NIF.ionex_header(handle) end) do
      {:ok, Header.from_nif_map(fields)}
    end
  end

  @doc """
  Serialize a parsed IONEX product back to standard IONEX text.

  `handle` is a product handle from `parse_ionex/1`, `load_ionex/1`,
  `from_samples/1` or `from_node_samples/5`. This is the inverse of
  `parse_ionex/1`: re-parsing the output reproduces the same TEC grids. The
  serialization is deterministic and performs no I/O.

  The writer is fallible: it refuses a value it cannot write exactly rather than
  rounding it, and that refusal is returned as `{:error, reason}`.

  ## Examples

      {:ok, handle} = Sidereon.GNSS.Ionosphere.parse_ionex(ionex_bytes)
      {:ok, text} = Sidereon.GNSS.Ionosphere.ionex_to_string(handle)
      {:ok, _reparsed} = Sidereon.GNSS.Ionosphere.parse_ionex(text)
  """
  @spec ionex_to_string(reference()) :: {:ok, String.t()} | {:error, term()}
  def ionex_to_string(handle) when is_reference(handle) do
    Boundary.result(:ionex, fn -> NIF.ionex_to_string(handle) end)
  end

  @doc """
  Build an IONEX product directly from whole-grid TEC samples.

  Axes are degrees, shell and base radii are kilometers, TEC and RMS grids are
  TECU and height grids are kilometers. A node without a value is `nil`; absent
  RMS or height maps are `nil`, which is not the same as maps present with every
  node `nil`.

  The returned handle is accepted anywhere a parsed IONEX handle is, including
  `ionex_slant_delay/7` and `ionex_to_string/1`.
  """
  @spec from_samples(TecGridSamples.t()) :: {:ok, reference()} | {:error, term()}
  def from_samples(%TecGridSamples{} = samples) do
    with {:ok, term} <- TecGridSamples.to_nif_map(samples) do
      case NIF.ionex_from_samples(term) do
        {:ok, handle} -> {:ok, handle}
        {:error, _reason} = error -> error
      end
    end
  rescue
    # This call takes no handle, so it has no wrong-resource failure to name;
    # only a decoder that names its own field can raise out of it.
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :ionex_from_samples)
  end

  @doc """
  Build an IONEX product from one sample per TEC grid node.

  Every node of the grid the samples span must appear exactly once. The product
  has RMS maps when any sample carries an RMS value and height maps when any
  carries a height offset; a node without one is `nil` there.

  `shell_height_km` and `base_radius_km` are kilometers and `exponent` is the
  IONEX `EXPONENT` field. `header` carries the descriptive records the product
  keeps: node samples say nothing about the mapping function or the program that
  produced them, so they are stated here.

  Flat node samples carry no map-presence field, so this entry cannot state RMS
  or height maps that are declared yet hold no value at any node: samples whose
  `rms_tecu` is `nil` everywhere give a product with no RMS map.
  `from_samples/1` states each stack explicitly and is the entry for that.

  `{:error, {:value_out_of_range, field, value}}` names a radius that is an
  integer larger in magnitude than the largest finite double, which has no
  double to be read onto, or an `exponent` outside the signed 32-bit range the
  core holds it in, alongside the refusals
  `Sidereon.GNSS.Ionosphere.TecSample`,
  `Sidereon.GNSS.Ionosphere.Header` and the core name.
  """
  @spec from_node_samples([TecSample.t()], number(), number(), integer(), Header.t()) ::
          {:ok, reference()} | {:error, term()}
  def from_node_samples(samples, shell_height_km, base_radius_km, exponent, header \\ %Header{})
      when is_list(samples) and is_number(shell_height_km) and is_number(base_radius_km) and is_integer(exponent) do
    with {:ok, terms} <- tec_sample_terms(samples),
         {:ok, header_term} <- Header.to_nif_map(header),
         {:ok, shell_height_km} <- float_argument(shell_height_km, :shell_height_km),
         {:ok, base_radius_km} <- float_argument(base_radius_km, :base_radius_km),
         :ok <- i32_argument(exponent, :exponent) do
      case NIF.ionex_from_node_samples(
             terms,
             shell_height_km,
             base_radius_km,
             exponent,
             header_term
           ) do
        {:ok, handle} -> {:ok, handle}
        {:error, _reason} = error -> error
      end
    end
  rescue
    # This call takes no handle either, so it has no wrong-resource failure to
    # name; `exponent` is checked against the core's 32-bit field above, so only
    # a decoder that names its own field can raise out of it.
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :ionex_from_node_samples)
  end

  @doc """
  Extract a product handle as whole-grid TEC samples.

  This is the inverse of `from_samples/1`: rebuilding from the returned samples
  reproduces every stored float and epoch. Axes are degrees, shell and base
  radii are kilometers, TEC and RMS grids are TECU and height grids are
  kilometers.
  """
  @spec tec_grid_samples(reference()) :: {:ok, TecGridSamples.t()} | {:error, term()}
  def tec_grid_samples(handle) when is_reference(handle) do
    with {:ok, fields} <- Boundary.call(:ionex, fn -> NIF.ionex_tec_grid_samples(handle) end) do
      {:ok, TecGridSamples.from_nif_map(fields)}
    end
  end

  @doc """
  Extract a product handle as one TEC sample per grid node.

  Samples come back in `[map][latitude][longitude]` order. Each carries its own
  epoch, latitude and longitude in degrees, vertical TEC and RMS in TECU, and a
  height offset in kilometers, with `nil` for any value the node does not have.
  """
  @spec tec_samples(reference()) :: {:ok, [TecSample.t()]} | {:error, term()}
  def tec_samples(handle) when is_reference(handle) do
    with {:ok, terms} <- Boundary.call(:ionex, fn -> NIF.ionex_tec_samples(handle) end) do
      {:ok, Enum.map(terms, &TecSample.from_nif_map/1)}
    end
  end

  @doc """
  IONEX vertical-TEC-grid slant ionospheric group delay, scaled to `frequency_hz`.

  `handle` is a product handle from `parse_ionex/1`, `load_ionex/1`,
  `from_samples/1` or `from_node_samples/5`. The receiver geodetic
  latitude/longitude and the satellite azimuth/elevation are in degrees; `epoch`
  is a UTC `NaiveDateTime` or `{{y, m, d}, {h, min, s}}` tuple on a whole second,
  UTC being the scale of IONEX map epochs (the pierce point rides on the IONEX
  shell, so the receiver height is not used).

  This is the strict convenience: it refuses a query outside the product's
  coverage and one whose interpolation weights a node the product gives as
  non-available, and it maps vertical TEC to the line of sight with the
  single-layer `1/cos(z')`. Use `ionex_slant_evaluation/8` for other policies or
  for the status of the value.

  Returns `{:ok, delay_m}` (positive meters) or `{:error, reason}`, where
  `reason` is one of the refusals `ionex_slant_evaluation/8` documents.
  """
  @spec ionex_slant_delay(
          reference(),
          number(),
          number(),
          number(),
          number(),
          NaiveDateTime.t() | tuple(),
          number()
        ) :: {:ok, float()} | {:error, term()}
  def ionex_slant_delay(handle, lat_deg, lon_deg, azimuth_deg, elevation_deg, epoch, frequency_hz)
      when is_reference(handle) do
    with {:ok, lat_deg} <- SlantRequest.float_field(lat_deg, :lat_deg),
         {:ok, lon_deg} <- SlantRequest.float_field(lon_deg, :lon_deg),
         {:ok, azimuth_deg} <- SlantRequest.float_field(azimuth_deg, :azimuth_deg),
         {:ok, elevation_deg} <- SlantRequest.float_field(elevation_deg, :elevation_deg),
         {:ok, frequency_hz} <- SlantRequest.float_field(frequency_hz, :frequency_hz),
         {:ok, epoch_j2000_s} <- EpochAxis.j2000_seconds(epoch) do
      case Boundary.result(:ionex, fn ->
             NIF.ionex_slant(
               handle,
               lat_deg,
               lon_deg,
               elevation_deg,
               azimuth_deg,
               epoch_j2000_s,
               frequency_hz
             )
           end) do
        {:ok, delay_m} -> {:ok, delay_m}
        {:error, reason} -> Refusal.error(reason)
      end
    end
  end

  @doc """
  IONEX slant delay under explicit coverage, missing-node and mapping policies.

  Arguments are as `ionex_slant_delay/7`, plus `policy`: a
  `Sidereon.GNSS.Ionosphere.SlantPolicy`, or a keyword list or map of its
  `:coverage`, `:missing_nodes` and `:mapping` choices. An unknown key or choice
  is an error; nothing falls back to a default for a name it does not recognize.

  Returns `{:ok, %SlantEvaluation{}}` carrying the delay and its independent
  `held`, `degraded` and `assumed_mapping` status fields, which can all be set on
  one value, or `{:error, reason}`.

  ## Refusals

  Where the product gives no value:

    * `{:out_of_coverage, coverage_error}` - the query is outside the product's
      epochs, latitudes or longitudes under `:strict` coverage.
      `coverage_error` is `:epoch_before_first_map`, `:epoch_after_last_map`,
      `:latitude_out_of_range` or `:longitude_out_of_range`.
    * `{:nodes_not_available, %Sidereon.GNSS.Ionosphere.NodeGap{}}` - the
      interpolation weights a node the product gives as non-available, under
      `:strict` missing nodes. The gap names every such node on each bracketing
      map.
    * `{:height_not_available, %Sidereon.GNSS.Ionosphere.HeightNode{}}` - the
      product's height maps give no value at the named node, so the maps state
      no single-layer height to ride on.
    * `{:varying_heights, %Sidereon.GNSS.Ionosphere.HeightNode{}}` - the height
      maps give two different heights, the second at the named node.
    * `{:mapping_function, declaration}` - `:declared` mapping against a product
      whose `MAPPING FUNCTION` defines no factor. `declaration` is `:none`,
      `:cosz`, `:qfac`, the declared code's own text, or `:absent` where the
      product carries no such record.

  Where an input is refused before or by the core:

    * `{:invalid_field, field, reason}` - the receiver position is outside the
      geodetic frame's range, with the core's own field and reason text. The
      frame takes latitude in `[-90, 90]` and longitude in `[-180, 180]`
      degrees, and a value outside either is reported as `"lat_rad"` or
      `"lon_rad"` because the frame names its radian fields.
    * `{:invalid_input, message}` - the core refused elevation (which it takes
      in `[0, 90]` degrees), a non-positive or non-finite frequency, or another
      input, with the core's own message. The core carries no field/reason pair
      for these, so none is invented here.
    * `{:unhandled, message}` - a core refusal variant this binding predates,
      with the core's own text. No other tag stands in for it.
    * `:non_integer_second_epoch` or `{:value_out_of_range, field, value}` - the
      epoch is not on a whole second, or a calendar field, a J2000 second or one
      of the numeric arguments is past the range the boundary carries it in. A
      numeric argument is past it when it is an integer larger in magnitude than
      the largest finite double, which has no `f64` to be read onto.
    * `{:invalid_epoch_field, field, value}` - a date or clock field of a tuple
      epoch that is not an integer. The shared calendar helper takes those five
      fields as 32-bit integers, and `hour` arrived at by division is a float,
      since Elixir's `/` always gives one.
    * `{:invalid_request_field, field, value}` - an argument that is not a
      number, named with the value that was given.
    * `{:invalid_resource, :ionex}` - the handle is not a reference to an IONEX
      product, as described under "Handles" in this module's documentation.
    * the policy refusals of `Sidereon.GNSS.Ionosphere.SlantPolicy`.
  """
  @spec ionex_slant_evaluation(
          reference(),
          number(),
          number(),
          number(),
          number(),
          NaiveDateTime.t() | tuple(),
          number(),
          SlantPolicy.t() | keyword() | map()
        ) :: {:ok, SlantEvaluation.t()} | {:error, term()}
  def ionex_slant_evaluation(
        handle,
        lat_deg,
        lon_deg,
        azimuth_deg,
        elevation_deg,
        epoch,
        frequency_hz,
        policy \\ %SlantPolicy{}
      )
      when is_reference(handle) do
    with {:ok, policy_term} <- SlantPolicy.to_nif_map(policy),
         {:ok, lat_deg} <- SlantRequest.float_field(lat_deg, :lat_deg),
         {:ok, lon_deg} <- SlantRequest.float_field(lon_deg, :lon_deg),
         {:ok, azimuth_deg} <- SlantRequest.float_field(azimuth_deg, :azimuth_deg),
         {:ok, elevation_deg} <- SlantRequest.float_field(elevation_deg, :elevation_deg),
         {:ok, frequency_hz} <- SlantRequest.float_field(frequency_hz, :frequency_hz),
         {:ok, epoch_j2000_s} <- EpochAxis.j2000_seconds(epoch) do
      case Boundary.result(:ionex, fn ->
             NIF.ionex_slant_with_policy(
               handle,
               lat_deg,
               lon_deg,
               elevation_deg,
               azimuth_deg,
               epoch_j2000_s,
               frequency_hz,
               policy_term
             )
           end) do
        {:ok, evaluation} -> {:ok, SlantEvaluation.from_nif_map(evaluation)}
        {:error, reason} -> Refusal.error(reason)
      end
    end
  end

  @doc """
  Batch IONEX slant delays, one result per request in request order.

  `requests` is a list of `Sidereon.GNSS.Ionosphere.SlantRequest`. `policy` is as
  in `ionex_slant_evaluation/8`.

  Returns `{:ok, results}` where `results` has exactly one entry per request, in
  request order, each `{:ok, %SlantEvaluation{}}` or `{:error, reason}` with that
  row's own reason. A row that fails does not remove itself from the list, take
  any other row with it, or come back as a zero delay.

  A row fails on its own for a request that cannot be put into the form the
  boundary takes as much as for one the product refuses: a sub-second epoch, a
  calendar field that is not an integer, a field that is not a number, a value
  past the range the boundary carries it in and a row that is not a
  `SlantRequest` are each that row's failure, with the reasons
  `Sidereon.GNSS.Ionosphere.SlantRequest` documents. A product refusal is one of
  those `ionex_slant_evaluation/8` documents.

  The call itself fails only on something that is not a property of one row: a
  policy the binding cannot read, a request list of the wrong shape, a handle
  that is not an IONEX product (`{:invalid_resource, :ionex}`), or a failure of
  the boundary itself, which is returned as it was reported rather than turned
  into row values. Nothing that belongs to one row is allowed to become the
  whole call's failure and take the other rows' results with it.
  """
  @spec ionex_slant_batch(reference(), [SlantRequest.t()], SlantPolicy.t() | keyword() | map()) ::
          {:ok, [{:ok, SlantEvaluation.t()} | {:error, term()}]} | {:error, term()}
  def ionex_slant_batch(handle, requests, policy \\ %SlantPolicy{}) when is_reference(handle) and is_list(requests) do
    with {:ok, policy_term} <- SlantPolicy.to_nif_map(policy) do
      # A request that does not convert is that row's failure, so the rows that
      # do convert are still evaluated and every row keeps its place. Only the
      # converted rows are sent, and the results are walked back onto the
      # original order.
      converted = Enum.map(requests, &SlantRequest.to_nif_map/1)
      request_terms = for {:ok, term} <- converted, do: term

      # Only the call is wrapped. The conversion above refuses each row's own
      # value by name and cannot raise, and the merge below is this binding's
      # own bookkeeping: rescuing either would turn one row's problem, or a
      # defect here, into the loss of every row's result.
      with {:ok, rows} <-
             Boundary.result(:ionex, fn ->
               NIF.ionex_slant_batch(handle, request_terms, policy_term)
             end) do
        {:ok, merge_batch_rows(converted, rows)}
      end
    end
  end

  # --- helpers -------------------------------------------------------------

  defp klobuchar_coeffs(%{alpha: alpha, beta: beta}) do
    with {:ok, a} <- four_tuple(alpha, :alpha),
         {:ok, b} <- four_tuple(beta, :beta) do
      {:ok, a, b}
    end
  end

  defp klobuchar_coeffs(_other), do: {:error, :bad_klobuchar_params}

  defp nequick_coeffs(%{ai0: ai0, ai1: ai1, ai2: ai2}) do
    with {:ok, [ai0, ai1, ai2]} <- doubles(ai0: ai0, ai1: ai1, ai2: ai2) do
      {:ok, ai0, ai1, ai2}
    end
  end

  defp nequick_coeffs(_other), do: {:error, :bad_nequick_params}

  @nequick_ray_doubles [
    :utc_hours,
    :station_lon_deg,
    :station_lat_deg,
    :station_height_m,
    :satellite_lon_deg,
    :satellite_lat_deg,
    :satellite_height_m
  ]

  defp nequick_ray(%{month: month} = ray) do
    if Enum.all?(@nequick_ray_doubles, &Map.has_key?(ray, &1)) do
      with :ok <- nequick_month(month),
           {:ok, values} <- doubles(Enum.map(@nequick_ray_doubles, &{&1, Map.fetch!(ray, &1)})) do
        {:ok, @nequick_ray_doubles |> Enum.zip(values) |> Map.new() |> Map.put(:month, month)}
      end
    else
      {:error, :bad_nequick_ray}
    end
  end

  defp nequick_ray(_other), do: {:error, :bad_nequick_ray}

  # The boundary reads `month` as an unsigned byte; the core refuses a month
  # outside 1..12 itself.
  defp nequick_month(month) when is_integer(month) and month >= 0 and month <= 255, do: :ok
  defp nequick_month(month) when is_integer(month), do: {:error, {:value_out_of_range, :month, month}}
  defp nequick_month(month), do: {:error, {:invalid_integer, :month, month}}

  defp four_tuple({a, b, c, d}, field), do: four_tuple([a, b, c, d], field)

  defp four_tuple([_a, _b, _c, _d] = values, field) do
    with {:ok, [a, b, c, d]} <- doubles(Enum.map(values, &{field, &1})) do
      {:ok, {a, b, c, d}}
    end
  end

  defp four_tuple(_other, _field), do: {:error, :bad_coefficients}

  # A scalar the boundary takes as a double: a value that is not a number and an
  # integer no double holds are each named with the value, rather than raising
  # out of `value / 1.0`.
  defp double(value, field) do
    case Numeric.float(value) do
      {:ok, float} -> {:ok, float}
      {:out_of_range, value} -> {:error, {:value_out_of_range, field, value}}
      :not_a_number -> {:error, {:invalid_double, field, value}}
    end
  end

  # `double/2` over `{field, value}` pairs, in order, stopping at the first
  # refusal.
  defp doubles(pairs) do
    pairs
    |> Enum.reduce_while({:ok, []}, fn {field, value}, {:ok, acc} ->
      case double(value, field) do
        {:ok, float} -> {:cont, {:ok, [float | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  # The compact models return the delay, or `{:error, reason}` for a value the
  # model refuses.
  defp delay_result({:error, _reason} = error), do: error
  defp delay_result(delay) when is_float(delay), do: {:ok, delay}

  defp tec_sample_terms(samples), do: collect(samples, &TecSample.to_nif_map/1)

  # A whole-product integer argument the core holds as an `i32`: an integer
  # outside that range is reported under its own field name before the call,
  # the way the radii are.
  defp i32_argument(value, field) do
    if Numeric.i32?(value), do: :ok, else: {:error, {:value_out_of_range, field, value}}
  end

  # A whole-product argument, not a slant request field, so it is not named as
  # one: an integer no double holds is reported under its own field name.
  defp float_argument(value, field) do
    case Numeric.float(value) do
      {:ok, float} -> {:ok, float}
      {:out_of_range, value} -> {:error, {:value_out_of_range, field, value}}
    end
  end

  # One row out for one row in, in the order the caller gave them: a request
  # that did not convert keeps its own reason, and a request that did takes the
  # next result the boundary returned.
  defp merge_batch_rows(converted, rows) do
    {merged, _unused} =
      Enum.map_reduce(converted, rows, fn
        {:error, _reason} = error, remaining ->
          {error, remaining}

        {:ok, _term}, [row | remaining] ->
          {batch_row(row), remaining}

        # The boundary returns one result per request it was given. A short
        # result list is reported as the failure it is rather than filled in.
        {:ok, _term}, [] ->
          {{:error, {:unhandled, "IONEX batch returned fewer results than requests"}}, []}
      end)

    merged
  end

  defp batch_row({:ok, evaluation}), do: {:ok, SlantEvaluation.from_nif_map(evaluation)}
  defp batch_row({:error, reason}), do: Refusal.error(reason)

  # Node samples build one product, so a sample that does not convert is the
  # whole call's failure: there is no partial product to return, and no sample
  # is skipped to keep the rest going. This is not the batch rule, where each
  # row has its own result.
  defp collect(values, convert) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case convert.(value) do
        {:ok, term} -> {:cont, {:ok, [term | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, terms} -> {:ok, Enum.reverse(terms)}
      {:error, _reason} = error -> error
    end
  end
end
