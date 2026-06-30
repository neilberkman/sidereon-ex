# Batch Analysis: Coverage, Visibility, and Link Budgets

Use `Sidereon.Coverage` for single-epoch constellation/station coverage grids
and `Sidereon.RF` for scalar or list-based link-budget helpers. The Elixir layer
marshals element structs and station coordinates, while propagation, look-angle
evaluation, and RF calculations run in the Rust core.

## Which Satellites Can a Ground Station See?

```elixir
{:ok, iss} = Sidereon.Format.TLE.parse(line1, line2)

stations = [
  %{latitude: 40.7128, longitude: -74.0060, altitude_m: 10.0},
  {51.5074, -0.1278, 11.0}
]

datetime = ~U[2024-01-01 12:00:00Z]

look = Sidereon.Coverage.look_angles([iss], stations, datetime)
# [[{:ok, {azimuth_deg, elevation_deg, range_km}}, ...]]

visible = Sidereon.Coverage.visible_mask([iss], stations, datetime, 10.0)
# [[true | false, ...]]
```

## Access Counts

`access_counts/4` returns one count per station at a single epoch: the number of
input satellites above the elevation threshold.

```elixir
counts = Sidereon.Coverage.access_counts(tles, stations, datetime, 10.0)
```

## Maximum Elevation

`max_elevation/3` reduces the satellite rows and returns one value per station,
or `nil` if no satellite produced a valid look angle for that station.

```elixir
max_el = Sidereon.Coverage.max_elevation(tles, stations, datetime)
```

## Batch Link Budget

```elixir
ranges_km =
  look
  |> List.first()
  |> Enum.flat_map(fn
    {:ok, {_az, _el, range_km}} -> [range_km]
    :error -> []
  end)

path_loss_db = Sidereon.RF.fspl_batch(ranges_km, 1616.0)

budgets =
  Enum.map(path_loss_db, fn fspl_db ->
    %{
      eirp_dbw: 0.0,
      fspl_db: fspl_db,
      receiver_gt_dbk: -12.0,
      other_losses_db: 3.0,
      required_cn0_dbhz: 35.0
    }
  end)

margins_db = Sidereon.RF.link_margin_batch(budgets)
```
