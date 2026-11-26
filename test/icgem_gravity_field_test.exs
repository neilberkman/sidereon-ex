defmodule Sidereon.IcgemGravityFieldTest do
  use ExUnit.Case, async: true

  alias Sidereon.Forces.IcgemGravityField
  alias Sidereon.Forces.IcgemGravityField.IcgemError
  alias Sidereon.Forces.IcgemGravityField.IcgemHeader
  alias Sidereon.Forces.IcgemGravityField.IcgemSigmas
  alias Sidereon.Forces.IcgemGravityField.IcgemTimeVariableTerm
  alias Sidereon.Forces.SphericalHarmonicGravity
  alias Sidereon.Forces.SphericalHarmonicGravity.SphericalHarmonicCoefficient
  alias Sidereon.Test.CoreGolden

  @text File.read!(Path.expand("fixtures/gravity/degree2.gfc", __DIR__))
  @coefficient %SphericalHarmonicCoefficient{degree: 2, order: 0, c: -4.84165e-4, s: 0.0}

  test "ICGEM exposes header, coefficients, uncertainty, and truncation" do
    assert {:ok, field} = IcgemGravityField.parse(@text)
    assert {:ok, same} = IcgemGravityField.parse_truncated(@text, 2, 2)
    assert {:ok, truncated} = IcgemGravityField.parse_truncated(@text, 2, 0)

    assert IcgemGravityField.equal?(field, same)
    refute IcgemGravityField.equal?(field, truncated)
    assert IcgemGravityField.stored_max_degree(truncated) == 2
    assert IcgemGravityField.stored_max_order(truncated) == 0

    assert IcgemGravityField.header(field) === %IcgemHeader{
             model_name: "degree2",
             gravity_constant_m3_s2: 3.986_004_418e14,
             radius_m: 6_378_137.0,
             max_degree: 2,
             errors: :formal,
             normalization: :fully_normalized,
             tide_system: :tide_free,
             format: :icgem1_0
           }

    assert IcgemGravityField.static_coefficient(field, 2, 0) === @coefficient
    assert IcgemGravityField.static_coefficient(truncated, 2, 1) == nil
    assert IcgemGravityField.static_sigmas(field, 2, 0) === %IcgemSigmas{calibrated: nil, formal: {1.0e-12, 0.0}}
    assert IcgemGravityField.coefficient_at(field, 2, 0, 0.0) === {:ok, @coefficient}
    assert IcgemGravityField.time_variable_terms(field) === []
    refute IcgemGravityField.time_variable?(field)
    assert {:ok, assumed} = IcgemGravityField.with_assumed_tide_system(field, :tide_free)
    assert IcgemGravityField.equal?(field, assumed)
  end

  test "unbounded time-variable coefficients preserve both endpoints" do
    text = String.replace(@text, "gfc 2 0 -4.84165e-4 0 1e-12 0", "gfct 2 0 -4.84165e-4 0 1e-12 0 20000101")
    assert {:ok, field} = IcgemGravityField.parse(text)
    assert IcgemGravityField.time_variable?(field)
    assert IcgemGravityField.static_coefficient(field, 2, 0) == nil
    assert IcgemGravityField.coefficient_at(field, 2, 0, 0.0) === {:ok, @coefficient}

    assert IcgemGravityField.time_variable_terms(field) === [
             %IcgemTimeVariableTerm{
               line: 10,
               kind: :constant,
               degree: 2,
               order: 0,
               c: -4.84165e-4,
               s: 0.0,
               sigmas: %IcgemSigmas{formal: {1.0e-12, 0.0}},
               reference_tt_seconds: -43_200.0,
               valid_from_tt_seconds: :negative_infinity,
               valid_until_tt_seconds: :infinity
             }
           ]
  end

  test "spherical harmonics evaluate potential and acceleration in body-fixed coordinates" do
    expected = CoreGolden.load("gravity_and_radiation.json")
    [_epoch, position, _velocity] = expected["initial"]
    position = CoreGolden.tuple3(position)

    assert {:ok, field} = IcgemGravityField.parse(@text)
    assert {:ok, harmonic} = IcgemGravityField.gravity(field, 2, 2)
    assert {:ok, same} = IcgemGravityField.gravity_in_tide_system(field, 2, 2, :tide_free)
    assert {:ok, different} = IcgemGravityField.gravity_in_tide_system(field, 2, 2, :zero_tide)
    assert SphericalHarmonicGravity.equal?(harmonic, same)
    refute SphericalHarmonicGravity.equal?(harmonic, different)

    assert SphericalHarmonicGravity.max_degree(harmonic) == 2
    assert SphericalHarmonicGravity.max_order(harmonic) == 2
    assert SphericalHarmonicGravity.mu_km3_s2(harmonic) === 398_600.4418
    assert SphericalHarmonicGravity.reference_radius_km(harmonic) === 6378.137
    assert SphericalHarmonicGravity.tide_system(harmonic) == :tide_free
    refute SphericalHarmonicGravity.time_variable?(harmonic)
    assert SphericalHarmonicGravity.coefficient_at(harmonic, 2, 0, 0.0) === {:ok, @coefficient}

    acceleration = CoreGolden.tuple3(expected["icgem_acceleration"])
    potential = CoreGolden.f(expected["icgem_potential"])

    assert SphericalHarmonicGravity.body_fixed_acceleration_at_km_s2(harmonic, position, 0.0) === {:ok, acceleration}
    assert SphericalHarmonicGravity.body_fixed_acceleration_km_s2(harmonic, position) === {:ok, acceleration}
    assert SphericalHarmonicGravity.body_fixed_potential_at_km2_s2(harmonic, position, 0.0) === {:ok, potential}
    assert SphericalHarmonicGravity.body_fixed_potential_km2_s2(harmonic, position) === {:ok, potential}

    assert {:ok, egm96} = SphericalHarmonicGravity.egm96_truncated(8, 8)

    assert SphericalHarmonicGravity.body_fixed_acceleration_km_s2(egm96, position) ===
             {:ok, CoreGolden.tuple3(expected["egm96_acceleration"])}
  end

  test "missing end-of-header and missing mandatory fields carry exact reasons" do
    assert {:error, %IcgemError{kind: :missing_end_of_head, detail: detail} = error} = IcgemGravityField.parse("")
    assert detail === %{}
    assert to_string(error) === "ICGEM file has no end_of_head line"
    missing = String.replace(@text, "radius 6378137\n", "")

    assert {:error, %IcgemError{kind: :missing_header_keyword, detail: %{keyword: "radius"}}} =
             IcgemGravityField.parse(missing)
  end

  test "data-section keywords and coefficient indices are validated" do
    for {replacement, kind, detail} <- [
          {"gfc 2 0 -4.84165e-4", :missing_field, %{line: 10, keyword: "gfc", field: "S"}},
          {"gfc 2 0 bad 0 1e-12 0", :invalid_field, %{line: 10, keyword: "gfc", field: "C", value: "bad"}},
          {"typo 2 0 -4.84165e-4 0 1e-12 0", :unknown_record_keyword, %{line: 10, keyword: "typo"}},
          {"2 0 -4.84165e-4 0 1e-12 0", :missing_record_keyword, %{line: 10}},
          {"gfc 3 0 -4.84165e-4 0 1e-12 0", :degree_above_maximum, %{line: 10, degree: 3, max_degree: 2}},
          {"gfc 2 3 -4.84165e-4 0 1e-12 0", :order_above_degree, %{line: 10, degree: 2, order: 3}},
          {"gfc 2 1 -4.84165e-4 0 1e-12 0", :repeated_coefficient, %{line: 11, first_line: 10, degree: 2, order: 1}}
        ] do
      text = String.replace(@text, "gfc 2 0 -4.84165e-4 0 1e-12 0", replacement)
      assert {:error, %IcgemError{kind: ^kind, detail: ^detail}} = IcgemGravityField.parse(text)
    end
  end

  test "tide system and truncation refusals retain values" do
    assert {:ok, field} = IcgemGravityField.parse(@text)

    assert {:error, %IcgemError{kind: :tide_system_conflict, detail: %{stated: :tide_free, assumed: :zero_tide}}} =
             IcgemGravityField.with_assumed_tide_system(field, :zero_tide)

    assert {:error, %IcgemError{kind: :truncation_out_of_range, detail: %{degree: 3, order: 2, max_degree: 2}}} =
             IcgemGravityField.gravity(field, 3, 2)

    assert {:ok, unknown} =
             IcgemGravityField.parse(String.replace(@text, "tide_system tide_free", "tide_system unknown"))

    assert {:error, %IcgemError{kind: :unknown_tide_system, detail: %{}}} = IcgemGravityField.gravity(unknown, 2, 2)
  end

  test "structural refusals cover repeated headers, missing coefficients and sparse files" do
    repeated = String.replace(@text, "radius 6378137\n", "radius 6378137\nradius 6378137\n")

    assert {:error, %IcgemError{kind: :repeated_header_keyword, detail: %{line: 5, first_line: 4, keyword: "radius"}}} =
             IcgemGravityField.parse(repeated)

    missing = String.replace(@text, "gfc 2 1 0 0 1e-12 1e-12", "non-coefficient comment")

    assert {:error, %IcgemError{kind: :missing_coefficient, detail: %{degree: 2, order: 1}}} =
             IcgemGravityField.parse(missing)

    sparse = String.replace(@text, "max_degree 2", "max_degree 3")

    assert {:error, %IcgemError{kind: :too_few_records, detail: %{max_degree: 3, required: 7, lines: 3}}} =
             IcgemGravityField.parse(sparse)
  end

  test "ICGEM enforces interval disjointness and coverage" do
    dated = icgem2("")

    assert {:error, %IcgemError{kind: :keyword_not_in_format, detail: %{line: 14, keyword: "dot"}}} =
             IcgemGravityField.parse(dated <> "dot 2 0 1e-12 0 0 0 20000101 20100101\n")

    assert {:error,
            %IcgemError{
              kind: :overlapping_term,
              detail: %{line: 14, first_line: 11, keyword: "gfct", degree: 2, order: 0}
            }} =
             IcgemGravityField.parse(dated <> "gfct 2 0 -4.8e-4 0 0 0 20090101 20110101\n")

    assert {:error, %IcgemError{kind: :uncovered_term, detail: %{line: 14, keyword: "trnd", degree: 2, order: 0}}} =
             IcgemGravityField.parse(dated <> "trnd 2 0 1e-12 0 0 0 20100101 20110101\n")

    assert {:ok, field} = IcgemGravityField.parse(dated)

    assert {:error,
            %IcgemError{kind: :epoch_outside_validity, detail: %{degree: 2, order: 0, epoch_tt_seconds: -43_201.0}}} =
             IcgemGravityField.coefficient_at(field, 2, 0, -43_201.0)

    assert {:ok, overflow} = IcgemGravityField.parse(icgem2("acos 2 0 1e-11 0 0 0 20000101 20100101 1e-320\n"))

    assert {:error,
            %IcgemError{kind: :non_finite_coefficient, detail: %{degree: 2, order: 0, epoch_tt_seconds: -43_199.0}}} =
             IcgemGravityField.coefficient_at(overflow, 2, 0, -43_199.0)
  end

  test "unnormalized coefficients that overflow during normalization are refused" do
    header = @text |> String.split("end_of_head", parts: 2) |> hd()
    header = header |> String.replace("max_degree 2", "max_degree 170") |> String.replace("errors formal", "errors no")
    header = String.replace(header, "norm fully_normalized", "norm unnormalized")

    rows =
      for degree <- 2..170, order <- 0..degree do
        c = if degree == 170 and order == 170, do: 1, else: 0
        "gfc #{degree} #{order} #{c} 0\n"
      end

    assert {:error, %IcgemError{kind: :normalization_out_of_range, detail: %{line: 14_712, degree: 170, order: 170}}} =
             IcgemGravityField.parse(IO.iodata_to_binary([header, "end_of_head\n", rows]))
  end

  test "ICGEM header flags and trigonometric term kinds preserve their data" do
    assert %IcgemSigmas{} === %IcgemSigmas{calibrated: nil, formal: nil}
    record = "gfc 2 0 -4.84165e-4 0 1e-12 0"

    for {flag, expected} <- [
          {"calibrated", %IcgemSigmas{calibrated: {1.0e-12, 0.0}, formal: nil}},
          {"calibrated_and_formal", %IcgemSigmas{calibrated: {1.0e-12, 0.0}, formal: {0.0, 0.0}}},
          {"no", nil}
        ] do
      text = String.replace(@text, "errors formal", "errors " <> flag)

      text =
        if flag == "calibrated_and_formal" do
          Regex.replace(~r/^gfc .*$/m, text, &(&1 <> " 0 0"))
        else
          if flag == "no", do: Regex.replace(~r/^(gfc \S+ \S+ \S+ \S+) .*$/m, text, "\\1"), else: text
        end

      assert {:ok, field} = IcgemGravityField.parse(text)
      assert IcgemGravityField.header(field).errors === String.to_existing_atom(flag)

      assert IcgemGravityField.static_sigmas(field, 2, 0) === expected
    end

    assert {:ok, field} =
             @text
             |> String.replace("norm fully_normalized", "norm unnormalized")
             |> String.replace(record, "gfc 2 0 0 0 0 0")
             |> IcgemGravityField.parse()

    assert IcgemGravityField.header(field).normalization === :unnormalized

    text =
      icgem2("""
      trnd 2 0 1e-12 0 0 0 20000101 20100101
      acos 2 0 2e-12 0 0 0 20000101 20100101 1
      asin 2 0 3e-12 0 0 0 20000101 20100101 0.5
      """)

    assert {:ok, field} = IcgemGravityField.parse(text)
    assert IcgemGravityField.header(field).format === :icgem2_0

    assert field |> IcgemGravityField.time_variable_terms() |> Enum.map(& &1.kind) ===
             [:constant, :trend, {:cosine, 1.0}, {:sine, 0.5}]
  end

  defp icgem2(extra) do
    text = String.replace(@text, "gfc 2 0 -4.84165e-4 0 1e-12 0", "gfct 2 0 -4.84165e-4 0 1e-12 0 20000101 20100101")
    "format icgem2.0\n" <> text <> extra
  end
end
