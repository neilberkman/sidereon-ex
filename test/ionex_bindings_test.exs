defmodule Sidereon.GNSS.IonexBindingsTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Ionosphere
  alias Sidereon.GNSS.Ionosphere.Epoch
  alias Sidereon.GNSS.Ionosphere.Header
  alias Sidereon.GNSS.Ionosphere.HeightNode
  alias Sidereon.GNSS.Ionosphere.MissingNodes
  alias Sidereon.GNSS.Ionosphere.NodeGap
  alias Sidereon.GNSS.Ionosphere.ParseResult
  alias Sidereon.GNSS.Ionosphere.SlantEvaluation
  alias Sidereon.GNSS.Ionosphere.SlantPolicy
  alias Sidereon.GNSS.Ionosphere.SlantRequest
  alias Sidereon.GNSS.Ionosphere.SlantStatus
  alias Sidereon.GNSS.Ionosphere.TecGrid
  alias Sidereon.GNSS.Ionosphere.TecGridSamples
  alias Sidereon.GNSS.Ionosphere.TecSample
  alias Sidereon.GNSS.Ionosphere.Warning
  alias Sidereon.NIF

  @ionex_path Path.join(__DIR__, "fixtures/synthetic_2map_7x7.20i")
  @ionex File.read!(@ionex_path)
  @l1_hz 1_575_420_000.0

  # Elixir carries this integer exactly and the largest finite double is about
  # 1.8e308, so it has no double to be read onto: dividing it raises
  # `ArithmeticError`, which is neither a refusal nor an `ErlangError`.
  @oversized Integer.pow(10, 400)

  # A grid whose two latitude nodes and two longitude nodes span the whole
  # sphere, so every pierce point lands in the single cell [0][0] and the cell a
  # missing node sits in is known without depending on the pierce-point
  # geometry.
  defp whole_sphere_samples(opts \\ []) do
    tec_maps =
      Keyword.get(opts, :tec_maps, [
        [[1.0, 2.0], [3.0, 4.0]],
        [[5.0, 6.0], [7.0, 8.0]]
      ])

    %TecGridSamples{
      map_epochs: [
        utc_epoch({{2020, 6, 24}, {0, 0, 0}}),
        utc_epoch({{2020, 6, 24}, {2, 0, 0}})
      ],
      lat_nodes_deg: [90.0, -90.0],
      lon_nodes_deg: [-180.0, 180.0],
      dlat_deg: -180.0,
      dlon_deg: 360.0,
      shell_height_km: 450.0,
      base_radius_km: 6371.0,
      exponent: -1,
      tec_maps: tec_maps,
      rms_maps: Keyword.get(opts, :rms_maps),
      height_maps: Keyword.get(opts, :height_maps),
      header: Keyword.get(opts, :header, Header.new(:none))
    }
  end

  defp utc_epoch(civil) do
    {:ok, epoch} = Epoch.from_civil("UTC", civil)
    epoch
  end

  # A `NaiveDateTime` whose year is past the 32-bit range the shared calendar
  # helper takes.
  defp naive_past_i32_year do
    %{~N[2020-01-01 00:00:00] | year: 3_000_000_000}
  end

  describe "whole-grid samples: zero, absence and absent maps" do
    test "a node holding zero stays zero and a node without a value stays nil" do
      samples =
        whole_sphere_samples(
          tec_maps: [
            [[0.0, 1.0], [2.0, 3.0]],
            [[nil, 5.0], [6.0, 7.0]]
          ]
        )

      assert {:ok, handle} = Ionosphere.from_samples(samples)
      assert {:ok, %TecGridSamples{} = read_back} = Ionosphere.tec_grid_samples(handle)

      assert read_back.tec_maps == [
               [[0.0, 1.0], [2.0, 3.0]],
               [[nil, 5.0], [6.0, 7.0]]
             ]
    end

    test "absent height maps and height maps present with every node absent are different" do
      absent = whole_sphere_samples(height_maps: nil)
      all_nil = whole_sphere_samples(height_maps: [[[nil, nil], [nil, nil]], [[nil, nil], [nil, nil]]])

      assert {:ok, absent_handle} = Ionosphere.from_samples(absent)
      assert {:ok, all_nil_handle} = Ionosphere.from_samples(all_nil)

      assert {:ok, %TecGridSamples{height_maps: nil}} = Ionosphere.tec_grid_samples(absent_handle)

      assert {:ok, %TecGridSamples{height_maps: kept}} = Ionosphere.tec_grid_samples(all_nil_handle)
      assert kept == [[[nil, nil], [nil, nil]], [[nil, nil], [nil, nil]]]
    end

    test "height offsets and every header record survive a samples round trip" do
      header = %Header{
        version: 1.1,
        satellite_system: "MIX",
        program: "SIDEREON",
        run_by: "TEST",
        date: "24-JUN-20 00:00",
        descriptions: ["synthetic whole-sphere grid"],
        comments: ["first comment", "second comment"],
        interval_s: 7200,
        mapping_function: "MSLM",
        elevation_cutoff_deg: 10.0,
        observables_used: "L1L2",
        station_count: 3,
        satellite_count: 31,
        maps_in_file: 2
      }

      heights = [[[0.0, 0.0], [0.0, 0.0]], [[0.0, 0.0], [0.0, nil]]]
      samples = whole_sphere_samples(header: header, height_maps: heights)

      assert {:ok, handle} = Ionosphere.from_samples(samples)
      assert {:ok, read_back} = Ionosphere.tec_grid_samples(handle)

      assert read_back.header == header
      assert read_back.height_maps == heights
      assert {:ok, ^header} = Ionosphere.ionex_header(handle)
    end

    test "an unstated mapping function is nil, and a declared blank code is a blank string" do
      assert {:ok, absent} = Ionosphere.from_samples(whole_sphere_samples(header: %Header{}))
      assert {:ok, %Header{mapping_function: nil}} = Ionosphere.ionex_header(absent)

      assert {:ok, blank} = Ionosphere.from_samples(whole_sphere_samples(header: Header.new("")))
      assert {:ok, %Header{mapping_function: ""}} = Ionosphere.ionex_header(blank)
    end

    test "node samples carry their own epoch, and rebuild the same product" do
      assert {:ok, handle} = Ionosphere.from_samples(whole_sphere_samples())
      assert {:ok, node_samples} = Ionosphere.tec_samples(handle)
      assert length(node_samples) == 8

      assert [%TecSample{epoch: %Epoch{time_scale: "UTC", jd_whole: whole}} | _] = node_samples
      assert is_float(whole)

      assert {:ok, rebuilt} =
               Ionosphere.from_node_samples(node_samples, 450.0, 6371.0, -1, Header.new(:none))

      assert {:ok, original} = Ionosphere.tec_grid_samples(handle)
      assert {:ok, from_nodes} = Ionosphere.tec_grid_samples(rebuilt)
      assert from_nodes.tec_maps == original.tec_maps
      assert from_nodes.map_epochs == original.map_epochs
    end
  end

  describe "fallible serialization" do
    test "a latitude axis that no IONEX field writes exactly is refused, not rounded" do
      samples = %{whole_sphere_samples() | lat_nodes_deg: [0.25, -0.25], dlat_deg: -0.5}

      assert {:ok, handle} = Ionosphere.from_samples(samples)
      assert {:error, {:invalid_input, message}} = Ionosphere.ionex_to_string(handle)
      assert message =~ "exactly"
    end

    test "a writable product round-trips through text" do
      assert {:ok, handle} = Ionosphere.from_samples(whole_sphere_samples())
      assert {:ok, text} = Ionosphere.ionex_to_string(handle)
      assert {:ok, reparsed} = Ionosphere.parse_ionex(text)
      assert {:ok, samples} = Ionosphere.tec_grid_samples(reparsed)
      assert samples.tec_maps == [[[1.0, 2.0], [3.0, 4.0]], [[5.0, 6.0], [7.0, 8.0]]]
    end
  end

  describe "parse warnings" do
    test "every reader finding comes back with its own fields and message" do
      assert {:ok, %ParseResult{handle: handle, warnings: warnings}} =
               Ionosphere.parse_ionex_with_warnings(@ionex)

      assert is_reference(handle)
      assert warnings != []

      assert Enum.all?(warnings, fn %Warning{tag: tag, message: message} ->
               is_atom(tag) and is_binary(message)
             end)

      assert %Warning{label: label} =
               Enum.find(warnings, &(&1.tag == :missing_record))

      assert is_binary(label)
    end

    test "a wrong map count is reported with the declared and actual counts and its line" do
      # Line 2 of the fixture is its `# OF MAPS IN FILE` record, which gives 2.
      mangled =
        @ionex
        |> String.split("\n")
        |> List.update_at(1, &String.replace(&1, "     2", "     5", global: false))
        |> Enum.join("\n")

      refute mangled == @ionex

      assert {:ok, %ParseResult{warnings: warnings}} = Ionosphere.parse_ionex_with_warnings(mangled)

      assert %Warning{
               tag: :map_count_mismatch,
               line: line,
               declared_count: 5,
               tec_maps: 2,
               all_maps: 2,
               message: message
             } = Enum.find(warnings, &(&1.tag == :map_count_mismatch))

      assert line == 2
      assert message =~ "# OF MAPS IN FILE"
    end
  end

  describe "slant policies" do
    setup do
      samples =
        whole_sphere_samples(
          tec_maps: [
            [[1.0, 2.0], [3.0, 4.0]],
            [[nil, 6.0], [7.0, 8.0]]
          ]
        )

      {:ok, handle} = Ionosphere.from_samples(samples)
      {:ok, handle: handle}
    end

    test "held, degraded and assumed_mapping are all set on one value", %{handle: handle} do
      # Past the last map (held), on the map whose cell has a node without a
      # value (degraded), against a product declaring NONE (assumed mapping).
      assert {:ok, policy} =
               SlantPolicy.new(coverage: :hold, missing_nodes: :renormalize, mapping: :single_layer)

      assert {:ok, %SlantEvaluation{delay_m: delay_m, status: status}} =
               Ionosphere.ionex_slant_evaluation(
                 handle,
                 45.0,
                 10.0,
                 60.0,
                 60.0,
                 {{2020, 6, 24}, {3, 0, 0}},
                 @l1_hz,
                 policy
               )

      assert delay_m > 0.0

      assert %SlantStatus{
               held: :epoch_after_last_map,
               degraded: %NodeGap{earlier: nil, later: %MissingNodes{} = later},
               assumed_mapping: :no_mapping,
               valid?: false
             } = status

      assert later.map_number == 2
      assert later.lat_index == 0
      assert later.lon_index == 0
      assert later.lon_index_next == 1
      assert later.missing == [true, false, false, false]
    end

    test "the strict default refuses the same query and names the coverage miss", %{handle: handle} do
      assert {:error, {:out_of_coverage, :epoch_after_last_map}} =
               Ionosphere.ionex_slant_evaluation(
                 handle,
                 45.0,
                 10.0,
                 60.0,
                 60.0,
                 {{2020, 6, 24}, {3, 0, 0}},
                 @l1_hz
               )
    end

    test "strict missing nodes names the nodes rather than interpolating around them", %{handle: handle} do
      assert {:error, {:nodes_not_available, %NodeGap{later: %MissingNodes{map_number: 2}}}} =
               Ionosphere.ionex_slant_evaluation(
                 handle,
                 45.0,
                 10.0,
                 60.0,
                 60.0,
                 {{2020, 6, 24}, {2, 0, 0}},
                 @l1_hz,
                 coverage: :hold,
                 missing_nodes: :strict
               )
    end

    test "an :other mapping code comes back with the code's own text" do
      samples = whole_sphere_samples(header: Header.new("MSLM"))
      assert {:ok, handle} = Ionosphere.from_samples(samples)

      assert {:ok, %SlantEvaluation{status: %SlantStatus{assumed_mapping: {:other, "MSLM"}, valid?: true}}} =
               Ionosphere.ionex_slant_evaluation(
                 handle,
                 45.0,
                 10.0,
                 60.0,
                 60.0,
                 {{2020, 6, 24}, {1, 0, 0}},
                 @l1_hz
               )
    end

    test "the :declared mapping policy refuses a product whose code defines no factor" do
      samples = whole_sphere_samples(header: Header.new(:none))
      assert {:ok, handle} = Ionosphere.from_samples(samples)

      assert {:error, {:mapping_function, :none}} =
               Ionosphere.ionex_slant_evaluation(
                 handle,
                 45.0,
                 10.0,
                 60.0,
                 60.0,
                 {{2020, 6, 24}, {1, 0, 0}},
                 @l1_hz,
                 mapping: :declared
               )
    end
  end

  describe "policy validation" do
    test "an unknown choice is an error naming the field and the value" do
      assert {:error, {:invalid_policy_value, :coverage, :nearest}} =
               SlantPolicy.new(coverage: :nearest)

      assert {:error, {:invalid_policy_value, :missing_nodes, "renormalize"}} =
               SlantPolicy.new(missing_nodes: "renormalize")

      assert {:error, {:invalid_policy_value, :mapping, :klobuchar}} =
               SlantPolicy.new(mapping: :klobuchar)
    end

    test "an unknown key is an error rather than being ignored" do
      assert {:error, {:unknown_policy_key, :missing_node}} =
               SlantPolicy.new(missing_node: :renormalize)
    end

    test "a key left out takes its documented default" do
      assert {:ok, %SlantPolicy{coverage: :hold, missing_nodes: :strict, mapping: :single_layer}} =
               SlantPolicy.new(coverage: :hold)
    end

    test "an invalid policy stops the call before it reaches the product" do
      assert {:ok, handle} = Ionosphere.from_samples(whole_sphere_samples())

      assert {:error, {:invalid_policy_value, :coverage, :nearest}} =
               Ionosphere.ionex_slant_evaluation(
                 handle,
                 45.0,
                 10.0,
                 60.0,
                 60.0,
                 {{2020, 6, 24}, {1, 0, 0}},
                 @l1_hz,
                 coverage: :nearest
               )
    end
  end

  describe "batch evaluation" do
    test "every request keeps its own result, in request order" do
      assert {:ok, handle} = Ionosphere.from_samples(whole_sphere_samples())

      requests = [
        SlantRequest.new(45.0, 10.0, 60.0, 60.0, {{2020, 6, 24}, {1, 0, 0}}, @l1_hz),
        SlantRequest.new(45.0, 10.0, 60.0, 60.0, {{2020, 6, 23}, {23, 0, 0}}, @l1_hz),
        SlantRequest.new(-20.0, 140.0, 300.0, 30.0, {{2020, 6, 24}, {1, 30, 0}}, @l1_hz)
      ]

      assert {:ok, rows} = Ionosphere.ionex_slant_batch(handle, requests)
      assert length(rows) == 3

      assert [
               {:ok, %SlantEvaluation{delay_m: first}},
               {:error, {:out_of_coverage, :epoch_before_first_map}},
               {:ok, %SlantEvaluation{delay_m: third}}
             ] = rows

      assert first > 0.0
      assert third > 0.0
    end

    test "a failed row matches the scalar call for the same request" do
      assert {:ok, handle} = Ionosphere.from_samples(whole_sphere_samples())
      epoch = {{2020, 6, 24}, {1, 0, 0}}

      assert {:ok, [{:ok, batched}]} =
               Ionosphere.ionex_slant_batch(handle, [
                 SlantRequest.new(45.0, 10.0, 60.0, 60.0, epoch, @l1_hz)
               ])

      assert {:ok, scalar} =
               Ionosphere.ionex_slant_evaluation(handle, 45.0, 10.0, 60.0, 60.0, epoch, @l1_hz)

      assert batched.delay_m == scalar.delay_m
      assert batched.status == scalar.status
    end

    test "a row with distinct azimuth and elevation matches the scalar call for the same pair" do
      assert {:ok, handle} = Ionosphere.from_samples(whole_sphere_samples())
      epoch = {{2020, 6, 24}, {1, 0, 0}}

      # The public order is `(azimuth_deg, elevation_deg)` and the boundary's
      # positional order is `(elevation, azimuth)`; the batch bridges the two by
      # map key and the scalar call by position. 30 and 60 are both elevations
      # the core takes, so the swapped pair is a query that succeeds with a
      # different value rather than one the core refuses: a transposition on
      # either path moves a number instead of raising, and only comparing the
      # two paths on a pair that is not symmetric catches it.
      assert {:ok, upright} =
               Ionosphere.ionex_slant_evaluation(handle, 45.0, 10.0, 30.0, 60.0, epoch, @l1_hz)

      assert {:ok, swapped} =
               Ionosphere.ionex_slant_evaluation(handle, 45.0, 10.0, 60.0, 30.0, epoch, @l1_hz)

      refute upright.delay_m == swapped.delay_m

      assert {:ok, rows} =
               Ionosphere.ionex_slant_batch(handle, [
                 SlantRequest.new(45.0, 10.0, 30.0, 60.0, epoch, @l1_hz),
                 SlantRequest.new(45.0, 10.0, 60.0, 30.0, epoch, @l1_hz)
               ])

      # Exact equality: the two paths carry the same pair of numbers to the same
      # core call, so any tolerance here would be room for a transposition.
      assert [{:ok, batched_upright}, {:ok, batched_swapped}] = rows
      assert batched_upright.delay_m == upright.delay_m
      assert batched_swapped.delay_m == swapped.delay_m
    end

    test "an empty batch is an empty result list, not an error" do
      assert {:ok, handle} = Ionosphere.from_samples(whole_sphere_samples())
      assert {:ok, []} = Ionosphere.ionex_slant_batch(handle, [])
    end
  end

  # Latitude spans 10 degrees and longitude 40, and the values rise a hundred
  # times faster along latitude, so a query that swaps the two axes reads a value
  # nowhere near the right one instead of landing inside the grid by accident.
  defp asymmetric_grid do
    TecGrid.new(
      [0.0, 1.0e9],
      [0.0, 10.0],
      [0.0, 40.0],
      [0.0, 4.0, 100.0, 104.0, 0.0, 4.0, 100.0, 104.0]
    )
  end

  describe "standalone TEC grid" do
    test "longitude comes before latitude, and the axes are not interchangeable" do
      assert {:ok, grid} = asymmetric_grid()

      assert {:ok, %TecGrid.Evaluation{value: value, degraded: nil}} =
               TecGrid.vtec_at_pierce_point(grid, 0, 10.0, 2.5)

      assert_in_delta value, 26.0, 1.0e-9

      assert {:ok, %TecGrid.Evaluation{value: swapped}} =
               TecGrid.vtec_at_pierce_point(grid, 0, 2.5, 10.0)

      assert_in_delta swapped, 100.25, 1.0e-9
    end

    test "the immutable accessors report the axes and values as stored" do
      assert {:ok, grid} = asymmetric_grid()

      assert {:ok, [+0.0, 1.0e9]} = TecGrid.epochs_ns(grid)
      assert {:ok, [+0.0, 10.0]} = TecGrid.latitudes_deg(grid)
      assert {:ok, [+0.0, 40.0]} = TecGrid.longitudes_deg(grid)
      assert {:ok, values} = TecGrid.values(grid)
      assert values == [0.0, 4.0, 100.0, 104.0, 0.0, 4.0, 100.0, 104.0]
    end

    test "a node holding zero is a value and a node without one is nil" do
      assert {:ok, grid} =
               TecGrid.new([0.0, 1.0e9], [0.0, 10.0], [0.0, 40.0], [
                 0.0,
                 4.0,
                 100.0,
                 104.0,
                 nil,
                 4.0,
                 100.0,
                 104.0
               ])

      assert {:ok, values} = TecGrid.values(grid)
      assert Enum.at(values, 0) == 0.0
      assert Enum.at(values, 4) == nil
    end

    test "a weighted node without a value is refused by name, and renormalized on request" do
      assert {:ok, grid} =
               TecGrid.new([0.0, 1.0e9], [0.0, 10.0], [0.0, 40.0], [
                 nil,
                 4.0,
                 100.0,
                 104.0,
                 nil,
                 4.0,
                 100.0,
                 104.0
               ])

      assert {:error, {:nodes_not_available, %NodeGap{} = gap}} =
               TecGrid.vtec_at_pierce_point(grid, 0, 10.0, 2.5)

      assert %MissingNodes{missing: [true, false, false, false]} = gap.earlier

      assert {:ok, %TecGrid.Evaluation{value: value, degraded: %NodeGap{}}} =
               TecGrid.vtec_at_pierce_point(grid, 0, 10.0, 2.5, missing_nodes: :renormalize)

      assert value > 0.0
    end

    test "an unknown missing-node choice is an error, never a silent default" do
      assert {:ok, grid} = asymmetric_grid()

      assert {:error, {:invalid_policy_value, :missing_nodes, :nearest}} =
               TecGrid.vtec_at_pierce_point(grid, 0, 10.0, 2.5, missing_nodes: :nearest)
    end

    test "a too-short axis is refused with the failed invariant" do
      assert {:error, :axes_too_short} = TecGrid.new([0.0], [0.0, 10.0], [0.0, 40.0], [0.0, 4.0])
    end

    test "a value count that does not match the axes names both counts" do
      assert {:error, {:value_count_mismatch, 3, 8}} =
               TecGrid.new([0.0, 1.0e9], [0.0, 10.0], [0.0, 40.0], [0.0, 4.0, 100.0])
    end
  end

  # The grid of the XYZ evaluations holds 1 + (lon - 20) / 10 + 2 (lat / 10) +
  # 4 (t / 10) on the corners of one cell, so a query at a dyadic point
  # interpolates exactly: at the mid epoch 5, (25, 5) gives 1 + 0.5 + 1 + 2 = 4.5
  # and (22.5, 2.5) gives 1 + 0.25 + 0.5 + 2 = 3.75.
  defp xyz_grid(values \\ [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]) do
    {:ok, grid} = TecGrid.new([0.0, 10.0], [0.0, 10.0], [20.0, 30.0], values)
    grid
  end

  # A receiver on the mean sphere with the satellite straight overhead. The line
  # of sight meets the default shell, radius 6,371,000 + 450,000 m, exactly
  # 450,000 m up, the discriminant being 13,642,000^2. The elevation is pi/2,
  # whose cosine leaves the slant factor at exactly 1, so slant TEC equals
  # vertical TEC.
  @overhead_receiver {6_371_000.0, 0.0, 0.0}
  @overhead_satellite {26_371_000.0, 0.0, 0.0}
  @overhead_pierce_point {6_821_000.0, 0.0, 0.0}

  defp nan_answer, do: {TecGrid.nan(), TecGrid.nan(), TecGrid.nan()}

  # A converter that answers from `answers` in order and records each position it
  # is asked about. A call past the last answer fails its match, so a request a
  # test does not expect fails that test.
  defp recorder(answers) do
    key = make_ref()
    Process.put(key, {answers, []})

    converter = fn xyz ->
      {[answer | rest], asked} = Process.get(key)
      Process.put(key, {rest, [xyz | asked]})
      answer
    end

    {converter, fn -> Enum.reverse(elem(Process.get(key), 1)) end}
  end

  # A `{:nonfinite, bits}` whose pattern is a NaN: every exponent bit set and a
  # nonzero fraction. The sign and payload of the NaN a missed shell gives are
  # the platform's own, so only the class is checked.
  defp nan?({:nonfinite, bits}) when is_integer(bits) do
    exponent = Bitwise.band(bits, 0x7FF0_0000_0000_0000)
    fraction = Bitwise.band(bits, 0x000F_FFFF_FFFF_FFFF)
    exponent == 0x7FF0_0000_0000_0000 and fraction != 0
  end

  defp nan?(_value), do: false

  defp outcome({:ok, %TecGrid.Evaluation{value: value}}), do: {:ok, value}
  defp outcome(error), do: error

  # Prepares the overhead TEC evaluation on a grid that nothing but the returned
  # stage refers to.
  defp pending_tec_stage do
    %TecGrid{handle: handle} = xyz_grid()

    options = %{
      missing_nodes: :strict,
      min_elevation_rad: nil,
      nan_pierce_point_height_m: nil,
      earth_radius_m: nil,
      shell_height_m: nil
    }

    {:ok, {:convert, stage, _xyz}} =
      NIF.tec_grid_tec_xyz_prepare(handle, 5, @overhead_satellite, @overhead_receiver, options)

    stage
  end

  describe "standalone TEC grid XYZ evaluation" do
    test "a finite answer asks for the pierce point once, bit for bit" do
      {converter, asked} = recorder([{25.0, 5.0, 450_000.0}])
      result = TecGrid.tec_xyz(xyz_grid(), 5, @overhead_satellite, @overhead_receiver, converter)

      assert {:ok, %TecGrid.Evaluation{value: {4.5, 4.5}, degraded: nil}} = result
      assert asked.() === [@overhead_pierce_point]
    end

    test "a NaN in any component of the answer asks for the receiver once, and its altitude is not read" do
      first_answers = [
        nan_answer(),
        {25.0, 5.0, TecGrid.nan()},
        {TecGrid.nan(), 5.0, 450_000.0}
      ]

      for first <- first_answers do
        {converter, asked} = recorder([first, {22.5, 2.5, TecGrid.nan()}])
        result = TecGrid.tec_xyz(xyz_grid(), 5, @overhead_satellite, @overhead_receiver, converter)

        assert {:ok, %TecGrid.Evaluation{value: {3.75, 3.75}, degraded: nil}} = result
        assert asked.() === [@overhead_pierce_point, @overhead_receiver]
      end
    end

    test "every NaN pattern is read as NaN, whatever its sign or payload" do
      nans = [TecGrid.nan(), {:nonfinite, 0xFFF8_0000_0000_0000}, {:nonfinite, 0x7FF0_0000_0000_0001}]

      for nan <- nans do
        {converter, asked} = recorder([{25.0, nan, 0.0}, {22.5, 2.5, 0.0}])
        result = TecGrid.tec_xyz(xyz_grid(), 5, @overhead_satellite, @overhead_receiver, converter)

        assert {:ok, %TecGrid.Evaluation{value: {3.75, 3.75}}} = result
        assert asked.() === [@overhead_pierce_point, @overhead_receiver]
      end
    end

    test "a NaN longitude or latitude from the receiver is refused, not asked about again" do
      cases = [
        {{22.5, TecGrid.nan(), 0.0}, {:invalid_field, "latitude", "not finite"}},
        {{TecGrid.nan(), 2.5, 0.0}, {:invalid_field, "longitude", "not finite"}}
      ]

      for {receiver_answer, reason} <- cases do
        {converter, asked} = recorder([nan_answer(), receiver_answer])
        result = TecGrid.tec_xyz(xyz_grid(), 5, @overhead_satellite, @overhead_receiver, converter)

        assert result == {:error, reason}
        assert asked.() === [@overhead_pierce_point, @overhead_receiver]
      end
    end

    test "a line of sight that misses the shell still asks about its NaN pierce point" do
      # The ray along +y from radius 7,000,000 m touches that sphere and never
      # meets the 6,821,000 m shell, so every pierce-point component is NaN. The
      # elevation is 0, raised to the 5 degree default.
      receiver = {7.0e6, 0.0, 0.0}
      satellite = {7.0e6, 1.0e6, 0.0}

      {converter, asked} = recorder([{25.0, 5.0, 0.0}])
      result = TecGrid.tec_xyz(xyz_grid(), 5, satellite, receiver, converter)

      assert {:ok, %TecGrid.Evaluation{value: {vtec, stec}, degraded: nil}} = result
      assert [{x, y, z}] = asked.()
      assert nan?(x) and nan?(y) and nan?(z)
      assert vtec == 4.5
      # Thin-shell mapping 4.5 / sqrt(1 - (R cos 5 deg / (R + h))^2).
      assert_in_delta stec, 12.28298557025832, 12.28298557025832 * 1.0e-12

      # Answering with the request itself, NaN components and all, falls back to
      # the receiver, which is asked about exactly as given.
      {converter, asked} = recorder([{x, y, z}, {25.0, 5.0, 0.0}])
      fallback = TecGrid.tec_xyz(xyz_grid(), 5, satellite, receiver, converter)

      assert outcome(fallback) === {:ok, {vtec, stec}}
      assert [{^x, ^y, ^z}, ^receiver] = asked.()
    end

    test "a refused elevation ends the evaluation after one call, even after a NaN answer" do
      # |x|^2 = 1e-320 is subnormal, so the receiver unit vector's x rounds above
      # 1 and the elevation is NaN. The pierce point is still exactly the default
      # shell radius on +x.
      {converter, asked} = recorder([nan_answer()])
      result = TecGrid.tec_xyz(xyz_grid(), 5, {20_000_000.0, 0.0, 0.0}, {1.0e-160, 0.0, 0.0}, converter)

      assert {:error, {:invalid_field, "elevation_rad", "not finite"}} = result
      assert asked.() === [@overhead_pierce_point]
    end

    test "inputs the core refuses leave the converter uncalled" do
      {converter, asked} = recorder([])
      grid = xyz_grid()

      at_origin = TecGrid.tec_xyz(grid, 5, @overhead_satellite, {0.0, 0.0, 0.0}, converter)
      assert {:error, {:invalid_field, "receiver radius_m", "not positive"}} = at_origin

      no_line_of_sight = TecGrid.tec_xyz(grid, 5, @overhead_receiver, @overhead_receiver, converter)
      assert {:error, {:invalid_field, "line of sight_m", "not positive"}} = no_line_of_sight

      nan_satellite = TecGrid.tec_xyz(grid, 5, {TecGrid.nan(), 0.0, 0.0}, @overhead_receiver, converter)
      assert {:error, {:invalid_field, "satellite_xyz", "not finite"}} = nan_satellite

      refusals = [
        {[earth_radius_m: 0.0], {:invalid_field, "earth_radius_m", "not positive"}},
        {[shell_height_m: -1.0], {:invalid_field, "shell_height_m", "negative"}},
        {[min_elevation_rad: TecGrid.infinity()], {:invalid_field, "min_elevation_rad", "not finite"}},
        {[nan_pierce_point_height_m: TecGrid.nan()], {:invalid_field, "nan_pierce_point_height_m", "not finite"}}
      ]

      for {opts, reason} <- refusals do
        result = TecGrid.tec_xyz(grid, 5, @overhead_satellite, @overhead_receiver, converter, opts)
        assert result == {:error, reason}
      end

      assert asked.() == []
    end

    test "a delay checks its carrier before the geometry, and the TEC evaluation reads no carrier" do
      # The geometry refuses both positions; the carrier is checked first.
      satellite = {TecGrid.nan(), 0.0, 0.0}
      receiver = {0.0, 0.0, 0.0}
      {converter, asked} = recorder([])

      zero = TecGrid.iono_delay_xyz(xyz_grid(), 5, 0.0, satellite, receiver, converter)
      assert {:error, {:invalid_field, "frequency_hz", "not positive"}} = zero

      nan = TecGrid.iono_delay_xyz(xyz_grid(), 5, TecGrid.nan(), satellite, receiver, converter)
      assert {:error, {:invalid_field, "frequency_hz", "not finite"}} = nan

      tec = TecGrid.tec_xyz(xyz_grid(), 5, satellite, receiver, converter)
      assert {:error, {:invalid_field, "satellite_xyz", "not finite"}} = tec

      assert asked.() == []
    end

    test "a carrier the delay refuses does not stop the TEC evaluation" do
      {converter, asked} = recorder([])
      refused = TecGrid.iono_delay_xyz(xyz_grid(), 5, 0.0, @overhead_satellite, @overhead_receiver, converter)

      assert {:error, {:invalid_field, "frequency_hz", "not positive"}} = refused
      assert asked.() == []

      {converter, asked} = recorder([{25.0, 5.0, 0.0}])
      tec = TecGrid.tec_xyz(xyz_grid(), 5, @overhead_satellite, @overhead_receiver, converter)

      assert {:ok, %TecGrid.Evaluation{value: {4.5, 4.5}}} = tec
      assert asked.() === [@overhead_pierce_point]
    end

    test "the delay is the slant TEC on the carrier, after one or two conversions" do
      # 40.308193e16 * stec / 1575.42e6^2 meters, with stec 4.5 and then 3.75.
      {converter, asked} = recorder([{25.0, 5.0, 0.0}])
      direct = TecGrid.iono_delay_xyz(xyz_grid(), 5, @l1_hz, @overhead_satellite, @overhead_receiver, converter)

      assert {:ok, %TecGrid.Evaluation{value: 0.7308245604188918, degraded: nil}} = direct
      assert asked.() === [@overhead_pierce_point]

      {converter, asked} = recorder([nan_answer(), {22.5, 2.5, 0.0}])
      fallback = TecGrid.iono_delay_xyz(xyz_grid(), 5, @l1_hz, @overhead_satellite, @overhead_receiver, converter)

      assert {:ok, %TecGrid.Evaluation{value: 0.6090204670157431, degraded: nil}} = fallback
      assert asked.() === [@overhead_pierce_point, @overhead_receiver]
    end

    test "a carrier whose square underflows is refused when the delay is formed" do
      # 1e-200 is finite and positive, and its square is 0.
      {converter, asked} = recorder([{25.0, 5.0, 0.0}])
      result = TecGrid.iono_delay_xyz(xyz_grid(), 5, 1.0e-200, @overhead_satellite, @overhead_receiver, converter)

      assert {:error, {:invalid_field, "ionosphere_delay_m", "not finite"}} = result
      assert asked.() === [@overhead_pierce_point]
    end

    test "an epoch outside the grid is refused after the conversion" do
      {converter, asked} = recorder([{25.0, 5.0, 0.0}])
      result = TecGrid.tec_xyz(xyz_grid(), 100, @overhead_satellite, @overhead_receiver, converter)

      assert {:error, {:out_of_bounds, "timestamp", 100.0}} = result
      assert asked.() === [@overhead_pierce_point]
    end

    test "a missing node is refused under :strict and interpolated around under :renormalize" do
      grid = xyz_grid([nil, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0])

      nodes = %MissingNodes{
        map_number: 1,
        lat_index: 0,
        lon_index: 0,
        lon_index_next: 1,
        missing: [true, false, false, false]
      }

      gap = %NodeGap{earlier: nodes, later: nil}

      {converter, asked} = recorder([{25.0, 5.0, 0.0}])
      strict = TecGrid.tec_xyz(grid, 5, @overhead_satellite, @overhead_receiver, converter)

      assert {:error, {:nodes_not_available, ^gap}} = strict
      assert asked.() === [@overhead_pierce_point]

      # Earlier map: the mean of 2, 3 and 4 is 3; later map: the mean of 5 to 8 is
      # 6.5; equal temporal weights give 4.75.
      opts = [missing_nodes: :renormalize]
      {converter, _asked} = recorder([{25.0, 5.0, 0.0}])
      renormalized = TecGrid.tec_xyz(grid, 5, @overhead_satellite, @overhead_receiver, converter, opts)

      assert {:ok, %TecGrid.Evaluation{value: {4.75, 4.75}, degraded: ^gap}} = renormalized

      {converter, _asked} = recorder([{25.0, 5.0, 0.0}])
      delay = TecGrid.iono_delay_xyz(grid, 5, @l1_hz, @overhead_satellite, @overhead_receiver, converter, opts)

      assert {:ok, %TecGrid.Evaluation{value: delay_m, degraded: ^gap}} = delay
      assert delay_m > 0.7308245604188918
    end

    test "an infinite latitude is clamped and an infinite longitude is refused" do
      # Latitude rows -87.5 and 87.5 hold 1 and 3 on both maps.
      values = [1.0, 1.0, 3.0, 3.0, 1.0, 1.0, 3.0, 3.0]
      {:ok, polar} = TecGrid.new([0.0, 10.0], [-87.5, 87.5], [20.0, 30.0], values)
      not_finite = {:error, {:invalid_field, "longitude", "not finite"}}

      cases = [
        {{25.0, TecGrid.infinity(), TecGrid.infinity()}, {:ok, {3.0, 3.0}}},
        {{25.0, TecGrid.neg_infinity(), 0.0}, {:ok, {1.0, 1.0}}},
        {{TecGrid.infinity(), 0.0, 0.0}, not_finite},
        {{TecGrid.neg_infinity(), 0.0, 0.0}, not_finite}
      ]

      for {answer, expected} <- cases do
        {converter, asked} = recorder([answer])
        result = TecGrid.tec_xyz(polar, 5, @overhead_satellite, @overhead_receiver, converter)

        assert outcome(result) === expected
        assert asked.() === [@overhead_pierce_point]
      end
    end

    test "an integer answer is read onto its double" do
      {converter, _asked} = recorder([{25, 5, 450_000}])
      result = TecGrid.tec_xyz(xyz_grid(), 5, @overhead_satellite, @overhead_receiver, converter)

      assert {:ok, %TecGrid.Evaluation{value: {4.5, 4.5}}} = result
    end

    test "integer positions, options and carrier are read onto their doubles" do
      float_answer = fn _xyz -> {25.0, 5.0, 450_000.0} end
      integer_answer = fn _xyz -> {25, 5, 450_000} end

      float =
        TecGrid.iono_delay_xyz(
          xyz_grid(),
          5,
          1_575_420_000.0,
          @overhead_satellite,
          @overhead_receiver,
          float_answer,
          earth_radius_m: 6_371_000.0,
          shell_height_m: 450_000.0
        )

      integer =
        TecGrid.iono_delay_xyz(
          xyz_grid(),
          5,
          1_575_420_000,
          {26_371_000, 0, 0},
          {6_371_000, 0, 0},
          integer_answer,
          earth_radius_m: 6_371_000,
          shell_height_m: 450_000
        )

      assert {:ok, %TecGrid.Evaluation{}} = float
      assert integer === float
    end

    test "an infinite request component crosses the tagged transport" do
      # An Earth radius of 1.0e200 m makes the squared shell radius overflow, so
      # the pierce-point parameter is +inf: the requested x is 6_371_000 + inf * 1
      # = +inf and y and z are 0 + inf * 0 = NaN. The answer is finite, so the
      # receiver is not asked about, and the obliquity term at an elevation of
      # pi/2 is about 6e-17, which leaves slant TEC equal to vertical TEC.
      {converter, asked} = recorder([{25.0, 5.0, 0.0}])

      result =
        TecGrid.tec_xyz(xyz_grid(), 5, @overhead_satellite, @overhead_receiver, converter, earth_radius_m: 1.0e200)

      assert {:ok, %TecGrid.Evaluation{value: {4.5, 4.5}}} = result
      assert [{x, y, z}] = asked.()
      assert x === TecGrid.infinity()
      assert nan?(y) and nan?(z)
    end

    test "an answer that is not three doubles is refused after the call" do
      # 0x3FF0... is the pattern of 1.0, which is finite, and 0x1_0000... is 2^64.
      answers = [
        {25.0, 5.0},
        [25.0, 5.0, 0.0],
        :ok,
        {25.0, :north, 0.0},
        {25.0, {:nonfinite, 0x3FF0_0000_0000_0000}, 0.0},
        {25.0, {:nonfinite, -1}, 0.0},
        {25.0, {:nonfinite, 0x1_0000_0000_0000_0000}, 0.0},
        {25.0, {:nan, 0x7FF8_0000_0000_0000}, 0.0}
      ]

      for answer <- answers do
        {converter, asked} = recorder([answer])
        result = TecGrid.tec_xyz(xyz_grid(), 5, @overhead_satellite, @overhead_receiver, converter)

        assert {:error, {:invalid_conversion, ^answer}} = result
        assert asked.() === [@overhead_pierce_point]
      end

      {converter, _asked} = recorder([{25.0, @oversized, 0.0}])
      result = TecGrid.tec_xyz(xyz_grid(), 5, @overhead_satellite, @overhead_receiver, converter)

      assert {:error, {:value_out_of_range, :lat_deg, @oversized}} = result
    end

    test "a position, carrier or option the boundary cannot carry is named before the core reads anything" do
      {converter, asked} = recorder([])
      grid = xyz_grid()
      satellite = @overhead_satellite
      receiver = @overhead_receiver

      list = TecGrid.tec_xyz(grid, 5, satellite, [6_371_000.0, 0.0, 0.0], converter)
      assert list == {:error, {:invalid_position, :receiver_xyz, [6_371_000.0, 0.0, 0.0]}}

      atom = TecGrid.tec_xyz(grid, 5, {1.0, :up, 0.0}, receiver, converter)
      assert atom == {:error, {:invalid_position, :satellite_xyz, {1.0, :up, 0.0}}}

      finite_tag = {:nonfinite, 0x3FF0_0000_0000_0000}
      tagged = TecGrid.tec_xyz(grid, 5, {finite_tag, 0.0, 0.0}, receiver, converter)
      assert tagged == {:error, {:invalid_position, :satellite_xyz, {finite_tag, 0.0, 0.0}}}

      oversized = TecGrid.tec_xyz(grid, 5, satellite, {@oversized, 0.0, 0.0}, converter)
      assert {:error, {:value_out_of_range, :receiver_xyz, @oversized}} = oversized

      carrier = TecGrid.iono_delay_xyz(grid, 5, "L1", satellite, receiver, converter)
      assert {:error, {:invalid_double, :frequency_hz, "L1"}} = carrier

      big_carrier = TecGrid.iono_delay_xyz(grid, 5, @oversized, satellite, receiver, converter)
      assert {:error, {:value_out_of_range, :frequency_hz, @oversized}} = big_carrier

      option_cases = [
        {[min_elevation_rad: nil], {:invalid_double, :min_elevation_rad, nil}},
        {[earth_radius_m: @oversized], {:value_out_of_range, :earth_radius_m, @oversized}},
        {[shell_height_km: 450.0], {:unknown_option_key, :shell_height_km}},
        {[earth_radius_m: 1.0, earth_radius_m: 2.0], {:duplicate_option_key, :earth_radius_m}},
        {[missing_nodes: :nearest], {:invalid_policy_value, :missing_nodes, :nearest}},
        {%{missing_nodes: :strict}, {:invalid_options, %{missing_nodes: :strict}}}
      ]

      for {opts, reason} <- option_cases do
        result = TecGrid.tec_xyz(grid, 5, satellite, receiver, converter, opts)
        assert result == {:error, reason}
      end

      assert {:error, {:bad_tec_grid, :grid}} = TecGrid.tec_xyz(:grid, 5, satellite, receiver, converter)

      {:ok, ionex} = Ionosphere.from_samples(whole_sphere_samples())
      wrong_resource = TecGrid.tec_xyz(ionex, 5, satellite, receiver, converter)
      assert {:error, {:invalid_resource, :tec_grid}} = wrong_resource

      assert asked.() == []
    end

    test "a converter of another arity is refused before anything is evaluated" do
      two = fn _xyz, _extra -> {25.0, 5.0, 0.0} end
      tec = TecGrid.tec_xyz(xyz_grid(), 5, @overhead_satellite, @overhead_receiver, two)
      assert {:error, {:invalid_converter, ^two}} = tec

      # The core would refuse this receiver; the converter is named first.
      at_origin = TecGrid.tec_xyz(xyz_grid(), 5, @overhead_satellite, {0.0, 0.0, 0.0}, :convert)
      assert {:error, {:invalid_converter, :convert}} = at_origin

      delay = TecGrid.iono_delay_xyz(xyz_grid(), 5, 0.0, @overhead_satellite, @overhead_receiver, two)
      assert {:error, {:invalid_converter, ^two}} = delay
    end

    test "the options reach the core" do
      # Earth radius 6,000,000 m under a 450,000 m shell: the receiver at
      # 6,371,000 m meets the 6,450,000 m shell 79,000 m up, the discriminant
      # being 12,900,000^2.
      {converter, asked} = recorder([{25.0, 5.0, 0.0}])
      opts = [earth_radius_m: 6_000_000.0, shell_height_m: 450_000.0]
      result = TecGrid.tec_xyz(xyz_grid(), 5, @overhead_satellite, @overhead_receiver, converter, opts)

      assert {:ok, %TecGrid.Evaluation{value: {4.5, 4.5}}} = result
      assert asked.() === [{6_450_000.0, 0.0, 0.0}]

      # A 350,000 m shell over the default Earth radius: 13,442,000^2.
      {converter, asked} = recorder([{25.0, 5.0, 0.0}])
      opts = [shell_height_m: 350_000.0]
      result = TecGrid.tec_xyz(xyz_grid(), 5, @overhead_satellite, @overhead_receiver, converter, opts)

      assert {:ok, %TecGrid.Evaluation{value: {4.5, 4.5}}} = result
      assert asked.() === [{6_721_000.0, 0.0, 0.0}]

      # A floor above the overhead pi/2 raises the elevation to it, and the slant
      # factor exceeds 1.
      {converter, _asked} = recorder([{25.0, 5.0, 0.0}])
      opts = [min_elevation_rad: 2.0]
      result = TecGrid.tec_xyz(xyz_grid(), 5, @overhead_satellite, @overhead_receiver, converter, opts)

      assert {:ok, %TecGrid.Evaluation{value: {4.5, stec}}} = result
      assert stec > 4.5
    end

    test "an exception the converter raises, throws or exits with reaches the caller as itself" do
      grid = xyz_grid()

      # ArgumentError and ErlangError are the two a boundary call is rescued
      # from; out of the converter each arrives as raised, with the converter's
      # own frame on top of its stacktrace.
      refuses = fn _xyz -> raise ArgumentError, "converter refused" end

      try do
        TecGrid.tec_xyz(grid, 5, @overhead_satellite, @overhead_receiver, refuses)
        flunk("the converter's ArgumentError did not reach the caller")
      rescue
        error in ArgumentError ->
          assert error.message == "converter refused"
          assert [{__MODULE__, _fun, 1, _location} | _frames] = __STACKTRACE__
      end

      fails = fn _xyz -> :erlang.error({:converter_failed, 1}) end
      call = fn -> TecGrid.tec_xyz(grid, 5, @overhead_satellite, @overhead_receiver, fails) end
      error = assert_raise ErlangError, call
      assert error.original == {:converter_failed, 1}

      throws = fn _xyz -> throw({:converter, :thrown}) end
      thrown = catch_throw(TecGrid.tec_xyz(grid, 5, @overhead_satellite, @overhead_receiver, throws))
      assert thrown == {:converter, :thrown}

      exits = fn _xyz -> exit({:converter, :exited}) end
      exited = catch_exit(TecGrid.iono_delay_xyz(grid, 5, @l1_hz, @overhead_satellite, @overhead_receiver, exits))
      assert exited == {:converter, :exited}
    end

    test "an exception on the receiver request reaches the caller too" do
      converter = fn
        {6_821_000.0, _y, _z} -> nan_answer()
        _receiver -> raise "receiver refused"
      end

      call = fn -> TecGrid.tec_xyz(xyz_grid(), 5, @overhead_satellite, @overhead_receiver, converter) end
      assert_raise RuntimeError, "receiver refused", call
    end

    test "the converter may query the grid it is converting for" do
      grid = xyz_grid()

      converter = fn xyz ->
        assert {:ok, %TecGrid.Evaluation{value: 4.5}} = TecGrid.vtec_at_pierce_point(grid, 5, 25.0, 5.0)
        nested = TecGrid.tec_xyz(grid, 5, @overhead_satellite, @overhead_receiver, fn _xyz -> {25.0, 5.0, 0.0} end)
        assert {:ok, %TecGrid.Evaluation{value: {4.5, 4.5}}} = nested

        if xyz === @overhead_pierce_point, do: nan_answer(), else: {22.5, 2.5, 0.0}
      end

      result = TecGrid.iono_delay_xyz(grid, 5, @l1_hz, @overhead_satellite, @overhead_receiver, converter)
      assert {:ok, %TecGrid.Evaluation{value: 0.6090204670157431}} = result
    end

    test "an evaluation holds its grid when the caller's reference is gone" do
      converter = fn xyz ->
        :erlang.garbage_collect()
        if xyz === @overhead_pierce_point, do: nan_answer(), else: {22.5, 2.5, 0.0}
      end

      # The grid is built in the argument list and bound to nothing here.
      result = TecGrid.tec_xyz(xyz_grid(), 5, @overhead_satellite, @overhead_receiver, converter)
      assert {:ok, %TecGrid.Evaluation{value: {3.75, 3.75}}} = result
    end

    test "a stage owns its grid and takes one answer" do
      stage = pending_tec_stage()
      :erlang.garbage_collect()

      assert {:ok, {:convert, receiver_stage, receiver}} = NIF.tec_grid_tec_xyz_resume(stage, nan_answer())
      assert receiver === @overhead_receiver
      assert {:error, :conversion_consumed} = NIF.tec_grid_tec_xyz_resume(stage, {25.0, 5.0, 0.0})

      :erlang.garbage_collect()
      finished = NIF.tec_grid_tec_xyz_resume(receiver_stage, {22.5, 2.5, 0.0})
      assert {:ok, {:complete, %{value: {3.75, 3.75}, degraded: nil}}} = finished
      assert {:error, :conversion_consumed} = NIF.tec_grid_tec_xyz_resume(receiver_stage, {22.5, 2.5, 0.0})
    end

    test "an answer the boundary cannot read leaves the stage unanswered" do
      stage = pending_tec_stage()

      assert {:error, {:invalid_transport, "lat_deg"}} =
               NIF.tec_grid_tec_xyz_resume(stage, {25.0, {:nonfinite, 0}, 0.0})

      assert {:ok, {:complete, %{value: {4.5, 4.5}}}} = NIF.tec_grid_tec_xyz_resume(stage, {25.0, 5.0, 0.0})
    end
  end

  # A record's data is its first 60 bytes and its label starts at byte 60, which
  # is how the reader cuts one apart.
  defp ionex_record(data, label), do: String.pad_trailing(data, 60) <> label

  defp with_header_records(text, records) do
    lines = String.split(text, "\n")
    index = Enum.find_index(lines, &String.contains?(&1, "END OF HEADER"))
    {before_header_end, rest} = Enum.split(lines, index)
    Enum.join(before_header_end ++ records ++ rest, "\n")
  end

  defp j2000_nanos_samples(counts, opts \\ []) do
    scale = Keyword.get(opts, :time_scale, "UTC")

    %{
      whole_sphere_samples(opts)
      | map_epochs: Enum.map(counts, &Epoch.j2000_nanos(scale, &1))
    }
  end

  describe "typed refusal payloads" do
    test "the strict scalar delay names the node gap as the public struct" do
      samples =
        whole_sphere_samples(
          tec_maps: [
            [[nil, 2.0], [3.0, 4.0]],
            [[5.0, 6.0], [7.0, 8.0]]
          ]
        )

      assert {:ok, handle} = Ionosphere.from_samples(samples)

      assert {:error, {:nodes_not_available, %NodeGap{} = gap}} =
               Ionosphere.ionex_slant_delay(
                 handle,
                 45.0,
                 10.0,
                 60.0,
                 60.0,
                 {{2020, 6, 24}, {1, 0, 0}},
                 @l1_hz
               )

      assert %MissingNodes{map_number: 1, lat_index: 0, lon_index: 0, missing: [true, false, false, false]} =
               gap.earlier

      assert gap.later == nil
    end

    test "height maps without a value at a node refuse by naming that node" do
      samples = whole_sphere_samples(height_maps: [[[nil, nil], [nil, nil]], [[nil, nil], [nil, nil]]])
      assert {:ok, handle} = Ionosphere.from_samples(samples)

      assert {:error, {:height_not_available, %HeightNode{map_number: 1, lat_index: 0, lon_index: 0}}} =
               Ionosphere.ionex_slant_delay(
                 handle,
                 45.0,
                 10.0,
                 60.0,
                 60.0,
                 {{2020, 6, 24}, {1, 0, 0}},
                 @l1_hz
               )
    end

    test "height maps giving two heights refuse by naming the node that differs" do
      samples = whole_sphere_samples(height_maps: [[[0.0, 5.0], [0.0, 0.0]], [[0.0, 0.0], [0.0, 0.0]]])
      assert {:ok, handle} = Ionosphere.from_samples(samples)

      assert {:error, {:varying_heights, %HeightNode{map_number: 1, lat_index: 0, lon_index: 1}}} =
               Ionosphere.ionex_slant_evaluation(
                 handle,
                 45.0,
                 10.0,
                 60.0,
                 60.0,
                 {{2020, 6, 24}, {1, 0, 0}},
                 @l1_hz
               )
    end

    test "a receiver outside the frame's range is refused by field and reason" do
      assert {:ok, handle} = Ionosphere.from_samples(whole_sphere_samples())

      assert {:error, {:invalid_field, "lon_rad", "must be in [-pi, pi]"}} =
               Ionosphere.ionex_slant_delay(
                 handle,
                 45.0,
                 200.0,
                 60.0,
                 60.0,
                 {{2020, 6, 24}, {1, 0, 0}},
                 @l1_hz
               )

      assert {:error, {:invalid_field, "lat_rad", "must be in [-pi/2, pi/2]"}} =
               Ionosphere.ionex_slant_delay(
                 handle,
                 95.0,
                 10.0,
                 60.0,
                 60.0,
                 {{2020, 6, 24}, {1, 0, 0}},
                 @l1_hz
               )
    end

    test "an elevation the core refuses comes back as its own message" do
      assert {:ok, handle} = Ionosphere.from_samples(whole_sphere_samples())

      assert {:error, {:invalid_input, message}} =
               Ionosphere.ionex_slant_delay(
                 handle,
                 45.0,
                 10.0,
                 60.0,
                 -5.0,
                 {{2020, 6, 24}, {1, 0, 0}},
                 @l1_hz
               )

      assert message =~ "elevation_rad"
    end
  end

  describe "epoch representation and origin" do
    test "a zero nanosecond count is the J2000 epoch, not the Unix epoch" do
      assert {:ok, handle} = Ionosphere.from_samples(j2000_nanos_samples([0, 7_200_000_000_000]))

      # Zero is 2000-01-01 12:00, so a query there is the product's first map.
      assert {:ok, delay_m} =
               Ionosphere.ionex_slant_delay(
                 handle,
                 45.0,
                 10.0,
                 60.0,
                 60.0,
                 {{2000, 1, 1}, {12, 0, 0}},
                 @l1_hz
               )

      assert delay_m > 0.0

      # The Unix reading of the same count is thirty years earlier, which this
      # product does not cover.
      assert {:error, {:out_of_coverage, :epoch_before_first_map}} =
               Ionosphere.ionex_slant_delay(
                 handle,
                 45.0,
                 10.0,
                 60.0,
                 60.0,
                 {{1970, 1, 1}, {0, 0, 0}},
                 @l1_hz
               )
    end

    test "a negative count is an epoch before J2000, and comes back as given" do
      counts = [-7_200_000_000_000, 0]
      assert {:ok, handle} = Ionosphere.from_samples(j2000_nanos_samples(counts))

      assert {:ok, _delay_m} =
               Ionosphere.ionex_slant_delay(
                 handle,
                 45.0,
                 10.0,
                 60.0,
                 60.0,
                 {{2000, 1, 1}, {11, 0, 0}},
                 @l1_hz
               )

      assert {:ok, %TecGridSamples{map_epochs: epochs}} = Ionosphere.tec_grid_samples(handle)

      assert epochs == [
               %Epoch{time_scale: "UTC", j2000_nanos: -7_200_000_000_000},
               %Epoch{time_scale: "UTC", j2000_nanos: 0}
             ]
    end

    test "the exact integer count survives the round trip with no scaling" do
      counts = [646_228_800_000_000_000, 646_236_000_000_000_000]
      assert {:ok, handle} = Ionosphere.from_samples(j2000_nanos_samples(counts))
      assert {:ok, %TecGridSamples{map_epochs: epochs}} = Ionosphere.tec_grid_samples(handle)
      assert Enum.map(epochs, & &1.j2000_nanos) == counts
      assert Enum.all?(epochs, &(&1.jd_whole == nil and &1.jd_fraction == nil))
    end

    test "the split Julian date and the nanosecond count name the same instant" do
      # 2020-06-24 00:00 and 02:00 UTC, stated both ways.
      split = whole_sphere_samples()
      nanos = j2000_nanos_samples([646_228_800_000_000_000, 646_236_000_000_000_000])

      assert {:ok, split_handle} = Ionosphere.from_samples(split)
      assert {:ok, nanos_handle} = Ionosphere.from_samples(nanos)

      epoch = {{2020, 6, 24}, {1, 0, 0}}

      assert {:ok, from_split} =
               Ionosphere.ionex_slant_delay(split_handle, 45.0, 10.0, 60.0, 60.0, epoch, @l1_hz)

      assert {:ok, from_nanos} =
               Ionosphere.ionex_slant_delay(nanos_handle, 45.0, 10.0, 60.0, 60.0, epoch, @l1_hz)

      assert from_nanos == from_split

      # Each product still reports the representation it was built with.
      assert {:ok, %TecGridSamples{map_epochs: [%Epoch{jd_whole: whole} | _]}} =
               Ionosphere.tec_grid_samples(split_handle)

      assert is_float(whole)

      assert {:ok, %TecGridSamples{map_epochs: [%Epoch{j2000_nanos: first} | _]}} =
               Ionosphere.tec_grid_samples(nanos_handle)

      assert first == 646_228_800_000_000_000
    end

    test "a count that is not a whole second is refused rather than rounded" do
      samples = j2000_nanos_samples([500_000_000, 7_200_000_000_000])
      assert {:error, :epoch_not_representable} = Ionosphere.from_samples(samples)
    end

    test "the standalone grid keeps its own Unix origin" do
      # The standalone axis is Unix nanoseconds and is taken as stored: zero is a
      # node of this grid, where zero on the IONEX surface is J2000.
      assert {:ok, grid} = asymmetric_grid()
      assert {:ok, [+0.0, 1.0e9]} = TecGrid.epochs_ns(grid)
      assert {:ok, %TecGrid.Evaluation{}} = TecGrid.vtec_at_pierce_point(grid, 0, 10.0, 2.5)
    end

    test "every time scale the core names crosses the boundary and maps onto UTC" do
      # IONEX map epochs are UT (IONEX 1, Table 1). The core carries an epoch
      # with a whole UTC second onto UTC exactly and stores a UTC epoch as given.
      samples = j2000_nanos_samples([0, 7_200_000_000_000], time_scale: "UTC")
      assert {:ok, handle} = Ionosphere.from_samples(samples)
      assert {:ok, %TecGridSamples{map_epochs: epochs}} = Ionosphere.tec_grid_samples(handle)
      assert Enum.map(epochs, &{&1.time_scale, &1.j2000_nanos}) == [{"UTC", 0}, {"UTC", 7_200_000_000_000}]

      for scale <- ~w(TAI GPST GST BDT GLONASST QZSST) do
        samples = j2000_nanos_samples([0, 7_200_000_000_000], time_scale: scale)
        assert {:ok, handle} = Ionosphere.from_samples(samples)
        assert {:ok, %TecGridSamples{map_epochs: [first, second]}} = Ionosphere.tec_grid_samples(handle)
        assert {first.time_scale, second.time_scale} == {"UTC", "UTC"}
      end

      # TT - UTC is never a whole second, and TCG, TDB and TCB have no exact
      # whole UTC second, so those epochs are refused rather than rounded.
      for scale <- ~w(TT TCG TDB TCB) do
        samples = j2000_nanos_samples([0, 7_200_000_000_000], time_scale: scale)
        assert {:error, _reason} = Ionosphere.from_samples(samples)
      end
    end

    test "a scale the boundary does not know is refused, not replaced with a default" do
      samples = j2000_nanos_samples([0, 7_200_000_000_000], time_scale: "XYZ")

      # The boundary refuses the epoch field; the message is the decoder's, since
      # the map decode reports the field it could not read rather than the
      # reason the scale was refused.
      assert {:error, _reason} = Ionosphere.from_samples(samples)
    end

    test "a split Julian date the core refuses keeps the core's field and reason" do
      samples = %{
        whole_sphere_samples()
        | map_epochs: [
            Epoch.julian_date("UTC", 2_459_024.0, 1.5),
            utc_epoch({{2020, 6, 24}, {2, 0, 0}})
          ]
      }

      assert {:error, {:invalid_field, "fraction", "must be within one residual day"}} =
               Ionosphere.from_samples(samples)
    end
  end

  describe "civil epochs" do
    test "a civil epoch is the split Julian date of that calendar instant" do
      assert {:ok, %Epoch{time_scale: "UTC", jd_whole: 2_459_024.5, jd_fraction: +0.0, j2000_nanos: nil}} =
               Epoch.from_civil("UTC", {{2020, 6, 24}, {0, 0, 0}})

      assert {:ok, %Epoch{jd_whole: 2_459_024.5, jd_fraction: +0.0}} =
               Epoch.from_civil("UTC", ~N[2020-06-24 00:00:00])
    end

    test "a fractional second is carried into the fraction, the same from either form" do
      assert {:ok, %Epoch{} = from_tuple} = Epoch.from_civil("TAI", {{2020, 6, 24}, {0, 0, 30.5}})
      assert {:ok, %Epoch{} = from_naive} = Epoch.from_civil("TAI", ~N[2020-06-24 00:00:30.500000])

      assert from_tuple == from_naive
      assert from_tuple.jd_fraction > 0.0
    end

    test "a calendar field that is not an integer is named rather than raising" do
      # Elixir's `/` always gives a float. Unchecked, this hour reaches the
      # shared calendar helper's 32-bit parameter as `:badarg`, which raises
      # `ArgumentError` naming no field.
      assert {:error, {:invalid_epoch_field, :hour, 2.0}} =
               Epoch.from_civil("UTC", {{2020, 6, 24}, {7200 / 3600, 0, 0}})

      assert {:error, {:invalid_epoch_field, :month, 6.0}} =
               Epoch.from_civil("UTC", {{2020, 6.0, 24}, {0, 0, 0}})

      assert {:error, {:invalid_epoch_field, :second, :noon}} =
               Epoch.from_civil("UTC", {{2020, 6, 24}, {12, 0, :noon}})
    end

    test "an integer past the range its field carries is named with the field" do
      assert {:error, {:value_out_of_range, :year, 3_000_000_000}} =
               Epoch.from_civil("UTC", {{3_000_000_000, 1, 1}, {0, 0, 0}})

      assert {:error, {:value_out_of_range, :minute, -3_000_000_000}} =
               Epoch.from_civil("UTC", {{2020, 6, 24}, {0, -3_000_000_000, 0}})

      # A second no double holds; unchecked, the helper's own division raises
      # `ArithmeticError`.
      assert {:error, {:value_out_of_range, :second, @oversized}} =
               Epoch.from_civil("UTC", {{2020, 6, 24}, {0, 0, @oversized}})
    end

    test "a NaiveDateTime past the 32-bit year is refused as the tuple holding the same year is" do
      assert {:error, {:value_out_of_range, :year, 3_000_000_000}} =
               Epoch.from_civil("UTC", naive_past_i32_year())
    end
  end

  describe "batch rows keep their own outcome" do
    setup do
      {:ok, handle} = Ionosphere.from_samples(whole_sphere_samples())
      {:ok, handle: handle}
    end

    test "a sub-second epoch fails its own row and the others are still evaluated", %{handle: handle} do
      requests = [
        SlantRequest.new(45.0, 10.0, 60.0, 60.0, {{2020, 6, 24}, {1, 0, 0}}, @l1_hz),
        SlantRequest.new(45.0, 10.0, 60.0, 60.0, ~N[2020-06-24 01:00:00.500], @l1_hz),
        SlantRequest.new(-20.0, 140.0, 300.0, 30.0, {{2020, 6, 24}, {1, 30, 0}}, @l1_hz)
      ]

      assert {:ok, rows} = Ionosphere.ionex_slant_batch(handle, requests)
      assert length(rows) == 3

      assert [
               {:ok, %SlantEvaluation{delay_m: first}},
               {:error, :non_integer_second_epoch},
               {:ok, %SlantEvaluation{delay_m: third}}
             ] = rows

      assert first > 0.0
      assert third > 0.0
    end

    test "a receiver the frame refuses fails its own row", %{handle: handle} do
      requests = [
        SlantRequest.new(45.0, 200.0, 60.0, 60.0, {{2020, 6, 24}, {1, 0, 0}}, @l1_hz),
        SlantRequest.new(45.0, 10.0, 60.0, 60.0, {{2020, 6, 24}, {1, 0, 0}}, @l1_hz)
      ]

      assert {:ok, rows} = Ionosphere.ionex_slant_batch(handle, requests)

      assert [
               {:error, {:invalid_field, "lon_rad", "must be in [-pi, pi]"}},
               {:ok, %SlantEvaluation{}}
             ] = rows
    end

    test "a field that is not a number fails its own row, naming the field and the value", %{handle: handle} do
      bad = %SlantRequest{
        lat_deg: :north,
        lon_deg: 10.0,
        azimuth_deg: 60.0,
        elevation_deg: 60.0,
        epoch: {{2020, 6, 24}, {1, 0, 0}},
        frequency_hz: @l1_hz
      }

      requests = [
        bad,
        SlantRequest.new(45.0, 10.0, 60.0, 60.0, {{2020, 6, 24}, {1, 0, 0}}, @l1_hz)
      ]

      assert {:ok, rows} = Ionosphere.ionex_slant_batch(handle, requests)

      assert [
               {:error, {:invalid_request_field, :lat_deg, :north}},
               {:ok, %SlantEvaluation{}}
             ] = rows
    end

    test "a calendar field past the boundary's range fails its own row", %{handle: handle} do
      requests = [
        SlantRequest.new(45.0, 10.0, 60.0, 60.0, {{2020, 6, 24}, {1, 0, 0}}, @l1_hz),
        SlantRequest.new(45.0, 10.0, 60.0, 60.0, {{3_000_000_000, 1, 1}, {0, 0, 0}}, @l1_hz)
      ]

      assert {:ok, rows} = Ionosphere.ionex_slant_batch(handle, requests)

      assert [
               {:ok, %SlantEvaluation{}},
               {:error, {:value_out_of_range, :year, 3_000_000_000}}
             ] = rows
    end

    test "a NaiveDateTime past the 32-bit year fails its own row, keeping both neighbours", %{handle: handle} do
      # An ordinary `NaiveDateTime` with a year the shared calendar helper has no
      # 32-bit integer for. Unchecked, it reaches the boundary as `:badarg`,
      # which raises `ArgumentError` out of the conversion of the whole batch.
      far = naive_past_i32_year()
      naive = ~N[2020-06-24 01:00:00]
      tuple = {{2020, 6, 24}, {1, 30, 0}}

      requests = [
        SlantRequest.new(45.0, 10.0, 60.0, 60.0, naive, @l1_hz),
        SlantRequest.new(45.0, 10.0, 60.0, 60.0, far, @l1_hz),
        SlantRequest.new(-20.0, 140.0, 300.0, 30.0, tuple, @l1_hz)
      ]

      assert {:ok, rows} = Ionosphere.ionex_slant_batch(handle, requests)
      assert length(rows) == 3

      assert [
               {:ok, %SlantEvaluation{delay_m: first}},
               {:error, {:value_out_of_range, :year, 3_000_000_000}},
               {:ok, %SlantEvaluation{delay_m: third}}
             ] = rows

      # Each neighbour holds the value its own scalar call gives, so neither was
      # dropped nor took another row's result.
      assert {:ok, %SlantEvaluation{delay_m: ^first}} =
               Ionosphere.ionex_slant_evaluation(handle, 45.0, 10.0, 60.0, 60.0, naive, @l1_hz)

      assert {:ok, %SlantEvaluation{delay_m: ^third}} =
               Ionosphere.ionex_slant_evaluation(handle, -20.0, 140.0, 300.0, 30.0, tuple, @l1_hz)

      # The scalar calls refuse it the same way, and the same as the tuple
      # holding the same year.
      assert {:error, {:value_out_of_range, :year, 3_000_000_000}} =
               Ionosphere.ionex_slant_delay(handle, 45.0, 10.0, 60.0, 60.0, far, @l1_hz)

      assert {:error, {:value_out_of_range, :year, 3_000_000_000}} =
               Ionosphere.ionex_slant_evaluation(handle, 45.0, 10.0, 60.0, 60.0, far, @l1_hz)

      assert {:error, {:value_out_of_range, :year, 3_000_000_000}} =
               Ionosphere.ionex_slant_delay(
                 handle,
                 45.0,
                 10.0,
                 60.0,
                 60.0,
                 {{3_000_000_000, 1, 1}, {0, 0, 0}},
                 @l1_hz
               )
    end

    test "an integer second no double holds fails its own row", %{handle: handle} do
      epoch = {{2020, 6, 24}, {1, 0, 0}}
      huge = {{2020, 6, 24}, {1, 0, @oversized}}

      requests = [
        SlantRequest.new(45.0, 10.0, 60.0, 60.0, huge, @l1_hz),
        SlantRequest.new(45.0, 10.0, 60.0, 60.0, epoch, @l1_hz)
      ]

      assert {:ok, rows} = Ionosphere.ionex_slant_batch(handle, requests)

      assert [
               {:error, {:value_out_of_range, :second, @oversized}},
               {:ok, %SlantEvaluation{}}
             ] = rows

      assert {:error, {:value_out_of_range, :second, @oversized}} =
               Ionosphere.ionex_slant_delay(handle, 45.0, 10.0, 60.0, 60.0, huge, @l1_hz)
    end

    test "a calendar field that is not an integer fails its own row, keeping both neighbours", %{handle: handle} do
      # Elixir's `/` always gives a float, so an hour arrived at by division is
      # an ordinary producer's value. It has no 32-bit integer to be read onto:
      # unchecked it reaches the boundary as `:badarg`, which raises
      # `ArgumentError` out of the conversion of the whole batch and so loses
      # every other row's result.
      epoch = {{2020, 6, 24}, {1, 0, 0}}
      good = SlantRequest.new(45.0, 10.0, 60.0, 60.0, epoch, @l1_hz)
      divided = {{2020, 6, 24}, {3600 / 3600, 0, 0}}

      requests = [good, SlantRequest.new(45.0, 10.0, 60.0, 60.0, divided, @l1_hz), good]

      assert {:ok, rows} = Ionosphere.ionex_slant_batch(handle, requests)
      assert length(rows) == 3

      assert [
               {:ok, %SlantEvaluation{delay_m: first}},
               {:error, {:invalid_epoch_field, :hour, 1.0}},
               {:ok, %SlantEvaluation{delay_m: third}}
             ] = rows

      # Both neighbours are the same request, and both hold the value the scalar
      # call gives it, so neither was dropped nor took the other's result.
      assert {:ok, scalar} =
               Ionosphere.ionex_slant_evaluation(handle, 45.0, 10.0, 60.0, 60.0, epoch, @l1_hz)

      assert first == scalar.delay_m
      assert third == scalar.delay_m

      # The scalar calls refuse the same epoch the same way, and a fractional
      # second stays the distinct refusal of the axis itself rather than being
      # folded into this one.
      assert {:error, {:invalid_epoch_field, :hour, 1.0}} =
               Ionosphere.ionex_slant_delay(handle, 45.0, 10.0, 60.0, 60.0, divided, @l1_hz)

      assert {:error, {:invalid_epoch_field, :minute, 0.5}} =
               Ionosphere.ionex_slant_evaluation(
                 handle,
                 45.0,
                 10.0,
                 60.0,
                 60.0,
                 {{2020, 6, 24}, {1, 0.5, 0}},
                 @l1_hz
               )

      assert {:error, :non_integer_second_epoch} =
               Ionosphere.ionex_slant_delay(
                 handle,
                 45.0,
                 10.0,
                 60.0,
                 60.0,
                 {{2020, 6, 24}, {1, 0, 0.5}},
                 @l1_hz
               )
    end

    test "an integer no double can hold fails its own row, keeping the rows on either side", %{handle: handle} do
      # Elixir carries this integer exactly; an f64 has no value for it, and
      # dividing it raises rather than producing one. It is that row's refusal,
      # so the conversion of the batch it sits in still reaches the rows after
      # it.
      oversized = Integer.pow(10, 400)
      epoch = {{2020, 6, 24}, {1, 0, 0}}

      requests = [
        SlantRequest.new(45.0, 10.0, 60.0, 60.0, epoch, @l1_hz),
        SlantRequest.new(oversized, 10.0, 60.0, 60.0, epoch, @l1_hz),
        SlantRequest.new(-20.0, 140.0, 300.0, 30.0, {{2020, 6, 24}, {1, 30, 0}}, @l1_hz)
      ]

      assert {:ok, rows} = Ionosphere.ionex_slant_batch(handle, requests)
      assert length(rows) == 3

      assert [
               {:ok, %SlantEvaluation{delay_m: first}},
               {:error, {:value_out_of_range, :lat_deg, ^oversized}},
               {:ok, %SlantEvaluation{delay_m: third}}
             ] = rows

      assert first > 0.0
      assert third > 0.0

      # The request itself exists to be refused: `new/6` keeps the number it was
      # given rather than converting it on the way in.
      assert %SlantRequest{lat_deg: ^oversized} = Enum.at(requests, 1)

      # The scalar and policy calls refuse the same value the same way, and
      # neither raises out of its own conversion.
      assert {:error, {:value_out_of_range, :frequency_hz, ^oversized}} =
               Ionosphere.ionex_slant_delay(handle, 45.0, 10.0, 60.0, 60.0, epoch, oversized)

      assert {:error, {:value_out_of_range, :lat_deg, ^oversized}} =
               Ionosphere.ionex_slant_evaluation(handle, oversized, 10.0, 60.0, 60.0, epoch, @l1_hz)
    end

    test "an ordinary integer argument is read onto the boundary's double", %{handle: handle} do
      epoch = {{2020, 6, 24}, {1, 0, 0}}

      assert {:ok, from_integers} = Ionosphere.ionex_slant_delay(handle, 45, 10, 60, 60, epoch, @l1_hz)
      assert {:ok, from_floats} = Ionosphere.ionex_slant_delay(handle, 45.0, 10.0, 60.0, 60.0, epoch, @l1_hz)
      assert from_integers == from_floats

      assert {:ok, rows} = Ionosphere.ionex_slant_batch(handle, [SlantRequest.new(45, 10, 60, 60, epoch, @l1_hz)])
      assert [{:ok, %SlantEvaluation{delay_m: ^from_floats}}] = rows
    end

    test "an argument that is not a number is refused rather than raising", %{handle: handle} do
      epoch = {{2020, 6, 24}, {1, 0, 0}}

      assert {:error, {:invalid_request_field, :elevation_deg, :overhead}} =
               Ionosphere.ionex_slant_delay(handle, 45.0, 10.0, 60.0, :overhead, epoch, @l1_hz)

      assert {:error, {:invalid_request_field, :lon_deg, nil}} =
               Ionosphere.ionex_slant_evaluation(handle, 45.0, nil, 60.0, 60.0, epoch, @l1_hz)
    end

    test "a row that is not a request fails as that row", %{handle: handle} do
      requests = [
        SlantRequest.new(45.0, 10.0, 60.0, 60.0, {{2020, 6, 24}, {1, 0, 0}}, @l1_hz),
        %{lat_deg: 45.0}
      ]

      assert {:ok, [{:ok, %SlantEvaluation{}}, {:error, :bad_slant_request}]} =
               Ionosphere.ionex_slant_batch(handle, requests)
    end

    test "several bad rows keep their places among the good ones", %{handle: handle} do
      good = SlantRequest.new(45.0, 10.0, 60.0, 60.0, {{2020, 6, 24}, {1, 0, 0}}, @l1_hz)

      requests = [
        good,
        SlantRequest.new(45.0, 200.0, 60.0, 60.0, {{2020, 6, 24}, {1, 0, 0}}, @l1_hz),
        good,
        SlantRequest.new(45.0, 10.0, 60.0, 60.0, ~N[2020-06-24 01:00:00.250], @l1_hz),
        good
      ]

      assert {:ok, rows} = Ionosphere.ionex_slant_batch(handle, requests)
      assert length(rows) == 5

      assert [
               {:ok, %SlantEvaluation{}},
               {:error, {:invalid_field, "lon_rad", _}},
               {:ok, %SlantEvaluation{}},
               {:error, :non_integer_second_epoch},
               {:ok, %SlantEvaluation{}}
             ] = rows

      # The evaluated rows are the same values the scalar call gives, so no row
      # took another row's result.
      assert {:ok, scalar} =
               Ionosphere.ionex_slant_evaluation(handle, 45.0, 10.0, 60.0, 60.0, {{2020, 6, 24}, {1, 0, 0}}, @l1_hz)

      for index <- [0, 2, 4] do
        assert {:ok, %SlantEvaluation{delay_m: delay_m}} = Enum.at(rows, index)
        assert delay_m == scalar.delay_m
      end
    end

    test "a policy the binding cannot read fails the whole call, not a row", %{handle: handle} do
      requests = [SlantRequest.new(45.0, 10.0, 60.0, 60.0, {{2020, 6, 24}, {1, 0, 0}}, @l1_hz)]

      assert {:error, {:invalid_policy_value, :coverage, :nearest}} =
               Ionosphere.ionex_slant_batch(handle, requests, coverage: :nearest)
    end
  end

  describe "option and key validation" do
    test "a policy key stated twice is refused rather than collapsed" do
      assert {:error, {:duplicate_policy_key, :coverage}} =
               SlantPolicy.new(coverage: :nearest, coverage: :hold)
    end

    test "a key whose name is nil is an unknown key, not an absent one" do
      assert {:error, {:unknown_policy_key, nil}} = SlantPolicy.new(%{nil => :hold})
      assert {:error, {:unknown_policy_key, "coverage"}} = SlantPolicy.new(%{"coverage" => :hold})
    end

    test "an options container that is not a keyword list is refused" do
      assert {:error, :bad_slant_policy} = SlantPolicy.new([:hold])
    end

    test "an unknown TecGrid option key is refused rather than ignored" do
      assert {:ok, grid} = asymmetric_grid()

      assert {:error, {:unknown_option_key, :missing_node}} =
               TecGrid.vtec_at_pierce_point(grid, 0, 10.0, 2.5, missing_node: :renormalize)

      assert {:error, {:unknown_option_key, nil}} =
               TecGrid.vtec_at_pierce_point(grid, 0, 10.0, 2.5, [{nil, :renormalize}])
    end

    test "a TecGrid option stated twice is refused rather than collapsed" do
      assert {:ok, grid} = asymmetric_grid()

      assert {:error, {:duplicate_option_key, :missing_nodes}} =
               TecGrid.vtec_at_pierce_point(grid, 0, 10.0, 2.5, missing_nodes: :nearest, missing_nodes: :strict)
    end

    test "a malformed TecGrid option container is refused" do
      assert {:ok, grid} = asymmetric_grid()

      assert {:error, {:invalid_options, %{missing_nodes: :strict}}} =
               TecGrid.vtec_at_pierce_point(grid, 0, 10.0, 2.5, %{missing_nodes: :strict})

      assert {:error, {:invalid_options, [:strict]}} =
               TecGrid.vtec_at_pierce_point(grid, 0, 10.0, 2.5, [:strict])
    end

    test "a header count past the unsigned 32-bit range is named with its value" do
      samples = whole_sphere_samples(header: Header.new(:none, interval_s: 4_294_967_296))

      assert {:error, {:value_out_of_range, :interval_s, 4_294_967_296}} =
               Ionosphere.from_samples(samples)

      negative = whole_sphere_samples(header: Header.new(:none, station_count: -1))
      assert {:error, {:value_out_of_range, :station_count, -1}} = Ionosphere.from_samples(negative)

      wrong_type = whole_sphere_samples(header: Header.new(:none, station_count: "three"))

      assert {:error, {:invalid_header_field, :station_count, "three"}} =
               Ionosphere.from_samples(wrong_type)
    end

    test "an exponent past the signed 32-bit range is named with its value" do
      samples = %{whole_sphere_samples() | exponent: 2_147_483_648}

      assert {:error, {:value_out_of_range, :exponent, 2_147_483_648}} =
               Ionosphere.from_samples(samples)
    end

    test "a TecGrid axis entry that is not a number names the field and the value" do
      assert {:error, {:invalid_grid_field, :epochs_ns, :now}} =
               TecGrid.new([:now, 1.0e9], [0.0, 10.0], [0.0, 40.0], [0.0, 4.0, 100.0, 104.0, 0.0, 4.0, 100.0, 104.0])

      assert {:error, {:invalid_grid_field, :values, :missing}} =
               TecGrid.new([0.0, 1.0e9], [0.0, 10.0], [0.0, 40.0], [
                 :missing,
                 4.0,
                 100.0,
                 104.0,
                 0.0,
                 4.0,
                 100.0,
                 104.0
               ])
    end
  end

  describe "skipped records" do
    test "a product built from samples has skipped nothing" do
      assert {:ok, handle} = Ionosphere.from_samples(whole_sphere_samples())
      assert {:ok, 0} = Ionosphere.skipped_records(handle)
    end

    test "a block the reader does not support is counted, and is not a warning" do
      aux =
        [
          ionex_record("", "START OF AUX DATA"),
          ionex_record("G01  -1.234  0.567", "PRN / BIAS / RMS"),
          ionex_record("", "END OF AUX DATA")
        ]

      lines = String.split(@ionex, "\n")
      index = Enum.find_index(lines, &String.contains?(&1, "END OF HEADER"))
      {header, body} = Enum.split(lines, index + 1)
      injected = Enum.join(header ++ aux ++ body, "\n")

      assert {:ok, %ParseResult{handle: handle, warnings: warnings, skipped_records: 1}} =
               Ionosphere.parse_ionex_with_warnings(injected)

      assert {:ok, 1} = Ionosphere.skipped_records(handle)

      # The skip raises no finding of its own: the warnings are the ones the
      # clean fixture already reports.
      assert {:ok, %ParseResult{warnings: clean_warnings, skipped_records: 0}} =
               Ionosphere.parse_ionex_with_warnings(@ionex)

      assert Enum.map(warnings, & &1.tag) == Enum.map(clean_warnings, & &1.tag)
    end
  end

  describe "parse findings by variant" do
    test "a declared first-map epoch that disagrees with the maps carries both epochs" do
      text =
        with_header_records(@ionex, [
          ionex_record("  2020     6    24     1     0     0", "EPOCH OF FIRST MAP")
        ])

      assert {:ok, %ParseResult{warnings: warnings}} = Ionosphere.parse_ionex_with_warnings(text)

      assert %Warning{
               tag: :epoch_mismatch,
               label: "EPOCH OF FIRST MAP",
               line: line,
               declared_epoch: %Epoch{} = declared,
               maps_epoch: %Epoch{} = maps
             } = Enum.find(warnings, &(&1.tag == :epoch_mismatch))

      assert is_integer(line)
      assert declared != maps
    end

    test "a declared interval that disagrees with the map spacing carries both" do
      text = with_header_records(@ionex, [ionex_record("  3600", "INTERVAL")])

      assert {:ok, %ParseResult{warnings: warnings}} = Ionosphere.parse_ionex_with_warnings(text)

      assert %Warning{tag: :interval_mismatch, declared_s: 3600, map_number: 2, spacing_s: 7200} =
               Enum.find(warnings, &(&1.tag == :interval_mismatch))
    end

    test "a value field that is not a number names the band and the node" do
      text = String.replace(@ionex, "  100  101", "  nan  101", global: false)
      refute text == @ionex

      assert {:ok, %ParseResult{warnings: warnings}} = Ionosphere.parse_ionex_with_warnings(text)

      assert %Warning{tag: :not_a_number_value, kind: :tec, map_number: 1, lat_deg: 60.0, lon_deg: -180.0} =
               Enum.find(warnings, &(&1.tag == :not_a_number_value))
    end

    test "a version record that is not first names the line it is on" do
      [version, maps_in_file | rest] = String.split(@ionex, "\n")
      text = Enum.join([maps_in_file, version | rest], "\n")

      assert {:ok, %ParseResult{warnings: warnings}} = Ionosphere.parse_ionex_with_warnings(text)

      assert %Warning{tag: :version_record_not_first, line: 2} =
               Enum.find(warnings, &(&1.tag == :version_record_not_first))
    end

    test "an exponent carried from one map into the next names both maps' lines" do
      lines = String.split(@ionex, "\n")
      index = Enum.find_index(lines, &String.contains?(&1, "START OF TEC MAP"))
      {before_map, rest} = Enum.split(lines, index + 1)
      text = Enum.join(before_map ++ [ionex_record("    -2", "EXPONENT")] ++ rest, "\n")

      assert {:ok, %ParseResult{warnings: warnings}} = Ionosphere.parse_ionex_with_warnings(text)

      assert %Warning{
               tag: :exponent_carried_into_map,
               kind: :tec,
               map_number: 2,
               exponent: -2,
               set_by_line: set_by_line
             } = Enum.find(warnings, &(&1.tag == :exponent_carried_into_map))

      assert is_integer(set_by_line)
    end
  end

  describe "mapping codes that no IONEX field writes" do
    test "a declared blank code is held and read back, and refused by the writer" do
      assert {:ok, handle} = Ionosphere.from_samples(whole_sphere_samples(header: Header.new("")))

      # The product keeps the declaration it was given, which is not `nil`.
      assert {:ok, %Header{mapping_function: ""}} = Ionosphere.ionex_header(handle)

      # Writing it is where it fails: the reader would read a blank code back as
      # no declaration at all, so the writer refuses rather than writing
      # something the file does not mean.
      assert {:error, {:invalid_input, message}} = Ionosphere.ionex_to_string(handle)
      assert message =~ "MAPPING FUNCTION"
    end

    test "a code longer than the record's field is refused by the writer" do
      assert {:ok, handle} = Ionosphere.from_samples(whole_sphere_samples(header: Header.new("MSLM12")))
      assert {:ok, %Header{mapping_function: "MSLM12"}} = Ionosphere.ionex_header(handle)
      assert {:error, {:invalid_input, message}} = Ionosphere.ionex_to_string(handle)
      assert message =~ "MAPPING FUNCTION"
    end

    test "a four-character code the spec does not name writes and reads back" do
      assert {:ok, handle} = Ionosphere.from_samples(whole_sphere_samples(header: Header.new("MSLM")))
      assert {:ok, text} = Ionosphere.ionex_to_string(handle)
      assert {:ok, reparsed} = Ionosphere.parse_ionex(text)
      assert {:ok, %Header{mapping_function: "MSLM"}} = Ionosphere.ionex_header(reparsed)
    end
  end

  describe "RMS and height map presence" do
    test "absent RMS maps and RMS maps present with every node absent are different" do
      all_nil = [[[nil, nil], [nil, nil]], [[nil, nil], [nil, nil]]]

      assert {:ok, absent_handle} = Ionosphere.from_samples(whole_sphere_samples(rms_maps: nil))
      assert {:ok, all_nil_handle} = Ionosphere.from_samples(whole_sphere_samples(rms_maps: all_nil))

      assert {:ok, %TecGridSamples{rms_maps: nil}} = Ionosphere.tec_grid_samples(absent_handle)
      assert {:ok, %TecGridSamples{rms_maps: ^all_nil}} = Ionosphere.tec_grid_samples(all_nil_handle)

      # The two stay distinct through the public round trip, not only in the
      # handle: a product with no RMS map stack writes no RMS records at all,
      # and one whose stack gives no value at any node writes the records with
      # every node at the file's missing value.
      assert {:ok, absent_text} = Ionosphere.ionex_to_string(absent_handle)
      assert {:ok, all_nil_text} = Ionosphere.ionex_to_string(all_nil_handle)

      refute absent_text =~ "START OF RMS MAP"
      assert all_nil_text =~ "START OF RMS MAP"

      assert {:ok, absent_reparsed} = Ionosphere.parse_ionex(absent_text)
      assert {:ok, all_nil_reparsed} = Ionosphere.parse_ionex(all_nil_text)

      assert {:ok, %TecGridSamples{rms_maps: nil}} = Ionosphere.tec_grid_samples(absent_reparsed)
      assert {:ok, %TecGridSamples{rms_maps: ^all_nil}} = Ionosphere.tec_grid_samples(all_nil_reparsed)
    end

    test "an RMS map holding values survives the round trip" do
      rms = [[[0.5, 0.6], [0.7, nil]], [[0.8, 0.9], [1.0, 1.1]]]
      assert {:ok, handle} = Ionosphere.from_samples(whole_sphere_samples(rms_maps: rms))
      assert {:ok, %TecGridSamples{rms_maps: ^rms}} = Ionosphere.tec_grid_samples(handle)
    end

    test "absent height maps and height maps present with every node absent stay different" do
      all_nil = [[[nil, nil], [nil, nil]], [[nil, nil], [nil, nil]]]

      assert {:ok, absent_handle} = Ionosphere.from_samples(whole_sphere_samples(height_maps: nil))
      assert {:ok, all_nil_handle} = Ionosphere.from_samples(whole_sphere_samples(height_maps: all_nil))

      assert {:ok, %TecGridSamples{height_maps: nil}} = Ionosphere.tec_grid_samples(absent_handle)
      assert {:ok, %TecGridSamples{height_maps: ^all_nil}} = Ionosphere.tec_grid_samples(all_nil_handle)

      # The two also behave differently: a product whose height maps give no
      # value has no single-layer height to ride on.
      epoch = {{2020, 6, 24}, {1, 0, 0}}
      assert {:ok, _delay_m} = Ionosphere.ionex_slant_delay(absent_handle, 45.0, 10.0, 60.0, 60.0, epoch, @l1_hz)

      assert {:error, {:height_not_available, %HeightNode{}}} =
               Ionosphere.ionex_slant_delay(all_nil_handle, 45.0, 10.0, 60.0, 60.0, epoch, @l1_hz)
    end
  end

  describe "a reference the boundary cannot read as this resource" do
    test "every IONEX entry names the resource it expected rather than raising" do
      # A TEC-grid handle is a reference, so it passes every guard here and is
      # refused by the boundary, which reports `:badarg` and so raises
      # `ArgumentError` - not the `ErlangError` a field decoder raises.
      assert {:ok, %TecGrid{handle: grid_handle}} = asymmetric_grid()
      epoch = {{2020, 6, 24}, {1, 0, 0}}

      assert {:error, {:invalid_resource, :ionex}} = Ionosphere.ionex_header(grid_handle)
      assert {:error, {:invalid_resource, :ionex}} = Ionosphere.skipped_records(grid_handle)
      assert {:error, {:invalid_resource, :ionex}} = Ionosphere.ionex_to_string(grid_handle)
      assert {:error, {:invalid_resource, :ionex}} = Ionosphere.tec_grid_samples(grid_handle)
      assert {:error, {:invalid_resource, :ionex}} = Ionosphere.tec_samples(grid_handle)

      assert {:error, {:invalid_resource, :ionex}} =
               Ionosphere.ionex_slant_delay(grid_handle, 45.0, 10.0, 60.0, 60.0, epoch, @l1_hz)

      assert {:error, {:invalid_resource, :ionex}} =
               Ionosphere.ionex_slant_evaluation(grid_handle, 45.0, 10.0, 60.0, 60.0, epoch, @l1_hz)

      # The handle is not a property of one row, so it is the whole batch's
      # failure - and it is still a returned value, not an exception.
      assert {:error, {:invalid_resource, :ionex}} =
               Ionosphere.ionex_slant_batch(grid_handle, [
                 SlantRequest.new(45.0, 10.0, 60.0, 60.0, epoch, @l1_hz)
               ])
    end

    test "the standalone grid names its own resource the same way" do
      assert {:ok, ionex_handle} = Ionosphere.from_samples(whole_sphere_samples())

      assert {:error, {:invalid_resource, :tec_grid}} = TecGrid.epochs_ns(ionex_handle)
      assert {:error, {:invalid_resource, :tec_grid}} = TecGrid.latitudes_deg(ionex_handle)
      assert {:error, {:invalid_resource, :tec_grid}} = TecGrid.longitudes_deg(ionex_handle)
      assert {:error, {:invalid_resource, :tec_grid}} = TecGrid.values(ionex_handle)

      assert {:error, {:invalid_resource, :tec_grid}} =
               TecGrid.vtec_at_pierce_point(ionex_handle, 0, 10.0, 2.5)
    end

    test "a value that is no handle at all keeps its own refusal" do
      # `{:bad_tec_grid, value}` is this binding's own check, which happens
      # before any call, and stays distinct from the boundary's refusal of a
      # reference it cannot read.
      assert {:error, {:bad_tec_grid, :grid}} = TecGrid.epochs_ns(:grid)
      assert {:error, {:bad_tec_grid, nil}} = TecGrid.vtec_at_pierce_point(nil, 0, 10.0, 2.5)
    end
  end

  describe "an integer no double holds" do
    test "a whole-grid axis entry is named with the entry, not with the axis" do
      samples = %{whole_sphere_samples() | lat_nodes_deg: [@oversized, -90.0]}

      assert {:error, {:value_out_of_range, :lat_nodes_deg, @oversized}} =
               Ionosphere.from_samples(samples)

      assert {:error, {:value_out_of_range, :lon_nodes_deg, @oversized}} =
               Ionosphere.from_samples(%{whole_sphere_samples() | lon_nodes_deg: [-180.0, @oversized]})
    end

    test "a whole-grid scalar field is named with its own field" do
      assert {:error, {:value_out_of_range, :shell_height_km, @oversized}} =
               Ionosphere.from_samples(%{whole_sphere_samples() | shell_height_km: @oversized})

      assert {:error, {:value_out_of_range, :base_radius_km, @oversized}} =
               Ionosphere.from_samples(%{whole_sphere_samples() | base_radius_km: @oversized})

      assert {:error, {:value_out_of_range, :dlat_deg, @oversized}} =
               Ionosphere.from_samples(%{whole_sphere_samples() | dlat_deg: @oversized})
    end

    test "a whole-grid node value is named with the band it sits in" do
      assert {:error, {:value_out_of_range, :tec_maps, @oversized}} =
               Ionosphere.from_samples(
                 whole_sphere_samples(
                   tec_maps: [
                     [[1.0, 2.0], [3.0, 4.0]],
                     [[@oversized, 6.0], [7.0, 8.0]]
                   ]
                 )
               )

      assert {:error, {:value_out_of_range, :rms_maps, @oversized}} =
               Ionosphere.from_samples(
                 whole_sphere_samples(rms_maps: [[[0.5, 0.6], [0.7, nil]], [[0.8, 0.9], [1.0, @oversized]]])
               )
    end

    test "a node-sample field and a build radius are each named, and the header's records too" do
      assert {:ok, handle} = Ionosphere.from_samples(whole_sphere_samples())
      assert {:ok, [first | rest]} = Ionosphere.tec_samples(handle)

      assert {:error, {:value_out_of_range, :shell_height_km, @oversized}} =
               Ionosphere.from_node_samples([first | rest], @oversized, 6371.0, -1, Header.new(:none))

      assert {:error, {:value_out_of_range, :base_radius_km, @oversized}} =
               Ionosphere.from_node_samples([first | rest], 450.0, @oversized, -1, Header.new(:none))

      # The core holds `EXPONENT` as a signed 32-bit integer; one past either
      # end is named before the call, with its value, as far past it as the
      # caller goes.
      for exponent <- [2_147_483_648, -2_147_483_649, @oversized] do
        assert {:error, {:value_out_of_range, :exponent, ^exponent}} =
                 Ionosphere.from_node_samples([first | rest], 450.0, 6371.0, exponent, Header.new(:none))
      end

      assert {:ok, _handle} =
               Ionosphere.from_node_samples([first | rest], 450.0, 6371.0, -2_147_483_648, Header.new(:none))

      assert {:error, {:value_out_of_range, :rms_tecu, @oversized}} =
               Ionosphere.from_node_samples(
                 [%{first | rms_tecu: @oversized} | rest],
                 450.0,
                 6371.0,
                 -1,
                 Header.new(:none)
               )

      assert {:error, {:value_out_of_range, :version, @oversized}} =
               Ionosphere.from_samples(whole_sphere_samples(header: Header.new(:none, version: @oversized)))
    end

    test "a standalone grid axis entry and node value are each named" do
      cells = [0.0, 4.0, 100.0, 104.0, 0.0, 4.0, 100.0, 104.0]

      assert {:error, {:value_out_of_range, :epochs_ns, @oversized}} =
               TecGrid.new([0.0, @oversized], [0.0, 10.0], [0.0, 40.0], cells)

      assert {:error, {:value_out_of_range, :latitudes_deg, @oversized}} =
               TecGrid.new([0.0, 1.0e9], [0.0, @oversized], [0.0, 40.0], cells)

      assert {:error, {:value_out_of_range, :values, @oversized}} =
               TecGrid.new([0.0, 1.0e9], [0.0, 10.0], [0.0, 40.0], [
                 @oversized,
                 4.0,
                 100.0,
                 104.0,
                 0.0,
                 4.0,
                 100.0,
                 104.0
               ])
    end

    test "a standalone grid query argument is named with its own field" do
      assert {:ok, grid} = asymmetric_grid()

      assert {:error, {:value_out_of_range, :lon_deg, @oversized}} =
               TecGrid.vtec_at_pierce_point(grid, 0, @oversized, 2.5)

      assert {:error, {:value_out_of_range, :lat_deg, @oversized}} =
               TecGrid.vtec_at_pierce_point(grid, 10, 10.0, @oversized)

      assert {:error, {:value_out_of_range, :unix_nanos, @oversized}} =
               TecGrid.vtec_at_pierce_point(grid, @oversized, 10.0, 2.5)
    end

    test "an ordinary integer argument is still read onto the boundary's double" do
      assert {:ok, grid} = asymmetric_grid()

      assert {:ok, %TecGrid.Evaluation{value: from_integers}} =
               TecGrid.vtec_at_pierce_point(grid, 0, 10, 2)

      assert {:ok, %TecGrid.Evaluation{value: from_floats}} =
               TecGrid.vtec_at_pierce_point(grid, 0, 10.0, 2.0)

      assert from_integers == from_floats

      # And an integer axis still builds the grid it did before the bound.
      assert {:ok, integer_axes} =
               TecGrid.new([0, 1_000_000_000], [0, 10], [0, 40], [
                 0.0,
                 4.0,
                 100.0,
                 104.0,
                 0.0,
                 4.0,
                 100.0,
                 104.0
               ])

      assert {:ok, [+0.0, 1.0e9]} = TecGrid.epochs_ns(integer_axes)
      assert {:ok, [+0.0, 10.0]} = TecGrid.latitudes_deg(integer_axes)
    end

    test "a grid field is not named as a request field" do
      # The slant surface names a bad field `:invalid_request_field`; the grid
      # surface has its own name for one, and neither borrows the other's.
      assert {:error, {:invalid_grid_field, :values, :missing}} =
               TecGrid.new([0.0, 1.0e9], [0.0, 10.0], [0.0, 40.0], [
                 :missing,
                 4.0,
                 100.0,
                 104.0,
                 0.0,
                 4.0,
                 100.0,
                 104.0
               ])

      assert {:error, {:invalid_grid_field, :shell_height_km, :high}} =
               Ionosphere.from_samples(%{whole_sphere_samples() | shell_height_km: :high})

      assert {:error, {:invalid_sample_field, :lat_deg, :north}} =
               Ionosphere.from_node_samples(
                 [%TecSample{epoch: Epoch.j2000_nanos("UTC", 0), lat_deg: :north, lon_deg: 0.0}],
                 450.0,
                 6371.0,
                 -1,
                 Header.new(:none)
               )
    end
  end
end
