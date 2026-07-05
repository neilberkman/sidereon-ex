defmodule Sidereon.GNSS.ObservablesBatchTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Observables
  alias Sidereon.GNSS.PreciseEphemeris.Interpolant
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.Time

  @grg Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")
  @rx {3_512_900.0, 780_500.0, 5_248_700.0}
  @surface_rx {4_484_127.992325785, 550_581.6865701446, 4_487_560.540900275}
  @below_mask_rx {4_027_894.0, 307_046.0, 4_919_474.0}
  @epoch ~N[2020-06-24 12:00:00]

  setup do
    sp3 = SP3.load!(@grg)

    visible =
      sp3
      |> Observables.predict_all(@rx, @epoch)
      |> Enum.filter(fn {id, r} -> match?({:ok, _}, r) and String.starts_with?(id, "G") end)
      |> Enum.map(fn {id, _} -> id end)
      |> Enum.take(4)

    {:ok, sp3: sp3, ids: visible}
  end

  test "batch results are index-aligned and bit-identical to per-request predict/5",
       %{sp3: sp3, ids: ids} do
    requests = Enum.map(ids, fn id -> {id, @rx, @epoch} end)
    batch = Observables.predict_batch(sp3, requests)

    assert length(batch) == length(requests)

    for {id, batched} <- Enum.zip(ids, batch) do
      assert {:ok, obs} = batched
      assert {:ok, single} = Observables.predict(sp3, id, @rx, @epoch)
      # The batch shares the single-shot kernel, so values match bit-for-bit.
      assert obs.geometric_range_m == single.geometric_range_m
      assert obs.range_rate_m_s == single.range_rate_m_s
      assert obs.doppler_hz == single.doppler_hz
    end
  end

  test "a malformed request is reported in place without sinking the batch",
       %{sp3: sp3, ids: ids} do
    [first | _] = ids
    requests = [{first, @rx, @epoch}, {"not-a-sat", @rx, @epoch}, {first, {1.0, 2.0}, @epoch}]
    assert [ok, bad_sat, bad_rx] = Observables.predict_batch(sp3, requests)
    assert {:ok, _obs} = ok
    assert {:error, _reason} = bad_sat
    assert {:error, :invalid_receiver} = bad_rx
  end

  test "an empty request list returns an empty list", %{sp3: sp3} do
    assert [] = Observables.predict_batch(sp3, [])
  end

  test "emission_media_batch returns index-aligned arrays and media delays", %{sp3: sp3} do
    # Reference literals generated from sidereon-core through this binding
    # against the patched core on 2026-07-05.
    {:ok, t_rx_j2000_s} = Time.epoch_to_j2000_seconds_fractional(@epoch)
    requests = [{"G21", t_rx_j2000_s}, {"G16", t_rx_j2000_s}, {"G26", t_rx_j2000_s}]

    assert {:ok, batch} =
             Observables.emission_media_batch(sp3, requests, @surface_rx,
               troposphere: true,
               min_elevation_deg: 0.0
             )

    assert batch.statuses == [:valid, :valid, :valid]
    assert batch.element_errors == [nil, nil, nil]
    assert length(batch.positions_ecef_m) == 3
    assert length(batch.clocks_s) == 3
    assert length(batch.ionosphere_slant_delays_m) == 3
    assert length(batch.troposphere_delays_m) == 3

    assert {x, y, z} = hd(batch.positions_ecef_m)
    assert_in_delta x, 16_999_913.180000003, 1.0e-9
    assert_in_delta y, 4_708_560.403000001, 1.0e-9
    assert_in_delta z, 20_550_418.404999997, 1.0e-9

    assert_in_delta hd(batch.clocks_s), 1.5546298999999998e-5, 1.0e-18
    assert batch.ionosphere_slant_delays_m == [0.0, 0.0, 0.0]

    assert [tropo_0, tropo_1, tropo_2] = batch.troposphere_delays_m
    assert_in_delta tropo_0, 2.4261120112807175, 1.0e-15
    assert_in_delta tropo_1, 2.50692031875299, 1.0e-15
    assert_in_delta tropo_2, 2.906273871798339, 1.0e-15
  end

  test "emission_media_batch accepts artifact sources and surfaces typed row statuses", %{sp3: sp3} do
    {:ok, t_rx_j2000_s} = Time.epoch_to_j2000_seconds_fractional(@epoch)
    requests = [{"G01", t_rx_j2000_s}, {"G02", t_rx_j2000_s}, {"G03", t_rx_j2000_s}]

    {:ok, bytes} = Interpolant.artifact_bytes(sp3)
    {:ok, artifact} = Interpolant.open(bytes)

    assert {:ok, from_sp3} = Observables.emission_media_batch(sp3, requests, @below_mask_rx)
    assert {:ok, from_artifact} = Observables.emission_media_batch(artifact, requests, @below_mask_rx)
    assert from_artifact == from_sp3

    assert {:ok, below_mask} =
             Observables.emission_media_batch(sp3, requests, @below_mask_rx,
               troposphere: true,
               min_elevation_deg: 0.0
             )

    assert below_mask.statuses == [
             :below_elevation_cutoff,
             :below_elevation_cutoff,
             :below_elevation_cutoff
           ]

    assert below_mask.element_errors == [nil, nil, nil]
    assert below_mask.ionosphere_slant_delays_m == [nil, nil, nil]
    assert below_mask.troposphere_delays_m == [nil, nil, nil]
  end
end
