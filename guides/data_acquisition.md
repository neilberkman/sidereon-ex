# Data Acquisition

`Sidereon.GNSS.Data` fetches GNSS archive products and DTED terrain tiles into a
verified local cache. It is cache-first, supports offline reads, records
provenance next to each data file, and derives product names, URLs, terrain paths,
and DTED bytes through the core NIF.

## Terrain Quick Start

Fetch the tile first, then pass the terrain cache root to the terrain reader:

```elixir
{:ok, tile_path} = Sidereon.GNSS.Data.fetch_dted(36.75, -106.25)
terrain_root = tile_path |> Path.dirname() |> Path.dirname()

{:ok, terrain} = Sidereon.Terrain.dted(terrain_root)
{:ok, height_m} = Sidereon.Terrain.height(terrain, -106.25, 36.75)
```

For fully ocean or no-data tiles, `fetch_dted/3` returns:

```elixir
{:ok, {:no_coverage, tile_id}}
```

The terrain reader treats absent tiles as sea level, so callers can decide
whether to prefetch no-coverage markers or simply rely on the reader fallback.

## Bulk Terrain Cache

Populate a region while online:

```elixir
terrain_root = "/tmp/sidereon-terrain"

{:ok, report} =
  Sidereon.GNSS.Data.prefetch_dted_bbox({36.0, -107.0, 37.0, -106.0},
    cache_dir: terrain_root
  )

report.fetched
report.cached
report.no_coverage
report.errors
```

Tile lists accept core Skadi ids or `{lat_index, lon_index}` pairs:

```elixir
{:ok, report} =
  Sidereon.GNSS.Data.prefetch_dted_tiles(["N36W107", {36, -106}],
    cache_dir: terrain_root
  )
```

Later, run without network:

```elixir
{:ok, tile_path} =
  Sidereon.GNSS.Data.fetch_dted(36.75, -106.25,
    cache_dir: terrain_root,
    offline: true
  )
```

## GNSS Products

Build products through the catalog wrappers and fetch them to the GNSS cache:

```elixir
{:ok, sp3_product} = Sidereon.GNSS.Data.mgex_sp3(:esa, ~D[2020-06-24])
{:ok, sp3_path} = Sidereon.GNSS.Data.fetch(sp3_product)
{:ok, sp3} = Sidereon.GNSS.SP3.load(sp3_path)

{:ok, ionex_path} = Sidereon.GNSS.Data.fetch_ionex(:cod_rap, ~D[2026-06-13])
{:ok, ionex} = Sidereon.GNSS.Ionosphere.load_ionex(ionex_path)

{:ok, nav_product} = Sidereon.GNSS.Data.mgex_nav(:igs, ~D[2020-06-25])
{:ok, nav_path} = Sidereon.GNSS.Data.fetch(nav_product)

{:ok, clk_product} = Sidereon.GNSS.Data.mgex_clk(:gfz, ~D[2020-06-24])
{:ok, clk_path} = Sidereon.GNSS.Data.fetch(clk_product)
```

Merged SP3 acquisition fetches each contributing center, parses the products, and
uses the existing SP3 merge implementation:

```elixir
{:ok, merged_sp3, report} =
  Sidereon.GNSS.Data.fetch_merged_sp3(~D[2024-09-03], [:igs_ult, :gfz_ult])
```

Every fetch returns either `{:ok, value}` or `{:error, reason}`. Offline misses,
checksum failures, redirects, archive 404s, no-coverage terrain, cache failures,
and catalog validation all use typed tagged reasons.
