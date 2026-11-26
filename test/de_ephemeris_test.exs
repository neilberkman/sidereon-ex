defmodule Sidereon.DeEphemerisTest do
  use ExUnit.Case, async: true

  alias Sidereon.DeEphemeris
  alias Sidereon.DeEphemeris.DeError
  alias Sidereon.DeEphemeris.DeState
  alias Sidereon.DeEphemeris.DeSunMoon
  alias Sidereon.Propagator.PropagationContext
  alias Sidereon.Test.CoreGolden

  @de Path.expand("fixtures/de/lnxp1990.440", __DIR__)

  test "DE headers, constants, and geocentric states" do
    expected = CoreGolden.load("de_ephemeris.json")
    assert {:ok, ephemeris} = DeEphemeris.load(@de)
    assert {:ok, parsed} = @de |> File.read!() |> DeEphemeris.from_bytes()
    assert DeEphemeris.version(ephemeris) == expected["version"]
    assert DeEphemeris.record_size(ephemeris) == expected["record_size"]
    assert DeEphemeris.coverage_tdb_seconds(ephemeris) === List.to_tuple(CoreGolden.f(expected["coverage"]))

    assert DeEphemeris.constants(ephemeris) ===
             Map.new(expected["constants"], fn {name, value} -> {name, CoreGolden.f(value)} end)

    assert DeEphemeris.astronomical_unit_m(ephemeris) === CoreGolden.f(expected["astronomical_unit_m"])
    assert DeEphemeris.earth_moon_mass_ratio(ephemeris) === CoreGolden.f(expected["earth_moon_mass_ratio"])
    assert DeEphemeris.gm_m3_s2(ephemeris, :sun) === {:ok, CoreGolden.f(expected["sun_gm"])}

    for {body, gm} <- expected["body_gm"] do
      assert DeEphemeris.gm_m3_s2(ephemeris, String.to_existing_atom(body)) === {:ok, CoreGolden.f(gm)}
    end

    epoch = CoreGolden.f(expected["epoch"])
    sun = de_state(expected["sun"])
    moon = de_state(expected["moon"])
    assert DeEphemeris.sun_moon_at_tdb_seconds(parsed, epoch) === {:ok, %DeSunMoon{sun: sun, moon: moon}}

    assert DeEphemeris.sun_moon_positions_at_tdb_seconds(ephemeris, epoch) ===
             {:ok, {sun.position_m, moon.position_m}}

    context = PropagationContext.new() |> PropagationContext.with_de_ephemeris(ephemeris)
    assert PropagationContext.de_ephemeris(context) === ephemeris
    assert PropagationContext.ut1_departure(context) == nil
  end

  test "DE errors preserve the source details" do
    assert {:error, %DeError{kind: :io, detail: detail}} = DeEphemeris.load(@de <> ".missing")
    assert detail === %{message: "No such file or directory (os error 2)", raw_os_error: 2}

    assert {:error, %DeError{kind: :invalid_file, detail: %{reason: "incomplete first header record"}} = error} =
             DeEphemeris.from_bytes(<<>>)

    assert to_string(error) === "Invalid DE ephemeris: incomplete first header record"

    assert {:ok, ephemeris} = DeEphemeris.load(@de)

    assert {:error, %DeError{kind: :outside_coverage, detail: %{epoch_tdb_seconds: +0.0}}} =
             DeEphemeris.sun_moon_at_tdb_seconds(ephemeris, 0.0)

    assert {:error, %DeError{kind: :invalid_body, detail: %{body: :unlisted}}} =
             DeEphemeris.gm_m3_s2(ephemeris, :unlisted)
  end

  test "an undefined DE record preserves the evaluation refusal" do
    data = File.read!(@de)
    %{"record_size" => size, "coverage" => [start, _end]} = CoreGolden.load("de_ephemeris.json")
    pointer = 2696 + 12 * 10
    <<_::binary-size(^pointer), offset::little-unsigned-32, _::binary>> = data
    position = 2 * size + 8 * (offset - 1)
    <<before::binary-size(^position), _::binary-size(8), after_coefficient::binary>> = data
    undefined = <<before::binary, 0x7FF8000000000000::little-unsigned-64, after_coefficient::binary>>

    assert {:ok, ephemeris} = DeEphemeris.from_bytes(undefined)

    assert {:error, %DeError{kind: :non_finite_state, detail: details}} =
             DeEphemeris.sun_moon_positions_at_tdb_seconds(ephemeris, CoreGolden.f(start))

    assert details == %{}
  end

  defp de_state(%{"position_m" => position, "velocity_m_s" => velocity}) do
    %DeState{position_m: CoreGolden.tuple3(position), velocity_m_s: CoreGolden.tuple3(velocity)}
  end
end
