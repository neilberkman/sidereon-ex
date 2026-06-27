defmodule DopplerVelocityFixture202606 do
  @moduledoc """
  Build the pinned Doppler-velocity gate fixtures for the `doppler-positioning`
  capability from the staged GSDC corpus.

  Replays the D1 campaign's velocity-quality pipeline on the fastest vendored arc
  (2021-12-15 US-MTV-1, Pixel 5) and emits two self-contained fixtures under
  `test/fixtures/rtk/`:

    * `doppler_velocity_gsdc_2021_12_15_mtv1_pixel5_l1_gps.nav` - a thinned
      GPS-only RINEX 3 broadcast NAV holding only the GPS ephemeris records whose
      reference epoch falls in the arc window (with a lookback so each epoch has a
      valid record). The pinned test loads this so `Orbis.GNSS.Velocity.solve`
      computes its own satellite geometry from real broadcast ephemeris.

    * `doppler_velocity_gsdc_2021_12_15_mtv1_pixel5_l1_inputs.json` - per-epoch
      inputs to the velocity solve: GPST epoch, GPS D1C Doppler observations (sign
      applied), the broadcast-code SPP receiver ECEF for that epoch, and the
      central finite-difference truth velocity from the oracle truth track.

  The upstream RINEX-observation parse and the SPP position solve are tested
  elsewhere; baking their output into the inputs fixture keeps the gate
  self-contained while still running the real `Velocity.solve` as the code under
  test. Regenerate with:

      ORBIS_BUILD=1 mix run \\
        test/fixtures/rtk/generators/doppler_velocity_fixture_2026_06.exs

  Requires the staged corpus under /tmp/gsdc-work (phone RINEX + broadcast NAV).
  """

  alias Orbis.GNSS.Broadcast
  alias Orbis.GNSS.Positioning
  alias Orbis.GNSS.RINEX.Observations

  @gps_l1_hz 1_575_420_000.0

  # Fastest vendored arc: truth median speed ~24 m/s, so the velocity vector is
  # well above the truth finite-difference noise floor.
  @arc %{
    label: "gsdc_2021_12_15_mtv1_pixel5",
    rover_path:
      "/tmp/gsdc-work/train/2021-12-15-US-MTV-1/GooglePixel5/supplemental/gnss_rinex.21o",
    nav_path: "/tmp/gsdc-work/cors/BRDC00WRD_R_20213490000_01D_MN.rnx",
    oracle_fixture: "gsdc_2021_12_15_mtv1_pixel5_p222_demo5_rtklib_oracle.json"
  }

  # This arc's base station carries no Doppler, so the campaign sign basis falls
  # back to the raw RINEX convention.
  @doppler_sign 1.0
  @doppler_sign_basis "raw_rinex_default_no_base_doppler"

  # GPS ephemeris validity is ~2 h; include a 3 h lookback so every arc epoch has
  # a valid record, plus a small forward pad.
  @nav_lookback_s 3 * 3600
  @nav_forward_pad_s 300

  def main(_args) do
    fixture_dir = Path.expand("..", __DIR__)
    oracle_path = Path.join(fixture_dir, @arc.oracle_fixture)

    require_file!(@arc.rover_path)
    require_file!(@arc.nav_path)
    require_file!(oracle_path)

    IO.puts("loading #{@arc.label}")
    rover_obs = Observations.load!(@arc.rover_path)
    nav = Broadcast.load!(@arc.nav_path)
    oracle = oracle_path |> File.read!() |> Jason.decode!()

    base_arp = oracle_base_arp(oracle)
    oracle_by_time = Map.new(oracle["per_epoch"], &{&1["time"], &1})

    contexts = build_contexts(rover_obs, oracle_by_time)
    IO.puts("  matched #{length(contexts)} rover/oracle epochs")

    truth_by_time = truth_velocities(contexts)

    samples =
      contexts
      |> Enum.map(fn ctx ->
        doppler = rover_doppler_observations(rover_obs, ctx.index)

        if length(doppler) >= 4 do
          case spp_position(nav, rover_obs, ctx, base_arp) do
            nil ->
              nil

            %{x_m: rx, y_m: ry, z_m: rz} ->
              {tx, ty, tz} = Map.fetch!(truth_by_time, ctx.time)

              %{
                "time" => ctx.time,
                "epoch" => NaiveDateTime.to_iso8601(ctx.epoch),
                "receiver_ecef_m" => %{"x" => rx, "y" => ry, "z" => rz},
                "doppler_hz" => Enum.map(doppler, fn {sat, hz} -> [sat, hz] end),
                "truth_velocity_m_s" => %{"x" => tx, "y" => ty, "z" => tz}
              }
          end
        end
      end)
      |> Enum.reject(&is_nil/1)

    IO.puts("  built #{length(samples)} eligible velocity epochs")

    if length(samples) < 1000 do
      raise "only #{length(samples)} eligible epochs, fixture would not meet the gate sample size"
    end

    write_nav_fixture(fixture_dir, contexts)
    write_inputs_fixture(fixture_dir, samples)
    sanity_check(fixture_dir, samples)
  end

  # --- contexts -------------------------------------------------------------

  defp build_contexts(rover_obs, oracle_by_time) do
    rover_obs
    |> Observations.epochs()
    |> Enum.flat_map(fn entry ->
      epoch = naive_datetime(entry.epoch)
      time_key = epoch_key(epoch)

      case Map.fetch(oracle_by_time, time_key) do
        {:ok, oracle_epoch} ->
          truth = oracle_epoch["truth_ecef_m"]

          [
            %{
              index: entry.index,
              epoch: epoch,
              time: time_key,
              truth_ecef: {truth["x"], truth["y"], truth["z"]}
            }
          ]

        :error ->
          []
      end
    end)
  end

  # Central finite difference of the truth ECEF track over the matched grid,
  # matching the D1 campaign's truth-velocity oracle.
  defp truth_velocities(contexts) do
    count = length(contexts)

    contexts
    |> Enum.with_index()
    |> Map.new(fn {ctx, index} ->
      {left, right} =
        cond do
          count < 2 -> {index, index}
          index == 0 -> {0, 1}
          index == count - 1 -> {count - 2, count - 1}
          true -> {index - 1, index + 1}
        end

      l = Enum.at(contexts, left)
      r = Enum.at(contexts, right)
      dt = NaiveDateTime.diff(r.epoch, l.epoch, :microsecond) / 1_000_000.0

      velocity =
        if dt > 0.0 do
          {lx, ly, lz} = l.truth_ecef
          {rx, ry, rz} = r.truth_ecef
          {(rx - lx) / dt, (ry - ly) / dt, (rz - lz) / dt}
        else
          {0.0, 0.0, 0.0}
        end

      {ctx.time, velocity}
    end)
  end

  # --- per-epoch inputs -----------------------------------------------------

  defp rover_doppler_observations(rover_obs, index) do
    {:ok, values} = Observations.values(rover_obs, index, codes: %{"G" => ["D1C"]})

    values
    |> Enum.flat_map(fn {sat, observations} ->
      case Enum.find_value(observations, fn obs ->
             if obs.code == "D1C" and is_number(obs.value), do: obs.value
           end) do
        value when is_number(value) -> [{sat, value * @doppler_sign}]
        _ -> []
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp spp_position(nav, rover_obs, ctx, base_arp) do
    {:ok, prs} = Observations.pseudoranges(rover_obs, ctx.index, codes: %{"G" => ["C1C"]})
    {bx, by, bz} = base_arp

    case Positioning.solve(nav, prs, ctx.epoch,
           initial_guess: {bx, by, bz, 0.0},
           troposphere: true
         ) do
      {:ok, sol} -> sol.position
      {:error, _} -> nil
    end
  end

  # --- NAV thinning ---------------------------------------------------------

  defp write_nav_fixture(fixture_dir, contexts) do
    {start_epoch, end_epoch} =
      contexts
      |> Enum.map(& &1.epoch)
      |> Enum.min_max_by(&NaiveDateTime.to_erl/1)

    lo = NaiveDateTime.add(start_epoch, -@nav_lookback_s, :second)
    hi = NaiveDateTime.add(end_epoch, @nav_forward_pad_s, :second)

    lines = File.read!(@arc.nav_path) |> String.split("\n")
    {header, body} = split_header(lines)
    records = gps_records(body)

    selected =
      Enum.filter(records, fn rec ->
        toc = record_toc(rec)
        NaiveDateTime.compare(toc, lo) != :lt and NaiveDateTime.compare(toc, hi) != :gt
      end)

    out =
      ([gps_only_header(header)] ++ Enum.map(selected, &Enum.join(&1, "\n")))
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    path = Path.join(fixture_dir, "doppler_velocity_#{@arc.label}_l1_gps.nav")
    File.write!(path, out)
    IO.puts("wrote #{path} (#{length(selected)} GPS records, #{byte_size(out)} bytes)")
  end

  defp split_header(lines) do
    idx = Enum.find_index(lines, &String.contains?(&1, "END OF HEADER"))
    {Enum.take(lines, idx + 1), Enum.drop(lines, idx + 1)}
  end

  # Rewrite the RINEX TYPE line to GPS-only so a GPS broadcast loader is happy.
  defp gps_only_header(header) do
    header
    |> Enum.map_join("\n", fn line ->
      if String.contains?(line, "RINEX VERSION / TYPE") do
        String.replace(line, "M: MIXED            ", "G: GPS              ")
      else
        line
      end
    end)
  end

  defp gps_records(body) do
    do_gps_records(body, [])
  end

  defp do_gps_records([], acc), do: Enum.reverse(acc)

  defp do_gps_records([line | rest], acc) do
    if gps_record_start?(line) do
      {record, remaining} = Enum.split([line | rest], 8)
      do_gps_records(remaining, [record | acc])
    else
      do_gps_records(rest, acc)
    end
  end

  defp gps_record_start?(line) do
    String.length(line) >= 3 and String.at(line, 0) == "G" and
      String.slice(line, 1, 2) =~ ~r/^\d\d$/
  end

  defp record_toc([first | _]) do
    NaiveDateTime.new!(
      String.to_integer(String.slice(first, 4, 4)),
      String.to_integer(String.trim(String.slice(first, 9, 2))),
      String.to_integer(String.trim(String.slice(first, 12, 2))),
      String.to_integer(String.trim(String.slice(first, 15, 2))),
      String.to_integer(String.trim(String.slice(first, 18, 2))),
      String.to_integer(String.trim(String.slice(first, 21, 2)))
    )
  end

  # --- inputs JSON ----------------------------------------------------------

  defp write_inputs_fixture(fixture_dir, samples) do
    payload = %{
      "version" => 1,
      "arc" => @arc.label,
      "description" =>
        "Per-epoch inputs to the Doppler velocity gate: GPST epoch, GPS D1C " <>
          "Doppler with sign applied, broadcast-code SPP receiver ECEF, central " <>
          "finite-difference truth velocity from the vendored oracle truth track.",
      "oracle_fixture" => @arc.oracle_fixture,
      "doppler_sign" => @doppler_sign,
      "doppler_sign_basis" => @doppler_sign_basis,
      "carrier_hz" => @gps_l1_hz,
      "receiver_position_source" => "broadcast-code SPP per epoch",
      "truth_velocity_source" => "central finite difference of oracle truth_ecef_m",
      "nav_fixture" => "doppler_velocity_#{@arc.label}_l1_gps.nav",
      "epochs" => samples
    }

    path = Path.join(fixture_dir, "doppler_velocity_#{@arc.label}_l1_inputs.json")
    File.write!(path, Jason.encode!(payload, pretty: true))
    IO.puts("wrote #{path} (#{length(samples)} epochs)")
  end

  # --- sanity check: reproduce the campaign median with the thinned NAV -----

  defp sanity_check(fixture_dir, samples) do
    nav_path = Path.join(fixture_dir, "doppler_velocity_#{@arc.label}_l1_gps.nav")
    nav = Broadcast.load!(nav_path)

    errors =
      samples
      |> Enum.flat_map(fn s ->
        receiver =
          {s["receiver_ecef_m"]["x"], s["receiver_ecef_m"]["y"], s["receiver_ecef_m"]["z"]}

        doppler = Enum.map(s["doppler_hz"], fn [sat, hz] -> {sat, hz} end)
        {:ok, epoch} = NaiveDateTime.from_iso8601(s["epoch"])

        case Orbis.GNSS.Velocity.solve(nav, doppler, epoch, receiver,
               observable: :doppler,
               carrier_hz: @gps_l1_hz
             ) do
          {:ok, sol} ->
            {vx, vy, vz} = sol.velocity_m_s
            t = s["truth_velocity_m_s"]
            dx = vx - t["x"]
            dy = vy - t["y"]
            dz = vz - t["z"]
            [:math.sqrt(dx * dx + dy * dy + dz * dz)]

          {:error, _} ->
            []
        end
      end)
      |> Enum.sort()

    n = length(errors)
    med = percentile(errors, 0.5)
    p95 = percentile(errors, 0.95)

    IO.puts(
      "sanity (thinned NAV): n=#{n} median=#{Float.round(med, 4)} m/s p95=#{Float.round(p95, 4)} m/s"
    )
  end

  defp percentile([], _), do: nil

  defp percentile(sorted, pct) do
    n = length(sorted)
    rank = pct * (n - 1)
    lo = trunc(rank)
    hi = min(lo + 1, n - 1)
    frac = rank - lo
    Enum.at(sorted, lo) * (1.0 - frac) + Enum.at(sorted, hi) * frac
  end

  # --- helpers --------------------------------------------------------------

  defp oracle_base_arp(oracle) do
    ref = oracle["reference"] || oracle["inputs"]

    cond do
      is_map(ref) and is_map(ref["base_arp_ecef_m"]) ->
        a = ref["base_arp_ecef_m"]
        {a["x"], a["y"], a["z"]}

      is_map(oracle["truth"]) and is_map(oracle["truth"]["ecef_m"]) ->
        a = oracle["truth"]["ecef_m"]
        {a["x"], a["y"], a["z"]}

      true ->
        first = hd(oracle["per_epoch"])
        a = first["truth_ecef_m"]
        {a["x"], a["y"], a["z"]}
    end
  end

  defp naive_datetime({{y, mo, d}, {h, mi, s}}) do
    whole = trunc(s)
    us = round((s - whole) * 1_000_000)
    NaiveDateTime.new!(y, mo, d, h, mi, whole, {us, 6})
  end

  defp epoch_key(%NaiveDateTime{} = ndt) do
    ndt
    |> NaiveDateTime.truncate(:millisecond)
    |> NaiveDateTime.to_iso8601()
  end

  defp require_file!(path) do
    if !File.exists?(path) do
      raise "missing required input: #{path}"
    end
  end
end

DopplerVelocityFixture202606.main(System.argv())
