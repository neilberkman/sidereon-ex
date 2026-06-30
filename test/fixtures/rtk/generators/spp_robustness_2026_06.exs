defmodule SppRobustness202606 do
  @moduledoc false

  # Gate 2/3 of the spp-robustness capability: before/after single-frequency SPP
  # on real degraded GSDC Pixel-5 phone observations, bare crate solve vs the
  # opt-in robust (FDE) solve, measured against the vendored demo5/RTKLIB
  # position-domain oracles. See spp-robustness-spec.md.
  #
  # The oracle JSONs carry RTKLIB output and GSDC truth per epoch but NO raw
  # observations; the raw phone L1 pseudoranges and broadcast NAV are staged
  # locally. sidereon SPP is run per matched epoch as (A) bare, (B) robust-unit (the
  # harmful mode, via :unsafe_unit_weights), and (C) robust-weighted (a realistic
  # 5 m phone code sigma via :weights). Error vs the oracle truth is computed and
  # 3D and horizontal median/p95 are summarized per arc.
  #
  # Run from the sidereon worktree root:
  #   ORBIS_BUILD=1 mix run test/fixtures/rtk/generators/spp_robustness_2026_06.exs
  # Options: --work DIR (staged GSDC root, default /tmp/gsdc-work),
  #          --results FILE, --report FILE.

  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.Positioning
  alias Sidereon.GNSS.RINEX.Observations

  @default_work "/tmp/gsdc-work"
  @default_results "/tmp/spp-robustness-2026-06-results.json"

  @oracle_fixtures [
    "gsdc_2021_08_04_sjc1_pixel5_p222_demo5_rtklib_oracle.json",
    "gsdc_2021_08_24_svl1_pixel5_p222_demo5_rtklib_oracle.json",
    "gsdc_2021_12_15_mtv1_pixel5_p222_demo5_rtklib_oracle.json",
    "gsdc_2021_12_28_mtv1_pixel5_p222_demo5_rtklib_oracle.json"
  ]

  # Phone single-frequency L1 code preference per system. Ionosphere is not
  # enabled, so the unsupported-carrier path is never reached.
  @l1_codes %{
    "G" => ["C1C"],
    "R" => ["C1C"],
    "E" => ["C1C", "C1X"],
    "C" => ["C2I"]
  }

  # Declared up-front gate parameters (see spp-robustness-spec.md).
  @min_epochs 100
  @credibility_factor 2.0
  @max_pdop 1000.0
  # Realistic phone L1 code-noise standard deviation (m) for the RAIM detection
  # weights. Phone GNSS chipsets carry several-metre code noise, so 5 m is a
  # conservative uniform detection sigma. Detection-side only; the crate solve
  # numerics are unchanged.
  @code_sigma_m 5.0

  def main(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [work: :string, results: :string, report: :string, stride: :integer],
        aliases: [w: :work, r: :results]
      )

    if invalid != [], do: raise(ArgumentError, "invalid arguments: #{inspect(invalid)}")

    generator_dir = __DIR__
    fixture_dir = Path.expand("..", generator_dir)
    work = Keyword.get(opts, :work, @default_work)
    # Decimate matched epochs by this stride (default 1 = every epoch). A stride
    # keeps a powered sample (kept well above the @min_epochs floor) at a fraction
    # of the runtime; the sample is a fixed deterministic decimation, not a
    # cherry-pick. The kept-epoch count per arc is reported.
    stride = max(Keyword.get(opts, :stride, 1), 1)
    results_path = Keyword.get(opts, :results, @default_results)

    report_path =
      Keyword.get(
        opts,
        :report,
        Path.join(generator_dir, "spp-robustness-measurement-2026-06.md")
      )

    arcs = Enum.map(@oracle_fixtures, &measure_arc(fixture_dir, &1, work, stride))
    pooled = pool(arcs)

    results = %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      work_dir: work,
      stride: stride,
      gate_params: %{
        min_epochs: @min_epochs,
        credibility_factor: @credibility_factor,
        max_pdop: @max_pdop,
        code_sigma_m: @code_sigma_m
      },
      arcs: arcs,
      pooled: pooled
    }

    File.write!(results_path, Jason.encode!(results, pretty: true))
    File.write!(report_path, report(results))
    IO.puts("wrote #{results_path}")
    IO.puts("wrote #{report_path}")
    print_summary(arcs, pooled)
  end

  defp measure_arc(fixture_dir, fixture, work, stride) do
    oracle_path = Path.join(fixture_dir, fixture)
    oracle = oracle_path |> File.read!() |> Jason.decode!()
    inputs = oracle["inputs"]
    drive = inputs["drive"]

    rover_path = Path.join([work, drive, "supplemental/gnss_rinex.21o"])
    nav_name = inputs["nav"] |> Path.basename() |> String.replace_suffix(".gz", "")
    nav_path = Path.join([work, "cors", nav_name])

    IO.puts("measuring #{oracle["reference"]["label"]}")

    cond do
      not File.exists?(rover_path) ->
        %{
          fixture: fixture,
          label: oracle["reference"]["label"],
          blocked: "missing rover RINEX #{rover_path}"
        }

      not File.exists?(nav_path) ->
        %{
          fixture: fixture,
          label: oracle["reference"]["label"],
          blocked: "missing broadcast NAV #{nav_path}"
        }

      true ->
        rover_obs = Observations.load!(rover_path)
        nav = Broadcast.load!(nav_path)
        oracle_by_key = Map.new(oracle["per_epoch"], &{&1["time"], &1})
        base_arp = base_arp(oracle)

        epochs =
          rover_obs
          |> matched_epochs(oracle_by_key)
          |> Enum.with_index()
          |> Enum.filter(fn {_e, i} -> rem(i, stride) == 0 end)
          |> Enum.map(&elem(&1, 0))

        rows = Enum.flat_map(epochs, &solve_set(rover_obs, nav, &1, base_arp))

        bare = summarize(Enum.map(rows, & &1.bare_3d), Enum.map(rows, & &1.bare_h))
        unit = summarize(Enum.map(rows, & &1.unit_3d), Enum.map(rows, & &1.unit_h))
        robust = summarize(Enum.map(rows, & &1.robust_3d), Enum.map(rows, & &1.robust_h))
        demo5 = demo5_summary(oracle["per_epoch"])

        %{
          fixture: fixture,
          label: oracle["reference"]["label"],
          matched_epochs: length(epochs),
          solved_epochs: length(rows),
          excluded_total: Enum.sum(Enum.map(rows, & &1.excluded)),
          unit_excluded_total: Enum.sum(Enum.map(rows, & &1.unit_excluded)),
          bare: bare,
          unit: unit,
          robust: robust,
          demo5: demo5,
          verdict: verdict(bare, robust, demo5, length(rows))
        }
    end
  end

  defp base_arp(oracle) do
    b = oracle["truth"]["base_station"]["marker_ecef_m"]
    {b["x"], b["y"], b["z"]}
  end

  defp matched_epochs(rover_obs, oracle_by_key) do
    rover_obs
    |> Observations.epochs()
    |> Enum.flat_map(fn entry ->
      key = entry.epoch |> naive_datetime() |> epoch_key()

      case Map.get(oracle_by_key, key) do
        nil -> []
        oracle_epoch -> [%{entry: entry, oracle_epoch: oracle_epoch}]
      end
    end)
  end

  defp solve_set(rover_obs, nav, %{entry: entry, oracle_epoch: oracle_epoch}, base_arp) do
    {:ok, observations} = Observations.pseudoranges(rover_obs, entry.index, codes: @l1_codes)

    if length(observations) < 5 do
      []
    else
      seed = with_clock(base_arp, 0.0)

      bare =
        Positioning.solve(nav, observations, entry.epoch, initial_guess: seed, troposphere: true)

      # Unit-weight FDE via the explicit escape hatch: the harmful mode. With
      # sigma assumed at 1 m the chi-square test reads several-metre phone code
      # noise as faults and over-excludes; recorded to show the failure plainly.
      robust_unit =
        Positioning.solve(nav, observations, entry.epoch,
          initial_guess: seed,
          troposphere: true,
          robust: true,
          unsafe_unit_weights: true,
          max_pdop: @max_pdop
        )

      # Weighted FDE: a realistic uniform phone code sigma scales the RAIM
      # statistic so the test fires on genuine outliers, not the noise floor.
      weights =
        Map.new(observations, fn {sat, _pr} -> {sat, 1.0 / (@code_sigma_m * @code_sigma_m)} end)

      robust_w =
        Positioning.solve(nav, observations, entry.epoch,
          initial_guess: seed,
          troposphere: true,
          robust: true,
          weights: weights,
          max_pdop: @max_pdop
        )

      case {bare, robust_unit, robust_w} do
        {{:ok, bare_sol}, {:ok, ru_sol}, {:ok, rw_sol}} ->
          truth = oracle_epoch["truth_ecef_m"]
          truth_tuple = {truth["x"], truth["y"], truth["z"]}

          [
            %{
              bare_3d: error_3d(bare_sol, truth_tuple),
              bare_h: error_h(bare_sol, truth_tuple),
              unit_3d: error_3d(ru_sol, truth_tuple),
              unit_h: error_h(ru_sol, truth_tuple),
              unit_excluded: length(get_in(ru_sol.metadata, [:fde, :excluded]) || []),
              robust_3d: error_3d(rw_sol, truth_tuple),
              robust_h: error_h(rw_sol, truth_tuple),
              excluded: length(get_in(rw_sol.metadata, [:fde, :excluded]) || [])
            }
          ]

        _ ->
          []
      end
    end
  end

  defp error_3d(sol, truth), do: norm3(sub3(ecef(sol), truth))

  defp error_h(sol, {tx, ty, tz}) do
    {lat, lon, _h} = ecef_to_geodetic({tx, ty, tz})
    {e, n, _u} = ecef_delta_to_enu(sub3(ecef(sol), {tx, ty, tz}), lat, lon)
    :math.sqrt(e * e + n * n)
  end

  defp ecef(%{position: %{x_m: x, y_m: y, z_m: z}}), do: {x, y, z}

  defp summarize([], []), do: %{n: 0}

  defp summarize(threed, horiz) do
    %{
      n: length(threed),
      median_3d_m: percentile(threed, 50),
      p95_3d_m: percentile(threed, 95),
      median_h_m: percentile(horiz, 50),
      p95_h_m: percentile(horiz, 95)
    }
  end

  defp demo5_summary(per_epoch) do
    threed = Enum.map(per_epoch, & &1["error_3d_m"])
    horiz = Enum.map(per_epoch, & &1["horizontal_error_m"])

    %{
      n: length(threed),
      median_3d_m: percentile(threed, 50),
      p95_3d_m: percentile(threed, 95),
      median_h_m: percentile(horiz, 50),
      p95_h_m: percentile(horiz, 95)
    }
  end

  defp verdict(bare, robust, demo5, n) do
    powered? = n >= @min_epochs
    substrate_ok? = bare.median_3d_m <= @credibility_factor * demo5.median_3d_m

    improved? =
      powered? and robust.median_3d_m <= bare.median_3d_m and robust.p95_3d_m <= bare.p95_3d_m

    %{
      powered?: powered?,
      substrate_ok?: substrate_ok?,
      improved?: improved?,
      median_non_regress?: powered? and robust.median_3d_m <= bare.median_3d_m,
      delta_median_3d_m: bare.median_3d_m - robust.median_3d_m,
      delta_p95_3d_m: bare.p95_3d_m - robust.p95_3d_m,
      classification:
        cond do
          not powered? ->
            "underpowered (#{n} < #{@min_epochs} epochs)"

          improved? ->
            "robust non-regression on median and p95"

          robust.median_3d_m <= bare.median_3d_m ->
            "median non-regression, p95 regressed (null on strict bar)"

          true ->
            "null: weighted FDE did not beat the bare elevation-weighted solve"
        end
    }
  end

  defp pool(arcs) do
    powered = Enum.filter(arcs, &(Map.get(&1, :verdict, %{})[:powered?] == true))

    %{
      powered_arc_count: length(powered),
      total_arc_count: length(arcs),
      all_powered_improved?: powered != [] and Enum.all?(powered, &(&1.verdict[:improved?] == true)),
      all_powered_median_non_regress?: powered != [] and Enum.all?(powered, &(&1.verdict[:median_non_regress?] == true))
    }
  end

  defp print_summary(arcs, pooled) do
    IO.puts("\n=== spp-robustness Gate 2/3 ===")

    Enum.each(arcs, fn arc ->
      if Map.has_key?(arc, :blocked) do
        IO.puts("#{arc.label}: BLOCKED #{arc.blocked}")
      else
        v = arc.verdict

        IO.puts(
          "#{arc.label}: n=#{arc.solved_epochs}\n" <>
            "  bare        med3D=#{fmt(arc.bare.median_3d_m)} p95=#{fmt(arc.bare.p95_3d_m)}\n" <>
            "  robust-unit med3D=#{fmt(arc.unit.median_3d_m)} p95=#{fmt(arc.unit.p95_3d_m)} excl=#{arc.unit_excluded_total} (harmful: over-excludes)\n" <>
            "  robust-wtd  med3D=#{fmt(arc.robust.median_3d_m)} p95=#{fmt(arc.robust.p95_3d_m)} excl=#{arc.excluded_total} (sigma=#{fmt(@code_sigma_m)} m)\n" <>
            "  demo5 med=#{fmt(arc.demo5.median_3d_m)} | #{v.classification}"
        )
      end
    end)

    IO.puts(
      "pooled: powered #{pooled.powered_arc_count}/#{pooled.total_arc_count}, all median non-regress? #{pooled.all_powered_median_non_regress?}, all (median AND p95) non-regress? #{pooled.all_powered_improved?}"
    )
  end

  defp report(results) do
    rows =
      results.arcs
      |> Enum.map_join("\n", fn arc ->
        if Map.has_key?(arc, :blocked) do
          "| #{arc.label} | BLOCKED | #{arc.blocked} | | | | | | | |"
        else
          "| #{arc.label} | #{arc.solved_epochs} | #{fmt(arc.bare.median_3d_m)} | #{fmt(arc.bare.p95_3d_m)} | #{fmt(arc.unit.median_3d_m)} | #{fmt(arc.unit.p95_3d_m)} | #{fmt(arc.robust.median_3d_m)} | #{fmt(arc.robust.p95_3d_m)} | #{fmt(arc.demo5.median_3d_m)} | #{arc.excluded_total} |"
        end
      end)

    """
    # spp-robustness Gate 2/3 measurement (#{results.generated_at})

    Before/after single-frequency SPP on real GSDC Pixel-5 phone observations,
    bare crate solve vs opt-in robust (FDE) solve, vs the demo5/RTKLIB
    position-domain oracle. Truth is GSDC ground truth carried in the oracle.

    Gate params: min epochs #{results.gate_params.min_epochs}, credibility factor #{results.gate_params.credibility_factor}x demo5 median (absolute floor only), max_pdop #{results.gate_params.max_pdop}, detection sigma #{fmt(results.gate_params.code_sigma_m)} m. Epoch stride #{results.stride} (every #{results.stride}th matched epoch; n per arc reported, kept above the #{results.gate_params.min_epochs}-epoch floor).

    | arc | n | bare med 3D | bare p95 3D | robust-unit med 3D | robust-unit p95 3D | robust-wtd med 3D | robust-wtd p95 3D | demo5 med 3D | wtd sats excl |
    |---|---|---|---|---|---|---|---|---|---|
    #{rows}

    All values in metres. robust-unit is RAIM/FDE with unit weights (sigma=1 m
    assumed), reachable ONLY via the explicit `:unsafe_unit_weights` opt-in;
    robust-wtd is RAIM/FDE with a realistic uniform phone code sigma of
    #{fmt(results.gate_params.code_sigma_m)} m via `:weights`.

    Pooled: powered arcs #{results.pooled.powered_arc_count}/#{results.pooled.total_arc_count}; all powered arcs median non-regress (robust-wtd <= bare on median)? #{results.pooled.all_powered_median_non_regress?}; all powered arcs median AND p95 non-regress? #{results.pooled.all_powered_improved?}.

    Reading: sidereon runs an unaided single-frequency SPP per epoch; demo5 is a
    tuned multi-GNSS RTK reference and is the absolute bar, not the comparand for
    the robustness delta. The robustness claim is the bare-vs-robust delta on
    identical sidereon SPP inputs. The unit-weight FDE over-excludes on real phone
    noise (it reads several-metre code noise as faults under a 1 m sigma
    assumption) and degrades the fix: reported as the harmful mode, now reachable
    only behind `:unsafe_unit_weights`. Default `:robust` without a noise model
    refuses (`{:error, {:robust_requires_noise_model, :no_weights}}`), so it can
    never silently degrade a fix. A non-positive delta is a null result, not
    massaged. The strict all-arc bar (median AND p95 non-regress) being a null is
    reported as a null.
    """
  end

  defp fmt(nil), do: "nil"
  defp fmt(x) when is_float(x), do: :erlang.float_to_binary(x, decimals: 3)
  defp fmt(x), do: to_string(x)

  defp percentile([], _p), do: nil

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    n = length(sorted)
    rank = p / 100.0 * (n - 1)
    lo = trunc(rank)
    hi = min(lo + 1, n - 1)
    frac = rank - lo
    Enum.at(sorted, lo) * (1.0 - frac) + Enum.at(sorted, hi) * frac
  end

  defp sub3({ax, ay, az}, {bx, by, bz}), do: {ax - bx, ay - by, az - bz}
  defp norm3({x, y, z}), do: :math.sqrt(x * x + y * y + z * z)
  defp with_clock({x, y, z}, c), do: {x, y, z, c}

  @earth_a_m 6_378_137.0
  @earth_f 1.0 / 298.257_223_563

  defp ecef_to_geodetic({x, y, z}) do
    e2 = @earth_f * (2.0 - @earth_f)
    p = :math.sqrt(x * x + y * y)
    lon = :math.atan2(y, x)
    lat = :math.atan2(z, p * (1.0 - e2))
    lat = ecef_lat_iter(z, p, lat, e2, 0)
    {lat, lon, 0.0}
  end

  defp ecef_lat_iter(_z, _p, lat, _e2, 5), do: lat

  defp ecef_lat_iter(z, p, lat, e2, iter) do
    sin_lat = :math.sin(lat)
    n = @earth_a_m / :math.sqrt(1.0 - e2 * sin_lat * sin_lat)
    h = p / :math.cos(lat) - n
    new_lat = :math.atan2(z, p * (1.0 - e2 * n / (n + h)))
    ecef_lat_iter(z, p, new_lat, e2, iter + 1)
  end

  defp ecef_delta_to_enu({dx, dy, dz}, lat, lon) do
    sin_lat = :math.sin(lat)
    cos_lat = :math.cos(lat)
    sin_lon = :math.sin(lon)
    cos_lon = :math.cos(lon)
    e = -sin_lon * dx + cos_lon * dy
    n = -sin_lat * cos_lon * dx - sin_lat * sin_lon * dy + cos_lat * dz
    u = cos_lat * cos_lon * dx + cos_lat * sin_lon * dy + sin_lat * dz
    {e, n, u}
  end

  defp naive_datetime({{year, month, day}, {hour, minute, second}}) do
    whole = trunc(second)
    micro = round((second - whole) * 1_000_000)
    NaiveDateTime.new!(Date.new!(year, month, day), Time.new!(hour, minute, whole, {micro, 6}))
  end

  defp epoch_key(%NaiveDateTime{} = ndt) do
    {micro, _p} = ndt.microsecond
    ms = round(micro / 1_000)
    {base, ms} = if ms == 1_000, do: {NaiveDateTime.add(ndt, 1, :second), 0}, else: {ndt, ms}
    base = %{base | microsecond: {0, 0}}
    NaiveDateTime.to_iso8601(base) <> "." <> String.pad_leading(Integer.to_string(ms), 3, "0")
  end
end

SppRobustness202606.main(System.argv())
