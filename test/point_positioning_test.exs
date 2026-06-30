defmodule Sidereon.GNSS.PositioningTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.Geometry
  alias Sidereon.GNSS.Observables
  alias Sidereon.GNSS.Positioning
  alias Sidereon.GNSS.Positioning.Decode
  alias Sidereon.GNSS.Positioning.Solution
  alias Sidereon.GNSS.SP3

  @speed_of_light_m_s 299_792_458.0

  # End-to-end check of the Elixir -> NIF -> astrodynamics-gnss SPP path. The
  # observations, epoch parameters, atmosphere coefficients, and synthesized
  # receiver truth come from a committed known-truth trace fixture
  # (spp_trace_L2_tropo.json); the precise
  # ephemeris is the matching SP3 file. Bit-exact physics parity is asserted in
  # the crate's own test suite; here we only prove the full round trip recovers
  # the truth, so a sub-millimetre solver-agreement bound is the right bar.
  @sp3_path Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")
  @trace_path Path.join(__DIR__, "fixtures/spp_trace_L2_tropo.json")

  # The trace's epoch index 48 is 2020-06-24 12:00:00 GPST (DOY 176, noon).
  @epoch ~N[2020-06-24 12:00:00]

  # Solver-agreement bound (meters). The crate documents agreement to a few
  # nanometres; the public boundary adds only term encode/decode, so a
  # sub-millimetre bound is comfortable and proves the wiring is lossless.
  @agreement_bound_m 1.0e-3

  setup_all do
    trace = @trace_path |> File.read!() |> Jason.decode!()
    inputs = trace["fixture"]["inputs"]
    final = trace["fixture"]["final_solution"]

    observations =
      Enum.map(inputs["observations"], fn obs ->
        {obs["sat_id"], hex_to_float(obs["p_meas_m"])}
      end)

    {:ok,
     sp3: SP3.load!(@sp3_path),
     observations: observations,
     alpha: inputs["klobuchar_alpha"] |> Enum.map(&hex_to_float/1) |> List.to_tuple(),
     beta: inputs["klobuchar_beta"] |> Enum.map(&hex_to_float/1) |> List.to_tuple(),
     pressure_hpa: hex_to_float(inputs["met"]["pressure_hpa"]),
     temperature_k: hex_to_float(inputs["met"]["temperature_k"]),
     relative_humidity: hex_to_float(inputs["met"]["relative_humidity"]),
     truth_x: Enum.map(final["truth_x"], &hex_to_float/1),
     truth_rx_clock_s: hex_to_float(final["truth_rx_clock_s"]),
     reference_x: Enum.map(final["x"], &hex_to_float/1),
     reference_rx_clock_s: hex_to_float(final["rx_clock_s"]),
     initial_guess: trace["fixture"]["frozen"]["initial_guess_x0"] |> Enum.map(&hex_to_float/1) |> List.to_tuple()}
  end

  describe "solve/4 end-to-end" do
    test "recovers the synthesized receiver truth to sub-millimetre", ctx do
      assert {:ok, %Solution{} = sol} =
               Positioning.solve(ctx.sp3, ctx.observations, @epoch,
                 ionosphere: true,
                 troposphere: true,
                 klobuchar_alpha: ctx.alpha,
                 klobuchar_beta: ctx.beta,
                 pressure_hpa: ctx.pressure_hpa,
                 temperature_k: ctx.temperature_k,
                 relative_humidity: ctx.relative_humidity,
                 # The crate fixture's frozen initial guess.
                 initial_guess: {4_500_000.0, 500_000.0, 4_500_000.0, 0.0}
               )

      [tx, ty, tz, _tb] = ctx.truth_x

      assert_in_delta sol.position.x_m, tx, @agreement_bound_m
      assert_in_delta sol.position.y_m, ty, @agreement_bound_m
      assert_in_delta sol.position.z_m, tz, @agreement_bound_m

      # Clock bias agrees to the same length bound, expressed in seconds.
      c_m_s = 299_792_458.0
      assert_in_delta sol.rx_clock_s, ctx.truth_rx_clock_s, @agreement_bound_m / c_m_s

      assert sol.metadata.converged
      assert sol.metadata.ionosphere_applied
      assert sol.metadata.troposphere_applied

      # The solver's termination status is surfaced as an atom. For this fixture
      # the trust-region solve stops on the step tolerance after 7 iterations;
      # the value is deterministic, so pin it exactly rather than accepting any
      # known status.
      assert sol.metadata.status == :step_tolerance
      assert sol.metadata.iterations == 7
    end

    test "matches the crate's independent-solve reference byte-for-byte", ctx do
      # The fixture carries the converged reference solution the crate, the
      # Python binding, and the C binding all reproduce. Driving the public
      # `solve/4` through the calendar epoch (which derives the seconds-since-J2000,
      # second-of-day, and fractional day-of-year the crate consumes) must land on
      # that same reference, proving the Elixir boundary threads identical inputs
      # and the default policy with no per-binding drift. The bound is the
      # crate's own independent-solve agreement tolerance (1e-6 m); a regression
      # past it means the boundary or a committed fixture has fallen out of sync
      # with the core, not that the band should be widened.
      reference_bound_m = 1.0e-6

      assert {:ok, %Solution{} = sol} =
               Positioning.solve(ctx.sp3, ctx.observations, @epoch,
                 ionosphere: true,
                 troposphere: true,
                 klobuchar_alpha: ctx.alpha,
                 klobuchar_beta: ctx.beta,
                 pressure_hpa: ctx.pressure_hpa,
                 temperature_k: ctx.temperature_k,
                 relative_humidity: ctx.relative_humidity,
                 initial_guess: ctx.initial_guess
               )

      [rx, ry, rz, _b] = ctx.reference_x

      assert_in_delta sol.position.x_m, rx, reference_bound_m
      assert_in_delta sol.position.y_m, ry, reference_bound_m
      assert_in_delta sol.position.z_m, rz, reference_bound_m
      assert_in_delta sol.rx_clock_s, ctx.reference_rx_clock_s, reference_bound_m / @speed_of_light_m_s
    end

    test "surfaces per-system TDOP keyed by GNSS letter (A3)", ctx do
      assert {:ok, %Solution{} = sol} =
               Positioning.solve(ctx.sp3, ctx.observations, @epoch,
                 ionosphere: true,
                 troposphere: true,
                 klobuchar_alpha: ctx.alpha,
                 klobuchar_beta: ctx.beta,
                 pressure_hpa: ctx.pressure_hpa,
                 temperature_k: ctx.temperature_k,
                 relative_humidity: ctx.relative_humidity,
                 initial_guess: {4_500_000.0, 500_000.0, 4_500_000.0, 0.0}
               )

      # A GPS-only solve has exactly one clock, so system_tdops carries one
      # entry, keyed "G", and the reference system's value equals dop.tdop.
      assert is_map(sol.system_tdops)
      assert Map.keys(sol.system_tdops) == ["G"]
      assert sol.system_tdops["G"] == sol.dop.tdop
      assert sol.system_tdops["G"] > 0.0
    end

    test "accepts a sub-second receive epoch", ctx do
      # SPP receive time is a continuous f64 second, so a fractional epoch must
      # be accepted (not rejected as a non-integer-second epoch).
      epoch = ~N[2020-06-24 12:00:00.250000]

      assert {:ok, %Solution{}} =
               Positioning.solve(ctx.sp3, ctx.observations, epoch,
                 ionosphere: true,
                 troposphere: true,
                 klobuchar_alpha: ctx.alpha,
                 klobuchar_beta: ctx.beta,
                 pressure_hpa: ctx.pressure_hpa,
                 temperature_k: ctx.temperature_k,
                 relative_humidity: ctx.relative_humidity,
                 initial_guess: {4_500_000.0, 500_000.0, 4_500_000.0, 0.0}
               )
    end

    test "accepts a sub-second receive epoch given as a tuple", ctx do
      # The `{{y, m, d}, {h, min, s}}` epoch form must also carry a fractional
      # second, on the same footing as a NaiveDateTime.
      epoch = {{2020, 6, 24}, {12, 0, 0.25}}

      assert {:ok, %Solution{}} =
               Positioning.solve(ctx.sp3, ctx.observations, epoch,
                 ionosphere: true,
                 troposphere: true,
                 klobuchar_alpha: ctx.alpha,
                 klobuchar_beta: ctx.beta,
                 pressure_hpa: ctx.pressure_hpa,
                 temperature_k: ctx.temperature_k,
                 relative_humidity: ctx.relative_humidity,
                 initial_guess: {4_500_000.0, 500_000.0, 4_500_000.0, 0.0}
               )
    end

    test "returns geodetic, DOP, residuals and used satellites", ctx do
      assert {:ok, %Solution{} = sol} =
               Positioning.solve(ctx.sp3, ctx.observations, @epoch,
                 ionosphere: true,
                 troposphere: true,
                 klobuchar_alpha: ctx.alpha,
                 klobuchar_beta: ctx.beta,
                 pressure_hpa: ctx.pressure_hpa,
                 temperature_k: ctx.temperature_k,
                 relative_humidity: ctx.relative_humidity,
                 initial_guess: {4_500_000.0, 500_000.0, 4_500_000.0, 0.0}
               )

      # Truth is ~45 deg N, 7 deg E, 300 m (Turin-ish).
      assert_in_delta sol.geodetic.lat_rad, :math.pi() * 45.0 / 180.0, 1.0e-6
      assert_in_delta sol.geodetic.lon_rad, :math.pi() * 7.0 / 180.0, 1.0e-6
      assert_in_delta sol.geodetic.height_m, 300.0, 1.0e-2

      assert sol.dop.pdop > 0.0
      assert is_list(sol.used_sats)
      assert length(sol.used_sats) >= 4
      assert length(sol.used_sats) == length(sol.residuals_m)
      assert Enum.all?(sol.used_sats, &is_binary/1)
      # Every observation is accounted for as either used or rejected.
      assert length(sol.used_sats) + length(sol.rejected_sats) == length(ctx.observations)

      assert Enum.all?(sol.rejected_sats, fn {sat, reason} ->
               is_binary(sat) and reason in [:no_ephemeris, :low_elevation]
             end)
    end
  end

  describe "solve/4 degenerate geometry" do
    @degenerate_sp3 Path.join(__DIR__, "fixtures/sp3/degenerate_coincident_5sat.sp3")

    test "a rank-deficient geometry is refused, not returned as a fix" do
      sp3 = SP3.load!(@degenerate_sp3)

      # All five satellites share one ECEF position, so every line of sight is
      # identical and the geometry is rank-deficient (no DOP cofactor inverse).
      # Such a geometry has no unique trustworthy fix and is also what lets a
      # wrong-root mirror land on the plausible shell with zero residuals, so it
      # is refused with a tagged error rather than returned as a plausible fix.
      observations = for prn <- 1..5, do: {"G0#{prn}", 20_181_863.0}

      # A receive epoch inside the product's [00:00, 00:15] window.
      epoch = ~N[2020-06-24 00:03:20]

      assert Positioning.solve(sp3, observations, epoch, initial_guess: {6_378_137.0, 0.0, 0.0, 0.0}) ==
               {:error, {:degenerate_geometry, :rank_deficient}}
    end
  end

  describe "solve/4 from broadcast ephemeris" do
    @nav_path Path.join(__DIR__, "fixtures/nav/ESBC00DNK_R_20201770000_01D_MN.rnx")
    @nav_v4_path Path.join(__DIR__, "fixtures/nav/KMS300DNK_R_20221591000_01H_MN.rnx")
    @nav_glonass_path Path.join(__DIR__, "fixtures/nav/ESBC00DNK_R_20201770000_01D_RN.rnx")

    # GPS pseudoranges synthesized from the committed broadcast NAV product with
    # the same forward model the solver inverts, for a known receiver near the
    # ESBC station at 2020-06-25 12:00 GPST. The solve must recover that truth.
    @broadcast_truth %{x_m: 3_512_900.0, y_m: 780_500.0, z_m: 5_248_700.0}
    @broadcast_obs [
      {"G07", 24_602_022.181241553},
      {"G08", 23_676_569.520090435},
      {"G10", 23_359_996.74001386},
      {"G15", 24_308_689.12412482},
      {"G16", 20_729_337.624163955},
      {"G18", 21_218_848.782066472},
      {"G20", 21_331_195.197190672},
      {"G21", 20_769_683.82405165},
      {"G26", 22_031_046.45549123},
      {"G27", 21_170_243.258043874}
    ]

    test "loads a GLONASS navigation file through the broadcast path" do
      # GLONASS records (a PZ-90.11 state-vector model) parse through the NIF into
      # a usable handle; the RK4 propagation and time mapping are handled in Rust.
      assert %Broadcast{} = Broadcast.load!(@nav_glonass_path)
    end

    # GLONASS pseudoranges synthesized (same forward model the solver inverts)
    # from the committed GLONASS NAV product for the @broadcast_truth receiver at
    # 2020-06-25 12:00 GPST. The end-to-end solve must recover that truth through
    # the RK4 state-vector propagator.
    @broadcast_obs_glonass [
      {"R02", 22_163_462.853780},
      {"R03", 21_451_975.793444},
      {"R04", 23_499_605.720844},
      {"R09", 20_452_460.139838},
      {"R10", 20_967_543.625096},
      {"R18", 21_065_842.276262},
      {"R19", 19_294_047.490245},
      {"R20", 22_280_594.596830}
    ]

    test "recovers a known receiver from broadcast GLONASS pseudoranges" do
      eph = Broadcast.load!(@nav_glonass_path)

      assert {:ok, %Solution{} = sol} =
               Positioning.solve(eph, @broadcast_obs_glonass, ~N[2020-06-25 12:00:00],
                 initial_guess: {3_513_900.0, 779_500.0, 5_249_700.0, 0.0}
               )

      assert_in_delta sol.position.x_m, @broadcast_truth.x_m, 1.0e-2
      assert_in_delta sol.position.y_m, @broadcast_truth.y_m, 1.0e-2
      assert_in_delta sol.position.z_m, @broadcast_truth.z_m, 1.0e-2
      assert Map.keys(sol.system_clocks_s) == ["R"]
    end

    test "a GLONASS ionosphere-corrected solve with no FDMA channel map is rejected" do
      eph = Broadcast.load!(@nav_glonass_path)

      # With the ionosphere correction requested, the GLONASS L1 delay must be
      # scaled to each satellite's FDMA carrier by (f_L1/f_k)^2. With no channel
      # map (the default %{}), the per-satellite carrier cannot be resolved, so
      # the first GLONASS observation is rejected rather than mis-scaled.
      assert {:error, {:ionosphere_unsupported, sat}} =
               Positioning.solve(eph, @broadcast_obs_glonass, ~N[2020-06-25 12:00:00],
                 ionosphere: true,
                 klobuchar_alpha: {1.0e-8, 0.0, 0.0, 0.0},
                 klobuchar_beta: {9.0e4, 0.0, 0.0, 0.0},
                 initial_guess: {3_513_900.0, 779_500.0, 5_249_700.0, 0.0}
               )

      assert is_binary(sat) and String.starts_with?(sat, "R"),
             "the rejected satellite must be a GLONASS slot, got #{inspect(sat)}"
    end

    test "a GLONASS ionosphere-corrected solve is accepted when the FDMA channel map is supplied" do
      eph = Broadcast.load!(@nav_glonass_path)

      # The real slot -> FDMA channel map for the observed GLONASS satellites,
      # read from the broadcast nav product itself (the freq_channel field) so
      # the channels are not fabricated. %{slot => channel} is exactly the shape
      # solve/4 accepts for :glonass_channels.
      channels =
        eph
        |> Broadcast.glonass_records()
        |> Map.new(fn rec ->
          slot = rec.satellite_id |> String.trim_leading("R") |> String.to_integer()
          {slot, rec.freq_channel}
        end)

      # Sanity: the map covers every observed GLONASS slot, so none is rejected
      # for a missing channel.
      observed_slots =
        for {"R" <> slot, _pr} <- @broadcast_obs_glonass, into: MapSet.new() do
          String.to_integer(slot)
        end

      assert MapSet.subset?(observed_slots, MapSet.new(Map.keys(channels)))

      # Same observation set and epoch as the unmodified GLONASS solve, now with
      # the ionosphere correction on. Supplying the channel map turns the
      # :ionosphere_unsupported rejection into a converged fix: proof the map
      # reaches the solver. (These pseudoranges were synthesized without an
      # ionosphere, so the applied correction leaves a small offset rather than
      # an exact recovery, exactly as for the BeiDou ionosphere case above.)
      assert {:ok, %Solution{} = sol} =
               Positioning.solve(eph, @broadcast_obs_glonass, ~N[2020-06-25 12:00:00],
                 ionosphere: true,
                 glonass_channels: channels,
                 klobuchar_alpha: {1.0e-8, 0.0, 0.0, 0.0},
                 klobuchar_beta: {9.0e4, 0.0, 0.0, 0.0},
                 initial_guess: {3_513_900.0, 779_500.0, 5_249_700.0, 0.0}
               )

      assert sol.metadata.ionosphere_applied
      assert Map.keys(sol.system_clocks_s) == ["R"]

      err =
        :math.sqrt(
          (sol.position.x_m - @broadcast_truth.x_m) ** 2 +
            (sol.position.y_m - @broadcast_truth.y_m) ** 2 +
            (sol.position.z_m - @broadcast_truth.z_m) ** 2
        )

      assert err < 500.0, "position off by #{err} m"
    end

    test "a malformed :glonass_channels option is rejected before the solve" do
      eph = Broadcast.load!(@nav_glonass_path)

      assert {:error, {:invalid_option, :glonass_channels}} =
               Positioning.solve(eph, @broadcast_obs_glonass, ~N[2020-06-25 12:00:00],
                 glonass_channels: [{2, 1}],
                 initial_guess: {3_513_900.0, 779_500.0, 5_249_700.0, 0.0}
               )
    end

    test "loads a RINEX 4.00 navigation file through the broadcast path" do
      # A real v4.00 MIXED file parses through the NIF into a usable handle; the
      # version-4 frame markers are handled in Rust transparently to Elixir.
      assert {:ok, %Broadcast{}} =
               Broadcast.parse(File.read!(@nav_v4_path))

      assert %Broadcast{} = Broadcast.load!(@nav_v4_path)
    end

    test "recovers a known receiver from broadcast GPS pseudoranges" do
      eph = Broadcast.load!(@nav_path)

      assert {:ok, %Solution{} = sol} =
               Positioning.solve(eph, @broadcast_obs, ~N[2020-06-25 12:00:00],
                 initial_guess: {3_513_900.0, 779_500.0, 5_249_700.0, 0.0}
               )

      assert_in_delta sol.position.x_m, @broadcast_truth.x_m, 1.0e-2
      assert_in_delta sol.position.y_m, @broadcast_truth.y_m, 1.0e-2
      assert_in_delta sol.position.z_m, @broadcast_truth.z_m, 1.0e-2
      assert length(sol.used_sats) == 10
      assert sol.dop.pdop > 0.0
    end

    test "solves a mixed GPS+Galileo set together with a per-system clock" do
      eph = Broadcast.load!(@nav_path)
      # The 10 GPS pseudoranges plus visible Galileo sats at the same epoch,
      # synthesized with the same forward model.
      galileo = [
        {"E05", 27_038_058.41625906},
        {"E09", 25_628_329.464706413},
        {"E13", 25_860_944.599908587}
      ]

      mixed = @broadcast_obs ++ galileo

      assert {:ok, %Solution{} = sol} =
               Positioning.solve(eph, mixed, ~N[2020-06-25 12:00:00],
                 initial_guess: {3_513_900.0, 779_500.0, 5_249_700.0, 0.0}
               )

      # Recovers the same receiver as the GPS-only solve, now using both systems.
      assert_in_delta sol.position.x_m, @broadcast_truth.x_m, 1.0e-2
      assert_in_delta sol.position.y_m, @broadcast_truth.y_m, 1.0e-2
      assert_in_delta sol.position.z_m, @broadcast_truth.z_m, 1.0e-2

      systems = sol.used_sats |> Enum.map(&String.first/1) |> Enum.uniq() |> Enum.sort()
      assert systems == ["E", "G"], "both constellations must contribute"

      # A per-system receiver clock is surfaced for each constellation; the
      # reference (GPS) clock equals rx_clock_s.
      assert Map.keys(sol.system_clocks_s) |> Enum.sort() == ["E", "G"]
      assert_in_delta sol.system_clocks_s["G"], sol.rx_clock_s, 1.0e-15

      # The mixed geometry still yields a dilution of precision (a multi-system
      # inverse with one clock column per constellation).
      assert sol.dop.gdop > 0.0
      assert sol.dop.pdop > 0.0
      assert sol.dop.hdop > 0.0
      assert sol.dop.vdop > 0.0
      assert sol.dop.tdop > 0.0
    end

    test "solves a GPS+Galileo+BeiDou set, including a geostationary satellite" do
      eph = Broadcast.load!(@nav_path)
      # GPS + Galileo + BeiDou (C05 is geostationary, C13 IGSO, C19 MEO), all
      # synthesized with the same forward model at the same epoch.
      beidou = [
        {"C05", 40_127_033.52503693},
        {"C13", 39_200_124.95320755},
        {"C19", 23_661_671.39784395}
      ]

      galileo = [
        {"E05", 27_038_058.41625906},
        {"E09", 25_628_329.464706413},
        {"E13", 25_860_944.599908587}
      ]

      observations = @broadcast_obs ++ galileo ++ beidou

      assert {:ok, %Solution{} = sol} =
               Positioning.solve(eph, observations, ~N[2020-06-25 12:00:00],
                 initial_guess: {3_513_900.0, 779_500.0, 5_249_700.0, 0.0}
               )

      assert_in_delta sol.position.x_m, @broadcast_truth.x_m, 1.0e-2
      assert_in_delta sol.position.y_m, @broadcast_truth.y_m, 1.0e-2
      assert_in_delta sol.position.z_m, @broadcast_truth.z_m, 1.0e-2

      # All three constellations contribute and each gets a receiver clock.
      assert Map.keys(sol.system_clocks_s) |> Enum.sort() == ["C", "E", "G"]
      assert "C05" in sol.used_sats, "the geostationary satellite must be used"

      # A three-system geometry (three clock columns) still reports DOP.
      assert sol.dop.pdop > 0.0
      assert sol.dop.tdop > 0.0
    end

    test "an ionosphere-corrected solve with a BeiDou satellite is accepted" do
      eph = Broadcast.load!(@nav_path)

      observations =
        @broadcast_obs ++ [{"C05", 40_127_033.52503693}, {"C19", 23_661_671.39784395}]

      # The broadcast Klobuchar L1 delay is now scaled to each carrier by
      # (f_L1/f)^2 (exactly 1 for GPS L1, scaled for BeiDou B1I), so requesting
      # the ionosphere correction with a BeiDou satellite is supported, not
      # rejected. (These pseudoranges were synthesized without ionosphere, so
      # the solve converges to within a small offset rather than exactly.)
      assert {:ok, %Solution{} = sol} =
               Positioning.solve(eph, observations, ~N[2020-06-25 12:00:00],
                 ionosphere: true,
                 klobuchar_alpha: {1.0e-8, 0.0, 0.0, 0.0},
                 klobuchar_beta: {9.0e4, 0.0, 0.0, 0.0},
                 initial_guess: {3_513_900.0, 779_500.0, 5_249_700.0, 0.0}
               )

      assert sol.metadata.ionosphere_applied
      # BeiDou contributed its own clock, and the position is sane (the small
      # unmodeled ionosphere offset keeps it within a few hundred metres).
      assert Map.has_key?(sol.system_clocks_s, "C")

      err =
        :math.sqrt(
          (sol.position.x_m - @broadcast_truth.x_m) ** 2 +
            (sol.position.y_m - @broadcast_truth.y_m) ** 2 +
            (sol.position.z_m - @broadcast_truth.z_m) ** 2
        )

      assert err < 500.0, "position off by #{err} m"
    end

    test "a too-small broadcast observation set is rejected through the broadcast path" do
      eph = Broadcast.load!(@nav_path)
      few = Enum.take(@broadcast_obs, 3)

      assert {:error, {:too_few_satellites, used, required}} =
               Positioning.solve(eph, few, ~N[2020-06-25 12:00:00],
                 initial_guess: {3_513_900.0, 779_500.0, 5_249_700.0, 0.0}
               )

      assert used < 4
      # GPS-only here, so the requirement is the classic four.
      assert required == 4
    end

    test "a four-satellite GPS+Galileo set is too few (needs 3 + n_systems)" do
      eph = Broadcast.load!(@nav_path)
      # Two GPS + two Galileo: four usable satellites, but a two-system solve
      # needs five (three position + one receiver clock per GNSS).
      mixed_few =
        Enum.take(@broadcast_obs, 2) ++
          [{"E05", 27_038_058.346363213}, {"E09", 25_628_329.534503363}]

      assert {:error, {:too_few_satellites, used, required}} =
               Positioning.solve(eph, mixed_few, ~N[2020-06-25 12:00:00],
                 initial_guess: {3_513_900.0, 779_500.0, 5_249_700.0, 0.0}
               )

      assert used == 4
      assert required == 5
    end
  end

  describe "solve/4 error paths" do
    test "fewer than four observations is rejected", ctx do
      few = Enum.take(ctx.observations, 3)

      assert {:error, {:too_few_satellites, used, required}} =
               Positioning.solve(ctx.sp3, few, @epoch, initial_guess: {4_500_000.0, 500_000.0, 4_500_000.0, 0.0})

      assert used < 4
      assert required == 4
    end

    test "a duplicated satellite observation is rejected", ctx do
      [first | _] = ctx.observations
      dup = [first | ctx.observations]

      assert {:error, {:duplicate_observation, sat}} =
               Positioning.solve(ctx.sp3, dup, @epoch, initial_guess: {4_500_000.0, 500_000.0, 4_500_000.0, 0.0})

      assert is_binary(sat)
    end
  end

  describe "error reason mapping" do
    # The `:too_few_satellites` and `:duplicate_observation` reasons are also
    # covered end-to-end above; `:singular_geometry` and `:ephemeris_lost` are
    # defensive crate paths that real SP3 inputs do not reach, so the mapping
    # onto the public contract is exercised directly here.
    test "every advertised NIF error reason maps to its public form" do
      assert Decode.map_solve_error({:error, :too_few_satellites, 3, 5}) ==
               {:error, {:too_few_satellites, 3, 5}}

      assert Decode.map_solve_error({:error, :singular_geometry}) ==
               {:error, :singular_geometry}

      assert Decode.map_solve_error({:error, :duplicate_observation, "G01"}) ==
               {:error, {:duplicate_observation, "G01"}}

      assert Decode.map_solve_error({:error, :ephemeris_lost, "G07"}) ==
               {:error, {:ephemeris_lost, "G07"}}

      assert Decode.map_solve_error({:error, :ionosphere_unsupported, "R01"}) ==
               {:error, {:ionosphere_unsupported, "R01"}}
    end

    test "an unrecognized NIF result is wrapped rather than dropped" do
      assert Decode.map_solve_error(:boom) == {:error, :boom}
    end

    test "decode helpers are not exported from the public positioning module" do
      refute function_exported?(Positioning, :map_solve_error, 1)
      refute function_exported?(Positioning, :__decode_nif_result__, 1)
    end
  end

  describe "solve/4 GLONASS FDMA ionosphere (SP3 path)" do
    @nav_glonass_path Path.join(__DIR__, "fixtures/nav/ESBC00DNK_R_20201770000_01D_RN.rnx")

    setup ctx do
      station = ctx.truth_x |> Enum.take(3) |> List.to_tuple()

      glonass_sats = visible_ids(ctx.sp3, station, "R")
      gps_sats = visible_ids(ctx.sp3, station, "G")

      # Real slot -> FDMA channel map, read from the committed GLONASS broadcast
      # nav product (the adjacent day; the GLONASS channel plan is stable across
      # days). The SP3 precise product carries no FDMA channel, so the channel
      # is genuinely external input the caller must supply. Not fabricated.
      channels =
        @nav_glonass_path
        |> Broadcast.load!()
        |> Broadcast.glonass_records()
        |> Map.new(fn rec ->
          {rec.satellite_id |> String.trim_leading("R") |> String.to_integer(), rec.freq_channel}
        end)

      {:ok, station: station, glonass_sats: glonass_sats, gps_sats: gps_sats, channels: channels}
    end

    test "recovers a known receiver from SP3-synthesized GLONASS pseudoranges", ctx do
      # A GLONASS-only solve needs at least four satellites (three position
      # components plus the GLONASS receiver clock).
      assert length(ctx.glonass_sats) >= 4

      obs = synth(ctx.sp3, ctx.glonass_sats, ctx.station)

      assert {:ok, %Solution{} = sol} =
               Positioning.solve(ctx.sp3, obs, @epoch, initial_guess: guess(ctx.station))

      assert Map.keys(sol.system_clocks_s) == ["R"]
      # The forward model (`Observables.predict` with light-time + Sagnac) is the
      # one the solver inverts, so a clean GLONASS arc is recovered to the same
      # sub-millimetre boundary agreement as the GPS trace fixture.
      assert dist(sol.position, ctx.station) < @agreement_bound_m
    end

    test "GLONASS with ionosphere on but no channel map is rejected", ctx do
      obs = synth(ctx.sp3, ctx.glonass_sats, ctx.station)

      assert {:error, {:ionosphere_unsupported, sat}} =
               Positioning.solve(ctx.sp3, obs, @epoch,
                 ionosphere: true,
                 klobuchar_alpha: {1.0e-8, 0.0, 0.0, 0.0},
                 klobuchar_beta: {9.0e4, 0.0, 0.0, 0.0},
                 initial_guess: guess(ctx.station)
               )

      assert sat in ctx.glonass_sats
    end

    test "supplying the FDMA channel map lifts the ionosphere gate and GLONASS solves",
         ctx do
      obs = synth(ctx.sp3, ctx.glonass_sats, ctx.station)

      assert {:ok, %Solution{} = sol} =
               Positioning.solve(ctx.sp3, obs, @epoch,
                 ionosphere: true,
                 glonass_channels: ctx.channels,
                 klobuchar_alpha: {1.0e-8, 0.0, 0.0, 0.0},
                 klobuchar_beta: {9.0e4, 0.0, 0.0, 0.0},
                 initial_guess: guess(ctx.station)
               )

      assert sol.metadata.ionosphere_applied
      assert Map.keys(sol.system_clocks_s) == ["R"]
      # The pseudoranges carry no ionosphere, so the applied correction leaves a
      # small offset (metres), but the fix is real, not a plumbing stub.
      assert dist(sol.position, ctx.station) < 1_000.0
    end

    test "an out-of-range FDMA channel is rejected like a missing one", ctx do
      obs = synth(ctx.sp3, ctx.glonass_sats, ctx.station)

      # Break exactly one observed slot with a channel outside the valid GLONASS
      # range [-7, +6] (50 is a legal i8 the NIF carries, but not a real channel),
      # leaving every other slot valid. The crate must reject that satellite for
      # the same reason a missing channel is rejected.
      "R" <> broken_slot = hd(ctx.glonass_sats)
      channels = Map.put(ctx.channels, String.to_integer(broken_slot), 50)

      assert {:error, {:ionosphere_unsupported, sat}} =
               Positioning.solve(ctx.sp3, obs, @epoch,
                 ionosphere: true,
                 glonass_channels: channels,
                 klobuchar_alpha: {1.0e-8, 0.0, 0.0, 0.0},
                 klobuchar_beta: {9.0e4, 0.0, 0.0, 0.0},
                 initial_guess: guess(ctx.station)
               )

      assert sat == hd(ctx.glonass_sats)
    end

    test "the channel map is a bit-for-bit no-op on a GPS-only solve", ctx do
      assert length(ctx.gps_sats) >= 4

      obs = synth(ctx.sp3, ctx.gps_sats, ctx.station)

      opts = [
        ionosphere: true,
        klobuchar_alpha: {1.0e-8, 0.0, 0.0, 0.0},
        initial_guess: guess(ctx.station)
      ]

      assert {:ok, %Solution{} = without} = Positioning.solve(ctx.sp3, obs, @epoch, opts)

      assert {:ok, %Solution{} = with_channels} =
               Positioning.solve(ctx.sp3, obs, @epoch, [{:glonass_channels, ctx.channels} | opts])

      # No GLONASS observation is present, so the channel map must not perturb the
      # solve by a single bit.
      assert with_channels.position == without.position
      assert with_channels.rx_clock_s == without.rx_clock_s
    end
  end

  # The SP3-declared satellites of one system visible from the station at the
  # fixture epoch, above a 10-degree mask.
  defp visible_ids(sp3, station, system) do
    sp3
    |> Geometry.visible(station, @epoch, systems: [system], elevation_mask_deg: 10.0)
    |> Enum.map(& &1.satellite_id)
  end

  # Synthesize clean pseudoranges from the precise SP3 product with the engine's
  # own forward model (`pr = geometric_range + c*(rx_clock - sat_clock)`, with
  # light-time and Sagnac) that the solver inverts. The receiver clock is taken
  # as zero; the solver re-estimates it. No fabricated numbers: the geometry and
  # satellite clock come straight from the SP3 fixture via `Observables.predict`.
  defp synth(sp3, sats, station) do
    Enum.map(sats, fn sat ->
      {:ok, o} = Observables.predict(sp3, sat, station, @epoch, light_time: true, sagnac: true)
      {sat, o.geometric_range_m + @speed_of_light_m_s * -(o.sat_clock_s || 0.0)}
    end)
  end

  defp guess({x, y, z}), do: {x, y, z, 0.0}

  defp dist(%{x_m: x, y_m: y, z_m: z}, {tx, ty, tz}) do
    :math.sqrt((x - tx) ** 2 + (y - ty) ** 2 + (z - tz) ** 2)
  end

  # Decode an IEEE-754 double from its raw big-endian 8-byte hex string (the
  # fixture's bit-exact float encoding), e.g. "0x417b0050747d1762".
  defp hex_to_float("0x" <> hex) do
    bytes = hex |> String.pad_leading(16, "0") |> Base.decode16!(case: :mixed)
    <<value::float-64>> = bytes
    value
  end
end
