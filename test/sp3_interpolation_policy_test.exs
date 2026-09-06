defmodule Sidereon.GNSS.SP3InterpolationPolicyTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.{PreciseEphemeris, SP3}

  alias Sidereon.GNSS.PreciseEphemeris.{
    Interpolant,
    InterpolantArtifact,
    PreciseInterpolantArtifact
  }

  @sp3_path Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")
  @midpoint_dt ~N[2020-06-24 08:45:00]
  @midpoint_j2000_s 646_260_300.0

  defp gapped_sp3_bytes do
    lines = @sp3_path |> File.read!() |> String.split("\n")

    {out_lines, _} =
      Enum.reduce(lines, {[], nil}, fn line, {acc, current_time} ->
        cond do
          String.starts_with?(line, "*") ->
            case String.split(line) do
              ["*", _y, _m, _d, h_str, min_str | _] ->
                time_m = String.to_integer(h_str) * 60 + String.to_integer(min_str)
                {[line | acc], time_m}

              _ ->
                {[line | acc], current_time}
            end

          String.starts_with?(line, "PG01") ->
            # Drop G01 records between 07:30 and 10:00 (minutes 450 to 600)
            if current_time && current_time >= 450 && current_time <= 600 do
              {acc, current_time}
            else
              {[line | acc], current_time}
            end

          true ->
            {[line | acc], current_time}
        end
      end)

    out_lines |> Enum.reverse() |> Enum.join("\n")
  end

  describe "SP3 parse and load with gap_threshold_factor" do
    test "default gap threshold factor is 1.5 and refuses interpolation across gap" do
      raw = gapped_sp3_bytes()
      assert {:ok, sp3} = SP3.parse(raw)
      assert SP3.gap_threshold_factor(sp3) == 1.5

      # Querying G01 at midpoint (08:45:00) falls in the gap
      assert {:error, "epoch out of range"} = SP3.position(sp3, "G01", @midpoint_dt)

      assert {:ok, batch} = SP3.interpolate(sp3, "G01", [@midpoint_j2000_s])
      assert batch.statuses == [:gap]
      assert batch.results == [error: :epoch_out_of_range]
    end

    test "gap_threshold_factor: 13.0 allows spanning the 2.5-hour gap" do
      raw = gapped_sp3_bytes()
      assert {:ok, sp3} = SP3.parse(raw, gap_threshold_factor: 13.0)
      assert SP3.gap_threshold_factor(sp3) == 13.0

      assert {:ok, %SP3.State{} = state} = SP3.position(sp3, "G01", @midpoint_dt)
      assert is_float(state.x_m) and is_float(state.y_m) and is_float(state.z_m)

      assert {:ok, batch} = SP3.interpolate(sp3, "G01", [@midpoint_j2000_s])
      assert batch.statuses == [:valid]
      assert batch.results == [:ok]
      assert [{x, y, z}] = batch.positions_ecef_m
      assert is_float(x) and is_float(y) and is_float(z)
    end

    test "SP3.load/2 and SP3.load!/2 accept gap_threshold_factor" do
      raw = gapped_sp3_bytes()
      tmp_dir = System.tmp_dir!()
      tmp_path = Path.join(tmp_dir, "sp3_policy_test_#{System.unique_integer([:positive])}.sp3")
      File.write!(tmp_path, raw)

      on_exit(fn -> File.rm(tmp_path) end)

      assert {:ok, sp3} = SP3.load(tmp_path, gap_threshold_factor: 13.0)
      assert SP3.gap_threshold_factor(sp3) == 13.0
      assert {:ok, _state} = SP3.position(sp3, "G01", @midpoint_dt)

      sp3_bang = SP3.load!(tmp_path, gap_threshold_factor: 13.0)
      assert SP3.gap_threshold_factor(sp3_bang) == 13.0
      assert {:ok, _state} = SP3.position(sp3_bang, "G01", @midpoint_dt)
    end

    test "gap_threshold_factor <= 1.0 or non-finite errors" do
      raw = gapped_sp3_bytes()

      assert {:error, msg} = SP3.parse(raw, gap_threshold_factor: 1.0)
      assert msg =~ "gap_threshold_factor must be finite and greater than 1.0"

      assert {:error, msg} = SP3.parse(raw, gap_threshold_factor: 0.5)
      assert msg =~ "gap_threshold_factor must be finite and greater than 1.0"

      assert {:error, msg} = SP3.parse(raw, gap_threshold_factor: -1.0)
      assert msg =~ "gap_threshold_factor must be finite and greater than 1.0"

      assert {:error, {:bad_gap_threshold_factor, :invalid}} =
               SP3.parse(raw, gap_threshold_factor: :invalid)
    end

    test "SP3.parse_exact/3 accepts gap_threshold_factor" do
      raw = File.read!(@sp3_path)
      assert {:ok, req} = SP3.ExactRequest.new(~D[2020-06-24], "01D", "15M")

      assert {:ok, sp3_exact, _alignment} =
               SP3.parse_exact(raw, req, gap_threshold_factor: 2.5)

      assert SP3.gap_threshold_factor(sp3_exact) == 2.5

      assert {:error, {:exact_sp3_validation_failed, msg}} =
               SP3.parse_exact(raw, req, gap_threshold_factor: 1.0)

      assert msg =~ "gap_threshold_factor must be finite and greater than 1.0"
    end
  end

  describe "Continuity and merge options with gap_threshold_factor" do
    test "SP3.check_continuity/2 and SP3.continuity_verdict/4 accept gap_threshold_factor" do
      raw = gapped_sp3_bytes()
      assert {:ok, sp3} = SP3.parse(raw)

      assert {:ok, report} = SP3.check_continuity(sp3, gap_threshold_factor: 13.0)
      assert is_list(report.defects)

      [e0 | _] = SP3.epochs_j2000_seconds(sp3)
      e_end = List.last(SP3.epochs_j2000_seconds(sp3))

      assert {:ok, verdict} =
               SP3.continuity_verdict(sp3, e0, e_end, gap_threshold_factor: 13.0)

      assert is_boolean(verdict.accepted)
    end

    test "SP3.merge/2 accepts gap_threshold_factor in verify_continuity" do
      raw = gapped_sp3_bytes()
      assert {:ok, sp3} = SP3.parse(raw)

      assert {:ok, _merged, report} =
               SP3.merge([sp3], verify_continuity: [gap_threshold_factor: 13.0])

      assert report.continuity != nil
    end
  end

  describe "PreciseEphemeris with gap_threshold_factor" do
    test "from_samples/2 records gap_threshold_factor" do
      raw = gapped_sp3_bytes()
      assert {:ok, sp3_f13} = SP3.parse(raw, gap_threshold_factor: 13.0)
      samples = SP3.precise_ephemeris_samples(sp3_f13)

      assert {:ok, pe_default} = PreciseEphemeris.from_samples(samples)
      assert PreciseEphemeris.gap_threshold_factor(pe_default) == 1.5

      assert {:ok, pe_f13} =
               PreciseEphemeris.from_samples(samples, gap_threshold_factor: 13.0)

      assert PreciseEphemeris.gap_threshold_factor(pe_f13) == 13.0

      assert {:error, msg} =
               PreciseEphemeris.from_samples(samples, gap_threshold_factor: 1.0)

      assert msg =~ "gap_threshold_factor must be finite and greater than 1.0"

      assert {:error, {:bad_gap_threshold_factor, :bad}} =
               PreciseEphemeris.from_samples(samples, gap_threshold_factor: :bad)
    end
  end

  describe "Interpolant with gap_threshold_factor" do
    test "from_sp3/2 inherits or overrides gap_threshold_factor" do
      raw = gapped_sp3_bytes()
      assert {:ok, sp3_default} = SP3.parse(raw)
      assert {:ok, sp3_f13} = SP3.parse(raw, gap_threshold_factor: 13.0)

      assert {:ok, interp_default} = Interpolant.from_sp3(sp3_default)
      assert Interpolant.gap_threshold_factor(interp_default) == 1.5

      assert {:ok, batch} =
               Interpolant.states_at_j2000_s(interp_default, ["G01"], [@midpoint_j2000_s])

      assert batch.statuses == [:gap]

      assert {:ok, interp_f13_inherited} = Interpolant.from_sp3(sp3_f13)
      assert Interpolant.gap_threshold_factor(interp_f13_inherited) == 13.0

      assert {:ok, batch} =
               Interpolant.states_at_j2000_s(interp_f13_inherited, ["G01"], [@midpoint_j2000_s])

      assert batch.statuses == [:valid]

      assert {:ok, interp_override} =
               Interpolant.from_sp3(sp3_default, gap_threshold_factor: 13.0)

      assert Interpolant.gap_threshold_factor(interp_override) == 13.0

      assert {:ok, batch} =
               Interpolant.states_at_j2000_s(interp_override, ["G01"], [@midpoint_j2000_s])

      assert batch.statuses == [:valid]
    end

    test "from_samples/2 and from_precise_ephemeris_samples/2 configure gap_threshold_factor" do
      raw = gapped_sp3_bytes()
      assert {:ok, sp3} = SP3.parse(raw, gap_threshold_factor: 13.0)
      samples = SP3.precise_ephemeris_samples(sp3)
      assert {:ok, pe} = PreciseEphemeris.from_samples(samples)

      assert {:ok, interp_samples} =
               Interpolant.from_samples(samples, gap_threshold_factor: 13.0)

      assert Interpolant.gap_threshold_factor(interp_samples) == 13.0

      assert {:ok, interp_pe} =
               Interpolant.from_precise_ephemeris_samples(pe, gap_threshold_factor: 13.0)

      assert Interpolant.gap_threshold_factor(interp_pe) == 13.0
    end
  end

  describe "Artifacts with gap_threshold_factor" do
    test "artifact_bytes/2 records gap_threshold_factor and open/1 restores it" do
      raw = gapped_sp3_bytes()
      assert {:ok, sp3_default} = SP3.parse(raw)

      # Default artifact
      assert {:ok, bytes_default} = Interpolant.artifact_bytes(sp3_default)
      assert {:ok, art_default} = InterpolantArtifact.open(bytes_default)
      assert InterpolantArtifact.gap_threshold_factor(art_default) == 1.5
      assert PreciseInterpolantArtifact.gap_threshold_factor(art_default) == 1.5

      assert {:ok, batch} =
               InterpolantArtifact.states_at_j2000_s(art_default, ["G01"], [@midpoint_j2000_s])

      assert batch.statuses == [:gap]

      # Artifact with factor 13.0 override
      assert {:ok, bytes_f13} =
               Interpolant.artifact_bytes(sp3_default, gap_threshold_factor: 13.0)

      assert {:ok, art_f13} = InterpolantArtifact.open(bytes_f13)
      assert InterpolantArtifact.gap_threshold_factor(art_f13) == 13.0
      assert PreciseInterpolantArtifact.gap_threshold_factor(art_f13) == 13.0

      assert {:ok, batch} =
               InterpolantArtifact.states_at_j2000_s(art_f13, ["G01"], [@midpoint_j2000_s])

      assert batch.statuses == [:valid]

      # Opened via PreciseInterpolantArtifact
      assert {:ok, canonical_art} = PreciseInterpolantArtifact.open(bytes_f13)
      assert PreciseInterpolantArtifact.gap_threshold_factor(canonical_art) == 13.0

      # Artifact from InterpolantArtifact.artifact_bytes/2 and PreciseInterpolantArtifact.artifact_bytes/2
      assert {:ok, art_bytes_1} =
               InterpolantArtifact.artifact_bytes(sp3_default, gap_threshold_factor: 13.0)

      assert art_bytes_1 == bytes_f13

      assert {:ok, art_bytes_2} =
               PreciseInterpolantArtifact.artifact_bytes(sp3_default, gap_threshold_factor: 13.0)

      assert art_bytes_2 == bytes_f13
    end
  end
end
