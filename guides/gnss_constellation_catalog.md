# GNSS Constellation Catalogs

`Sidereon.GNSS.Constellation` builds identity tables for GNSS satellites and checks
them against loaded GNSS products. The first supported system is GPS.

The base GPS source is CelesTrak's public `gps-ops` OMM/JSON feed, which carries
the current NORAD catalog id and a PRN in `OBJECT_NAME`. NAVCEN's GPS
constellation page can be merged as a status overlay for SVN and active NANU
usability.

```elixir
# Live fetch: CelesTrak gps-ops plus NAVCEN status overlay.
{:ok, records} = Sidereon.GNSS.Constellation.fetch_gps()

record = hd(records)
{record.system, record.prn, record.svn, record.norad_id, record.sp3_id}
# {:gps, prn, svn_or_nil, norad_cat_id, "Gxx"}
```

For reproducible workflows, fetch bytes elsewhere and parse explicitly:

```elixir
{:ok, records} = Sidereon.GNSS.Constellation.from_celestrak_omm(celestrak_omms)
{:ok, navcen} = Sidereon.GNSS.Constellation.parse_navcen_html(navcen_html)
records = Sidereon.GNSS.Constellation.merge_navcen(records, navcen)
```

NAVCEN rows are merged by PRN only when the NAVCEN block type is compatible
with the CelesTrak object name. If a PRN is in transition and NAVCEN still
carries a NANU for an older vehicle, the row is kept in
`record.source.navcen_conflict` instead of being used as the normalized SVN.

Export the compact CSV used by many GNSS workflows:

```elixir
csv = Sidereon.GNSS.Constellation.to_csv(records)

# prn,norad_cat_id,active,sp3_id
# 1,62339,true,G01
# ...
```

Validate the catalog before using it in a downstream pipeline:

```elixir
report = Sidereon.GNSS.Constellation.validate(records)

report.duplicate_prns
report.duplicate_norad_ids
report.inactive_unusable_prns
```

Compare active, usable catalog IDs against a loaded SP3 product:

```elixir
{:ok, sp3} = Sidereon.GNSS.Data.sp3(Sidereon.GNSS.Data.mgex_sp3(:gfz, ~D[2026-06-04]))
report = Sidereon.GNSS.Constellation.validate_sp3(records, sp3)

report.missing_sp3_ids
report.extra_sp3_ids
```

The catalog layer only reports data consistency. It does not change solver
selection, infer cross-correlation, or apply application-specific satellite
health policy.

## Tracking Health Over Time

Use `health_timeline/2` after validating a sequence of catalog snapshots. It
turns timestamped catalogs into half-open health intervals and reuses `diff/2`
for the structural transition audit. Each transition also carries derived
health-state changes, so a watcher can report what changed without re-deriving
the comparison.

```elixir
snapshots = [
  {~N[2026-06-09 00:00:00], previous_records},
  {~N[2026-06-09 06:00:00], current_records}
]

{:ok, timeline} =
  Sidereon.GNSS.Constellation.health_timeline(snapshots,
    as_of: ~N[2026-06-09 07:00:00],
    stale_after_s: 6 * 60 * 60
  )

timeline.intervals
timeline.changes
timeline.stale?
```

`health_state/1` keeps the policy deliberately small: explicit
`:health_state` metadata wins when present, otherwise active+usable is
`:healthy`, active+unusable is `:unhealthy`, and inactive records are
`:unknown`. Serialize watcher state or notifications with
`health_timeline_to_map/1`.
