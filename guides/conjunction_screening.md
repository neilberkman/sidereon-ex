# Conjunction Screening

Screen two satellites for close approaches over a time window.
Validated against the Iridium 33 / Cosmos 2251 collision of 2009.

## Basic Conjunction Search

```elixir
{:ok, sat1} = Sidereon.Format.TLE.parse(line1a, line2a)
{:ok, sat2} = Sidereon.Format.TLE.parse(line1b, line2b)

approaches = Sidereon.Conjunction.find(sat1, sat2,
  end_min: 1440.0,      # search 1 day from sat1 epoch
  step_min: 1.0,        # 1-minute scan resolution
  threshold_km: 50.0    # only report approaches < 50 km
)

for {tca_min, dist_km} <- approaches do
  hours = Float.round(tca_min / 60.0, 1)
  IO.puts("TCA: +#{hours}h | Miss distance: #{Float.round(dist_km, 2)} km")
end
```

## Historical Validation: Iridium 33 / Cosmos 2251

The most famous orbital collision occurred on 2009-02-10 at ~16:56 UTC.
Using the last TLEs before the event:

```elixir
{:ok, iridium} = Sidereon.Format.TLE.parse(
  "1 24946U 97051C   09040.78448243 +.00000153 +00000-0 +47668-4 0  9994",
  "2 24946 086.3994 121.7028 0002288 085.1644 274.9812 14.34219863597336"
)

{:ok, cosmos} = Sidereon.Format.TLE.parse(
  "1 22675U 93036A   09040.49834364 -.00000001  00000-0  95251-5 0  9996",
  "2 22675 074.0355 019.4646 0016027 098.7014 261.5952 14.31135643817415"
)

# Search 2 days from Iridium's epoch
approaches = Sidereon.Conjunction.find(iridium, cosmos,
  end_min: 2880.0,
  step_min: 1.0,
  threshold_km: 50.0
)

# Find the closest approach
{tca, min_dist} = Enum.min_by(approaches, fn {_t, d} -> d end)
IO.puts("Closest approach: +#{Float.round(tca / 60, 1)}h, #{Float.round(min_dist, 2)} km")
# Expected: ~22.1 hours from epoch, ~1.9 km miss distance
```

SGP4 with TLE data cannot predict the exact collision point (TLE
accuracy is ~1 km at epoch and degrades over time), but it consistently
finds the closest approach within 1 minute of the known collision time
and within a few kilometers.

## Screening a Constellation

Screen all pairs within a constellation for close approaches:

```elixir
{:ok, constellation} = Sidereon.Constellation.load("stations")

# Screen each pair (N² but small for most constellations)
satellites = constellation.satellites
pairs = for s1 <- satellites, s2 <- satellites, s1.catalog_number < s2.catalog_number, do: {s1, s2}

IO.puts("Screening #{length(pairs)} pairs...")

results =
  pairs
  |> Task.async_stream(fn {s1, s2} ->
    approaches = Sidereon.Conjunction.find(s1, s2,
      end_min: 1440.0, step_min: 5.0, threshold_km: 25.0)

    if approaches != [] do
      {best_t, best_d} = Enum.min_by(approaches, fn {_t, d} -> d end)
      {s1.catalog_number, s2.catalog_number, best_t, best_d}
    end
  end, max_concurrency: System.schedulers_online(), timeout: 30_000)
  |> Enum.flat_map(fn
    {:ok, nil} -> []
    {:ok, result} -> [result]
    _ -> []
  end)
  |> Enum.sort_by(fn {_, _, _, d} -> d end)

for {id1, id2, tca, dist} <- Enum.take(results, 10) do
  IO.puts("#{id1} × #{id2}: #{Float.round(dist, 1)} km at +#{Float.round(tca / 60, 1)}h")
end
```
