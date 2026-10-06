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
