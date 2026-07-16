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

## Exact Product and Explicit Source Selection

The exact-acquisition API treats product identity and distribution as separate
public concepts. First build the catalog product, then list only the acceptable
sources in priority order:

```elixir
alias Sidereon.GNSS.Data
alias Sidereon.GNSS.Distribution

{:ok, product} = Data.mgex_sp3(:cod, ~D[2020-06-25])

{:ok, request} =
  Data.request(product, [
    Distribution.nasa_cddis(),
    Distribution.direct()
  ])

{:ok, result} =
  Data.acquire(request,
    earthdata_auth:
      Distribution.EarthdataAuth.bearer(System.fetch_env!("EARTHDATA_TOKEN"))
  )

result.path
result.provenance.distribution_source
result.provenance.sha256
```

Only the listed sources are tried. If CDDIS returns 404, the example may try the
direct archive, but it retains the same publisher, analysis-center product line,
solution class, issue, date, cadence, family, format, and official filename.
Earlier failures appear in `result.provenance.attempts`.

When several exact products are required, declare the complete identity set and
gate dependent processing on the resolved acquisition identities:

```elixir
expected = [request_a.identity, request_b.identity]

available = [
  result_a.provenance.resolved_identity,
  result_b.provenance.resolved_identity
]

:ok = Data.validate_exact_product_set(expected, available)
```

The gate rejects empty declarations, duplicates, missing products, undeclared
products, and same-filename identities with different prediction metadata. For
SP3 observed/predicted timing, use
`Sidereon.GNSS.SP3.prediction_summary/1`; issue times and catalog fields are not
substitutes for the product's record flags.

Caller-provided inputs use the same validation path:

```elixir
Distribution.local_file("/data/exact-product.sp3.gz")
Distribution.in_memory(product_bytes, compression: :none)
```

These sources do not grant permission to relabel their contents. SP3 and IONEX
bytes must parse and match the requested start date/time and cadence.

## CDDIS and Earthdata Login

SP3 CDDIS URLs use the GNSS-products GPS-week directory. Current long-name
IONEX URLs use `ionex/<year>/<day-of-year>`. Both keep the identity's exact
official filename and use gzip as transport packaging.

Credentials are supplied by the caller. Besides bearer tokens, Earthdata's
documented netrc mechanism is available:

```text
machine urs.earthdata.nasa.gov login EARTHDATA_USERNAME password EARTHDATA_PASSWORD
```

```elixir
auth = Distribution.EarthdataAuth.netrc()
{:ok, result} = Data.acquire(request, earthdata_auth: auth)
```

The bearer token, netrc path and password, cookies, authorization headers, and
URL queries are excluded from errors and provenance. Redirects are restricted
to approved HTTPS hosts. Cookies retain their documented host/domain, path, and
secure restrictions.

The path and authentication decisions follow these official public sources:

- [NASA CDDIS archive access](https://www.earthdata.nasa.gov/centers/cddis-daac/archive-access)
- [Earthdata curl and wget access](https://urs.earthdata.nasa.gov/documentation/for_users/data_access/curl_and_wget)
- [Earthdata bearer-token example](https://urs.earthdata.nasa.gov/documentation/for_users/data_access/python_user_token_script)
- [NASA precise orbit products](https://www.earthdata.nasa.gov/data/space-geodesy-techniques/gnss/precise-orbits-product)
- [NASA GNSS atmospheric products](https://www.earthdata.nasa.gov/data/space-geodesy-techniques/gnss/atmospheric-products)
- [IGS long product filename guidelines](https://files.igs.org/pub/resource/guidelines/Guidelines_for_Long_Product_Filenames_in_the_IGS.pdf)

## Exact Acquisition Provenance and Cache

`Distribution.Provenance` records requested and parsed/resolved identity,
publisher, source, official filename, sanitized original and final URLs,
retrieval time, decompressed and archive lengths and SHA-256 hashes,
compression, ETag/Last-Modified when present, cache-hit state, and earlier
source failures.

The cache key includes the source and every exact identity discriminator. Each
accepted entry is one immutable transaction containing the decompressed
product, original archive bytes, and JSON provenance. A SHA-256-bound commit
record names that transaction and is atomically replaced only after the files
and directories are synchronized. Hits follow only that record, then recheck
both hashes and lengths, full requested and resolved identities, source, caller
checksum, and a fresh SP3/IONEX semantic parse.

On Linux and macOS, acquisition delegates to the shared Rust transaction
implementation. Threads, BEAM instances, and other cooperating processes use
its per-entry advisory lock across cache validation, acquisition, and commit.
Waiters therefore reuse the completed entry instead of downloading it again.
`:cache_lock_timeout_ms` bounds the wait (30,000 milliseconds by default); a
timeout or cache write failure is terminal and never authorizes trying another
distributor. The operating system releases a dead owner's lock, so abandoned
transactions are removed only after a new owner holds it. Low-level callers can
use `Sidereon.GNSS.ExactCache` directly while retaining responsibility for
transport and product-format validation.

Publication relies on same-filesystem atomic rename, synchronized regular
files, and synchronized entry, entries, and commit-record directories. A process
death or power loss at a boundary leaves the prior complete commit or no
acceptable commit. Fully valid cache triples from 0.29.0-0.29.2 are revalidated
and migrated without another acquisition. `result.path` keeps the official
filename inside the immutable transaction directory. These guarantees apply to
local filesystems on Linux and macOS that honor POSIX advisory locks, atomic
same-directory rename, and directory synchronization. The legacy `Data.fetch/2`
API and cache layout remain unchanged.

Failures remain typed tagged tuples, including authentication required/failed,
authorization denied, product not published, retired endpoint, redirect policy,
malformed URL, transport timeout/connection, HTML or invalid content, content
length, download size, decompression, checksum, semantic validation, and cache
read/write errors. Multiple failed sources return
`{:all_distributors_failed, failures}`. Retries are bounded to meaningful
transport errors, HTTP 408/429, and server errors; callers should retain the
verified cache and keep public-service concurrency modest.

Merged SP3 acquisition fetches each contributing center, parses the products, and
uses the existing SP3 merge implementation:

```elixir
{:ok, merged_sp3, report} =
  Sidereon.GNSS.Data.fetch_merged_sp3(~D[2024-09-03], [:igs_ult, :gfz_ult])
```

Ultra-rapid acquisition probes each center's current primary filename pattern,
then known duration/sampling alternates and documented latest-product aliases
when an archive returns 404. `report.contributors` records the pattern that
succeeded. Merge policy options are forwarded unchanged, including guarded
cell precedence:

```elixir
{:ok, merged_sp3, report} =
  Sidereon.GNSS.Data.fetch_merged_sp3(
    ~N[2026-07-12 18:30:00],
    [:igs_ult, :cod_ult, :esa_ult, :gfz_ult],
    combine: :precedence,
    min_agree: 1,
    precedence_scope: :cell,
    outlier_reject: [position_m: 0.5, clock_ns: 5.0]
  )

prediction = Sidereon.GNSS.SP3.prediction_summary(merged_sp3)
prediction.observed_through
```

The default merge timeline uses the finest commensurate input cadence, with
lower-precedence centers filling missing cells. No interpolation is introduced.
Even one successful contributor passes through the same merge path so system
filters and cadence validation remain consistent.

Every fetch returns either `{:ok, value}` or `{:error, reason}`. Offline misses,
checksum failures, redirects, archive 404s, no-coverage terrain, cache failures,
and catalog validation all use typed tagged reasons.
