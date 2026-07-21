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

{:ok, product} = Data.mgex_sp3(:cod, ~D[2026-07-12])

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
bytes must parse and match the complete exact request.

## Product Eras and Exact SP3 Validation

Catalog classification is product-aware. In particular, IGS final SP3 is
`"final"`, while IGS merged broadcast navigation remains `"broadcast"`:

```elixir
{:ok, "final"} = Data.product_solution_class(:igs, :sp3)
{:ok, "broadcast"} = Data.product_solution_class(:igs, :nav)
```

IGS final SP3 starts at GPS week 0730. Through GPS week 2237 its exact filename
is `igs<week><day>.sp3`, and CDDIS packages it as Unix `compress` (`.Z`). From
week 2238, beginning 2022-11-27, the identity uses the IGS long filename and
CDDIS packages it with gzip. `Distribution.location/2` returns the exact URL,
archive filename, and compression without changing the identity. Sidereon does
not derive a historical direct-BKG URL because the reviewed BKG listings do not
establish one uniform historical layout. Unix-compress decoding rejects
detectable partial terminal codes and nonzero terminal padding before product
parsing. The format has no end marker, so a code-aligned truncation is not
structurally distinguishable from a shorter stream; exact product validation
and any caller-supplied digest remain the final integrity checks.

CODE routing is also product-specific. Current MGEX final SP3 and clock files
use `CODE_MGEX/CODE/<year>`, final IONEX uses `CODE/<year>`, and rapid,
ultra-rapid, and predicted products retain their documented CODE-family paths.
GFZ rapid SP3 defaults to `15M` through 2021-05-17 and `05M` from 2021-05-18;
dated derivation uses `Data.default_sample_for_date/3` automatically.

The catalog also enforces the verified start of each modeled long-name SP3
family: ESA final starts on 2014-01-05, GFZ rapid on 2020-05-13, ESA
ultra-rapid on 2022-10-04, and GFZ ultra-rapid on 2020-10-06. IGS ultra-rapid
is modeled only from GPS week 2238. ESA ultra-rapid uses `15M` through the
2025-02-02 0600 issue and `05M` from the 1200 issue; the date-only default uses
the start-of-day (`0000`) convention. GFZ ultra-rapid uses `15M` through
2021-05-15 and `05M` from 2021-05-16.

CDDIS requests for every pre-week-2238 long-name SP3 identity are rejected.
The historical IGS combined-final product remains supported because its exact
identity uses the documented short filename and Unix `compress` packaging,
not a long-name alias.

The general `SP3.parse/1` reader remains permissive. To validate bytes against
a declared date, issue, span, cadence, format revision, and optional producing
agency, use an exact request:

```elixir
alias Sidereon.GNSS.SP3

{:ok, exact} =
  SP3.ExactRequest.new(~D[2026-07-12], "01D", "05M",
    issue: "0000",
    expected_agency: "AIUB"
  )

{:ok, product, coverage} = SP3.parse_exact(decompressed_bytes, exact)
coverage in [:half_open, :inclusive]
```

The exact gate rejects unknown, zero, non-finite, noncanonical, or mismatched
cadence; incomplete mandatory SP3 structure; a mismatched agency, declared
start, parsed start, epoch count, or identity; and nonascending, irregular,
short, or long epoch grids. A one-day five-minute request accepts 288 epochs
for half-open coverage or 289 epochs when the boundary epoch is present. The
permitted counts are calculated from the validated request cadence and span,
not from untrusted header values.

