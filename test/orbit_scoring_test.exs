defmodule Sidereon.OrbitScoringTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.SP3
  alias Sidereon.OrbitScoring
  alias Sidereon.OrbitScoring.BroadcastOrbit
  alias Sidereon.OrbitScoring.ErrorStats
  alias Sidereon.OrbitScoring.HorizonBinStats
  alias Sidereon.OrbitScoring.OrbitRegime
  alias Sidereon.OrbitScoring.OrbitScoreError
  alias Sidereon.OrbitScoring.OrbitScoreOptions
  alias Sidereon.OrbitScoring.OrbitScoreReport
  alias Sidereon.OrbitScoring.OrbitSourceState
  alias Sidereon.OrbitScoring.OrbitTrajectory
  alias Sidereon.OrbitScoring.PredictedSp3
  alias Sidereon.OrbitScoring.RtnComponents
  alias Sidereon.OrbitScoring.SatelliteScore
  alias Sidereon.OrbitScoring.ScoreCoverage
  alias Sidereon.OrbitScoring.ScoredProduct
  alias Sidereon.OrbitScoring.SisreWeights
  alias Sidereon.OrbitScoring.Sp3FrameReconciliationOptions
  alias Sidereon.OrbitScoring.SystemScore
  alias Sidereon.OrbitScoring.TrajectorySample
  alias Sidereon.Test.CoreGolden

  @reference Path.expand("fixtures/sp3/GBM0MGXRAP_20201770000_01D_05M_ORB_73epoch.sp3", __DIR__)
  @origin %{time_scale: "GPST", nanos_since_j2000: 646_056_000_000_000_000}
  @zero %ErrorStats{rms_m: 0.0, mean_m: 0.0, max_abs_m: 0.0}
  @weights %SisreWeights{radial: 0.5, transverse_normal_squared: 0.25}

  test "scoring constructors and queries return structured epoch and satellite refusals" do
    product = SP3.load!(@reference)
    assert {:ok, predicted} = PredictedSp3.with_cutoff(product, @origin)

    for {epoch, kind, reason, message} <- [
          {:bad, :bad_epoch, :bad_epoch, ":bad_epoch"},
          {%{@origin | time_scale: "OTHER"}, :invalid_input, ~s(unknown time scale "OTHER"),
           ~s(unknown time scale "OTHER")}
        ] do
      expected = {:error, %OrbitScoreError{kind: kind, detail: %{reason: reason}, message: message}}
      assert PredictedSp3.with_cutoff(product, epoch) === expected
      assert OrbitTrajectory.new("ITRF", epoch, []) === expected
    end

    options = %OrbitScoreOptions{horizon_bin_edges_s: [0.0]}

    reason = "outside the 1..=99 satellite-token range"

    expected =
      {:error,
       %OrbitScoreError{
         kind: :invalid_input,
         detail: %{field: "prn", reason: reason},
         message: "invalid GNSS satellite prn: #{reason}"
       }}

    for satellite <- ["G00", "g100", "G100", {:gps, 100}] do
      assert OrbitScoring.state_at_j2000_s(predicted, satellite, 0.0) === expected
      assert OrbitScoring.prediction_origin_j2000_s(predicted, satellite) === expected
      assert OrbitScoring.score_orbit(predicted, product, [satellite], options) === expected
    end

    assert {:error, %OrbitScoreError{kind: :invalid_input, message: "invalid GNSS satellite token"}} =
             OrbitScoring.state_at_j2000_s(predicted, {:gps, 256}, 0.0)

    for satellite <- ["X01", "bad"] do
      reason = {:bad_sat_id, satellite}
      expected = {:error, %OrbitScoreError{kind: :bad_sat_id, detail: %{reason: reason}, message: inspect(reason)}}
      assert OrbitScoring.state_at_j2000_s(predicted, satellite, 0.0) === expected
      assert OrbitScoring.prediction_origin_j2000_s(predicted, satellite) === expected
      assert OrbitScoring.score_orbit(predicted, product, [satellite], options) === expected
    end
  end

  test "a predicted SP3 source is scored per satellite, constellation and horizon" do
    expected = CoreGolden.load("orbit_assessment.json")["score"]
    product = SP3.load!(@reference)
    assert {:ok, predicted} = PredictedSp3.with_cutoff(product, @origin)
    assert PredictedSp3.product(predicted) === product
    assert OrbitScoring.time_scale(predicted) == {:ok, "GPST"}
    assert OrbitScoring.sp3_time_system(predicted) == {:ok, "GPS"}
    assert {:ok, {:label, _}} = OrbitScoring.frame(predicted)
    assert OrbitScoring.reference_point(predicted) == {:ok, :center_of_mass}
    assert OrbitScoring.clock_includes_relativity(predicted) == {:ok, false}
    assert OrbitScoring.prediction_origin_j2000_s(predicted, "G01") === {:ok, 646_056_000.0}

    edges = [-1.0e7, 1.0e7]
    options = %OrbitScoreOptions{horizon_bin_edges_s: edges, sisre_weights: {:fixed, @weights}}
    assert {:ok, %OrbitScoreReport{} = report} = OrbitScoring.score_orbit(predicted, product, ["G01"], options)
    assert report.horizon_bin_edges_s === edges
    assert report.frame == :same_label
    assert report.source_reference_point == :center_of_mass

    coverage = %ScoreCoverage{epochs: 73, scored: expected["scored"], clocked: expected["clocked"]}
    assert report.coverage === coverage

    assert [%SatelliteScore{satellite: "G01", coverage: ^coverage, sisre_weights: @weights, bins: [bin]}] =
             report.per_satellite

    assert bin === %HorizonBinStats{
             horizon_start_s: -1.0e7,
             horizon_end_s: 1.0e7,
             count: 73,
             clock_count: 0,
             radial: @zero,
             transverse: @zero,
             normal: @zero,
             orbit_3d: @zero,
             sisre_orbit: @zero,
             clock: nil,
             sisre: nil
           }

    assert [%SystemScore{system: "G", coverage: ^coverage, bins: [^bin]}] = report.per_system

    assert {:error,
            %OrbitScoreError{
              kind: :invalid_input,
              detail: %{field: "horizon_bin_edges_s", reason: "not strictly increasing"}
            }} =
             OrbitScoring.score_orbit(predicted, product, ["G01"], %{options | horizon_bin_edges_s: [1.0, 0.0]})

    assert {:error, %OrbitScoreError{kind: :missing_satellite, detail: %{product: :reference, satellite: "G99"}}} =
             OrbitScoring.score_orbit(predicted, product, ["G99"], %{options | gaps: :refuse})
  end

  test "broadcast and precise orbits have nonzero RTN and SISRE statistics" do
    nav = Broadcast.load!(Path.join(__DIR__, "fixtures/nav/ESBC00DNK_R_20201770000_01D_MN.rnx"))
    assert {:ok, source} = BroadcastOrbit.new(nav, @origin)
    product = SP3.load!(@reference)
    options = %OrbitScoreOptions{horizon_bin_edges_s: [-1.0e7, 1.0e7]}

    assert {:ok, %OrbitScoreReport{per_satellite: [%SatelliteScore{bins: [bin]}]}} =
             OrbitScoring.score_orbit(source, product, ["G03"], options)

    expected = CoreGolden.load("orbit_assessment.json")["broadcast_score"]
    assert bin.count === expected["count"]
    assert bin.count > 0

    for key <- [:radial, :transverse, :normal, :orbit_3d, :sisre_orbit] do
      [rms, mean, max] = CoreGolden.f(expected[Atom.to_string(key)])
      assert rms > 0.0
      assert Map.fetch!(bin, key) === %ErrorStats{rms_m: rms, mean_m: mean, max_abs_m: max}
    end
  end

  test "a sampled trajectory keeps exact epochs, frame and clock metadata" do
    sample = %TrajectorySample{
      satellite: "G01",
      epoch: @origin,
      position_ecef_m: {26_000_000.0, 0.0, 0.0},
      clock_s: 1.0e-6
    }

    assert {:ok, trajectory} = OrbitTrajectory.new("IGS20", @origin, [sample])
    assert {:ok, same} = OrbitTrajectory.new("IGS20", @origin, [sample])
    assert OrbitTrajectory.equal?(trajectory, same)
    assert OrbitTrajectory.epochs(trajectory) === [@origin]
    assert OrbitTrajectory.satellites(trajectory) === ["G01"]
    assert OrbitScoring.frame(trajectory) == {:ok, {:label, "IGS20"}}
    assert OrbitScoring.sp3_time_system(trajectory) === {:ok, nil}

    assert OrbitScoring.state_at_j2000_s(trajectory, "G01", 646_056_000.0) ===
             {:ok, %OrbitSourceState{position_ecef_m: {26_000_000.0, 0.0, 0.0}, clock_s: 1.0e-6}}

    stated = OrbitTrajectory.with_clock_relativity_included(trajectory, true)
    refute OrbitTrajectory.equal?(stated, trajectory)
    assert OrbitScoring.clock_includes_relativity(stated) == {:ok, true}

    assert {:error,
            %OrbitScoreError{
              kind: :instant_time_system_mismatch,
              detail: %{
                field: "samples",
                index: 0,
                found: "UTC",
                expected: "GPST"
              }
            }} = OrbitTrajectory.new("IGS20", @origin, [%{sample | epoch: %{@origin | time_scale: "UTC"}}])
  end

  test "RTN components, orbit classification and SISRE weights" do
    r = {26_000_000.0, 0.0, 0.0}
    v = {0.0, 3900.0, 0.0}
    components = %RtnComponents{radial_m: 8.0, transverse_m: 0.0, normal_m: 0.0}
    assert OrbitScoring.rtn_components({8.0, 0.0, 0.0}, r, v) === {:ok, components}
    assert OrbitRegime.from_inertial_state(r, v) == :meo
    assert OrbitRegime.to_string(:meo) == "MEO"
    assert ScoredProduct.to_string(:reference) == "reference product"
    assert OrbitScoring.inertial_velocity_from_earth_fixed({0.0, 0.0, 1.0}, v) === {:ok, v}

    assert SisreWeights.new(0.5, 0.25) === {:ok, @weights}
    assert SisreWeights.orbit_only_m(@weights, components) === {:ok, 4.0}
    assert SisreWeights.with_clock_m(@weights, components, 1.0) === {:ok, 3.0}
    assert %SisreWeights{radial: 0.98} = SisreWeights.montenbruck_2018(:gps, :meo)
    assert OrbitScoring.default_velocity_half_step_s() === 0.5
    assert OrbitScoring.min_velocity_half_step_s() === 1.0e-8

    assert {:error,
            %OrbitScoreError{kind: :invalid_input, detail: %{field: "sisre_weights.radial", reason: "not within 0..=1"}}} =
             SisreWeights.new(1.25, 0.25)
  end

  test "scoring accepts explicit epochs and reports stated and transformed terrestrial frames" do
    product = SP3.load!(@reference)
    first = %{time_scale: "GPST", nanos_since_j2000: 646_315_200_000_000_000}
    options = %OrbitScoreOptions{horizon_bin_edges_s: [-1.0e7, 1.0e7]}

    assert %ScoreCoverage{} === %ScoreCoverage{
             epochs: 0,
             scored: 0,
             clocked: 0,
             reference_satellite_missing: 0,
             reference_epoch_missing: 0,
             source_satellite_missing: 0,
             source_epoch_missing: 0,
             no_prediction_origin: 0,
             outside_horizon_bins: 0
           }

    assert {:ok, flags} = PredictedSp3.from_prediction_flags(product)
    assert OrbitScoring.prediction_origin_j2000_s(flags, "G01") === {:ok, 646_336_800.0}
    assert OrbitScoring.frame(flags) === {:ok, {:label, "IGS14"}}

    options = %{
      options
      | triad: :earth_fixed,
        epochs: {:instants, [first]},
        clock_datum: :unadjusted,
        sisre_weights: {:fixed, @weights}
    }

    assert {:ok, report} = OrbitScoring.score_orbit(flags, product, ["G01"], options)
    assert report.coverage === %ScoreCoverage{epochs: 1, scored: 1, clocked: 1}
    assert report.frame === :same_label
    assert [satellite] = report.per_satellite
    assert [bin] = satellite.bins
    assert bin.orbit_3d === @zero
    assert bin.clock === @zero
    assert bin.sisre === @zero

    text = File.read!(@reference) |> String.replace("IGS14", "IGS20")
    assert {:ok, other} = SP3.parse(text)
    assert {:ok, from} = PredictedSp3.with_cutoff(other, @origin)
    equivalent = %Sp3FrameReconciliationOptions{asserted_equivalent_label_sets: [["IGS20", "IGS14"]]}

    assert {:ok, report} =
             OrbitScoring.score_orbit(from, product, ["G01"], %{options | frame_reconciliation: equivalent})

    assert report.frame === :asserted_equivalent
    helmert = %Sp3FrameReconciliationOptions{helmert: true}
    assert {:ok, report} = OrbitScoring.score_orbit(from, product, ["G01"], %{options | frame_reconciliation: helmert})
    assert report.frame === {:helmert, "ITRF2020", "ITRF2014"}
  end

  test "scoring source queries retain exact SP3 interpolation refusals" do
    text = File.read!(Path.expand("fixtures/sp3/gbm_c08_c21_two_epoch.sp3", __DIR__))
    assert {:ok, product} = SP3.parse(text)
    assert {:ok, source} = PredictedSp3.with_cutoff(product, @origin)

    assert {:error, %OrbitScoreError{kind: :insufficient_precise_nodes, detail: detail}} =
             OrbitScoring.state_at_j2000_s(source, "C08", 646_315_200.0)

    assert detail === %{satellite: "C08", nodes: 2, required: 11}

    assert {:error, %OrbitScoreError{kind: :unknown_satellite, detail: detail}} =
             OrbitScoring.state_at_j2000_s(source, "C99", 646_315_200.0)

    assert detail === %{satellite: "C99"}

    collapsed = String.replace(text, "*  2020  6 25  0  5  0.00000000", "*  2020  6 25  0  0  0.00000001")
    assert {:ok, product} = SP3.parse(collapsed)
    assert {:ok, source} = PredictedSp3.with_cutoff(product, @origin)

    assert {:error, %OrbitScoreError{kind: :invalid_input, detail: detail} = error} =
             OrbitScoring.state_at_j2000_s(source, "C08", 646_315_200.0)

    assert detail === %{message: "SP3 interpolation epochs must be strictly increasing"}
    assert to_string(error) === "invalid input: SP3 interpolation epochs must be strictly increasing"
  end

  test "geosynchronous regimes distinguish inclination and the documented display names" do
    position = {42_164_000.0, 0.0, 0.0}
    assert OrbitRegime.from_inertial_state(position, {0.0, 3075.0, 0.0}) === :geo
    assert OrbitRegime.from_inertial_state(position, {0.0, 0.0, 3075.0}) === :igso
    assert ScoredProduct.to_string(:source) === "orbit source"
  end

  test "scoring refuses incompatible frames, scales and coverage with their details" do
    text = File.read!(@reference)
    {:ok, product} = SP3.parse(text)
    samples = Enum.filter(SP3.precise_ephemeris_samples(product), &(&1.sat == "G01"))
    [first, second | _] = samples
    state = %TrajectorySample{satellite: "G01", epoch: first.epoch, position_ecef_m: first.position_ecef_m}
    opts = %OrbitScoreOptions{horizon_bin_edges_s: [-1.0e7, 1.0e7], sisre_weights: {:fixed, @weights}, gaps: :refuse}

    assert {:ok, trajectory} = OrbitTrajectory.new("IGS20", first.epoch, [state])

    assert {:error, %OrbitScoreError{kind: :frame_mismatch, detail: %{orbit_source: "IGS20", reference: "IGS14"}}} =
             OrbitScoring.score_orbit(trajectory, product, ["G01"], opts)

    utc = %{first.epoch | time_scale: "UTC"}
    assert {:ok, utc_trajectory} = OrbitTrajectory.new("IGS14", utc, [%{state | epoch: utc}])

    assert {:error, %OrbitScoreError{kind: :time_system_mismatch, detail: %{orbit_source: "UTC", reference: "GPST"}}} =
             OrbitScoring.score_orbit(utc_trajectory, product, ["G01"], opts)

    assert {:ok, irnss} = text |> String.replace("cc GPS", "cc IRN") |> SP3.parse()
    assert {:ok, predicted} = PredictedSp3.with_cutoff(irnss, @origin)

    assert {:error,
            %OrbitScoreError{kind: :time_system_label_mismatch, detail: %{orbit_source: "IRN", reference: "GPS"}}} =
             OrbitScoring.score_orbit(predicted, product, ["G01"], opts)

    assert {:ok, trajectory} = OrbitTrajectory.new("IGS14", first.epoch, [state])

    assert {:error,
            %OrbitScoreError{
              kind: :missing_epoch,
              detail: %{
                product: :source,
                satellite: "G01",
                epoch_index: 1,
                error: %{kind: :epoch_out_of_range, detail: %{}}
              }
            }} =
             OrbitScoring.score_orbit(trajectory, product, ["G01"], %{
               opts
               | epochs: {:instants, [first.epoch, second.epoch]}
             })

    predicted_text = change_gps_records(text, fn line -> binary_part(String.pad_trailing(line, 80), 0, 79) <> "P" end)
    assert {:ok, flagged} = SP3.parse(predicted_text)
    assert {:ok, no_origin} = PredictedSp3.from_prediction_flags(flagged)
    assert OrbitScoring.prediction_origin_j2000_s(no_origin, "G01") === {:ok, nil}

    assert {:error, %OrbitScoreError{kind: :no_prediction_origin, detail: %{satellite: "G01"}}} =
             OrbitScoring.score_orbit(no_origin, product, ["G01"], opts)
  end

  test "scoring detects degenerate reference geometry and overflowing differences" do
    text = File.read!(@reference)
    {:ok, product} = SP3.parse(text)
    first = Enum.find(SP3.precise_ephemeris_samples(product), &(&1.sat == "G01"))
    state = %TrajectorySample{satellite: "G01", epoch: first.epoch, position_ecef_m: {1.7e308, 1.7e308, 1.7e308}}
    assert {:ok, trajectory} = OrbitTrajectory.new("IGS14", first.epoch, [state])

    options = %OrbitScoreOptions{
      horizon_bin_edges_s: [-1.0, 1.0],
      sisre_weights: {:fixed, @weights},
      epochs: {:instants, [first.epoch]}
    }

    assert {:error, %OrbitScoreError{kind: :non_finite_result, detail: %{satellite: "G01"}}} =
             OrbitScoring.score_orbit(trajectory, product, ["G01"], options)

    axis_text =
      change_gps_records(text, fn <<"PG01", _::binary-size(42), suffix::binary>> ->
        "PG01      0.000000      0.000000  26000.000000" <> suffix
      end)

    {:ok, axis} = SP3.parse(axis_text)

    assert {:error, %OrbitScoreError{kind: :degenerate_reference_state, detail: %{satellite: "G01", epoch_index: 0}}} =
             OrbitScoring.score_orbit(trajectory, axis, ["G01"], options)
  end

  test "scoring preserves the catalog error for an overflowing frame transform" do
    text = @reference |> File.read!() |> String.replace("IGS14", "IGS20")
    assert {:ok, product} = SP3.parse(text)
    first = Enum.find(SP3.precise_ephemeris_samples(product), &(&1.sat == "G01"))

    sample = %TrajectorySample{
      satellite: "G01",
      epoch: first.epoch,
      position_ecef_m: {1.797_693_134_862_315_7e308, 0.0, 0.0}
    }

    assert {:ok, trajectory} = OrbitTrajectory.new("IGS14", first.epoch, [sample])

    options = %OrbitScoreOptions{
      horizon_bin_edges_s: [-1.0, 1.0],
      sisre_weights: {:fixed, @weights},
      epochs: {:instants, [first.epoch]},
      frame_reconciliation: %Sp3FrameReconciliationOptions{helmert: true}
    }

    detail = %{
      error: %{
        kind: "invalid_input",
        field: "x_m",
        reason: "must be finite",
        from_frame: nil,
        to_frame: nil,
        epoch_year: nil
      }
    }

    assert {:error, %OrbitScoreError{kind: :frame_transform, detail: ^detail}} =
             OrbitScoring.score_orbit(trajectory, product, ["G01"], options)
  end

  test "published weights require a supported orbital regime and constellation" do
    text = File.read!(@reference)

    near_earth_text =
      change_gps_records(text, fn <<"PG01", _::binary-size(42), suffix::binary>> ->
        "PG01   6500.000000      0.000000      0.000000" <> suffix
      end)

    assert {:ok, near_earth} = SP3.parse(near_earth_text)
    assert {:ok, predicted} = PredictedSp3.with_cutoff(near_earth, @origin)
    options = %OrbitScoreOptions{horizon_bin_edges_s: [-1.0e7, 1.0e7]}

    assert {:error, %OrbitScoreError{kind: :undetermined_orbit_regime, detail: %{satellite: "G01"}}} =
             OrbitScoring.score_orbit(predicted, near_earth, ["G01"], options)

    assert {:ok, meo_sbas} = text |> String.replace("G01", "S99") |> SP3.parse()
    assert {:ok, predicted} = PredictedSp3.with_cutoff(meo_sbas, @origin)

    assert {:error, %OrbitScoreError{kind: :no_sisre_weights, detail: %{satellite: "S99", regime: :meo}}} =
             OrbitScoring.score_orbit(predicted, meo_sbas, ["S99"], options)
  end

  defp change_gps_records(text, transform) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "PG01" <> _ = record -> transform.(record)
      line -> line
    end)
  end
end
