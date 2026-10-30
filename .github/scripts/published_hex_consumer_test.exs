defmodule SidereonPublishedHexConsumerTest do
  use ExUnit.Case, async: false

  alias Sidereon.Astro.{Anomaly, Equinoctial, Relative}
  alias Sidereon.GNSS.{Data, Distribution, SP3}
  alias Sidereon.GNSS.Distribution.EarthdataAuth
  alias Sidereon.LeastSquares
  alias Sidereon.LeastSquares.Result
  alias Sidereon.OrbitalElements

  @sp3 """
  #cP2020  6 24  0  0  0.00000000       1 ORBIT IGS14 FIT  TST
  ## 2111 432000.00000000   900.00000000 59024 0.0000000000000
  +    1   G01  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0
  ++         0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0
  %c M  cc GPS ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc
  %c cc cc ccc ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc
  %f  1.2500000  1.025000000  0.00000000000  0.000000000000000
  %f  0.0000000  0.000000000  0.00000000000  0.000000000000000
  %i    0    0    0    0      0      0      0      0         0
  %i    0    0    0    0      0      0      0      0         0
  /* PUBLIC CONSUMER SP3-c FIXTURE
  *  2020  6 24  0  0  0.00000000
  PG01  15000.000000 -20000.000000   5000.000000    123.456789
  EOF
  """

  test "the exact requested public application and its NIF are running" do
    expected = System.fetch_env!("SIDEREON_CONSUMER_VERSION")
    assert Application.spec(:sidereon, :vsn) |> to_string() == expected

    assert {:ok, %Result{x: [intercept, slope], cost: cost, success: true}} =
             LeastSquares.least_squares(%{
               kind: :linear,
               a: [[1.0, 1.0], [1.0, 2.0], [1.0, 3.0]],
               b: [6.0, 8.0, 10.0]
             })

    assert_in_delta intercept, 4.0, 1.0e-9
    assert_in_delta slope, 2.0, 1.0e-9
    assert_in_delta cost, 0.0, 1.0e-12
  end

  test "the 3.0 SP3 writer migration returns tagged success values" do
    assert {:ok, sp3} = SP3.parse(@sp3)
    assert {:ok, text} = SP3.to_sp3_string(sp3)
    assert {:ok, iodata} = SP3.to_iodata(sp3)
    assert text == IO.iodata_to_binary(iodata)
    assert {:ok, reparsed} = SP3.parse(text)
    assert SP3.satellite_ids(reparsed) == ["G01"]
  end

  test "grid-in SP3 mean merge stays strictly writable and reports zero rounding" do
    assert {:ok, first} = SP3.parse(@sp3)
    second_text = String.replace(@sp3, "15000.000000", "15000.000001")
    assert {:ok, second} = SP3.parse(second_text)

    assert {:ok, first_state} = SP3.state(first, "G01", 0)
    assert {:ok, second_state} = SP3.state(second, "G01", 0)

    assert {:ok, merged, _merge_report} =
             SP3.merge([first, second], min_agree: 1, clock_min_common: 1)

    assert {:ok, strict_text} = SP3.to_sp3_string(merged)
    assert {:ok, reread} = SP3.parse(strict_text)
    assert {:ok, state} = SP3.state(reread, "G01", 0)
    assert {:ok, merged_state} = SP3.state(merged, "G01", 0)
    assert state.x_m == merged_state.x_m
    assert state.x_m in [first_state.x_m, second_state.x_m]

    assert {:ok, rounded_text, report} = SP3.to_sp3_string_with_rounding(merged)
    assert rounded_text == strict_text
    assert report.position_x_m == 0.0
  end

  test "three-satellite half-grid clock means remain strictly writable" do
    first_clocks = [-598.410235, 138.983111, 0.0]
    second_clocks = [-598.410234, 138.983110, 0.0]
    assert {:ok, first} = clock_product(first_clocks)
    assert {:ok, second} = clock_product(second_clocks)

    assert {:ok, _first_text} = SP3.to_sp3_string(first)
    assert {:ok, _second_text} = SP3.to_sp3_string(second)

    assert {:ok, merged, _merge_report} =
             SP3.merge([first, second], min_agree: 1, clock_min_common: 3)

    assert {:ok, strict_text} = SP3.to_sp3_string(merged)
    assert {:ok, reread} = SP3.parse(strict_text)

    for sat_id <- ["G01", "G02", "G03"] do
      assert {:ok, left} = SP3.state(first, sat_id, 0)
      assert {:ok, right} = SP3.state(second, sat_id, 0)
      assert {:ok, merged_state} = SP3.state(merged, sat_id, 0)
      assert {:ok, read_state} = SP3.state(reread, sat_id, 0)
      assert read_state.clock_s == merged_state.clock_s
      assert read_state.clock_s in [left.clock_s, right.clock_s]
    end

    assert {:ok, rounded_text, report} = SP3.to_sp3_string_with_rounding(merged)
    assert rounded_text == strict_text
    assert report.clock_s == 0.0
    assert report.clock_rate_s_s == 0.0
  end

  test "rounding reports a nonzero clock change without changing its source" do
    {:ok, canonical} = clock_product([-598.410235, 138.983111, 0.0])
    {:ok, canonical_text} = SP3.to_sp3_string(canonical)
    record = Enum.find(String.split(canonical_text, "\n"), &String.starts_with?(&1, "PG01"))
    refined_record = String.slice(record, 0, 46) <> String.pad_leading("-598.4102354", 14)
    refined_text = String.replace(canonical_text, record, refined_record)
    assert {:ok, source} = SP3.parse(refined_text)
    assert {:ok, original_state} = SP3.state(source, "G01", 0)

    assert {:error, {:record_value_not_representable, _detail}} = SP3.to_sp3_string(source)
    assert {:ok, rounded_text, report} = SP3.to_sp3_string_with_rounding(source)
    assert {:ok, reread} = SP3.parse(rounded_text)
    assert {:ok, rounded_state} = SP3.state(reread, "G01", 0)
    assert report.clock_s == abs(rounded_state.clock_s - original_state.clock_s)
    assert report.clock_s > 0.0
    assert {:ok, unchanged_state} = SP3.state(source, "G01", 0)
    assert unchanged_state.clock_s == original_state.clock_s

    assert report.position_x_m == 0.0
    assert report.position_y_m == 0.0
    assert report.position_z_m == 0.0
    assert report.velocity_x_m_s == 0.0
    assert report.velocity_y_m_s == 0.0
    assert report.velocity_z_m_s == 0.0
    assert report.clock_rate_s_s == 0.0
  end

  defp clock_product(clocks) do
    satellites = ["G01", "G02", "G03"]
    satellite_header = Enum.join(satellites, "") <> String.duplicate("  0", 14)

    records =
      Enum.zip(satellites, clocks)
      |> Enum.map(fn {satellite, clock_us} ->
        fmt = fn value -> value |> :erlang.float_to_binary(decimals: 6) |> String.pad_leading(14) end
        "P" <> satellite <> fmt.(15_000.0) <> fmt.(-20_000.0) <> fmt.(5000.0) <> fmt.(clock_us)
      end)

    text =
      Enum.join(
        [
          "#cP2020  6 25  0  0  0.00000000       1 ORBIT IGS14 FIT  TST",
          "## 2111 432000.00000000   900.00000000 59025 0.0000000000000",
          "+    3   " <> satellite_header,
          "++         0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0",
          "%c G  cc GPS ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc",
          "%c cc cc ccc ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc",
          "%f  1.2500000  1.025000000  0.00000000000  0.000000000000000",
          "%f  0.0000000  0.000000000  0.00000000000  0.000000000000000",
          "%i    0    0    0    0      0      0      0      0         0",
          "%i    0    0    0    0      0      0      0      0         0",
          "/* RELEASE CONSUMER SP3 CLOCK FIXTURE",
          "*  2020  6 25  0  0  0.00000000"
        ] ++ records ++ ["EOF", ""],
        "\n"
      )

    SP3.parse(text)
  end

  test "custom HTTP exception diagnostics redact credentials and exception data" do
    token = "PRIVATE_CONSUMER_BEARER"
    option_secret = "PRIVATE_CONSUMER_OPTION"
    message_secret = "PRIVATE_CONSUMER_EXCEPTION"
    parent = self()

    assert {:ok, product} = Data.mgex_sp3(:cod, ~D[2026-07-12])
    assert {:ok, request} = Data.request(product, [Distribution.nasa_cddis()])

    client = fn url, opts ->
      send(parent, {:request, url, opts})
      raise "#{message_secret} #{token} #{option_secret}"
    end

    diagnostics = fn event -> send(parent, {:diagnostic, event}) end
    cache = Path.join(System.tmp_dir!(), "sidereon-public-consumer-redaction")
    File.rm_rf!(cache)
    on_exit(fn -> File.rm_rf!(cache) end)

    assert {:error, {:http_client_failure, :raised, safe_url}} =
             Data.acquire(request,
               cache_dir: cache,
               earthdata_auth: EarthdataAuth.bearer(token),
               private_probe: option_secret,
               http_client: client,
               http_client_exception_diagnostics: diagnostics,
               retries: 1
             )

    assert safe_url =~ "cddis.nasa.gov"
    refute safe_url =~ token
    assert_received {:request, raw_url, request_opts}
    assert raw_url =~ "cddis.nasa.gov"
    assert Keyword.fetch!(request_opts, :private_probe) == option_secret
    assert_received {:diagnostic, event}
    assert Map.keys(event) |> Enum.sort() == [:client_callsite, :exception_class, :stack_frames]
    assert event.exception_class == RuntimeError
    rendered = inspect(event)
    refute rendered =~ token
    refute rendered =~ option_secret
    refute rendered =~ message_secret
    refute rendered =~ raw_url
    refute rendered =~ inspect(request_opts)
  end

  test "3.0.2 preserves undefined angles and flat compatible error contracts" do
    undefined_angles = [:raan, :argp, :nu, :arglat, :lonper]
    assert {:ok, before} = OrbitalElements.rv2coe({1.0, 0.0, 0.0}, {0.0, 1.0, 0.0}, 1.0)
    assert before.orbit_type == :circular_equatorial
    assert Enum.all?(undefined_angles, &(Map.fetch!(before, &1) == nil))
    assert {:ok, propagated} = Anomaly.propagate_kepler(before, 0.0, 1.0)
    assert Enum.all?(undefined_angles, &(Map.fetch!(propagated, &1) == nil))
    assert propagated.truelon == before.truelon
    assert {:ok, equinoctial} = Equinoctial.coe2eq(before)
    assert {:ok, modified} = Equinoctial.coe2mee(before)
    assert is_float(equinoctial.lambda)
    assert is_float(modified.l)

    zero = %Relative.State{
      epoch_tdb_seconds: 0.0,
      position_km: {0.0, 0.0, 0.0},
      velocity_km_s: {0.0, 1.0, 0.0}
    }

    assert {:error, :invalid_input} = Relative.rotation(:rsw, zero)

    assert_raise ArgumentError, "relative-frame calculation failed: :invalid_input", fn ->
      Relative.rotation!(:rsw, zero)
    end

    assert {:error, :invalid_input} = Sidereon.sun_moon_ecef([0])
    valid_epoch_us = DateTime.to_unix(~U[2026-05-13 00:00:00Z], :microsecond)
    assert {:ok, %{sun: [sun], moon: [moon]}} = Sidereon.sun_moon_ecef([valid_epoch_us])
    assert tuple_size(sun) == 3
    assert tuple_size(moon) == 3

    origin = {0.0, 0.0, 0.0}
    axis = {1.0, 0.0, 0.0}
    assert {:error, :invalid_input} = Sidereon.Angles.angular_separation(origin, axis)
    assert {:error, :invalid_input} = Sidereon.sun_angle(origin, axis)
    assert {:error, :invalid_input} = Sidereon.moon_angle(origin, axis)
  end
end