Fallback is deliberately narrow. An ordinary HTTP 404/not-yet-published result
or offline cache absence may advance to the next explicitly selected source or
official catalog candidate. A retired endpoint may advance to another
explicitly selected distributor for the same exact identity. An exhausted
timeout, connection, 408, 429, or server failure may do the same, but the first
such availability failure is preserved if no source succeeds. Malformed
content, parse failure, checksum or digest failure, cadence/span/identity
mismatch, cache integrity failure, and caller configuration errors are
terminal. No official source reviewed for this release documented a
moving-alias validation race that justified a validation-error exception.
Invalid `:http_client` options or callback responses, and callbacks that raise,
throw, or exit, return `{:http_client_failure, kind, sanitized_url}` and are
terminal. Only explicit timeout or connection atoms, typed `Req.TransportError`
values, and HTTP 408/429 or server-status results from a custom client enter the
retry and availability-fallback policy.

Acquisition byte limits are mandatory positive integers. Invalid
`:max_archive_bytes` or `:max_product_bytes` values—including zero, negatives,
fractions, and infinity-like atoms—return `{:invalid_option, option}` before
cache or transport work begins.

## CDDIS and Earthdata Login

SP3 CDDIS URLs use the GNSS-products GPS-week directory and preserve the
identity's era-specific `.Z` or `.gz` packaging. Current long-name IONEX URLs
use `ionex/<year>/<day-of-year>` and gzip.

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
- [IGS long product filename guidelines](https://files.igs.org/pub/resource/guidelines/Guidelines_for_Long_Product_Filenames_in_the_IGS_v2.2_EN.pdf)

### Public evidence for the 0.33 catalog audit

All sources in this table were accessed on 2026-07-20.

| Catalog or behavior | Official public evidence |
| --- | --- |
| IGS final products begin at GPS week 0730. | [1994 IGS Annual Report](https://files.igs.org/pub/resource/pubs/94an_repta.pdf) |
| IGS final SP3 changed from the short `.sp3.Z` identity to long filenames and gzip at GPS week 2238. | [IGS transition guideline](https://files.igs.org/pub/resource/guidelines/Guideline_for_the_transition_of_the_IGS_products_to_IGS20_and_long_filenames_v2.0.pdf), [IGSMAIL-8256](https://lists.igs.org/pipermail/igsmail/2022/008252.html), [week 2237 CDDIS object](https://cddis.nasa.gov/archive/gnss/products/2237/igs22370.sp3.Z), [week 2238 CDDIS object](https://cddis.nasa.gov/archive/gnss/products/2238/IGS0OPSFIN_20223310000_01D_15M_ORB.SP3.gz) |
| Current BKG layout is week-based, but transition-era listings do not define one uniform legacy direct layout. | [week 2238](https://igs.bkg.bund.de/root_ftp/IGS/products/2238/), [legacy week 2235](https://igs.bkg.bund.de/root_ftp/IGS/products/orbits/2235/), [transition week 2236](https://igs.bkg.bund.de/root_ftp/IGS/products/2236/) |
| SP3 declares start, cadence, count, mandatory header records, satellite records, comments, and EOF structure. | [SP3-d specification](https://files.igs.org/pub/data/format/sp3d.pdf) |
| Current official files use `IGS`, `ESOC`, `GFZ`, and `AIUB` producing-agency fields. | [IGS example](https://igs.bkg.bund.de/root_ftp/IGS/products/2428/IGS0OPSRAP_20262000000_01D_15M_ORB.SP3.gz), [ESA example](https://navigation-office.esa.int/products/gnss-products/2428/ESA0OPSRAP_20262000000_01D_05M_ORB.SP3.gz), [GFZ example](https://isdc-data.gfz.de/gnss/products/rapid/w2428/GFZ0OPSRAP_20262000000_01D_05M_ORB.SP3.gz), [CODE example](https://www.aiub.unibe.ch/download/CODE_MGEX/CODE/2026/COD0MGXFIN_20261920000_01D_05M_ORB.SP3.gz) |
| CODE publishes different product families in distinct paths. | [AIUB product documentation](https://www.aiub.unibe.ch/download/AIUB_AFTP.TXT), [MGEX 2026 listing](https://code.aiub.unibe.ch/s3_script/aiub_s3_bucket_listing.php?path=CODE_MGEX%2FCODE%2F2026), [CODE 2026 listing](https://code.aiub.unibe.ch/s3_script/aiub_s3_bucket_listing.php?path=CODE%2F2026), [current CODE listing](https://code.aiub.unibe.ch/s3_script/aiub_s3_bucket_listing.php?path=CODE) |
| GFZ rapid SP3 changed from `15M` on day 137 of 2021 to `05M` on day 138. | [GFZ week-2158 listing](https://isdc-data.gfz.de/gnss/products/rapid/w2158/), [current GFZ rapid listing](https://isdc-data.gfz.de/gnss/products/rapid/w2428/) |
| ESA's MGEX final-SP3 archive begins on 2014-01-05. | [preceding week 1773](https://navigation-office.esa.int/products/gnss-products/1773/), [first week 1774 listing](https://navigation-office.esa.int/products/gnss-products/1774/), [first SP3 object](https://navigation-office.esa.int/products/gnss-products/1774/ESA0MGNFIN_20140050000_01D_05M_ORB.SP3.gz) |
| GFZ's rapid-SP3 listing begins on 2020-05-13. | [GFZ week-2105 listing](https://isdc-data.gfz.de/gnss/products/rapid/w2105/), [first rapid SP3 object](https://isdc-data.gfz.de/gnss/products/rapid/w2105/GFZ0OPSRAP_20201340000_01D_15M_ORB.SP3.gz) |
| IGS operational ultra-rapid long names start with GPS week 2238. | [IGS transition guideline](https://files.igs.org/pub/resource/guidelines/Guideline_for_the_transition_of_the_IGS_products_to_IGS20_and_long_filenames_v2.0.pdf), [BKG week-2238 listing](https://igs.bkg.bund.de/root_ftp/IGS/products/2238/), [first long-name ultra SP3 object](https://igs.bkg.bund.de/root_ftp/IGS/products/2238/IGS0OPSULT_20223310000_02D_15M_ORB.SP3.gz) |
| ESA's operational ultra-rapid SP3 line begins on 2022-10-04. | [preceding week 2229](https://navigation-office.esa.int/products/gnss-products/2229/), [week-2230 listing](https://navigation-office.esa.int/products/gnss-products/2230/), [first ultra SP3 object](https://navigation-office.esa.int/products/gnss-products/2230/ESA0OPSULT_20222770000_02D_15M_ORB.SP3.gz) |
| GFZ's operational ultra-rapid SP3 listing begins on 2020-10-06. | [GFZ week-2126 listing](https://isdc-data.gfz.de/gnss/products/ultra/w2126/), [first ultra SP3 object](https://isdc-data.gfz.de/gnss/products/ultra/w2126/GFZ0OPSULT_20202800000_02D_15M_ORB.SP3.gz) |
| ESA ultra-rapid SP3 changes from `15M` at the 2025-02-02 0600 issue to `05M` at 1200. | [ESA week-2352 listing](https://navigation-office.esa.int/products/gnss-products/2352/), [0600 15M object](https://navigation-office.esa.int/products/gnss-products/2352/ESA0OPSULT_20250330600_02D_15M_ORB.SP3.gz), [1200 05M object](https://navigation-office.esa.int/products/gnss-products/2352/ESA0OPSULT_20250331200_02D_05M_ORB.SP3.gz) |
| GFZ ultra-rapid SP3 defaults to `15M` through 2021-05-15 and `05M` from 2021-05-16; one 0000 `05M` object overlaps the otherwise-`15M` final day. | [GFZ week-2157 listing](https://isdc-data.gfz.de/gnss/products/ultra/w2157/), [last 15M issue](https://isdc-data.gfz.de/gnss/products/ultra/w2157/GFZ0OPSULT_20211352100_02D_15M_ORB.SP3.gz), [overlapping 05M object](https://isdc-data.gfz.de/gnss/products/ultra/w2157/GFZ0OPSULT_20211350000_02D_05M_ORB.SP3.gz), [GFZ week-2158 listing](https://isdc-data.gfz.de/gnss/products/ultra/w2158/), [first next-day 05M object](https://isdc-data.gfz.de/gnss/products/ultra/w2158/GFZ0OPSULT_20211360000_02D_05M_ORB.SP3.gz) |

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
malformed URL, transport timeout/connection, caller HTTP-client failure, HTML or
invalid content, content length, download size, decompression, checksum,
semantic validation, and cache read/write errors. When every attempted source
ends in ordinary publication absence, multiple attempts return
`{:all_distributors_failed, failures}`. The first exhausted availability failure
is preserved if no source succeeds. The first integrity or configuration
failure is returned directly and stops fallback. Retries are bounded to
meaningful transport errors, HTTP 408/429, and server errors; callers should
retain the verified cache and keep public-service concurrency modest.

For multi-center merge acquisition, a center that supports SP3 but has no
publicly verified catalog convention for the requested date is recorded as
`reason: "catalog_unavailable"` without attempting transport. This does not
weaken the configuration boundary: unsupported center/product combinations,
invalid dates or issues, and other catalog errors remain terminal.

Merged SP3 acquisition fetches each contributing center, parses the products, and
uses the existing SP3 merge implementation:

```elixir
{:ok, merged_sp3, report} =
  Sidereon.GNSS.Data.fetch_merged_sp3(~D[2024-09-03], [:igs_ult, :gfz_ult])
```

Ultra-rapid acquisition probes each center's current primary filename pattern,
then known duration/sampling alternates and documented latest-product aliases
only when an archive returns ordinary publication absence. Integrity failure
does not mark that center absent and does not authorize another candidate or
center; it is returned to the caller. `report.contributors` records the pattern
that succeeded. Merge policy options are forwarded unchanged, including
guarded cell precedence:

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

Each successful contributor now has two deliberately separate records:
`artifact_identity` contains the requested and content-resolved product
identities, explicit distributor, official filename, product and archive
SHA-256 digests and lengths, and compression; `acquisition` contains cache-hit
status, retrieval time, sanitized public URLs, HTTP metadata, and earlier
attempts. Only the first record enters `report.stable_input_identity`.

That versioned identity canonically binds the complete contributor set and
merge policy. It is unchanged by a warm-cache hit, process restart, map order,
or non-semantic contributor enumeration order, and changes when an artifact,
resolved identity, contributor set, or merge option changes. Precedence source
order is bound explicitly because reversing it can change merged bytes. Persist
a secret-free map without inspecting cache directories:

```elixir
persisted = Sidereon.GNSS.Data.merge_report_to_map(report)
json = Jason.encode!(persisted)
:ok = json |> Jason.decode!() |> Sidereon.GNSS.Data.verify_merge_report()
```

The compatibility file helper still returns only the written path. Call
`fetch_merged_sp3_file_with_report/4` when the report must be retained:

```elixir
{:ok, path, report} =
  Sidereon.GNSS.Data.fetch_merged_sp3_file_with_report(
    ~D[2024-09-03],
    [:igs_ult, :gfz_ult],
    "merged.SP3"
  )
```

Merged-SP3 acquisition accepts only complete, verified exact-acquisition
records. It does not scan cache directories or infer a contributor identity
from a filename, timestamp, or local path.

Every fetch returns either `{:ok, value}` or `{:error, reason}`. Offline misses,
checksum failures, redirects, archive 404s, no-coverage terrain, cache failures,
and catalog validation all use typed tagged reasons.

The product-aware catalog and exact-SP3 APIs are additive, while stricter
acquisition rejection is intentional. The permissive parser remains available;
the new date-free default-sample query supports compatibility-oriented catalog
inspection. These changes therefore ship as minor version 0.33.0. Public
material did not resolve a uniform historical BKG direct layout or document a
safe moving-alias integrity fallback; Sidereon leaves both unsupported rather
than guessing.
