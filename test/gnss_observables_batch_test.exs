defmodule Sidereon.GNSS.ObservablesBatchTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Observables
  alias Sidereon.GNSS.SP3

  @grg Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")
  @rx {3_512_900.0, 780_500.0, 5_248_700.0}
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
end
