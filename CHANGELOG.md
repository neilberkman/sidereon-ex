# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.0.2] - 2026-10-05

### Fixed

- Classical orbital-element results preserve undefined optional angles as
  `NaN` instead of replacing them with zero during Kepler propagation and
  equinoctial conversions.
- Relative-state helpers return native errors directly, and their bang
  variants raise those errors, instead of returning or raising nested error
  tuples.
- Sun and Moon batch helpers recognize native error tuples before decoding a
  successful position pair.
- Direct angle helper documentation and typespecs include the existing
  `{:error, :invalid_input}` result for degenerate or unsupported geometry.

## [3.0.1] - 2026-10-04

### Added

- Opt-in `:http_client_exception_diagnostics` callbacks report raised custom
  HTTP-client exceptions and call sites using redacted metadata. The terminal
  acquisition failure result stays unchanged; callback failures are ignored.

### Fixed

- The default NTRIP user-agent product now follows the core package version.

## [3.0.0] - 2026-10-04

### Added

- `Sidereon.GNSS.RTK.RinexArc.unresolved_carriers/1` and
  `Sidereon.GNSS.RTK.DualFrequencyRinexArc.unresolved_carriers/1` list, as
  `Sidereon.GNSS.RTK.RinexUnresolvedCarrier` structs, each satellite
  measurement the arc builder left out of an epoch because no configured phase
  observable had a carrier frequency, naming the receiver (`:base` or
  `:rover`), the epoch's index in that receiver's file, the satellite and the
  observable. `solve_static_rinex_rtk_baseline/5` and
  `solve_wide_lane_fixed_rinex_rtk_baseline/5` carry them as
  `:unresolved_carriers`.
- `Sidereon.GNSS.SBAS.unassigned_mask_corrections/2` counts, per PRN mask
  number, the corrections a GEO addressed to active mask bits that name no
  satellite.
- `Sidereon.Terrain.tile_horizontal_datum/1` returns the horizontal datum a DTED
  tile's DSI record states: `:wgs84`, `:wgs72`, `:unstated` or `{:other, text}`.
- `Sidereon.GNSS.Antex` keeps every record ANTEX 1.4 defines: `header` (version
  and system, the `PCV TYPE / REFANT` calibration type and reference antenna,
  header comments, and whether `END OF HEADER` is present), `blocks` (every
  antenna block in file order, each validity interval of one id included),
  `outer_comments` and `skipped_records`. Each antenna keeps its method records,
  comments before and after `TYPE / SERIAL NO`, whether it carries
  `# OF FREQUENCIES`, and each frequency section's `START OF FREQ RMS` section.
  `antenna_intervals/2`, `antenna_at/3`, `frequency/2` and `skipped_records/1`
  are new.
- `Sidereon.GNSS.RINEX.Clock` exposes the lossless clock model: `records/1`,
  `header_records/1`, the scale-tagged `series/1`, `skipped_records/1`,
  `diagnostics/1`, `notices/1`, `source_line/2`, the header facts
  (`version/1`, `layout/1`, `satellite_system/1`, `time_system/1`,
  `time_system_status/1`, `time_scale/1`, `record_count/1`), the edits
  `set_time_system/2`, `set_record_values/3`, `insert_record/3`,
  `remove_record/2`, `retain_records/2` and `edit_records/2`, which return a new
  product, `to_rinex_string_with_policy/2` with a `WritePolicy` and its
  departures, `from_series_rows/1`, `from_clock_points/2`,
  `clock_s_at_gps_seconds/3`, `civil_to_instant/2` and `civil_to_gps_seconds/1`.
- `Sidereon.Format.OMM.parse_xml_all/1` reads every OMM of an XML document or
  NDM combined instantiation and `parse_json_array/1` every record of a GP JSON
  array, each returning `{:ok, omms, skipped}` with each unreadable record as
  `{index, reason}`. `encode_json_discarding_comments/1` writes GP JSON without
  the comments GP JSON cannot carry.
- `Sidereon.Format.TLE.parse_with_warnings/3` returns the checksum warnings the
  policy accepted with the elements.
- `Sidereon.CCSDS.OPM.Covariance.to_matrix/1` and
  `Sidereon.CCSDS.OEM.Covariance.to_matrix/1` expand the 21 lower-triangle
  values to six symmetric rows without validation.
- `Sidereon.GNSS.Broadcast.skipped/1`, `departures/1` and
  `iono_corrections_at/2`, the ionosphere sets in effect at an epoch.
- `Sidereon.GNSS.Bias.notices/1` lists the departures and other findings of a
  read.
- `Sidereon.GNSS.RTCM.decode_message_with_policy/2`, `encode_with_policy/2` and
  `encode_frame_with_reserved/2`.
- `Sidereon.GNSS.SSR.from_rtcm_strict/4`.
- `Sidereon.GNSS.SBAS.decode_with_policy/3`, `parse_ems_log/2` and
  `parse_rtklib_log/2`, which take `:policy` and `:reference_week` and return
  every line's disposition as a `Sidereon.GNSS.SBAS.Log`.
- `Sidereon.GNSS.Positioning.solve/4`, `solve_with_doppler/5`,
  `solve_with_fallback/5`, `solve_batch/3`,
  `Sidereon.GNSS.StaticPositioning.solve/3` and `Sidereon.GNSS.QC.fde/4` take
  `:pseudorange_code`: `:single_frequency` (the default), from which the
  broadcast single-frequency group delay of the record the satellite clock came
  from is subtracted, as RTKLIB `prange` does, or `:ionosphere_free`, to which
  none applies.
- PPP observations accept `:signals`, `%{code1:, code2:, phase1:, phase2:}`,
  the tracking codes of the two pseudoranges and two carrier phases an
  ionosphere-free observation was formed from.
- SPP, static and static reference-station solutions report `ut1_degraded`
  (`nil`, `:before_coverage` or `:after_coverage`), and every fusion update map
  carries `:ut1_degraded`.
- `Sidereon.GNSS.Observables.predict/5` returns `sat_clock_relativity_s`, the
  relativistic term `-2 r·v / c²` a positioning model adds to a product clock
  (`:not_applicable` for a broadcast clock, `:unavailable` within 1 ms of the
  end of the product's coverage), and `single_frequency_group_delay_s`, the
  broadcast group delay a single-frequency model subtracts from the clock.
- `Sidereon.GNSS.Observables.pseudorange_transmit_geometry/6` returns the
  transmit-time geometry of a pseudorange as SPP, the static solve, DGNSS and
  PPP place it (RTKLIB `satposs` and `geodist`): the transmission epoch, the
  signal flight time, the satellite clock with its relativistic term and group
  delay, the unrotated satellite position, the range with the first-order
  Sagnac term, the line of sight, elevation and azimuth.
- `Sidereon.SpaceWeather.ap_history_at_with_policy/3` returns the NRLMSISE-00
  Ap history as a `Sidereon.SpaceWeather.ApHistory` with the least-trusted row
  class consulted, `ap_defaulted` and `bins_from_daily_ap`, the number of
  three-hour bins filled from a row's daily Ap.
- `Sidereon.SpaceWeather.diagnostics/1` returns the skipped lines and warnings
  of the parse that built a table, which were discarded.
- `Sidereon.SpaceWeather.Policy.lenient/0`, and the `:space_weather_policy`
  option of `Sidereon.Drag.estimate_decay/3` and `Sidereon.Propagator.propagate/3`,
  which reads a `:space_weather_table` under that policy.
- `Sidereon.GNSS.SP3.merge/2` reports what the merge did not write:
  `:dropped_input_epochs` (input epochs off an explicit `:epoch_interval_s`
  grid, or on no SP3 epoch record's tick), `:omitted_epochs` (union-grid epochs
  with no accepted cell), `:arc_withheld` (cells whose preferred source carried
  no position) and `:clock_omissions` (each source clock left out, with its
  reason and whether the cell has a clock from other sources). Epochs keep the
  representation the merge recorded.
- **Breaking.** `Sidereon.GNSS.SP3.check_continuity/2` and
  `continuity_verdict/4` refuse a negative `:residual_tolerance_m` with
  `{:error, {:bad_residual_tolerance_m, value}}`, and `merge/2` and
  `merge_input_identity/2` refuse one in `:verify_continuity` with
  `{:error, {:invalid_verify_continuity, {:bad_residual_tolerance_m, value}}}`;
  a residual tolerance is a distance.
- `Sidereon.GNSS.SP3.merge/2` takes `provenance: :summary | :full`, and its
  report carries `:provenance`, the per-epoch provenance the core recorded
  (`nil` when not requested): the selection behind each accepted cell under
  `:full`, every change of supplying source with its reason, and what each
  contributor covered. `Sidereon.GNSS.Data.fetch_merged_sp3/3` forwards the
  option.
- `Sidereon.GNSS.SP3.selected_nodes/4` and
  `merge_continuity_selected_nodes/4` return the position nodes the
  interpolations of a satellite in a window select, for a product and for the
  merged product a merge continuity report holds: the nodes window verdicts
  read.
- A merge continuity violation carries `:sources` and `:cells`, each with its
  epoch, its role in the finding and the selection the merge recorded for it.
  A continuity defect carries every field of its kind under the core's name
  beside the summary fields.
- `Sidereon.solid_earth_tide/8` takes `constants: :conventions | :iers_routine`,
  the Step 2 constants the core applies (`:conventions` by default);
  `:iers_routine` reproduces the IERS `DEHANTTIDEINEL` routine.

### Changed

- **Breaking.** `Sidereon.GNSS.SP3.to_sp3_string/2` now returns
  `{:ok, binary}` or `{:error, writer_error()}`; `to_iodata/2` returns
  `{:ok, iodata}` or the same typed refusal. Callers must unwrap success
  before passing the result to functions such as `:zlib.gzip/1`; a refusal
  retains its named tag and fields instead of being an opaque writer failure.
  See the [SP3 writer migration example](README.md#sp3-writer-return-values-in-30).

- **Breaking.** `Sidereon.GNSS.SP3.merge_continuity_verdict/3` takes the report
  and the window alone; it took the merged product as its second argument and
  ignored it. The report holds the merged product's interpolation nodes, and a
  violation influences a window when the nodes its interpolations select
  include the violation's held-out, repeated or pair-end record or straddle a
  handover between its records.
- **Breaking.** `Sidereon.GNSS.SP3.merge/2` takes any `:epoch_interval_s` that
  is a whole number of the 10-nanosecond ticks an SP3 interval states, as the
  core's merge does, and passes it to the core as given. It refused an interval
  that was not a whole number of seconds and rounded one within 1e-9 s of it,
  so a value such as `600.0000000005` merged on a 600 s grid; the core now
  refuses it, with its message as the error. `merge_input_identity/2` and
  persisted merge policies still bind whole seconds only, to within the core's
  1e-6 s, and bind the value as given, so the `stable_id` of such a value
  changes. `Sidereon.GNSS.Data.fetch_merged_sp3/3` refuses an
  `:epoch_interval_s` the identity cannot bind, and any option the facade
  refuses, before it fetches any product.
- **Breaking.** `Sidereon.GNSS.Data.merge_report_to_map/1` writes
  `schema_version: 3`, in the record layout the sidereon Python package writes
  and verifies, so a record either package writes verifies in the other. Each
  contributor carries `acquisition_facts` (not `acquisition`), and it and the
  `artifact_identity` carry `schema_version: 1`; the retrieval time is stated
  in UTC with a `+00:00` offset. The `merge_policy` carries `schema_version: 2`,
  the target interval as `target_epoch_interval_s`, `nil` systems for no
  filter, an empty `precedence_artifact_sha256` for a combining rule, and the
  `verify_continuity` (its residual tolerance null or at least 0) and
  `provenance` options. The `merge_report` carries the
  four omission lists `SP3.merge/2` reports, the merge continuity report (its
  attestation as `attested`, each violation's cells and sources, each defect's
  fields) and the provenance, the last two `nil` when the merge was not asked
  for them. `verify_merge_report/1` checks a version 3 record against itself,
  its agreement and its policy: one violation per defect whose cells are the records the defect
  rests on, in time order, with its sources, pair-end sources and
  contributor crossing following from them; the splices; nothing found by a
  check the policy did not request, and no more findings than checks; full
  provenance cells against the agreement cells, and the coverage and
  transitions the cells imply, with reasons the changes admit; clock
  omissions against the agreement's clock counts, never taking source 0 off
  its own datum, and a preferred source only under precedence; withheld arc
  cells only under satellite-arc precedence and never written; an input epoch
  off the target grid only with a target grid; omitted epochs holding no
  accepted cell; and every epoch on one known time scale and on the merge
  grid. It still verifies version 1 and 2 records in the layout this binding
  wrote them in; version 2 records carry the omission lists, which are checked
  by the same rules. Every version accepts an epoch the core holds for a UTC
  `23:59:60.x` label, on the next day's boundary with a negative fraction,
  which it refused, and a contributor recorded without an issue, which is the
  catalog's issue `"0000"` its identity states (every fetched final product),
  which it refused. A canonical or requested-sample contributor is checked
  against the identity and filename the catalog derives for it, and a
  canonical one must be a center without issues, a requested-sample one an
  ultra-rapid center. A version 3 record spells each acquisition failure one
  way, the vocabulary the Python package writes: `transport_failure`,
  `decompression_failure`, `product_validation_failure`,
  `cache_read_failure` and `cache_write_failure` where this binding's
  `SourceFailure` says `:transport`, `:decompression_failed`,
  `:product_validation_failed`, `:cache_read_failed` and `:cache_write_failed`,
  and every other case under the name it has; an `http_status` failure states
  its status, which in every version is 100-599. A failure no case describes
  is `unclassified_failure` with a `detail` holding the inspected reason (a
  new `Sidereon.GNSS.Distribution.SourceFailure` field), where it was
  `:unknown` or `:acquisition`; a response status outside 100-599 is a
  transport failure with the value in its message. Version 1 and 2 records
  may carry either package's earlier spellings, and no unclassified failure. `SP3.merge_input_identity/2` returns the two reporting options in
  its `:merge_policy`.
- **Breaking.** A `Sidereon.GNSS.Data.AbsentCenter` reason is one of
  `"no_candidate"`, `"catalog_unavailable"`, `"offline_cache_miss"`,
  `"product_not_published"`, `"checksum_mismatch"`, `"http_status"` and
  `"unclassified"`, the status in `:http_status` and, for an unclassified
  failure, the inspected reason in the new `:detail`; it was `"offline_miss"`, `"candidate_not_found"`,
  `"product_not_published:<status>"`, `"checksum"` or `"http_status:<status>"`.
  A version 3 record states each case with exactly the candidate fields it
  has; a version 1 or 2 record may also carry the earlier spellings, and no
  other reason.
- **Breaking.** `Sidereon.GNSS.SP3.position/4` returns the core's typed
  refusals, `{:error, {:insufficient_precise_nodes, sat_id, nodes, 11}}` and
  `{:error, :epoch_out_of_range}`, where it returned their message strings.

- **Breaking.** An ionosphere-corrected SPP or static solve no longer fails the
  epoch with `{:ionosphere_unsupported, sat}` when one satellite has no
  resolvable carrier. The satellite is left out and reported in `rejected_sats`
  as `:ionosphere_carrier_unresolved`, and the rest of the epoch is solved; an
  epoch left with too few satellites fails with `{:too_few_satellites, used,
  required}`. Reasons are tested in the order ephemeris, elevation mask,
  augmentation-grid coverage, carrier.
- **Breaking.** A RINEX RTK arc no longer fails with
  `{:missing_frequency, satellite, observable}`; see `unresolved_carriers/1`.
- **Breaking.** `Sidereon.GNSS.RTCM.encode/1`, `encode_frame/1` and
  `encode_message/1` refuse a message the wire format cannot state as
  `{:error, {:invalid_input, message}}` instead of writing it as another
  satellite or signal: an MSM satellite id outside `1..64`, a signal id outside
  `1..32`, a satellite or cell listed twice, a signal whose satellite is not
  listed, an ephemeris satellite field wider than the message's, and any
  satellite or signal number outside `0..255`. A body over the frame length
  limit, previously refused with the error text, is refused the same way.
- **Breaking.** `Sidereon.GNSS.Frequencies` resolves a GLONASS G1 or G2 carrier
  only for a channel in `-7..6`, returning `{:error, {:invalid_channel,
  channel}}` for any other, and resolves the GLONASS CDMA, SBAS and NavIC
  carriers the core added.
- Satellite identifiers take the shared `01`..`99` token range for every
  constellation: merge-report verification accepts them, and a GLONASS
  navigation record for an extended slot such as `R28` is read rather than
  skipped.
- **Breaking.** DTED terrain lookups return `{:error,
  {:unknown_terrain_elevation, fields}}` for a lookup weighting a null posting,
  `{:error, {:non_wgs84_terrain_tile, fields}}` for a tile on another horizontal
  datum, `{:error, {:missing_terrain_tile, fields}}` for a missing store tile
  and `{:error, {:parse, message}}` for a tile that does not read, including one
  whose origin disagrees with the tile its file name names, in place of
  `:invalid_input` or the error text. `Terrain.load_tile/1`
  and `Terrain.tile_elevation/3` return every DTED tile refusal by its own tag
  with its fields, including `{:null_posting, fields}` and the UHL metadata
  checks; `load_tile/1` previously returned a failed load inside `{:ok, _}`.
  Terrain-store errors gain `:tile_id_out_of_range`, `:tile_bounds_mismatch`
  and `:non_wgs84_tile`. SRTM voids converted to DTED are null postings rather
  than sea level.
- **Breaking.** `Sidereon.GNSS.Antex.Antenna` holds `frequencies` as a list of
  sections in file order, `dazi_deg` and `zenith_grid` as `nil` when the block
  has no such record, and its validity bounds as `Sidereon.GNSS.Antex.Epoch`
  with the exact fraction of a second, so `59.9999999` is kept to the seventh
  decimal. `zenith_start_deg`, `zenith_end_deg` and `zenith_step_deg` are
  replaced by `zenith_grid`. `satellite_antenna/3` searches every validity
  interval and takes a `NaiveDateTime` or an `Antex.Epoch`. Parse, write and
  lookup refusals are `{tag, fields}` pairs with every field the core carries;
  a label whose sections differ is `{:ambiguous_frequency, fields}`. The
  precise-positioning satellite antenna option reads every validity interval
  with its exact bounds.
- **Breaking.** `Sidereon.GNSS.RINEX.Clock` holds the core product behind a
  handle; the unedited product is written back byte for byte, header records
  and `AR`, `CR`, `DR` and `MS` records included. `clock_s/3` takes a civil
  epoch in the product's time scale, so a UTC or `GLO` product answers a
  `23:59:60` query on a leap-second day, and reads the query second with every
  digit. Errors are `{tag, fields}` pairs in place of text.
- **Breaking.** `Sidereon.GNSS.Time.epoch_to_split_jd/1`, `second_of_day/1` and
  `day_of_year/1` return `{:ok, value}` or `{:error, reason}`, and every epoch
  helper there names a field the core cannot take, as `{:invalid_epoch_field,
  field, value}` or `{:value_out_of_range, field, value}`, instead of raising.
  `second_of_day/1` reads only the clock fields.
- `Sidereon.GNSS.Ionosphere.klobuchar_delay/7`, `galileo_nequick_g_delay/7`,
  `nequick_g_stec/2` and `nequick_g_delay/3` name an argument that is not a
  number or that no double holds, and a `month` outside `0..255`, before the
  call. `from_node_samples/5` names an `exponent` outside the signed 32-bit
  range as `{:value_out_of_range, :exponent, value}`.
- **Breaking.** `Sidereon.Format.OMM` keeps every item of CCSDS 502.0-B-3
  tables 4-1 to 4-3: `classification`, `message_id`, `ref_frame_epoch`,
  `semi_major_axis_km`, `gm_km3_s2`, `spacecraft` (`OMM.Spacecraft`),
  `bterm_m2_kg`, `agom_m2_kg`, `covariance` (`OMM.Covariance`, the 21
  lower-triangle values as read), `user_defined` (`OMM.UserDefined`) and
  `comments` (`OMM.Comments`). `ccsds_omm_vers`, `mean_motion` and the
  TLE-related parameters are `nil` when the message does not state them; the
  struct no longer defaults them to `"2.0"`, `"U"`, 999 or 0, and a writer
  states a version only when the message holds one.
- **Breaking.** `Sidereon.Format.OMM.encode_kvn/1`, `encode_xml/1` and
  `encode_json/1` return `{:error, reason}` for a message their reader would
  not return unchanged: text with a line break or trimmed whitespace, a
  character XML 1.0 cannot carry, a non-finite number, an epoch the reader
  refuses, and, in GP JSON, any comment but the single header comment.
  `parse_json/1` refuses a document holding several records.
- **Breaking.** `Sidereon.Format.OMM.to_elements/1` returns the SGP4 element
  set the core forms from the OMM (`Omm::to_element_set`). It refuses a stated
  `MEAN_ELEMENT_THEORY` other than `SGP4`, `SGP/SGP4` or `SDP4`, a
  `CENTER_NAME` other than `EARTH`, a `REF_FRAME` other than `TEME` or a
  `TIME_SYSTEM` other than `UTC` with `{:incompatible_metadata, field, value}`,
  an OMM without `MEAN_MOTION` or `BSTAR` with `{:missing_field, field}`, and an
  epoch that names no UTC instant or an element that is not finite or out of
  range with `{:invalid_field, field, kind}`. An OMM without `NORAD_CAT_ID` gives
  elements whose `catalog_number` is `nil`, where the conversion refused it.
  `bstar` and `mean_motion_double_dot` are quantized to the TLE assumed-decimal
  fields as the core quantizes them, where they were copied unquantized, and
  the epoch keeps its femtoseconds and a UTC leap second in the new
  `Sidereon.Elements` field `epoch_jd`, which propagation uses, where they were
  dropped or refused. The decoded-map `parse/1` requires `"BSTAR"`, which SGP4
  propagates with, where an absent value was filled with zero, gives `nil` for
  an absent `"NORAD_CAT_ID"`, where it gave `""`, and leaves unstated
  mean-motion derivatives, `"CLASSIFICATION_TYPE"`, `"EPHEMERIS_TYPE"`,
  `"ELEMENT_SET_NO"` and `"REV_AT_EPOCH"` as `nil`.
- **Breaking.** `Sidereon.Elements` fields `classification`, `mean_motion_dot`,
  `mean_motion_double_dot`, `ephemeris_type`, `elset_number` and `rev_number`
  may be `nil`, and the struct gains `bstar_text` and
  `mean_motion_double_dot_text`, the TLE field text as read, which
  `Sidereon.Format.TLE.encode/1` writes back while it decodes to the stored
  value, so `00000+0` is no longer written as `00000-0`. A `nil` ephemeris
  type, element set number or revolution number is written as a blank field,
  where encoding refused it; SGP4 propagates a `nil` mean-motion derivative as
  it does a stated zero. `catalog_number` may be `nil`: SGP4 propagation,
  visibility and constellation passes carry it as `nil`, and
  `Sidereon.Format.TLE.encode/1` refuses such elements with `{:missing_field,
  :catalog_number}`, since a TLE states one. `epoch_jd` is the epoch as the
  core's split Julian date, `nil` for elements read from a TLE.
- **Breaking.** `Sidereon.Format.TLE.parse/3`, `parse_file/2`,
  `Sidereon.parse_tle/3` and `Sidereon.parse_tle_file/2` take `policy:
  :strict` (the default) or `:lenient`. Under `:strict` a column-69 digit that
  disagrees with the checksum, or a column 69 that is not a digit, is refused,
  where it was logged and accepted; `:lenient` reads it and reports it.
  Checksum warnings are `{line, kind, computed}` with `kind` `{:mismatch,
  digit}`, `{:not_digit, character}` or `:missing`.
- **Breaking.** `Sidereon.Format.TLE.parse_file/2` returns `rejected`, every
  non-blank line that did not become a satellite with its line number, name
  line and reason (`{:invalid, reason}`, `:missing_line_2`, `:orphan_line_2`,
  `:orphan_name`), and each satellite's `line_number` and `checksum_warnings`;
  `skipped` is the number of rejected entries, where it counted only records
  that failed SGP4 initialization and stray lines were dropped.
- **Breaking.** `Sidereon.CCSDS.OPM` and `Sidereon.CCSDS.OEM` keep the header
  `comments`, `classification` and `message_id`, the metadata `comments` and
  `ref_frame_epoch`, and the comments of every block (OPM state, Keplerian,
  spacecraft, covariance and maneuvers; OEM `data_comments` and
  `covariance_comments` as `OEM.Comment` at their positions); OPM gains
  `user_defined` and `user_defined_comments`. Covariances hold the 21
  lower-triangle values as read in `lower_triangle`, replacing `matrix`, so a
  matrix that falls short of positive semidefinite only through its printed
  digits is read. `OEM.skipped_states` is a list of `OEM.SkippedState` (line,
  segment, text, reason) instead of a count.
- **Breaking.** `Sidereon.CCSDS.OPM`, `Sidereon.CCSDS.OEM` and
  `Sidereon.CCSDS.CDM` `encode/2`, `encode_kvn/1` and `encode_xml/1` return
  `{:ok, text}` or `{:error, reason}`, refusing a message their reader would not
  return unchanged.
- **Breaking.** `Sidereon.CCSDS.CDM` keeps every item and comment of CCSDS
  508.0-B-1 tables 3-1 to 3-4: `ccsds_cdm_vers`, `comments`, `message_for`,
  `relative_comments`, `relative_position_rtn_m`, `relative_velocity_rtn_m_s`,
  the screening period, volume frame, shape, size (`screen_volume_m`) and entry
  and exit times, and per object `metadata_comments`, `od_parameters`
  (`CDM.OdParameters`), `additional_parameters` (`CDM.AdditionalParameters`),
  `state_comments`, `covariance_comments` and covariance rows 7 to 9
  (`drag_covariance_rtn`, `srp_covariance_rtn`, `thrust_covariance_rtn`). A
  covariance row group of the wrong length is refused by name, where it was
  padded with zeros or cut.
- **Breaking.** `Sidereon.GNSS.Constellation.from_celestrak_omm_lenient/2` and
  `from_celestrak_json_lenient/2` skip an entry without `NORAD_CAT_ID` with
  `norad_id: nil` instead of aborting; `Catalog` gains `unread`, the GP JSON
  array elements the OMM reader could not read, which were dropped.
  `from_celestrak_json/2` refuses such an element with
  `{:bad_celestrak_record, {:unreadable_record, index, reason}, nil}`.
- **Breaking.** `Sidereon.SGP4.fit_tle/2` elements carry `mean_motion_dot`,
  `mean_motion_double_dot` and `catalog_number` as `nil` when unstated, and a
  fitted OMM the KVN writer refuses is returned as
  `{:error, {:omm_kvn, reason}}` with the writer's typed reason.
- **Breaking.** OMM, OPM, OEM and CDM reader and writer refusals, TLE codec
  refusals and SGP4 element-set refusals are typed terms that carry every field
  the core refusal holds, documented in the new `Sidereon.CCSDS.Error`, where
  they were error text (OMM, CDM, TLE, SGP4) or a category atom with no fields
  (OPM, OEM). A refusal with no fields is its atom; one with fields is a tuple
  of its atom and its fields, such as `{:duplicate_field, field, first,
  second}`, `{:unwritable_text, field, value, issue}` with `issue` one of the
  text issues `:line_break`, `:surrounding_whitespace` and the others, and
  `{:in_record, index, reason}` for a record of a GP JSON array. A field the
  core names with a fixed identifier is a lowercased atom (`:mean_motion`),
  and text taken from the input is a string. The skipped records of
  `OMM.parse_xml_all/1`, `OMM.parse_json_array/1` and the constellation
  catalog's `unread` list carry typed reasons, and a rejected TLE file record
  is `{:invalid, reason}` with the SGP4 refusal. The writers refuse fields that
  cannot form a message as `{:invalid_length, group, expected, got}` (a
  covariance without 21 lower-triangle values, a CDM covariance row group of
  the wrong length) or `{:invalid_field, field, :out_of_range | :non_finite}`;
  OPM and OEM returned `:invalid_covariance` and CDM the error text.
- **Breaking.** `Sidereon.GNSS.Broadcast` keeps every record of the
  single-frequency messages whatever its health. A query selects among a
  satellite's records as RTKLIB `seleph` and `selgeph` do, and a selected
  record RTKLIB `satexclude` excludes yields no state. `records/1`,
  `record_count/1`, `glonass_records/1` and `glonass_record_count/1` include
  unhealthy records. One unreadable record no longer fails `parse/2`;
  `skipped/1` and `departures/1` report what was left out or read through.
- **Breaking.** `Sidereon.GNSS.Broadcast` states and
  `Sidereon.GNSS.Observables.predict/5` on a broadcast source return the
  satellite clock RTKLIB `satposs` returns, without the broadcast group delay
  (GPS and QZSS TGD, Galileo BGD, BeiDou TGD1, CNAV TGD less ISC).
  Single-frequency SPP, DGNSS and tight fusion subtract the delay, so a
  single-frequency broadcast SPP solution is unchanged, and ionosphere-free PPP
  on broadcast clocks no longer carries it.
- **Breaking.** `Sidereon.GNSS.Broadcast.DetailedRecord.issue_of_data` is `nil`
  for a GPS or QZSS CNAV-family record, which states none. `sv_accuracy_m` on
  `Record` and `DetailedRecord` is `nil` where the record states no accuracy.
  `DetailedRecord` gains `stated` (`Broadcast.StatedNavFields`), which
  `encode_rinex_nav/1` writes back. `nav_message` gains
  `:galileo_unclassified` and `:navic_lnav`.
- **Breaking.** `Sidereon.GNSS.Broadcast.encode_nav/1` returns `{:ok, text}` or
  `{:error, {:not_representable, line, reason}}`, and `encode_rinex_nav/1`
  refuses the same record sets: a CNAV-family record together with an
  unclassified Galileo record. `Sidereon.GNSS.QC.repair_nav_text/2` reports this
  as `{:repaired_product_unwritable, {:not_representable, line, reason}}`.
- **Breaking.** `Sidereon.GNSS.Broadcast.parse_rinex_nav_lenient/1` returns
  `departures` and `other` besides `records` and `skipped`, and each
  `SkippedNavBlock` has its `line`. `parse_rinex_glonass_lenient/1` keeps every
  readable record and returns `invalid` and `departures`; `SkippedGlonass` has
  its `line`.
- **Breaking.** `Sidereon.GNSS.Broadcast.iono_corrections/1` also returns
  `qzss`, `navic`, `galileo`, `galileo_disturbance_flags` and `beidou_bdgim`,
  and takes each set from the header or the latest RINEX 4 ionosphere frame.
- **Breaking.** `Sidereon.GNSS.Bias` readers are strict by default and take
  `policy: :lenient` to read a Bias-SINEX file that departs from Bias-SINEX
  1.00, or a CODE DCB title with an unknown time-system label.
- **Breaking.** `Sidereon.GNSS.Bias.Record` replaces `is_phase` with `family`
  (`:code`, `:phase`, `:mixed`) and `unit` (`:nanoseconds`, `:cycles`), and
  gains `line`. `Bias.info/1`'s `time_scale` is `nil` for a product without a
  usable time scale; `time_system_label` is new.
- **Breaking.** `Sidereon.GNSS.Bias.code_osb/5` and `code_dsb/6` return `{:ok,
  value_s, %{records: [index], overridden: [index]}}`, or a typed error naming
  why no value is given (`:absent`, `{:unsupported_scale, product, query}`,
  `{:ambiguous, records}` and others), where `{:error, :not_found}` stood for
  all of them.
- **Breaking.** `Sidereon.GNSS.RTCM.decode_messages/1` refuses a stream with any
  byte outside a CRC-valid frame or any frame that does not decode, as
  `{:error, text}`. `decode_stream/2` reads a noisy stream frame by frame; its
  diagnostics add `crc_failures` and `departures`, and a skipped frame's
  `reason` is an atom (`:truncated`, `:malformed`, `:departure`).
- **Breaking.** RTCM station coordinates, antenna descriptors, the six
  ephemerides and MSM messages carry `trailing_bits`, MSM messages carry
  `signal_mask`, and GLONASS ephemerides carry `negative_zero`.
  `decode_frame/1` returns `reserved`. `decode_stream/2` takes `policy:
  :lenient` to read such input, which the new `encode_with_policy/2` writes
  back byte for byte.
- **Breaking.** `Sidereon.GNSS.SSR.from_rtcm/4` reads every readable frame under
  the lenient RTCM policy and returns `{:ok, store, report}` with the stream
  diagnostics, the length of an unfinished trailing frame and each message the
  store refused. `from_rtcm!/4` uses `from_rtcm_strict/4`, which refuses
  anything it cannot read and apply in full. SSR orbit and clock corrections
  gain `transmitted_epoch_j2000_s` and `has_nav_message`.
- **Breaking.** `Sidereon.GNSS.SBAS.parse_ems/1` and `parse_rtklib/1` refuse a
  record whose message-type field differs from the type its message carries,
  and return `{:error, reason}` for any refused line. `LogBlock` gains
  `declared_message_type` and `pad_bits`.
- **Breaking.** `Sidereon.Ephemeris.state/4` always returns `velocity_km_s`; for
  a type 2 segment it is the derivative of the Chebyshev expansion, as CSPICE
  `SPKE02` forms it. Legs in different NAIF inertial frames are rotated rather
  than refused.
- **Breaking.** `Sidereon.GNSS.Observables.predict/5`, `predict_ranges/3` and
  the scenario simulator keep every bit of the flight time in the transmission
  epoch, where it was rounded to whole microseconds, which moved the range by up
  to 0.4 mm; `transmit_time` stays the reception epoch less the flight time
  rounded to whole microseconds. On a broadcast source the satellite velocity is
  the selected record's difference over 1 ms, as RTKLIB `ephpos` forms it, so
  range rates and Doppler predictions change.
- **Breaking.** SPP, the static solve, DGNSS and the tight GNSS/INS update place
  each satellite at its transmission epoch from the pseudorange, `t_tx = (t_rx -
  P / c) - dts`, as RTKLIB `satposs` does, where they solved the geometric light
  time from the receiver's time tag, which leaves out the receiver clock
  offset. `Sidereon.GNSS.Positioning.solve_with_doppler/5` reads each Doppler
  satellite at the transmission epoch of its pseudorange, the state the
  position solve used, and adds the rate of the first-order Sagnac term, as
  RTKLIB `estvel` forms its rows from the `satposs` states; a Doppler satellite
  without a pseudorange has no row. `Sidereon.GNSS.RTK.build_rinex_rtk_arc/4`,
  `build_dual_frequency_rinex_rtk_arc/4` and the RINEX baseline and
  reference-station solves built on them place each receiver's satellites from
  that receiver's own pseudoranges, and skip a satellite for an epoch where the
  source has no clock for it or its pseudorange is not a positive distance, as
  RTKLIB places none there. On an SP3 source the solves add to the satellite
  clock the relativistic term `-2 r·v / c²` RTKLIB `peph2pos` applies to a
  precise clock, and a satellite within 1 ms of the end of the product's
  coverage has no ephemeris. Solutions move by millimetres to decimetres, and on
  SP3 sources by metres to tens of metres.
- **Breaking.** PPP places each satellite at its transmission epoch from the
  observation's pseudorange in the same way. An observation whose code is zero
  or negative places no transmission epoch; it is left out of the solve and
  listed in the new `unplaced_observations` of
  `Sidereon.GNSS.PrecisePositioning.MultiEpochSolution` and `FixedSolution` as
  `%{epoch_index, satellite_id, ambiguity_id, reason: :code_not_positive}`.
- **Breaking.** A PPP float or fixed solve leaves out every epoch left without
  observations and solves the rest. `epoch_clocks` of `MultiEpochSolution` and
  `FixedSolution` holds one clock per solved epoch, each with its
  `epoch_index`, and the new `solved_epoch_indices` lists the solved input
  epochs.
- **Breaking.** `MultiEpochSolution` gains `ssr_bias_exclusions`,
  `residual_screen_removals`, `metadata.residual_screen` and
  `metadata.solve_options`; `FixedSolution` gains `ssr_bias_exclusions`.
  Residual rows gain `epoch_index` and `ambiguity_id`. `solve_ppp_fixed/4`
  passes all of them back to the fixed solve, and refuses a residual row
  without `ambiguity_id` with `{:invalid_float_solution,
  :residual_ambiguity_id}`. Each SSR bias exclusion carries every field of the
  core record: the observation, which bias was missing, why the recorded biases
  do not hold at the transmission time, and the bias lookup's report row with
  each signal's query result; a phase continuity token and a source error,
  which the core does not let a caller build, carry a handle holding the core
  value. The fixed solve takes the records back unchanged and starts from
  them.
- **Breaking.** A PPP solve fails with
  `{:insufficient_observations_after_ssr_bias_exclusion, excluded, retained,
  required}` when leaving out observations without a required SSR/HAS bias
  leaves too few.
- **Breaking.** Every entry point that reads UT1 through an ephemeris source or
  a frame transform returns a UT1 outside the UT1 table as
  `{:ut1_outside_coverage, :before_coverage | :after_coverage}`, where it
  dropped the satellite or reported another error: SPP, DGNSS, static, FDE,
  PPP, tight fusion updates, RTK RINEX arcs, static reference-station modes,
  ARAIM, SBAS protection levels, scenarios (`{:ut1_outside_coverage,
  satellite, side}`), `Sidereon.OrbitDetermination` fits, which also return
  `:ut1_validity_mismatch` when a provider's UT1 policy differs from the fit's,
  and `Sidereon.GNSS.ReducedOrbit` fits. `Sidereon.GNSS.DGNSS.corrections/5`
  returns the refusal instead of raising.
- **Breaking.** `Sidereon.SpaceWeather.Policy` defaults to the core default
  policy: `require_geomagnetic: true`, so a blank daily Ap or three-hour Ap bin
  is refused with `{:missing_data, ...}` instead of filled, and the new
  `allow_not_observed: false`, so a row whose F10.7 flux qualifier is 3 (no
  observation) is refused with `{:rejected_by_policy, :not_observed, ...}`.
  Such rows read as the new class `:not_observed`; flux qualifiers 2 and 4 read
  as `:interpolated`, where 2 and 3 read as `:observed`. `sample_at/2`,
  `space_weather_at/2`, `ap_array_at/2`, decay estimation and propagation with
  drag on a table refuse Ap values the file does not state, where they substituted the quiet Ap of 4
  or the daily Ap without a report.
- **Breaking.** SPP and the static solve re-select, re-mask and re-weight the
  satellites at every iterate, as RTKLIB `estpos` does, and a converged solve
  reports `metadata.status` `:selection_settled`. `metadata.status` also takes
  `:outer_budget_exhausted` for a robust-reweighted solve that ran out of outer
  iterations, with `converged: false`; `converged` describes how the whole
  solve ended. `Sidereon.GNSS.Positioning` solves return
  `{:error, {:selection_unsettled, passes}}` and
  `Sidereon.GNSS.StaticPositioning.solve/3` returns
  `{:error, {:selection_unsettled, passes}}` when the selection does not
  settle; `Sidereon.GNSS.QC.fde/4` reports it the same way. SPP, static,
  DGNSS, fusion and RTK solutions seeded by SPP move with it.
- **Breaking.** `Sidereon.Elements` gains `omm_epoch_days`, the day count since
  1949-12-31 an OMM's epoch states. `Sidereon.Format.OMM.to_elements/1` sets it
  for an epoch of whole microseconds, and SGP4 then initialises the elements
  as python-sgp4 2.22's `sgp4.omm.initialize` does, with `bstar` and
  `mean_motion_double_dot` as the OMM states them; the OMM epoch takes
  python-sgp4's split Julian date. An OMM with any other epoch is bridged as a
  TLE, with `bstar` and `mean_motion_double_dot` quantized at the TLE writer's
  rounding, below 1e-10 at exponent -9; a value no TLE field holds passes
  through unquantized, and `Sidereon.Format.TLE.encode/1` refuses it.
- **Breaking.** `Sidereon.Format.TLE.encode/1` spells B\* and the second
  mean-motion derivative as python-sgp4's `export_tle` does: a zero B\* is
  `" 00000+0"`, a zero second derivative `" 00000-0"`, and ties round to even
  on the value's own digits.
- **Breaking.** Pass prediction and look angles propagate SGP4 at the split
  Julian date Skyfield 1.54 uses for the same UTC instant, so pass maximum
  elevations and topocentric states move in their last bits.
- UTC conversions from 1997-01-01 to 1997-06-30 and from 1998-01-01 to
  1998-12-31 were one second off: the embedded leap-second table dated the
  1997 and 1999 leap seconds to 1997-01-01 and 1998-01-01, where IERS dates
  them 1997-07-01 and 1999-01-01.
- `Sidereon.GNSS.RINEX.Clock` GPS seconds are the correctly rounded value of
  the civil tag, where the sum of the split Julian date's parts missed it for
  about one microsecond epoch in seven.
- PPP auto-initialisation passes each GLONASS observation's FDMA channel to its
  SPP seed.

### Fixed

- `klobuchar_delay/7` and `galileo_nequick_g_delay/7` returned a value the
  model refused as `{:ok, {:error, :invalid_input}}`; they return
  `{:error, :invalid_input}`.

- A function that returns `{:ok, _}` or `{:error, _}` around a native call no
  longer raises `KeyError` when the call cannot decode an argument: a value of
  another type, a map without a key the call reads, an integer outside the
  range the call accepts, or a handle to another kind of resource. It returns
  `{:error, {:invalid_argument, native_call}}`, and an argument that must be a
  number and is not one returns `{:error, {:arithmetic_error, native_call}}`;
  both are `t:Sidereon.argument_error/0`. A failure a decoder reports by field
  name is returned as before. Any other exception raised from Erlang inside
  these functions is raised as itself, where it too became `KeyError`.
- The accessors that raise `ArgumentError` when the native call fails, such as
  `Sidereon.GNSS.SP3.satellite_ids/1`, `Sidereon.GNSS.Broadcast.records/1` and
  `Sidereon.GNSS.RINEX.Observations.header/1`, raise it for these arguments too,
  in place of `KeyError`.
- `Sidereon.GNSS.Bias` loaders and `Sidereon.GNSS.ARAIM.araim/3` returned the
  `ArgumentError` struct itself as the reason for such an argument; they return
  `{:invalid_argument, native_call}`.
- `Sidereon.GNSS.Ntrip.sourcetable/2` with `:transport_fun` lets an exception
  the transport raises reach the caller as itself, as the stream already did.
  An Erlang error the transport raised was returned as `{:error, term}`, and an
  `ArgumentError` became `KeyError`.

## [2.1.1] - 2026-09-22

### Fixed

- CODE predicted ionosphere maps resolve to the archive AIUB now serves them
  from. `:cod_prd1` is `CODE/IONO/PRD/COD0OPSP0D_<date>0000_01D_01H_GIM.INX.gz`
  and `:cod_prd2` is `CODE/IONO/PRD/COD0OPSP1D_<date>0000_01D_01H_GIM.INX.gz`;
  the `CODE/IONO/P1/<year>` and `CODE/IONO/P2/<year>` `COD0OPSPRD` trees they
  were read from stopped receiving issues after 2026-09-21 and are now empty,
  so every predicted-IONEX request returned not-published. For the dates both
  layouts carried the objects decompress to the same bytes. The two lines now
  carry distinct official filenames, so their identities and cache paths
  differ by name as well as by prediction horizon. Publication status counts
  only objects under `CODE/IONO/PRD/`, not the rolling copies CODE keeps at
  the tree root.

### Changed

- Engine update: sidereon 2.1.1 / sidereon-core 2.1.1, which carries the
  predicted-map layout fix above.

## [2.1.0] - 2026-09-05

### Added

- Expose SP3 interpolation policy (`gap_threshold_factor`) across SP3 parsing, continuity checking, merge verification, precise ephemeris sample sources, and precise interpolant artifacts:
  - `Sidereon.GNSS.SP3.load/2`, `SP3.load!/2`, `SP3.parse/2`, and `SP3.parse_exact/3` accept `:gap_threshold_factor` (default `1.5`, must be > 1.0).
  - `Sidereon.GNSS.SP3.gap_threshold_factor/1` returns the configured gap threshold factor for an SP3 product.
  - `Sidereon.GNSS.SP3.check_continuity/2`, `SP3.continuity_verdict/4`, and `SP3.merge/2` (via `:verify_continuity`) accept `:gap_threshold_factor`.
  - `Sidereon.GNSS.PreciseEphemeris.from_samples/2` and `PreciseEphemeris.gap_threshold_factor/1`.
  - `Sidereon.GNSS.PreciseEphemeris.Interpolant.from_sp3/2`, `from_samples/2`, `from_precise_ephemeris_samples/2`, `artifact_bytes/2`, and `gap_threshold_factor/1`.
  - `Sidereon.GNSS.PreciseEphemeris.InterpolantArtifact` and `PreciseInterpolantArtifact` support `:gap_threshold_factor` in `artifact_bytes/2` and expose `gap_threshold_factor/1`.

### Changed


- Engine update: sidereon 2.1.0 / sidereon-core 2.1.0. Additive upstream release: the SP3 coverage-gap threshold is now a validated, product-carried policy (`Sp3InterpolationOptions`, default 1.5 and bit-identical to before), the SP3 window-scoped continuity reach is derived from the interpolator's actual selectable node spans, and RINEX 4 CNAV week/TOW round trips are stable at the week boundary.

## [2.0.0] - 2026-09-02

### Changed

- Engine update: sidereon 2.0.0 and sidereon-core 2.0.0 from crates.io registry.
- Struct instantiation modernization: all public non-exhaustive option and config structs now use canonical constructors (`Default::default()` or `::new(...)`) followed by explicit field assignments, preserving field coverage and strict backwards compatibility.
- Zero behavioral change: full precision, exact test value pinning, and complete parity preserved across all modules.

## [1.4.1] - 2026-08-31

### Changed

- Engine update: sidereon 1.4.1 / sidereon-core 1.4.1 with
  trust-region-least-squares 0.11.0. Portable scalar numerics keep coordinate
  transforms bit-identical across x86_64 and arm64 and align converged GNSS fit
  diagnostics across architectures.

## [1.3.3] - 2026-08-30

### Fixed

- `parse_archive_listing/1` runs on a dirty CPU scheduler and borrows its body
  as text instead of copying it, so a large listing no longer blocks a normal
  BEAM scheduler or duplicates the body in memory. A body that is not UTF-8
  now returns `{:error, {:unrecognized_archive_listing, reason}}` rather than
  raising. Covered by a scheduler-safety test on a single-scheduler peer.

### Changed

- Engine update: sidereon 1.3.3 / sidereon-core 1.3.3. Archive-listing parsing
  is no longer quadratic (154 s to 0.23 s on AIUB's ~426k-row listing), and
  transcendental math is bit-identical across x86_64 and arm64.

## [1.3.1] - 2026-08-29

### Changed

- Engine update: sidereon 1.3.1 / sidereon-core 1.3.1. This release keeps the
  shared release number across the language interfaces, which ships the Go
  interface relicense from Apache-2.0 to MIT. No interface API changes.

## [1.3.0] - 2026-08-29

### Changed

- Engine update: sidereon 1.3.0 / sidereon-core 1.3.0. This release keeps the
  shared release number across the language interfaces, which now include a Go
  interface. No interface API changes.

## [1.2.0] - 2026-08-28

### Added

- Raw, lenient, and GLONASS NAV record lists with arbitrary-list encoding;
  RINEX observation-code and version-aware frequency and wavelength lookups;
  single- and dual-frequency RINEX RTK arc builders with intermediate handles;
  and explicit DTED tile-list byte and file builders.

### Fixed

- The native pins now track the engine release. They were left at
  `=1.1.0` when the package moved to 1.1.1, so that release built against the
  previous engine version.

### Changed

- Engine update: sidereon 1.2.0 / sidereon-core 1.2.0, which corrects lenient
  RINEX 4 CNAV decoding and RTKLIB SBAS wire-form preservation.

### Added

- `Sidereon.GNSS.Broadcast` now exposes raw RINEX NAV record-list parsing,
  lenient skipped-block diagnostics, arbitrary-list encoding, and unfiltered
  GLONASS record parsing through the pinned core parser.
- `Sidereon.GNSS.Frequencies` now exposes version-aware full observation-code
  frequency and wavelength mappings, including BeiDou version policy and
  GLONASS FDMA channels.
- Public single- and dual-frequency RINEX RTK arc builders with retained
  intermediate handles and explicit DTED tile-list store builders.

## [1.1.1] - 2026-08-26

### Fixed

- Req 0.7 no longer warns when Sidereon selects its supervised Finch pools;
  all three HTTP paths now use Req's current named-pool option. No API changes.
- The install snippets in the README, the NIF README, and the Livebooks still
  pinned `~> 0.35`, `~> 0.38`, and `~> 0.9`; they now pin `~> 1.1`, and the
  suite fails if they lag `mix.exs` again. No API changes.

## [1.1.0] - 2026-08-24

### Added

- Source localization accepts `include_influence: false` to skip per-sensor
  leave-one-out re-solves, and exposes the Schau–Robinson
  `closed_form_initial_guess/4` initializer. `chan_ho_initial_guess/4` remains
  as a deprecated alias.

### Changed

- Source sensor influence scores are now
  `max(abs(residual_s), abs(leave_one_out_residual_s)) / timing_sigma_s`;
  robust-loss downweighting is reported separately in `loss_weight`.

## [1.0.1] - 2026-08-22

### Changed

- engine update: sidereon-core 1.0.1 with trust-region-least-squares 0.10.0 (unified fail-closed HostNumerics backend seam; host power dispatch reproduces NumPy's stride-0 scalar-exponent fast paths bit-for-bit). No interface API changes.

## [1.0.0] - 2026-08-21

Sidereon 1.0.0 across every interface. The engine's stability commitment
applies here too: additions arrive without breaking existing callers.

### Added

- Exact-cache single-flight coalescing: `Sidereon.GNSS.ExactCache` gains
  `:single_flight` options and `{:hit, entry} | {:owner, owner}` outcomes
  with typed timeout and ownership-loss errors; concurrent requesters for
  one product identity coalesce onto a single download.
- Window-scoped continuity verdicts: `SP3.stencil_extent/1`,
  `SP3.continuity_verdict/4`, and the merge-report equivalent answer
  whether any recorded defect influences a bounded evaluation window,
  with the stencil reach derived from the interpolator itself.
- `Data.next_issue_due/3`: network-free next nominal issue for cataloged
  product lines, naming the ultra lines' observed and predicted halves.

### Changed

- Engine pinned to `sidereon-core` 1.0.0.

## [0.39.1] - 2026-08-11

### Fixed

- DTED terrain lookups compute the grid cell and intra-cell fraction in
  exact integer arithmetic (engine fix): the binary64 scaling product
  rounded away up to 4096 ULP of the fraction and could flip a
  coordinate strictly below a posting into the next cell's stencil.
  No API change; heights at dyadic-exact coordinates are byte-identical.

### Changed

- Engine pinned to `sidereon-core` 0.39.1.

## [0.39.0] - 2026-08-10

### Added

- Attested opens for both mapped artifact readers:
  `Sidereon.Terrain.MmapTerrain.from_path_attested/2` and the
  precise-interpolant equivalent, recording a caller-attested content
  checksum instead of hashing the payload at open. `digest_provenance/1`
  returns `:verified` or `:attested`, and `verify/1` escalates to the
  full hash pass on demand. Malformed claims are typed errors, never a
  silent fallback to hashing.

### Changed

- Engine pinned to `sidereon-core` 0.39.0.

## [0.38.0] - 2026-08-09

### Changed

- Terrain stores and precise-interpolant artifacts opened from a path are
  now memory-mapped rather than read into memory. `terrain_store_mmap_from_path`
  previously read the whole file, so a 30+ GB store cost its size in
  process memory before the first lookup; it now maps the file read-only
  and the reader owns the mapping. No API change - existing callers get
  this by upgrading.

  The mapping is demand-paged, so a reader querying a geographically local
  region faults in only the pages covering those tiles. Construction parses
  the header, datum tag, and tile index and nothing else.

- Engine pinned to `sidereon-core` 0.38.0 with its `mmap` feature enabled.

## [0.37.0] - 2026-08-09

### Added

- `Sidereon.GNSS.SP3.check_continuity/2` attests that a parsed or merged
  product is physically continuous, or reports each violation with its
  epochs and magnitude. Two checks with different jobs: a physical
  earth-fixed speed gate that cannot false-positive and catches gross
  corruption, and a hold-out interpolation residual that supplies the
  sensitivity a speed gate structurally cannot (adjacent GNSS MEO epochs
  are hundreds of kilometres apart, so a metre-scale splice is invisible
  to any physical bound). Reports rather than refuses.

### Changed

- Engine pinned to `sidereon-core` 0.37.0.

## [0.36.5] - 2026-08-08

### Added

- A `:portable` variant of the glibc Linux precompiled NIFs
  (`x86_64-unknown-linux-gnu--portable`, `aarch64-unknown-linux-gnu--portable`),
  zig-linked against a glibc 2.17 floor so the artifact is self-contained on
  old-glibc hosts and in zig-based packaging pipelines such as Burrito. Opt
  in at compile time with `SIDEREON_PORTABLE_NIF=1` or
  `config :sidereon, portable_nif: true`; without the opt-in, artifact
  selection is unchanged. The musl artifacts are already self-contained and
  have no variant. CI verifies the variant's glibc symbol ceiling and
  load-smokes it alongside the musl artifacts.

## [0.36.4] - 2026-08-07

### Added

- Precompiled NIFs for `x86_64-unknown-linux-musl` and
  `aarch64-unknown-linux-musl`, so musl-based deployments (Alpine container
  images, including the standard `hexpm/elixir:*-alpine-*` bases) install
  without a Rust toolchain. The musl NIFs link the C runtime dynamically
  (`-crt-static`), as a static-crt object cannot be loaded as a NIF.

### Changed

- The FTP transport's default client is now `Sidereon.GNSS.FtpClient`, a
  minimal passive-mode anonymous-FTP client over `:gen_tcp` (RETR/LIST,
  TYPE I, RFC 959 multiline replies, FTP 550 as `:epath`), removing this
  library's dependency on OTP's `:ftp` application ahead of its OTP 30
  removal. Live-verified against the WHU archive for listings, exact
  acquisition, and merge. The `:ftp_module` application-env seam remains
  for callers preferring OTP's client (OTP <= 29) or their own.

## [0.36.3] - 2026-08-04

### Fixed

- Exact acquisition (`Distribution.acquire/2` and everything built on it,
  including `fetch_merged_sp3/3`) now acquires cataloged `ftp://` products.
  0.36.1's FTP transport lived only in the `Data` layer, so a WHU `wum_nrt`
  candidate - whose identity 0.36.2 fixed - was still rejected as
  `{:malformed_url, ...}` by the exact path's URL validation, and because
  that is an error rather than an absence, wiring the center into a merge
  set halted the whole batch. The `ftp` scheme is now accepted for hosts the
  core catalog itself serves over FTP (everything else stays http/https,
  redirect policy untouched), downloads route through the same bounded
  `:ftp` transport with its `:ftp_client` injection, and FTP 550 maps to
  the same typed `:product_not_published` absence as an HTTP 404 - a
  missing hourly issue degrades a merge batch instead of killing it.
  Verified live end to end: `fetch_merged_sp3` acquiring and merging
  `gfz_ult` (HTTPS) with `wum_nrt` (FTP), the candidate walk degrading
  through genuinely absent hourly issues on the way. Found by downstream
  0.36.2 verification; regression tests now sit at exactly this seam.

### Notes

- Merging `wum_nrt` with the IGS/ESA/GFZ operational ultras is the
  catalog's first mixed frame-label pair (`IGS20` vs `IGc20`). The merge's
  frame reconciliation fails closed on mismatched labels by design; assert
  the equivalence explicitly via
  `asserted_frame_label_sets: [["IGS20", "IGc20"]]` when your policy
  accepts it.

## [0.36.2] - 2026-08-04

### Fixed

- `Distribution.identity/1` no longer parses a filename-bearing product's
  identity through an interface-side filename grammar. That duplicated
  parser missed the `NRT` solution token the core learned in 0.36.0, so
  every cataloged WHU `wum_nrt` ultra candidate - which always carries a
  filename - died at identity parsing before any download, even with FTP
  transport working. Identity fields now always come from the one core
  catalog; a declared filename is verified against the core-derived
  official filename and a mismatch fails closed. The duplicated grammar and
  its token table are deleted, so the next core token addition cannot
  diverge here again. Found by downstream 0.36.1 verification.
- Engine crates updated to 0.36.3, whose `parse_archive_listing` accepts
  AIUB whole-tree CSV rows with spaces in unrelated object paths; 0.36.1's
  `publication_status/3` for CODE lines followed the redirect and then
  rejected the entire live 426k-row listing over one such row.

## [0.36.1] - 2026-08-04

### Fixed

- `Data.publication_status/3`'s built-in listing fetch now goes through the
  acquisition transport's bounded, host-allowlisted redirect policy. AIUB's
  whole-tree listing URL - the single bounded URL for every CODE product
  line - 302-redirects to its object store, so 0.36.0 reported
  `{:unreachable, url, {:http_status, 302}}` for all CODE publication-status
  queries, including the predicted-GIM lines the publication-lag work was
  motivated by. A 3xx is neither an authoritative 404 (walk-back semantics
  are unchanged) nor a transport failure.

### Added

- Anonymous-FTP transport (OTP `:ftp`, no new dependency) for cataloged
  `ftp://` archives, bounded exactly like the HTTP path: connect timeout,
  streamed chunk cap, `:ftp_client` injection for network-free tests, and
  FTP 550 mapped to archive absence like an HTTP 404. This makes the Wuhan
  `wum_nrt` hourly line - the only additional 02D/05M ultra source, i.e. the
  only new grid-defining alternative - acquirable from Elixir, including
  `publication_status/3` over its FTP directory listings.

### Notes

- Elixir 0.36.0 already accepts the `WUM` publisher and `near_real_time`
  solution-class tokens in caller-supplied identities (the fix the Python
  and WASM 0.36.1 releases shipped separately landed here before the Hex
  publish); a regression test now pins that. Engine crates stay at their
  0.36 series; this release pins 0.36.1 for lockstep with the other
  interfaces.

## [0.36.0] - 2026-08-04

### Added

- Publication-lag resilience surface over core 0.36.0:
  `Data.predicted_ionex_line_candidates/2` (the opt-in CODE `P1`/`P2`
  cross-line walk for one map date - never a neighboring day's map, each
  candidate keeping its own line identity), `Data.parse_archive_listing/1`
  (closed dialect detection: an unrecognizable listing body is
  `{:error, {:unrecognized_archive_listing, reason}}`, never a best-effort
  empty result), `Data.newest_published_product/3`,
  `Data.publication_listing_urls/3`, `Data.published_issue_age_minutes/2`,
  and `Data.resolve_first_published/2`.
- `Data.publication_status/3`: one bounded networked query reporting the
  newest published issue for a center and product line and its lag behind
  nominal, without fetching product bytes. An authoritative 404 walks back
  one directory; a transport failure or unreadable listing is
  `{:unreachable, url, reason}` and never walks back - "nothing published"
  and "archive did not answer" are distinct outcomes. `observed_at` is the
  archive-reported modification text, verbatim.
- `Data.fetch_ionex/3` accepts `cross_line: true` (CODE predicted centers)
  to walk the sibling predicted line for the same map date before falling
  back a day, cache-first, with provenance naming the line actually served.
  Off by default: the single-line request stays fail-closed.
- The Wuhan MGEX near-real-time orbit line (`:wum_nrt`, hourly `WUM0MGXNRT`
  02D/05M over anonymous FTP, archive-verified from 2024-07-03) flows
  through the catalog surface, with the `near_real_time` solution class.

### Changed

- Updated `sidereon` and `sidereon-core` to 0.36.0.

## [0.35.0] - 2026-07-24

### Fixed

- Observation QC now treats a RINEX `INTERVAL` of zero as the
  standards-defined unavailable value, reports `OBS-H19` at informational
  severity, and infers cadence from body epochs when possible. Negative parsed
  values, and non-finite values in programmatically constructed core headers,
  report `OBS-H20` as invalid metadata. Neither kind is used for calculations;
  an unresolved cadence remains explicit when the body cannot supply one.
  Explicit caller interval overrides must still be finite and positive.
- Opt-in interval repair replaces unavailable or invalid source metadata when
  cadence can be inferred and removes it when cadence is unresolved. Default
  repair preserves source `INTERVAL` metadata.

### Changed

- RINEX repair option defaults now match the canonical Rust interface and the
  Python, C, and WASM bindings: interval, last-epoch, observation-count,
  empty-record, and unsupported-record repairs are opt-in; record sorting
  remains enabled by default.
- Updated the native backend to `sidereon` and `sidereon-core` 0.35.0.

### Compatibility

- Observation QC call signatures are unchanged, and positioning, orbit, and
  other solver numerical kernels are unaffected. Elixir callers that relied on
  the former eager repair defaults must now pass the corresponding repair
  options explicitly.

## [0.34.0] - 2026-07-21

### Added

- `Sidereon.GNSS.Data.sp3_content_start_convention/3` exposes the core's exact
  relationship between an SP3 filename epoch and first content epoch, including
  the official historical GFZ ultra-rapid transition.
- `Sidereon.GNSS.Data.supported_samples/4` exposes the core's product-, date-,
  and issue-aware set of officially cataloged sampling tokens. Product
  constructors enforce the same set before deriving filenames, URLs,
  identities, or cache keys.

### Fixed

- Exact SP3 parsing and acquisition now accept the public terminal-record
  variants supported by the core: bare `EOF` or `EOF` followed only by ASCII
  spaces through column 80, with LF, CRLF, or no final separator. Malformed or
  missing terminal records and nonblank trailing content remain terminal
  integrity failures.
- Bounded gzip acquisition now follows RFC 1952's member-sequence model under
  one cumulative output limit. Every member must have a complete header,
  DEFLATE stream, CRC32, and ISIZE trailer; corrupt or truncated later members
  and non-member trailing data fail before exact-product parsing, distributor
  fallback, or cache publication. Valid concatenated members and large legal
  optional headers are accepted.
- Built-in HTTP and local-file acquisition now stop at the compressed-input
  cap instead of buffering an oversized archive first. Error precedence for
  redirects and ordinary publication absence is unchanged.
- Identity-derived exact SP3 validation now applies cataloged filename/content
  start semantics. Direct `Sidereon.GNSS.SP3.ExactRequest.new/4` requests
  retain supplied-date semantics.
- Ultra-rapid exact candidates now contain only dated span/cadence variants
  evidenced for the exact center, date, and issue. CODE's moving latest-product
  snapshot is excluded because it is not the dated one-day product; the
  documented GFZ `2021-05-15 0000` cadence overlap remains the only
  two-candidate issue. Caller-built identities must use the cataloged span.

### Changed

- Updated the native backend to `sidereon` and `sidereon-core` 0.34.0.

### Compatibility

- The new catalog query is additive; existing Elixir call signatures and all
  numerical behavior are unchanged. Ultra-SP3 candidate lists can be shorter
  because unsupported alternate spans/cadences and CODE's non-exact moving
  snapshot are no longer returned. Reports or cache entries that claimed that
  snapshot as a dated identity no longer verify. This is a minor release
  because the catalog API is public and historical GFZ and canonical-span
  validation are newly enforced.

## [0.33.1] - 2026-07-20

### Changed

- Multi-distributor fallback now continues after ordinary publication absence,
  retired endpoints, and exhausted source-local transport availability while
  keeping integrity and configuration failures terminal. Retryable HTTP status
  is limited to 408, 429, and 500 through 599.
- Unix-compress acquisition now locks the current ncompress maxbits-9 behavior
  and rejects detectable partial terminal codes and invalid terminal padding
  before product parsing. Because `.Z` has no end marker, exact product
  validation and an optional caller digest remain authoritative.
- Acquisition byte limits now require positive integers at the public boundary.
- Multi-center SP3 acquisition now records a generally supported center outside
  its verified catalog era as `catalog_unavailable`; unrelated configuration
  and integrity errors remain terminal.
- Invalid or failing caller-supplied HTTP callbacks now return a typed terminal
  client failure instead of being retried or authorizing distributor fallback.
- Precompiled NIF archives now carry the project license and third-party
  attribution notice alongside the native library. Hex source packages and NIF
  archives also include the full Apache-2.0, ERFA BSD-3-Clause, IERS
  Conventions, libloading ISC, and SciPy BSD-3-Clause license texts required by
  the source and locked Rust dependency graph, plus exact public 0.33.1
  tide-derived sources.
- Precompiled-NIF release builds now pin action revisions, Elixir/OTP/Hex,
  Rust 1.92.0, the architecture-specific rustup bootstrap checksums, the
  source-build container digest, and the cross build tool revision; they require
  locked Cargo resolution and grant write permission only to the release-asset
  publication job.
- Updated the native backend to `sidereon` and `sidereon-core` 0.33.1.

## [0.33.0] - 2026-07-20

### Added

- Added product-aware `Sidereon.GNSS.Data.product_solution_class/2`, dated
  `default_sample_for_date/3`, core-derived exact product identities and
  distribution locations, and historical IGS final-SP3 naming support.
- Added `Sidereon.GNSS.SP3.ExactRequest`, `parse_exact/2`,
  `validate_exact/2`, declared epoch-count/start accessors, and explicit
  half-open/inclusive coverage results.
- Added size-limited Unix `compress` (`.Z`) decoding for historical CDDIS
  products.

### Changed

- Exact SP3 acquisition now validates mandatory SP3 structure, producing
  agency, declared and parsed start/count, requested cadence, regular epoch
  grid, and exact span before publishing bytes or provenance.
- Source and ultra-rapid candidate fallback now continues only after ordinary
  publication absence. Malformed content, parsing, digest, identity, cadence,
  span, caller configuration, and cache-integrity failures are terminal.
- IGS final SP3 uses the official short filename and CDDIS `.Z` layout before
  GPS week 2238, then the long filename and gzip layout. IGS broadcast
  navigation remains independently classified as `broadcast`.
- CODE SP3/clock/IONEX URLs are resolved by product family, and GFZ rapid-SP3
  sampling defaults are selected by date across the 2021 15-minute to
  five-minute transition.
- Catalog derivation now enforces the verified publication floors for ESA
  final, GFZ rapid, and IGS/ESA/GFZ ultra-rapid SP3. ESA and GFZ ultra-rapid
  defaults follow their historical cadence eras, including ESA's intraday
  transition between the 2025-02-02 0600 and 1200 issues. CDDIS rejects
  pre-week-2238 long-name SP3 identities instead of inventing archive paths.
- Updated the native backend to `sidereon` and `sidereon-core` 0.33.0.

### Compatibility

- Existing permissive `Sidereon.GNSS.SP3.parse/1` remains available, and the
  core's date-free sampling query is exposed as `Data.default_sample/2` for
  compatibility-oriented catalog inspection. Exact acquisition is
  intentionally stricter, and unsupported center/product combinations now fail
  before transport. This additive API and integrity-policy change requires a
  minor release.

## [0.32.0] - 2026-07-18

### Added

- Added `Sidereon.GNSS.Constellation.parse_navcen_html_at/2` and
  `merge_navcen_at/2` for deterministic UTC evaluation of NAVCEN forecast
  outages. Assessments retain the raw NANU fields, Outage Start cell, and a
  parsed half-open interval or explicit ambiguity; the existing clock-free
  parsing and merge APIs remain unchanged.
- The time-aware path recognizes active `UNUSUFN` notices as immediately
  unusable while preserving the legacy parser's pre-existing behavior.

### Changed

- Updated the native backend to `sidereon` and `sidereon-core` 0.32.0.

## [0.31.2] - 2026-07-16

### Added

- Merged-SP3 reports now retain a complete exact artifact identity and separate
  acquisition observations for every contributor, plus the shared versioned
  stable identity of the contributor set and merge policy. Mean/median input
  enumeration is canonicalized; precedence order is recorded and bound.
- Added `Sidereon.GNSS.SP3.merge_input_identity/2`,
  `Sidereon.GNSS.Data.merge_report_to_map/1`, `verify_merge_report/1`, and
  `fetch_merged_sp3_file_with_report/4` for validation, secret-free
  persistence, and file output without discarding provenance.
- Added the shared literal merged-SP3 canonicalization fixture and returns the
  complete core-canonical contributor list plus semantic precedence order.

### Changed

- Merged-SP3 candidate downloads now use the exact acquisition and atomic cache
  path. Existing unverifiable files in the legacy flat merged-SP3 cache are not
  accepted as provenance-bearing contributors.
- Latest-product aliases must prove their public catalog equivalence and exact
  artifact duration before publication. Persisted reports now reject unknown
  or inconsistent fields at every nested schema level, and authenticate the
  ordered requested-center partition across contributors and absent centers.
- Updated the native backend to `sidereon` and `sidereon-core` 0.31.2.

### Compatibility

- Existing `Contributor` construction and the path-only return from
  `fetch_merged_sp3_file/4` remain valid. The new report fields and report-
  retaining file helper are additive. Merged acquisition no longer trusts the
  former digest-only flat cache because it cannot prove exact artifact
  identity.

## [0.30.0] - 2026-07-16

### Fixed

- Publishes exact-product cache entries as immutable payload/archive/provenance
  transactions selected by one atomic digest-bound commit record. Cache hits
  cannot observe a mixed update after independent BEAM instances race or a
  process dies at a publication boundary.
- Delegates exact acquisition to the shared Rust transaction implementation.
  Its bounded advisory lock coordinates Linux and macOS processes; dead owners
  release automatically, waiters avoid a second acquisition, and abandoned
  transactions are removed only by a lock owner.
- Revalidates and atomically migrates valid 0.29.0-0.29.2 cache triples without
  reacquisition. Cache lock/write failures are terminal and never authorize a
  distributor change.

### Added

- Added the optional `:cache_lock_timeout_ms` acquisition option, defaulting to
  30,000 milliseconds.
- Added the documented `Sidereon.GNSS.ExactCache` transaction module and public
  full-identity cache-key derivation.

### Changed

- Updated the native backend to `sidereon` and `sidereon-core` 0.30.0. Full
  identity hashing now uses the same golden canonical key in all five
  interfaces.

## [0.29.2]

### Added

- Added `Sidereon.GNSS.Distribution.validate_exact_product_set/2`, a fail-closed
  gate for a declared exact identity inventory. Empty declarations,
  duplicates, missing products, and undeclared products are rejected.
- Exact-set comparison preserves prediction-tier identity. SP3
  observed/predicted timing remains sourced from the parser's authoritative
  record-flag summary.

### Changed

- Updated the native backend to `sidereon` and `sidereon-core` 0.29.2.

## [0.29.1]

### Fixed

- Fetches CODE predicted IONEX P1 and P2 products from their current official
  tier-specific HTTPS directories, retaining the requested identity year and
  exact filename across validated AIUB redirects.
- Routes the legacy IONEX helper through exact acquisition so downloaded and
  cached bytes receive the same date, issue, and cadence validation. Explicit
  legacy lookback continues only after typed not-published or offline-miss
  results; validation and transport failures remain terminal.
- Keeps P1 and P2 cache identities isolated even when their filenames match.

### Changed

- Updated the native backend to `sidereon` and `sidereon-core` 0.29.1.

## [0.29.0]

### Added

- Added exact SP3/IONEX acquisition that separates product identity from an
  ordered, caller-selected list of direct, NASA CDDIS/Earthdata, local-file,
  and in-memory sources.
- Added caller-supplied Earthdata bearer-token and netrc authentication,
  source-specific verified caches, retained archive bytes, structured failures,
  parsed semantic checks, and secret-free acquisition provenance.

### Fixed

- Accepts both binary and charlist results from OTP's user-cache-directory
  helper, preserving the default cache path across supported OTP versions.

## [0.28.1]

### Fixed

- Updated the native backend to `sidereon` and `sidereon-core` 0.28.1. CODE
  ultra-rapid products now use AIUB's current HTTPS download endpoint instead
  of the retired `ftp.aiub.unibe.ch` HTTP tree.
- Follows only AIUB's validated HTTPS handoff to its download host and public
  object store. Missing candidates retain the URL and HTTP status in merge
  diagnostics without claiming authoritative publication state.
- Updated the locked Mint HTTP dependency to 1.9.2, clearing the published
  HTTP/1 and HTTP/2 response memory-exhaustion advisories affecting 1.9.1.

## [0.28.0]

### Added

- Added per-cell SP3 precedence, optional deterministic outlier rejection,
  clock-outlier provenance, and observed/predicted epoch summaries.
- Added ultra-rapid product-pattern fallback with contributor provenance and
  complete merge-option forwarding through `fetch_merged_sp3/3`.

### Changed

- Updated the native backend to `sidereon` and `sidereon-core` 0.28.0.

### Fixed

- Hex source packages now include the Cargo workspace lockfile, use exact Rust
  registry pins, and clear verifier scratch directories before clean builds.

## [0.27.1]

### Fixed

- Updated the native backend to `sidereon` and `sidereon-core` 0.27.1. LAMBDA
  integer least-squares now returns `{:error, :invalid_input}` when an ambiguity
  or back-transformed candidate is outside the signed 64-bit integer lattice,
  instead of saturating the integer result and returning non-finite scores.

## [0.27.0]

### Added

- PROJ-compatible EGM96 15-arcminute GTX loading and vertical-grid
  interpolation through `Sidereon.Geoid`. Callers explicitly select fused or
  separately rounded multiply-add evaluation to match their reference PROJ
  build, and invalid coordinates return `ProjVgridshiftError` rather than
  panicking, clamping, or extrapolating.

### Changed

- Updated the native backend to `sidereon` and `sidereon-core` 0.27.0.

## [0.26.1]

### Security

- Updated `sidereon` and `sidereon-core` to 0.26.1, which rejects RINEX 2
  observation epoch headers that declare an oversized satellite count before
  processing continuation records. Malicious input could otherwise request an
  enormous allocation and terminate the BEAM VM. Core releases and binary
  artifacts 0.11.1 through 0.26.0 are affected. Published Sidereon Hex versions
  0.11.1 through 0.25.0 are affected; upgrade to 0.26.1.

## [0.26.0]

### Breaking

- Removed the unsound generic sequential-RTK innovation screen together with
  `ArcUpdateOptions.innovation_screen_sigma`,
  `ArcUpdateOptions.innovation_screen_min_rows`, the corresponding map-option
  aliases, and `ArcEpochSolution.innovation_screen`. The removed classifier
  divided residuals by measurement variance, omitted predicted-state
  covariance and shared-reference correlation, and treated carrier-phase
  events as ordinary row outliers. Sequential RTK now always assimilates the
  complete correlated double-difference block of all admitted rows; carrier
  anomalies remain under the causal slip/arc lifecycle.

### Fixed

- Updated the native backend to `sidereon-core` and the Rust facade 0.26.0.
  Near-polar ionospheric pierce-point evaluation now remains finite when
  rounding puts a valid latitude sine just outside `[-1, 1]`, and the locked
  Rust graph includes the `crossbeam-epoch` security fix.
- Release validation now builds the actual Hex tarball, verifies that its NIF
  crate pins `sidereon-core` only by a registry version, and forces
  a source build from the unpacked package through a throwaway consumer in a
  clean Rust-enabled container. The gate runs in pull-request CI and before
  tagged precompiled artifacts are published. The documented source-build
  instructions now include the consumer-side optional Rustler dependency.
- Audited every published Hex package from 0.8.0 through 0.25.0. Version 0.8.0
  is the only affected release: its source-build path pins a nonexistent
  `sidereon-core` git tag. Its precompiled path still works; consumers should
  upgrade to 0.25.0 or newer. Versions 0.9.0 through 0.25.0 already use
  registry pins and are not affected.

### Evaluation-bit stability

- The near-polar TEC correction intentionally changes affected pierce-point
  results from non-finite latitude/longitude values to finite values. Existing
  in-range TEC evaluations require no golden re-pin, and the ordinary
  sequential-RTK path remains bit-identical to its former no-screen execution.

## [0.25.0]

### Added

- Typed public structs for the RTK arc surfaces: sequential arc, static arc,
  wide-lane fixed, and ionosphere-free preparation results, plus typed arc
  config structs (map input still accepted).
- `Sidereon.GNSS.QC.raim_for_solution/2` as a first-class direct wrapper.
- `Sidereon.GNSS.SPP.spp_inputs_from_rinex_obs/3` and
  `solve_spp_from_rinex_obs/3`, mirroring the Rust facade conveniences.
- `Sidereon.GNSS.PreciseEphemeris.InterpolantArtifact` as a named public type
  over the existing artifact bytes/open/checksum calls.
- `Sidereon.GNSS.Ntrip.request_bytes/2` (and the `ntrip_request_bytes/2`
  facade-name alias) exposing the sans-I/O NTRIP request builder.
- Parity naming for estimation, terrain/geoid, SP3 precise-accessor, signal
  analysis, and fusion typed-input helpers, matching the other interfaces.

## [0.24.0]

### Added

- Direct post-solve RAIM (`Sidereon.GNSS.QC.raim/2`): residuals and geometry
  in, fault flag and test statistic out, including the for-solution overload.
  Docs state the weighting contract: pass per-satellite inverse-variance
  weights; unit weights on metre-scale residuals saturate the fault test.
- ARAIM results expose `available` (with `availability` kept as an alias), and
  geometry that cannot support the integrity budget now returns an unavailable
  result instead of an error, matching core 0.24.0 semantics.
- `Sidereon.Reliability` ARAIM parity with the other interfaces.

## [0.23.0]

### Added

- RTCM broadcast ephemeris decode for Galileo (1045/1046), BeiDou (1042), and
  QZSS (1044), with solver conversion, at parity with core's real-data
  validated decoders.
- Public multi-epoch static positioning (`solve_static`) with covariance,
  leave-one-out redundancy diagnostics, and robust weighting.
- Static PPP options: optional elevation cutoff and optional
  tropospheric-gradient estimation (off by default).
- Temporal-correlation covariance fields on static PPP solutions
  (`temporal_position_covariance`, scale factor, and correlation diagnostics).

## [0.22.0]

### Added

- Static PPP posterior position covariance (ECEF and ENU) on float and fixed
  solutions, with the posterior variance factor and applied scale factor.
- SP3 multi-center merge coordinate-label reconciliation (asserted equivalence
  and catalog Helmert), with merge-report audit fields.

### Changed

- Static PPP eliminates per-epoch receiver clocks for tractable day-length arcs,
  and scales result covariance by the posterior residual variance factor.

## [0.21.0]

### Added

- Fusion field mode (`Sidereon.GNSS.Fusion`): zero-velocity and zero-angular-rate
  updates with a stationarity detector, non-holonomic vehicle constraints,
  per-fix-status measurement weighting, and the IMU-to-body mounting matrix,
  all off by default with parity tests against core values.
- Multi-epoch reference-station static solve (`Sidereon.GNSS.RTK`): rover and
  reference observations in, one station coordinate with covariance and typed
  per-mode errors out, verified against a published ITRF station pair.

## [0.20.0]

### Added

- Carrier-phase RTK baselines built straight from raw RINEX
  (`Sidereon.GNSS.RTK.solve_static_rinex_rtk_baseline/5` and
  `Sidereon.GNSS.RTK.solve_wide_lane_fixed_rinex_rtk_baseline/5`): rover and base
  observations plus ephemeris and base coordinates in, float and wide-lane
  fixed baselines out with covariance and fix status, verified to millimeters
  against a published ITRF station pair.
- Position error metrics (`Sidereon.ErrorMetrics`): CEP, DRMS, 2DRMS, R95/R99,
  SEP, MRSE, per-axis sigmas, percentile radii with probability and validity,
  and the error ellipse, from ENU or ECEF covariances or a kinematic solution.

## [0.19.1]

### Added

- The GNSS/INS fusion surface (`Sidereon.GNSS.Fusion`): strapdown mechanization,
  loose and tight coupling with the robust update configuration, fixed-interval
  RTS smoothing over recorded fusion history, and static fusion, with parity
  tests against core values.

## [0.19.0]

### Added

- The no-IMU track filter and RTS smoother (`Sidereon.Estimation`):
  covariance-weighted constant-velocity filtering of position fixes so
  weak-geometry fixes cannot spike the track, with fixed-interval smoothing.
- Solid Earth and pole tide forces for numerical propagation, and station
  displacement corrections (solid tide, pole tide, ocean loading from BLQ).

## [0.18.0]

### Added

- GNSS/INS fusion (`Sidereon.GNSS.Fusion`): mechanization configuration, EKF
  and UKF filtering, loose and tight measurements, robust loose update
  options, the RTS smoother, time synchronization, and the serializable
  filter state.
- The deterministic scenario simulator (`Sidereon.GNSS.Scenario`):
  bit-reproducible synthetic observables plus the ground-truth term ledger.
- Closed-form signal analysis (`Sidereon.GNSS.Signal.Analysis`): spectra,
  spectral separation coefficients, DLL jitter, and multipath envelopes.

## [0.17.0]

### Added

- Uncertainty-aware geodesic geofencing (`Sidereon.Geofence`): containment and
  crossing probabilities from a position covariance, with hysteresis.
- Multi-epoch static positioning (`Sidereon.StaticPositioning`).
- Doppler velocity solve with receiver clock drift, and ECEF position
  covariance on receiver solutions.
- The one-call emission correction bundle (contiguous per-satellite arrays
  with typed coverage status).
- The precise-interpolant artifact: build once, evaluate zero-copy from bytes,
  checksummed.
- IONEX coverage policy: typed out-of-coverage results by default, explicit
  hold opt-in.

### Fixed

- Sample-backed SP3 interpolation reconstructs its node axis before time-scale
  conversion, closing the remaining boundary-node case on real converted
  epochs (consumer-verified).
- Tight-coupling measurement row signs and the transmit-time model; tight
  numeric behavior changes relative to 0.16.x, see the core changelog.

## [0.16.1]

### Fixed

- The geodesic module is now a first-party implementation; a transitive
  dependency of the previous release could not build on Windows.

## [0.16.0]

### Added

- Geodesic direct and inverse solvers on WGS84 (Karney) (`Sidereon.Geodesic`).
- Epoch-aware terrestrial reference frame catalog with published ITRF and ETRF
  Helmert parameter sets (`Sidereon.FrameCatalog`).
- EGM2008 geoid raster loading alongside EGM96 (`Sidereon.Geoid`).
- Spherical-harmonic geopotential force selection for numerical propagation
  (`Sidereon.Propagator`).
- CCSDS TDM parse and encode (`Sidereon.CCSDS.TDM`).
- Terrestrial-frame (ECEF) SP3 orbit fitting entries
  (`Sidereon.OrbitDetermination`).
- SGP4 post-decay validity latch, oblate-Earth shadow model option, and typed
  troposphere mapping validity errors.

### Fixed

- The core SP3 evaluation path: epoch bucketing no longer mis-serves the state
  from one second later at nodes sensitive to the GPS-UTC offset, and clock and
  position evaluation are now gated by an independent oracle against the parsed
  file text. Consumers of SP3 clock or state evaluation on 0.15.0 should
  upgrade.
- The terrain store surfaces skipped and void input as typed results instead of
  silent zeros.

### Changed

- Reliability marshaling takes both w-test noncentrality components from the
  core; `Sidereon.Format.TLE.encode/1` surfaces out-of-range catalog numbers as
  typed errors.

## [0.15.0]

### Added

- Position error metrics: CEP, R95/R99, drms/2drms, SEP, VEP, and the 1-sigma
  error ellipse from any solution covariance, with exact elliptical percentile
  radii and typed errors for non-positive-semidefinite input
  (`Sidereon.ErrorMetrics`).
- Classical reliability: per-observation minimal detectable bias and
  internal/external reliability over the shared ARAIM gain matrix, with
  zero-redundancy observations reported uncheckable (`Sidereon.Reliability`).
- SBAS protection levels per DO-229 with the MOPS tables frozen bit-exact
  (`Sidereon.GNSS.SBAS`).
- Composable perturbation forces for numerical propagation: zonal harmonics
  through J6, Sun/Moon third-body, solar radiation pressure, and the
  relativistic correction (`Sidereon.Propagator`).
- Batch least-squares orbit fitting against precise ephemerides with a
  per-satellite RTN residual ledger (`Sidereon.OrbitDetermination`).
- Power-law clock-noise identification per IEEE 1139 over the Allan-family
  deviations (`Sidereon.ClockStability`).
- Robust geodetic time series: MIDAS velocity, trajectory fitting, step
  detection, and network motion fields (`Sidereon.GeodeticTimeSeries`).
- Sidereal filtering with per-satellite orbit repeat lag and coverage-aware
  templates (`Sidereon.Sidereal`).
- Alpha-5 TLE catalog numbers and CelesTrak GP ingest in the core TLE/OMM
  path.

### Changed

- `Sidereon.Format.TLE.encode/1` surfaces catalog numbers beyond the TLE range
  as a typed error instead of raising.

## [0.14.0]

### Added

- Weak-geometry observability classification (`GeometryQuality`: rank,
  redundancy, conditioning, covariance-validated flags) on every solution.

## [0.13.0]

### Added

- Batched multi-satellite state interpolation, source localization (ToA/TDOA),
  and estimation/detection primitives (scalar Kalman, alpha-beta, NIS, MAD,
  CFAR).

## [0.12.0]

### Added

- Allan-family clock stability, ARAIM protection levels, sample-backed IONEX,
  batch terrain probes, the memory-mappable terrain store, SBAS decode
  extensions, and angular-separation utilities.

## [0.11.0] and [0.11.1]

### Added

- RINEX observation quality control, NTRIP client handling, NMEA 0183, and the
  geoid/vertical-datum surface.

## [0.10.1]

### Fixed

- DTED block-directory naming now matches production store layouts.
- Sample-ephemeris construction rejects non-finite derived epochs and clock
  values.

## [0.10.0]

### Added

- Astrodynamics coverage for anomaly conversions, analytic Kepler propagation,
  equinoctial and modified-equinoctial elements, solar beta angle,
  RIC/RTN/LVLH relative frames, Clohessy-Wiltshire motion, angular separation,
  position angle, general body observation, almanac events, atmospheric drag
  force, orbital decay, source-agnostic ephemeris grid sampling, and
  terrain/DTED lookup.
- GNSS DCB/OSB bias ingestion, SBAS augmentation with decode and corrected SPP,
  SSR/HAS real-time corrections, and robust SPP with a fault
  detection/exclusion driver.
- Cache-first data acquisition support for SP3, IONEX, CLK, NAV, and SRTM
  terrain to DTED products, using a single sans-IO core catalog and bit-exact
  hgt to DTED conversion.

### Changed

- Rust, Python, C, WASM, and Elixir interfaces now expose uniform capability
  parity for the 0.10.0 surface.
- GNSS constellation labels now use conventional styling: GPS, GLONASS, Galileo,
  BeiDou, QZSS, NavIC, and SBAS.

## [0.32.0] - 2026-06-16

### Added

- Opt-in `:strategy` option (`:reference` default, or `:canonical`) on the SP3 and
  broadcast `Positioning.solve/4`, `RTK.solve_float_baseline_epochs/3` /
  `solve_fixed_baseline_epochs/3`, and `PrecisePositioning.solve_float_epochs/3` /
  `solve_fixed_epochs/3`. `:canonical` selects the canonical (IERS/IGS-rigorous)
  estimation strategy from `astrodynamics-gnss` 0.21.0: full iterative light-time
  with the closed-form Sagnac correction and a consistent WGS84/ITRF basis for SPP,
  and a numerically rigorous square-root-information solve for RTK and PPP. The
  default is byte-identical to 0.31.0 (the reference-faithful result), proven by a
  default-equals-reference bit-for-bit test. An unknown value returns
  `{:invalid_option, :strategy}`; `:canonical` is refused on the robust-FDE path and
  on the RTK sequential-filter / wide-lane paths rather than silently ignored.

## [0.31.0] - 2026-06-16

### Changed

- Rebuilds the native solver on `astrodynamics-gnss` 0.20.0, whose SPP / RTK /
  PPP estimators are now consolidated onto one shared estimation substrate plus
  runtime-selectable named-recipe strategies. The consolidation is
  behavior-preserving: every solver result is bit-identical to 0.30.0 and all
  reference goldens are unchanged. No public API or numerical change.

## [0.30.0] - 2026-06-16

### Changed

- Rust-primary port: GNSS modeling that previously lived in the Elixir wrapper
  now lives in the `astrodynamics-gnss` crate behind an unchanged public API.

## [0.29.1] - 2026-06-15

### Changed

- `Sidereon.GNSS.SP3.merge/2` and `Sidereon.GNSS.Data.fetch_merged_sp3/3` now combine
  source products with different native epoch intervals by decimating the finer
  ones onto a common coarser grid (exact subset selection, no positional
  interpolation), instead of rejecting the merge. This lets ultra-rapid products
  published at different cadences be consensus-merged across the full center set
  (e.g. `fetch_merged_sp3(target, [:igs_ult, :cod_ult, :esa_ult, :gfz_ult],
  combine: :precedence, systems: [:gps], epoch_interval_s: 900)` - IGS/ESA at
  15 min, CODE/GFZ at 5 min - now returns `{:ok, %SP3{}, provenance}`). Inputs
  whose interval does not evenly divide the common grid are still rejected;
  same-interval merges are unchanged. Rides astrodynamics-gnss 0.18.0.

## [0.29.0] - 2026-06-15

### Added

- PPP per-range correction stack for the static float/fixed precise-positioning
  solve, all opt-in (no change to default behaviour):
  - `solid_earth_tide`: IERS DEHANTTIDEINEL station displacement.
  - `phase_windup`: demo5/RTKLIB carrier-phase wind-up (nominal yaw attitude),
    applied to the phase observable only.
  - `satellite_antenna`: satellite antenna PCO/PCV from an ANTEX file, iono-free
    combined, projected onto the line of sight.
  These ride `astrodynamics` 0.11.0 (analytic Sun/Moon in ITRS, corrected for an
  of-date precession double-count) and `astrodynamics-gnss` 0.17.0 (solid-earth
  tide kernel). The Sun/Moon and tide kernels are validated through the NIF
  against Skyfield/DE440 and IERS golden vectors.
- RINEX `SYS / PHASE SHIFT`: the parsed `correction_cycles` are now applied to
  the carrier-phase observable (previously parsed but never applied).
- GLONASS FDMA: `Sidereon.GNSS.Velocity` accepts a per-satellite carrier
  (`:carrier_hz_by_sat`) so a GLONASS Doppler is converted to range rate with its
  own slot frequency instead of a single global GPS L1 carrier.

### Documentation

- Clarified the IONEX rapid/predicted fetch story. The latest-available-day
  candidate fallback described in 0.28.0 is delivered by `fetch_ionex/3` (which
  walks candidate days newest-first), not by `fetch/2` on a single product, which
  is single-shot by design. The `mgex_ionex/3`, `rapid_ionex/2`, and
  `predicted_ionex/3` docs now point to `fetch_ionex/3` for fallback fetching.
- Documented that the CODE rapid GIM (`:cod_rap`) is a rolling-recent window on
  the AIUB `/CODE` root (current day not yet published; files older than roughly
  three days roll off), and that the predicted map (`:cod_prd1`) is preferred for
  same-day use.

## [0.28.0] - 2026-06-14

### Added

- Lower-latency CODE IONEX (global ionosphere TEC map) products in the data
  catalog, alongside the existing final `COD0OPSFIN`: `:cod_rap` (rapid GIM,
  `COD0OPSRAP`) and `:cod_prd1` / `:cod_prd2` (predicted GIM, `COD0OPSPRD`, the
  map for the requested UTC day and the day after). Final GIMs lag one to three
  weeks; the rapid and predicted maps resolve same-day / before-the-day over the
  AIUB CODE archive, so a near-real-time ionosphere map is now fetchable through
  the same path as the final IONEX. Rapid and predicted lines carry a
  latest-available-day candidate fallback, mirroring the SP3 ultra-rapid pattern.
  Single-product fetch only (no merge/combine). IGS rapid IONEX has no verified
  open mirror and remains in the no-open-mirrors set.

## [0.27.0] - 2026-06-14

### Fixed

- SP3 satellite-orbit interpolation (via `astrodynamics-gnss` 0.16.0): the
  position channel was a global cubic spline that erred ~200 m at the day
  boundary and across coverage gaps, invisible in double-differenced RTK (it
  cancels) but corrupting undifferenced precise positioning. Replaced with the
  IGS/RTKLIB-standard sliding-window Lagrange. Anyone using SP3-based
  undifferenced positioning should upgrade.

### Added

- A-priori Saastamoinen troposphere in the dual-frequency RTK path (matching
  RTKLIB `tropopt=saas`), improving short/medium-baseline fixes; default on,
  `troposphere: false` to disable.
- Precise-positioning foundation toward static-arc PPP: cycle-slip arc-splitting
  in the iono-free float solve, a RINEX clock (`.CLK`) reader, receiver-antenna
  PCO/PCV and SP3 satellite-clock relativity applied through a single
  per-one-way-range correction point, a configurable data-gap arc reset, and a
  post-fit residual screen. The ratio-test threshold now rejects values below
  1.0 (which would silently disable ambiguity validation).

### Changed

- Rides `astrodynamics-gnss` 0.16.0.

## [0.26.0] - 2026-06-14

### Added

- `Sidereon.GNSS.Positioning.solve/4` gains an opt-in `:huber` option: a
  crate-layer Huber/IRLS robust reweighting loop that recomputes each
  satellite's weight from its post-fit residual, down-weighting multipath and
  gross code outliers on cheap single-frequency receivers rather than excluding
  whole satellites. Tunable via `:huber_k`, `:huber_sigma` (MAD scale floor,
  default 5.0 m), and `:huber_max_iter`. Default off and byte-identical to the
  static elevation-weighted solve when unused. On the vendored GSDC Pixel-5
  arcs it improves the 3D median and p95 on every arc with no loss of
  availability.
- When `:huber` runs, `solution.metadata` carries `:huber` with the
  `outer_iterations` count and the `final_scale_m` (the last MAD robust scale);
  the key is absent on the default path.

### Changed

- Riding `astrodynamics-gnss` 0.15.0 / `astrodynamics` 0.10.0, which carry the
  robust-reweighting kernel.

## [0.25.0] - 2026-06-13

### Added

- `Sidereon.GNSS.Positioning.solve/4` accepts an opt-in `:robust` flag that routes
  the single-point solve through RAIM leave-one-out fault detection and
  exclusion. It requires a real measurement noise model: a `:weights` map with a
  positive, finite weight for every observed satellite (extra keys are ignored),
  or the explicit `:unsafe_unit_weights` escape hatch. Without a noise model it
  refuses (`{:error, {:robust_requires_noise_model, :no_weights}}`) rather than
  silently running unit-weight FDE, which degrades real receiver fixes. An
  exhausted-but-still-faulted search returns `{:error, {:fault_unresolved, statistic}}`,
  and the exclusion ledger is reported in `solution.metadata.fde`.
- `solve/4` accepts an opt-in `:coarse_search` that widens the cold-start
  convergence basin from a degraded or absent position prior by solving from a
  deterministic golden-spiral lattice of near-surface seeds and selecting the
  best redundant converged fix. It is mutually exclusive with `:robust`. Default
  off (`nil`) preserves the single exact solve.

### Notes

- All `solve/4` robust and coarse options are additive and default to current
  behavior; with neither set the solve is unchanged from 0.24.0. Malformed
  robust/coarse option values return tagged `{:error, _}` rather than raising.

## [0.24.0] - 2026-06-13

### Fixed

- `Sidereon.GNSS.Positioning.solve/4` no longer returns a fix that did not converge
  to a physical receiver position. A fix whose geocentric radius is outside the
  plausible band (for example a degenerate first step from the earth-center
  default seed, previously returned as a ~6.4e6 m "converged" position, or a
  wrong-root least-squares fix whose residuals are forced to zero by an exactly
  determined geometry) is refused with `{:error, {:implausible_position, radius_m}}`,
  and a converged-flagged fix with physically implausible post-fit residual RMS
  with `{:error, {:no_convergence, rms_m}}`. A rank-deficient geometry (no DOP
  cofactor inverse, which is also what lets a wrong-root mirror land on the
  plausible shell) is refused with `{:error, {:degenerate_geometry, :rank_deficient}}`.
  These are behavior changes: inputs that previously returned a bogus
  `{:ok, solution}` now return a tagged error.

### Added

- `solve/4` solution metadata now carries the geometry redundancy:
  `used_count`, distinct `systems`, `redundancy` (degrees of freedom,
  `used_count - (3 + systems)`), and `raim_checkable?`. An exactly determined
  fix (`redundancy < 1`) is now visibly unverifiable rather than appearing
  perfect at zero residual.
- `solve/4` accepts an optional `:max_pdop` ceiling: a rank-deficient or
  high-PDOP geometry is refused with `{:error, {:degenerate_geometry, pdop}}`,
  and a non-positive ceiling is `{:error, {:invalid_option, :max_pdop}}`.
- A real-arc Doppler-velocity regression gate for `Sidereon.GNSS.Velocity` on a
  cheap single-frequency phone arc (GSDC Pixel-5), checking receiver velocity
  against a finite-differenced truth track.

## [0.23.0] - 2026-06-13

### Added

- `Sidereon.GNSS.RTK.solve_widelane_filter_baseline_epochs/3`: a dual-frequency
  (L1/L2) sequential RTK filter. It resolves the Melbourne-Wubbena wide-lane
  integers per arc, forms the ionosphere-free narrow-lane observable, and runs
  the sequential fix-and-hold filter (including the convergence arming gate and
  the SD gauge constraint) on it. On the vendored PASA/SCOA L1/L2 arc it solves
  continuously and reaches a centimeter-class fixed solution. Available on both
  the Rust and Elixir kernels.

### Documentation

- Documented the `:ar_arming_sigma_m` convergence arming gate option and why it
  is opt-in by default.
- README install version, feature-table wording, and the example livebooks
  refreshed; the livebooks now install the hex release so they run from the
  Run-in-Livebook badge without a Rust toolchain.

## [0.22.0] - 2026-06-12

### Added

- `Sidereon.GNSS.RTK.solve_filter_baseline_epochs/3` accepts an opt-in
  `ar_arming_sigma_m` convergence arming gate: the per-epoch ambiguity search
  is attempted only once the baseline-block posterior standard deviation has
  converged to at most the threshold, so the sequential filter stops committing
  integers while the float state is still too loose to support a
  half-wavelength decision. The default (unset) preserves the always-armed
  behavior. Implemented in both kernels with a per-epoch bit-equality gate.

### Changed

- The reference single-difference ambiguity gauge constraint now applies to
  single-system arcs (previously multi-system only). The reference SD ambiguity
  is an unobservable gauge degree of freedom in any system count; on a long
  single-system arc with tight integer holds its pivot otherwise cancels to
  zero (a `:singular_geometry` failure). The gauge is a double-difference
  null-space constraint, so baselines and double differences are unchanged, but
  single-system sequential filter numerics now include it. Together with the
  arming gate, the continuous real-arc L1 filter resolves centimeter-class
  fixed solutions on the default ambiguity-hold sigma.

## [0.21.0] - 2026-06-12

### Added

- The Rust RTK filter kernel applies receiver antenna corrections
  (`:receiver_antenna_corrections`), previously accepted only by the `:elixir`
  kernel. PCO/PCV are projected in the double-difference row builder with
  op-for-op parity against the Elixir reference, gated for bit-equality across
  both kernels on the vendored PASA/SCOA real arc.

## [0.20.0] - 2026-06-13

### Added

- `dynamics_model: :velocity_propagated` - the filter's prediction mean
  advances by a caller-supplied per-epoch ECEF velocity (`:velocity_mps` on
  epochs); default remains constant-position. Bit-equality gated across both
  kernels.
- Optional per-epoch innovation screen (`:innovation_screen_sigma`,
  `:innovation_screen_min_rows`): rows with excessive normalized predicted
  residuals are excluded from the measurement update; epochs coast below the
  survivor floor. Implemented in both kernels with firing bit-equality gates
  and per-epoch screen metadata.
- `Sidereon.GNSS.Antex`: ANTEX 1.4 receiver-antenna parser (PCO/PCV with zenith
  and azimuth interpolation), gated against vendored reference values.
  Measurement-model application lands in a later release.

### Changed

- GNSS data downloads no longer use the deprecated Erlang `:ftp` transport,
  which is no longer started or listed as an application dependency.
- GNSS product URLs now resolve through verified open HTTP(S) archives:
  GFZ rapid/ultra via `isdc-data.gfz.de`, ESA final/ultra/IONEX via
  `navigation-office.esa.int`, IGS broadcast nav / IGS ultra / station OBS via
  `igs.bkg.bund.de`, and CODE products via AIUB at `ftp.aiub.unibe.ch`.
- Restored CODE products over AIUB plain HTTP: `{:cod, :sp3}` and
  `{:cod, :clk}` use `CODE_MGEX/CODE/<year>/COD0MGXFIN_...`, `{:cod, :ionex}`
  uses `CODE/<year>/COD0OPSFIN_...`, and `{:cod_ult, :sp3}` uses the recent
  `CODE/COD0OPSULT_...` product. AIUB does not offer HTTPS; transport
  integrity relies on the plain-HTTP channel for these public products.
- `Sidereon.GNSS.RTK.solve_filter_baseline_epochs/3` now defaults to the Rust
  RTK filter kernel. `:elixir` remains fully supported as the reference
  implementation.

### Removed

- Still-retired catalog products with no verified open HTTP(S) mirror:
  `{:grg, :sp3}`, `{:grg, :clk}`, `{:wum, :sp3}`, `{:wum, :clk}`,
  `{:grg_ult, :sp3}`, `{:grg_ult, :clk}`, and `{:igs, :ionex}` now return
  `{:error, {:no_open_mirror, {center, content}}}`.

### Notes

- The default ambiguity-hold sigma is unchanged (1.0e-4): a softer default
  (1.0e-3) cures a documented long-arc conditioning failure but measurably
  degrades clean kinematic accuracy (the sigma-sweep gate caught it), so the
  softer value remains an explicit per-arc option pending a proper
  constraint-conditioning capability. See the C+D measurement report.

## [0.19.0] - 2026-06-12

### Changed

- `filter_kernel` now defaults to `:rust`. The Elixir path remains fully
  supported as the reference implementation; every kernel capability is gated
  by bit-equality (`===`) trace tests against it.
- The FTP transport was removed (`:ftp` is deprecated and removed in OTP 30).
  GFZ/ESA/BKG products moved to verified HTTPS archives; CODE (AIUB) products
  are served over plain HTTP (AIUB offers no TLS); products with no open
  mirror return `{:error, {:no_open_mirror, {center, content}}}`.

### Added

- GSDC moving-rover oracle fixtures generated with RTKLIB-demo5 (four
  pre-registered arcs, committed generators, ratio test enabled) and the
  pre-registered moving-rover gate specification with measurement report.
- Multi-GNSS oracle regenerated with GLONASS ephemerides present
  (BRDC00WRD GREC nav); oracle gates tightened to exact fixed-epoch equality.
- Early `{:unsupported_widelane, :multi_gnss}` rejection for multi-GNSS
  dual-frequency widelane input.

## [0.18.0] - 2026-06-12

### Added

- `Sidereon.GNSS.RTK.solve_filter_baseline_epochs/3` now supports multi-GNSS RTK
  filter epochs with per-system reference satellites. GLONASS can be kept in the
  float solution via `:float_only_systems` while GPS/Galileo/etc. remain
  eligible for integer search and hold.
- The sequential RTK filter accepts `:process_noise_baseline_sigma_m` for
  kinematic baseline tracking. The default remains the static filter.
- Added four vendored RTKLIB oracle fixtures for the WTZR/WTZZ real arc,
  covering broadcast/precise and static/kinematic RTK tracks, with the generator
  configs and conversion script checked in with the fixtures.

### Fixed

- Fixed cold-start fixed epochs so the reported fixed solution uses the
  ambiguity-conditioned baseline from the same epoch instead of reporting the
  float baseline while marking the epoch fixed.

### Tests

- Added `===` bit-equality gates between the Elixir RTK filter path and the Rust
  NIF kernel for multi-GNSS references, GLONASS float-only handling, kinematic
  process noise, gauge constraints, held ambiguities, and cold-start fixes.
- Added a sigma-sweep RTK gate that exercises the filter across the measurement
  variance settings used by the real-arc parity tests.
- Multi-GNSS input to `solve_widelane_fixed_baseline_epochs/3` is rejected
  early with `{:unsupported_widelane, :multi_gnss}` (single-constellation
  scope; previously failed late at the delegated fixed solve).

## [0.17.0] - 2026-06-11

### Added

- `Sidereon.GNSS.RTK.solve_filter_baseline_epochs/3` gains an opt-in Rust filter
  kernel via `filter_kernel: :rust` (default remains `:elixir`). The kernel
  reproduces the Elixir sequential RTK information filter - iterated
  Gauss-Newton update with correlated double-difference measurement covariance,
  SD→DD ambiguity transform, LAMBDA search-and-hold, and the elevation-weighted
  / RTKLIB stochastic models - and is verified epoch-for-epoch against the
  Elixir path on real Wettzell arcs. Existing callers are unaffected.

### Changed

- The native NIF now builds against the published `astrodynamics-gnss` 0.10.0
  crate (was a git-rev pin), which carries the RTK filter kernel. The kernel
  hot path holds a measured baseline of ~210k single-core solves/sec on a
  6-satellite epoch with a CI-gated allocations-per-solve regression bound.

## [0.16.1]

### Fixed

- The geodesic module is now a first-party implementation; a transitive
  dependency of the previous release could not build on Windows.

## [0.16.0] - 2026-06-10

### Added

- RTK fixed-baseline solving can now run an opt-in normalized-residual gate
  before integer search. When enabled, the solver excludes the worst offending
  satellite up to a bounded cap, re-solves, and reports the exclusions in
  solution metadata; if the residuals still fail, it returns a tagged
  `:residual_validation_failed` error with the offending residual.
- RTK float and fixed baseline solvers now accept `:elevation_mask_deg`, which
  removes satellites below the base-station elevation mask before reference
  selection and ambiguity construction. Masked satellites are reported in
  solution metadata.
- `Sidereon.GNSS.RTK.solve_filter_baseline_epochs/3` adds a sequential static RTK
  information filter: it carries baseline/ambiguity covariance epoch to epoch,
  attempts LAMBDA ambiguity fixing from the posterior covariance, and holds
  accepted integers with a configurable pseudo-measurement. The filter carries
  RTKLIB-style single-difference ambiguity states, searches/holds the
  corresponding double-difference integer combinations, and seeds the
  single-difference ambiguities from phase-code differences rather than starting
  every ambiguity at zero.
- Sequential RTK epoch metadata now includes integer-search diagnostics
  (`integer_best_score`, `integer_second_best_score`, `integer_candidates`, and
  `ambiguity_search`) so parity/debug gates can inspect the posterior ambiguity
  vector, covariance, and postfit residuals at each fix attempt.
- RTK float/fixed/filter baseline solvers accept `stochastic_model: :rtklib`
  for RTKLIB's floor-plus-elevation single-difference variance shape. The
  default remains `:simple`.
- RTK baseline epochs may now carry receiver-specific
  `:base_satellite_positions_m` and `:rover_satellite_positions_m` maps for
  transmit-time satellite positions. When omitted, the solvers keep the previous
  shared `:satellite_positions_m` behavior.
- RTK float/fixed/filter baseline solvers now apply the first-order Sagnac
  Earth-rotation range correction by default (`sagnac: true`), with
  `sagnac: false` available for synthetic Euclidean fixtures.
- `Sidereon.GNSS.RINEX.Observations.antenna_delta_hen/1` exposes the parsed
  `ANTENNA: DELTA H/E/N` receiver antenna offset so real RTK gates and
  consumers can derive antenna-reference-point baselines from the observation
  product itself.
- `Sidereon.GNSS.RINEX.Observations.phase_shifts/1` exposes parsed
  `SYS / PHASE SHIFT` carrier correction metadata for correction-model and
  RTK parity work.

### Fixed

- The sequential RTK filter now starts a fresh ambiguity arc when a satellite
  reappears after an outage (set below the horizon, or lost lock without an LLI
  flag). Previously only an explicit LLI cycle slip broke an arc, so a re-risen
  satellite reused its pre-outage carrier-phase ambiguity - a stale integer that
  could differ from the truth and corrupt the static baseline. Re-acquisition is
  now always treated as a new arc, independent of the `:on_cycle_slip` policy;
  continuous arcs are unaffected.
- RTK APIs now reject unknown/misspelled options at the public boundary instead
  of silently falling back to defaults, and RTK residual finalization returns a
  tagged error if an internal row set is missing either the code or phase member
  of a double-difference pair. Fractional-epoch helpers in broadcast and SPP
  positioning also no longer carry dead error clauses that produced
  warnings-as-errors failures on newer Elixir compilers.

### Tests

- Added a vendored WTZR/WTZZ real RTK oracle fixture generated with RTKLIB
  `rnx2rtkp`. The fixture pins the L1+broadcast fix-and-hold reference target
  (119/120 fixed, first fix at 2020-06-25 00:00:30 GPST, millimetre final ARP
  baseline error) plus L1 instantaneous, L1 float, and L1/L2 comparison
  summaries. The provenance now records that RTKLIB defaults to broadcast
  ephemeris unless `pos1-sateph = precise` is set, so this fixture is not
  mislabeled as an SP3 parity oracle.
- Added a separate RTKLIB precise-mode fixture for the same WTZR/WTZZ arc,
  generated with `pos1-sateph = precise`, a CODE final SP3 orbit, and a
  CNES/CLS RINEX clock. The provenance records RTKLIB 2.4.2's lowercase `.sp3`
  staging requirement and pins that the precise run fixes the same 119/120
  epochs as the broadcast reference.
- The real WTZR/WTZZ RTK gate now builds receiver-specific transmit-time
  satellite-position maps and verifies the corrected geometry against committed
  fixture targets: the two-epoch prefix fixes below 1 cm, the 120-epoch
  single-frequency partial-AR path fixes a safe subset below 1 cm, and the
  dual-frequency wide-lane/narrow-lane path fixes the full set below 1 cm.

## [0.15.1] - 2026-06-09

### Fixed

- The internal integer least-squares search wrappers now reject malformed
  covariance dimensions with tagged errors before entering the NIF, and map the
  Rust kernel's non-finite/search-limit failures explicitly. Undersized matrices
  no longer panic the NIF, and oversized matrices are no longer silently
  truncated to a submatrix.

## [0.15.0] - 2026-06-09

### Fixed

- `Sidereon.GNSS.SP3.merge/2` and `Sidereon.GNSS.Data.fetch_merged_sp3/3` now reject
  heterogeneous SP3 merge inputs conservatively instead of emitting a corrupt
  union product: mixed epoch intervals must be resampled before merge (or match
  a requested `:epoch_interval_s`), coordinate-system labels must match exactly,
  and `combine: :precedence` selects one source per satellite arc rather than
  switching centers between adjacent epochs. Merge callers can also restrict the
  output with `:systems` (for example `[:gps]`).

### Added

- `Sidereon.GNSS.Constellation.health_timeline/2`, `health_state/1`, and
  `health_timeline_to_map/1` build deterministic health/outage intervals from
  timestamped catalog snapshots. The timeline reuses `diff/2` for snapshot
  transitions, reports derived health-state changes, preserves source metadata
  (including NAVCEN/NANU fields), supports stale-snapshot detection for catalog
  watchers, and serializes to a versioned map for notification/state files.

## [0.14.1] - 2026-06-09

### Fixed

- Re-published the 0.14.x release line with precompiled-NIF checksums matching
  the final GitHub release assets built against `astrodynamics-gnss` 0.9.4. The
  0.14.0 package was published before the final checksum file was committed, so
  supported platforms could reject the downloaded precompiled archive and fall
  back poorly. No API or numerical behavior changed from 0.14.0.

## [0.14.0] - 2026-06-08

### Added

- `Sidereon.GNSS.SP3.to_iodata/2` serializes an `%Sidereon.GNSS.SP3{}` product back to
  standard SP3-c / SP3-d text - the inverse of the reader, so a read → `merge/2`
  → write pipeline emits a single standard SP3 file any reader consumes. Pure and
  deterministic; header fields are derived from the product; a satellite absent
  at an epoch is written as the SP3 missing-orbit sentinel (so a quarantined
  merge cell re-reads as missing, never a fabricated position). Round-trips to
  SP3 format precision (mm / sub-ns) for position-only and position+velocity,
  multi-constellation products.
- `Sidereon.GNSS.Data.write_sp3/3` writes a product to disk with the fetch layer's
  atomic-commit discipline (same-directory temp file + `File.rename/2`), with an
  optional `gzip: true` for the gzipped-archive shape. Unblocks persisting a
  merged product, which was otherwise only an in-memory handle.
- `Sidereon.GNSS.Data.fetch_merged_sp3_file/4` composes `fetch_merged_sp3/3` and
  `write_sp3/3` into one call - fetch the merged current-day product from several
  ultra-rapid centers and persist it to a standard SP3 file, returning
  `{:ok, path, report}` so a live-latency product feeds the cache / observables /
  positioning layers with no network at solve time.
- `Sidereon.GNSS.RTK.solve_widelane_fixed_baseline_epochs/3` now supports
  `partial_ambiguity_resolution: true`. When the full narrow-lane set fails the
  ratio test, a bounded largest-first exhaustive subset search (run only after
  the greedy ranking finds nothing) accepts the highest-ratio subset of the
  largest size that passes the **unchanged** ratio threshold. Holding the
  widelane integers fixed collapses the per-satellite bias, so the dual-frequency
  partial fix safely covers a larger subset than the single-frequency partial -
  on the real Wettzell arc, a 6-satellite fix (ratio 4.27, 4.4 cm baseline error)
  compared with the single-frequency 4. The full-set refusal and single-frequency
  behavior are unchanged.

### Fixed

- `Sidereon.GNSS.Data` now starts the Erlang `:ftp` transport itself before its
  first FTP fetch (the GSSC/MGEX archives are FTP). A consumer that used Sidereon
  without starting the `:sidereon` application tree (an escript, a bare script, a
  release that did not start the dep) previously crashed with
  `(EXIT) no process: :ftp_sup`; it no longer has to start Erlang transports by
  hand.
- `Sidereon.GNSS.SP3.merge/2` now treats equivalent IGS reference-frame
  realizations as compatible: `IGS20` / `IGb20` / `IGc20` are the same
  ITRF2020-based IGS frame (the middle letter is the product/realization line,
  not a datum), so products labeled differently across centers merge instead of
  failing with `{:incompatible_sources, "mismatched coordinate systems"}`. A
  genuinely different datum (e.g. `IGS14` vs `IGS20`) is still rejected.

## [0.13.0] - 2026-06-08

### Added

- `Sidereon.GNSS.Data.ops_ultra_sp3/3` and `ops_ultra_clk/3` add the ultra-rapid
  precise-product tier to the offline-safe catalog/fetch layer. The catalog now
  derives anonymous GSSC archive names and URLs for `IGS0OPSULT`, `COD0OPSULT`,
  `ESA0OPSULT`, `GFZ0OPSULT`, and `GRG0OPSULT` SP3 products (plus `GRG0OPSULT`
  clocks), including sub-daily issue times, `02D` spans, per-center sampling,
  and latest-available issue fallback before a target epoch.
- `Sidereon.GNSS.Data.fetch_merged_sp3/3` fetches the same SP3 product from several
  centers in precedence order, tolerates not-yet-published or missing centers,
  and returns one merged `Sidereon.GNSS.SP3` plus provenance and merge-audit
  metadata. One available center is returned as a flagged single-source result;
  zero available centers returns `{:error, {:no_products, reasons}}`; centers
  that cannot be combined (mismatched time scale / coordinate-system frame)
  return `{:error, {:incompatible_sources, %{centers:, reason:}}}` rather than
  leaking a raw merge error.

## [0.12.0] - 2026-06-08

### Added

- `Sidereon.GNSS.SP3.merge/2` merges several SP3 products from different analysis
  centers into one consistent precise-ephemeris dataset. Coverage is the union
  across satellite×epoch (a satellite present in any input is present in the
  output, filling a single center's dropouts); overlapping records are resolved
  by robust consensus - the largest subset of centers agreeing within tolerance
  is combined (`:mean`, `:median`, or `:precedence`), disagreeing centers are
  recorded as outliers, and a cell with no agreeing subset is quarantined rather
  than averaged. Pure and deterministic; returns the merged product plus an audit
  report (`:quarantined`, `:single_source`, `:position_outliers`).
- `Sidereon.GNSS.SP3.clock_reference_offset/3` and
  `Sidereon.GNSS.SP3.align_clock_reference/3` expose the clock-datum primitive:
  precise clock products from different centers are referenced to different
  station/ensemble clocks, so their raw clocks differ by a per-epoch common
  offset. The first estimates that offset (robust median over common satellites);
  the second returns a copy of a product with its clocks shifted onto a
  reference's datum so the two are directly comparable. Positions need no such
  treatment.
- `Sidereon.GNSS.BroadcastComparison` now reports `clock_datum_removed_rms_m` /
  `clock_datum_removed_max_m` alongside the raw clock statistics: the per-epoch
  common reference-clock offset (median over satellites) is removed to give the
  actual signal-in-space clock error, several times smaller than the raw value.
- `Sidereon.GNSS.Ephemeris.sample/3` samples a precise (`Sidereon.GNSS.SP3`) or
  broadcast (`Sidereon.GNSS.Broadcast`) ephemeris over an epoch window into a
  unified per-satellite, per-epoch table of ECEF position and clock bias - the
  same call shape for either source, with out-of-coverage cells reported as an
  explicit `:no_ephemeris` gap rather than extrapolated.
- `Sidereon.GNSS.Broadcast.position/3` evaluates a single satellite's broadcast
  ECEF position and clock at an epoch (IS-GPS-200 LNAV, Galileo OS-SIS-ICD,
  BeiDou BDS-SIS-ICD).
- `Sidereon.GNSS.BroadcastComparison.compare/4` (and the `mix gnss.broadcast_diff`
  task, with a `--system` selector) computes per-satellite broadcast and precise
  orbit and clock differences (3D plus radial/along/cross RMS and max) over a
  window - the standard broadcast ephemeris accuracy check. Validated over a full
  UTC day against the IGS combined broadcast (`BRDC00IGS`) and CODE MGEX final
  precise orbits (`COD0MGXFIN`): GPS LNAV ~1.4 m, Galileo I/NAV ~0.9 m, BeiDou
  ~2.5 m orbit RMS.
- `Sidereon.GNSS.RTK.solve_float_baseline_epochs/3` and fixed RTK solvers now
  accept `code_smoothing: true` to apply per-receiver/per-ambiguity-arc Hatch
  carrier smoothing to code observations before forming double differences.
  The real Wettzell RTK gate verifies the smoothing reduces code residual RMS
  while still refusing unsafe integer fixes.
- `Sidereon.GNSS.RTK.solve_fixed_baseline_epochs/3` now supports opt-in partial
  ambiguity resolution with `partial_ambiguity_resolution: true`. When the full
  ambiguity set fails the ratio test, Sidereon tries confidence-ranked subsets and
  re-solves with the accepted subset fixed while rejected ambiguities remain
  float-estimated. The real Wettzell RTK gate now verifies a safe four-ambiguity
  partial fix improves the L1 baseline while the unsafe full-set fix remains
  rejected.

### Changed

- GNSS integer ambiguity fixing now uses a complete bounded integer
  least-squares scan over the caller's `integer_search_radius_cycles`, scored by
  the exact ambiguity covariance inverse. Fixed-solution metadata reports
  `integer_method: :bounded_ils` (or
  `:widelane_narrowlane_bounded_ils`) for this path.
- The default integer candidate cap for precise positioning and RTK fixed
  solvers is now `200_000`, enough for the default radius-1 search with up to 11
  ambiguities.
- `Sidereon.GNSS.RTK.solve_float_baseline_epochs/3` and fixed RTK solvers now use
  non-reference satellites on the epochs where they are available instead of
  dropping a satellite from the entire arc when it is absent from one epoch. The
  reference satellite is still required across the arc.

### Fixed

- GNSS integer ambiguity fixing no longer treats a missing runner-up lattice
  candidate as infinite ratio confidence; one-candidate searches now return
  `integer_status: :not_fixed`.
- `Sidereon.GNSS.SP3.position/3` (and everything built on it, including
  `Sidereon.GNSS.Observables` and the ephemeris sampler) now refuses an epoch
  beyond the product's node coverage with an `epoch out of range` error instead
  of silently extrapolating the interpolation spline to a non-physical position.
  Queries within one sampling step of the ends still interpolate; in-coverage
  results are bit-for-bit unchanged.

## [0.11.0] - 2026-06-08

### Added

- `Sidereon.GNSS.PrecisePositioning.solve_fixed_epochs/3` now reports
  `metadata.ambiguity_search` diagnostics (satellite order, float ambiguities,
  ambiguity covariance, and inverse covariance in cycles) so callers can audit
  the LAMBDA integer decision against the same lattice metric.
- `Sidereon.GNSS.PrecisePositioning` now accepts `elevation_weighting: true` on
  float, multi-epoch, and fixed solves, scaling code and phase row sigmas by
  `1 / sin(elevation)` for a simple real-data stochastic model that down-weights
  low-elevation observations.
- `Sidereon.GNSS.RTK.double_differences/3` for deterministic base/rover
  code-and-carrier double differences, the RTK measurement primitive that
  cancels receiver clocks and common short-baseline satellite errors before
  baseline estimation.
- `Sidereon.GNSS.RTK.solve_float_baseline_epochs/3` for static float RTK baseline
  estimation from supplied satellite ECEF positions and multi-epoch
  code/carrier double differences, holding one float ambiguity per
  non-reference double-difference arc. The float solution now exposes the
  double-difference ambiguity covariance and inverse covariance in metres.
- `Sidereon.GNSS.RTK.solve_fixed_baseline_epochs/3` for LAMBDA-fixed RTK baseline
  estimation. It starts from the float RTK baseline, fixes double-difference
  carrier ambiguities with the same correlated covariance used by the float
  solve, and re-solves the baseline with those integers held fixed.
- `Sidereon.GNSS.RTK.solve_fixed_baseline_epochs/3` now accepts
  `ambiguity_offset_m`, so fixed RTK ambiguities can be modeled as
  `offset + integer * wavelength`. This is the hook needed for
  wide-lane-fixed / narrow-lane dual-frequency RTK workflows.
- `Sidereon.GNSS.RTK.solve_widelane_fixed_baseline_epochs/3` for dual-frequency
  RTK fixing. It estimates Melbourne-Wubbena wide-lane double-difference
  integers, converts the arc to ionosphere-free narrow-lane measurements, then
  runs the existing correlated LAMBDA baseline solve with the wide-lane offsets
  held fixed.
- `Sidereon.GNSS.RTK.solve_float_baseline_epochs/3` and
  `solve_fixed_baseline_epochs/3` now understand carrier-phase arc identities:
  map observations may carry `:ambiguity_id`, and LLI loss-of-lock can be
  handled with `on_cycle_slip: :error | :drop_satellite | :split_arc`. Split
  arcs reset the affected double-difference ambiguity while residuals keep the
  physical satellite id.
- `Sidereon.GNSS.RTK.solve_float_baseline_epochs/3` and
  `solve_fixed_baseline_epochs/3` now accept `elevation_weighting: true`, which
  scales each undifferenced measurement sigma by
  `1 / max(sin(elevation), 0.05)` before propagating the correlated
  double-difference covariance.
- `Sidereon.GNSS.PrecisePositioning.solve_widelane_fixed_epochs/3` now supports
  `on_cycle_slip: :split_arc`, which resets a satellite's carrier ambiguity at
  detected cycle slips and keeps any post-slip fragments long enough for
  wide-lane fixing. Split fragments are reported in
  `metadata.split_cycle_slip_arcs` and use suffixed ambiguity ids such as
  `"G21#2"` in `used_sats` and the ambiguity maps.

### Changed

- `Sidereon.GNSS.PrecisePositioning.solve_fixed_epochs/3` now uses an
  LDL-consistent forward recursion for the decorrelated LAMBDA sphere search.
  This fixes the zero-candidate search miss on noisy real arcs without an
  original-space substitute path: those arcs now return a `FixedSolution` with
  `metadata.integer_status == :not_fixed` when candidates exist but fail the
  ratio test.
- `Sidereon.GNSS.RTK.solve_float_baseline_epochs/3` now propagates the
  non-diagonal double-difference measurement covariance into the normal
  equations and ambiguity covariance instead of treating DD rows that share a
  reference satellite as independent.
- `Sidereon.GNSS.RTK.solve_float_baseline_epochs/3` now chooses the
  highest-average-elevation common satellite as the default reference, with a
  deterministic satellite-id tie-break. `double_differences/3` still defaults to
  the lexicographically first common satellite because it has no geometry.

## [0.10.0] - 2026-06-07

### Added

- `Sidereon.GNSS.IonosphereFree.iono_free_phase/4` and
  `iono_free_phase_cycles/4` for PPP/RTK-facing first-order ionosphere-free
  carrier-phase combinations, plus `Sidereon.GNSS.CarrierPhase.phase_meters/2`,
  `code_minus_carrier/3`, and `smooth_iono_free_code/2` for code-carrier
  diagnostics and dual-frequency divergence-free Hatch smoothing.
- `Sidereon.GNSS.PrecisePositioning.solve_float/4`, a first float-ambiguity
  carrier-phase estimator for one SP3-backed epoch from ionosphere-free code and
  phase observations. It estimates receiver ECEF position, clock, and one float
  ambiguity per satellite, exposing residuals and metadata for later PPP/RTK
  layers.
- `Sidereon.GNSS.PrecisePositioning.solve_float_epochs/3`, a static multi-epoch
  float carrier-phase estimator that holds one ambiguity per satellite across an
  arc while estimating one receiver clock per epoch. This is the bridge from
  single-epoch float positioning toward PPP/RTK ambiguity fixing.
- `Sidereon.GNSS.PrecisePositioning.solve_fixed_epochs/3`, an integer-fixed
  multi-epoch carrier-phase estimator. It starts from the float arc, builds the
  ambiguity covariance from the float normal matrix, runs LAMBDA integer
  decorrelation plus a covariance-weighted integer sphere search on explicit
  caller-supplied wavelengths, then re-solves receiver position and epoch clocks
  with the selected ambiguities held fixed. The fixed solution reports the
  integer method, ratio-test status, weighted scores, and evaluated candidate
  count.
- `Sidereon.GNSS.PrecisePositioning.solve_widelane_fixed_epochs/3`, a
  dual-frequency convenience layer that fixes Melbourne-Wubbena wide-lane
  integers first, then uses LAMBDA on the remaining narrow-lane integer while
  returning both ambiguity sets.
- `Sidereon.GNSS.PrecisePositioning` can now apply an opt-in a-priori
  Saastamoinen/Niell tropospheric slant delay to ionosphere-free code and phase
  observations (`troposphere: true` with surface meteorology options), including
  the float, multi-epoch, and fixed-ambiguity solve paths.
- `Sidereon.GNSS.PrecisePositioning.solve_float_epochs/3` and
  `solve_fixed_epochs/3` can now estimate one residual zenith troposphere delay
  over a static arc (`estimate_ztd: true`, with `troposphere: true`), reporting
  `ztd_residual_m` and `metadata.ztd_estimated`.
- `Sidereon.GNSS.PrecisePositioning.solve_widelane_fixed_epochs/3` accepts
  `on_cycle_slip: :drop_satellite` to remove slipped satellite arcs before the
  wide-lane / narrow-lane solve. The default remains `:error`; dropped satellites
  are reported in `metadata.dropped_cycle_slip_sats`.

### Changed

- `Req` is now a required dependency. Network-backed features (`CelesTrak`,
  `Sidereon.GNSS.Data`, NAVCEN constellation status) are first-class Sidereon
  capabilities, and making the HTTP client required keeps consumer compiles
  warning-free.
- The LAMBDA integer search now shrinks its live search bound to the current
  second-best candidate, so `solve_fixed_epochs/3` keeps the same integer
  decision and ratio-test semantics while visiting far fewer complete
  candidates.
- `Sidereon.GNSS.PrecisePositioning.solve_fixed_epochs/3` now reports an empty
  LAMBDA sphere-search result as `{:error, {:no_integer_candidates, count}}`
  instead of conflating it with the `:too_many_integer_candidates` cap.

## [0.9.2] - 2026-06-06

### Added

- `Sidereon.GNSS.Constellation.diff/2` and `changed?/1` for deterministic
  snapshot-to-snapshot catalog comparisons keyed by `{system, prn}`. The diff
  reports added/removed PRNs plus NORAD, SP3 id, SVN, activity, and usability
  changes in structured lists.
- GLONASS FDMA carrier-phase wavelengths. `Sidereon.GNSS.RINEX.Observations`
  exposes the parsed `GLONASS SLOT / FRQ #` channel map and `phases/3` now
  derives carrier frequency, G1/G2 wavelengths, and metre phases for GLONASS
  satellites with a channel entry, so `Sidereon.GNSS.CarrierPhase` can process
  real GLONASS phase arcs instead of skipping them.
- `Sidereon.GNSS.ReducedOrbit` and `Sidereon.GNSS.ReducedOrbit.Piecewise` can now fit
  and drift against `%Sidereon.Elements{}` TLE/OMM sources by sampling SGP4 over the
  requested window (TEME → GCRS → ECEF, UTC scale). This closes the LEO reduced
  orbit source path without changing the Rust reduced-orbit numerics.

## [0.9.1] - 2026-06-05

### Added

- Rustler precompiled-NIF packaging support. Release tags now build GitHub
  Release archives for common Linux/macOS/Windows targets, and the Hex package
  will include `checksum-*.exs` so supported users do not need a local Rust
  toolchain. If no checksum file is present, Sidereon source-builds instead of
  trying to download missing assets; `SIDEREON_BUILD=1` remains the explicit
  source-build escape hatch.
- **`Sidereon.GNSS.CarrierPhase`** - dual-frequency carrier-phase combinations and
  the quality tooling on them: geometry-free (`L1 - L2`), wide-lane wavelength,
  narrow-lane code, Melbourne-Wübbena, arc-wise cycle-slip detection (LLI bit,
  geometry-free step, and Melbourne-Wübbena step, with documented thresholds),
  and the single-frequency Hatch carrier-smoothed code (with slip/LLI reset).
  GPS/Galileo/BeiDou; GLONASS satellites are skipped (FDMA wavelengths not yet
  derived). Builds on the newly exposed phase observations; no crate change.
- `Sidereon.GNSS.RINEX.Observations.values/3` and `phases/3` - expose the raw RINEX
  observations for an epoch (pseudorange, carrier phase, Doppler, signal strength
  with their LLI/SSI), and a carrier-phase convenience that adds the wavelength
  and the phase in metres for GPS/Galileo/BeiDou bands (`band_frequency_hz/2` is
  public; GLONASS FDMA wavelengths are not yet derived). `values/3` takes a
  `:codes` per-system filter so only the requested systems/codes cross the NIF
  boundary. This unlocks carrier-phase combinations without a parser change.
- `Sidereon.GNSS.Constellation.validate_sp3!/2` - a build-time validation gate that
  returns `:ok` or raises `ArgumentError` describing the findings (e.g. a
  stale-active PRN that is active and usable in the catalog but missing from a
  current SP3 product). Intended for catalog-build automation, not the runtime.
- Python/georinex/scipy oracle gates for the recent Sidereon-only GNSS layer:
  raw RINEX `values/3` / `phases/3`, `CarrierPhase` combinations/slip/Hatch
  smoothing, `IonosphereFree` coefficients and combinations, `GNSS.QC`
  weighting/chi-square thresholds, `GNSS.Observables.predict/5`, C/A
  code/correlation/acquisition, LNAV parity/subframe synthesis,
  visibility/DOP, velocity, DGNSS, `SolutionReport`, and `ReducedOrbit` /
  `ReducedOrbit.Piecewise` fit/evaluation/drift against Astropy/scipy.

### Changed

- `Sidereon.GNSS.Constellation.to_csv/2` gains a `:booleans` option: `:lower`
  (default, conventional `true`/`false`) or `:title` (`True`/`False`, for a
  pandas-style consumer that reads the `active` column as Python booleans).
- `Sidereon.GNSS.QC.chi2_inv/2` now inverts the regularized-gamma chi-square CDF
  and is checked against `scipy.stats.chi2.ppf`, replacing the older
  Wilson-Hilferty approximation.

## [0.9.0] - 2026-06-05

A large GNSS expansion - signal generation, measurement modelling, velocity,
quality control, and differential positioning - alongside a consolidation of
the whole GNSS surface under the `Sidereon.GNSS.*` namespace.

### Added

- **`Sidereon.GNSS.Signal.CA`** - GPS L1 C/A Gold-code generation, chip indexing,
  and auto/cross-correlation (IS-GPS-200 G1/G2 generators and per-PRN taps).
- **`Sidereon.GNSS.Signal.Correlator`** - C/A code+carrier replica, coherent
  correlation, a 2-D code-phase/Doppler acquisition search, and the
  coherent-integration (sinc²) loss model.
- **`Sidereon.GNSS.Navigation.LNAV`** - GPS LNAV subframe synthesis and decoding:
  TLM/HOW, time-of-week, subframe parity (IS-GPS-200 Table 20-XIV), and
  ephemeris bit-packing.
- **`Sidereon.GNSS.Observables`** - predicted geometric range, range-rate, Doppler,
  satellite clock, elevation, and azimuth from a receiver position and an SP3
  ephemeris, with light-time (transmit-time) and Sagnac corrections.
- **`Sidereon.GNSS.Geometry`** - satellite visibility above an elevation mask,
  dilution of precision (GDOP/PDOP/HDOP/VDOP/TDOP), DOP/visibility time series,
  and rise/set passes.
- **`Sidereon.GNSS.Velocity`** - receiver velocity and clock drift from Doppler or
  pseudorange-rate measurements by least squares over the line-of-sight geometry.
- **`Sidereon.GNSS.QC`** - measurement quality control: residual-based RAIM fault
  detection, leave-one-out fault detection and exclusion (FDE), and
  elevation/C-N₀ measurement weighting.
- **`Sidereon.GNSS.IonosphereFree`** - the dual-frequency ionosphere-free
  pseudorange combination, with standard per-system frequency pairs
  (GPS L1/L2, Galileo E1/E5a, BeiDou B1I/B3I).
- **`Sidereon.GNSS.DGNSS`** - code-differential positioning: base-station
  pseudorange corrections and corrected rover solves that cancel the errors
  common to both receivers (satellite clock, ephemeris, short-baseline
  atmosphere).
- **`Sidereon.GNSS.SolutionReport`** - a per-satellite and summary diagnostic over
  a position solution: elevation/azimuth, post-fit and RAIM-normalized
  residuals, DOP, residual RMS, and the integrity verdict.
- **`Sidereon.GNSS.ReducedOrbit.Piecewise`** - a piecewise (segmented)
  reduced-orbit model that tiles a span into contiguous fitted segments for
  tighter caching/transport accuracy than a single mean-element fit.

### Changed

- **Breaking:** GNSS modules now live under the `Sidereon.GNSS.*` namespace. The
  old top-level GNSS names (`Sidereon.SP3`, `Sidereon.PointPositioning`,
  `Sidereon.GnssData`, etc.) were removed instead of retained as aliases, matching
  the library's current single-client / pre-broad-adoption status. Examples:
  `Sidereon.GNSS.SP3`, `Sidereon.GNSS.Positioning`, `Sidereon.GNSS.Data`,
  `Sidereon.GNSS.RINEX.Observations`, `Sidereon.GNSS.ReducedOrbit`,
  `Sidereon.GNSS.Signal.CA`, and `Sidereon.GNSS.Navigation.LNAV`.
- Internal GNSS implementation helpers were consolidated under
  `Sidereon.GNSS.Core` for shared constants, ECEF input normalization,
  epoch/window handling, validation, source sampling, and versioned-map guards.
- Hardened public-API input validation across the GNSS modules: malformed
  receiver/base positions, out-of-range RAIM options, sub-second piecewise
  segment lengths, out-of-range LNAV flags, and duplicate observations now
  return tagged errors (or raise a clear `ArgumentError` for invalid options)
  instead of crashing, looping, or silently truncating.

## [0.8.0] - 2026-06-05

Observation parsing and a compact orbit model. Sidereon can now read a station's
RINEX observation file end-to-end into pseudoranges, and distill a position
track into a tiny, transportable mean-element model.

### Added

- **`Sidereon.GNSS.RINEX.Observations`** - RINEX 3 observation parsing with Hatanaka (CRINEX 1.0
  and 3.0) decoding. Decodes `.crx`/`.rnx`, exposes the header (incl. the
  surveyed `APPROX POSITION`), observation codes, and epochs, and extracts
  single-frequency pseudoranges (`pseudoranges/3`) in the
  `[{satellite_id, range_m}]` shape `Sidereon.GNSS.Positioning.solve/4` consumes -
  closing the loop from a station's observation file to a recovered position.
  `Sidereon.GNSS.Data` gains a station observation product fetch and an
  `observations/2` loader. CRINEX decoding is verified byte-for-byte against
  `crx2rnx`; an end-to-end test recovers a surveyed station position to metre
  level from real GPS observations.

- **`Sidereon.GNSS.ReducedOrbit`** - a compact, fitted mean-element approximation of an
  orbit for caching, transport, and quick visibility math (not orbit
  determination). Fits from an `Sidereon.GNSS.SP3` track or a list of ECEF samples;
  evaluates position/velocity (ECEF by default, GCRS on request); reports a
  source-backed `drift/3` against the source ephemeris; and serialises to a
  stable, versioned map (`to_map/1`/`from_map/1`). Two models: `:circular_secular`
  (default) and `:eccentric_secular` (nonsingular `h = e·sin ω`, `k = e·cos ω`),
  the latter recovering the radial `a·e` signal that the circular model discards -
  cutting full-day extrapolation error by one-to-three orders of magnitude for
  GPS and BeiDou while matching the circular model on near-circular Galileo.

## [0.7.0] - 2026-06-04

GNSS positioning. Sidereon can now recover a receiver position from pseudoranges
against precise or broadcast ephemeris, with the supporting ephemeris,
correction, time, and data-fetch layers.

### Added

- **`Sidereon.GNSS.Positioning`** - single-point positioning (SPP). Solves a
  receiver position, clock, and geometry diagnostics from one epoch of
  pseudoranges against either an `Sidereon.GNSS.SP3` precise product or an
  `Sidereon.GNSS.Broadcast` handle. Multi-constellation
  (GPS / Galileo / BeiDou / GLONASS) solves carry one receiver clock per system;
  the solution reports position, geodetic position, per-system clocks, DOP,
  residuals, used/rejected satellites, and solver metadata.
- **`Sidereon.GNSS.SP3`** - SP3-c/SP3-d precise orbit/clock loading and arbitrary-epoch
  satellite position/clock interpolation, plus `satellite_ids/1` to read the
  product's declared satellite set.
- **`Sidereon.GNSS.Constellation`** - a GPS constellation catalog built from
  CelesTrak `gps-ops` OMM identity and an optional NAVCEN status/SVN overlay
  (PRN ↔ SVN ↔ NORAD ↔ SP3 id, active/usable flags). Merges sources only when
  the block type matches, recording PRN-transition disagreements as conflicts
  rather than corrupting identity; exports the compact mapping CSV and validates
  a catalog (duplicate PRNs/NORAD ids, inactive/unusable PRNs, and missing/extra
  satellites against a loaded `Sidereon.GNSS.SP3` product).
- **`Sidereon.GNSS.Broadcast`** - RINEX 3.x and 4.xx navigation parsing and
  broadcast orbit/clock evaluation: GPS LNAV, Galileo I/NAV and F/NAV, BeiDou
  D1/D2 (including geostationary satellites), and GLONASS (PZ-90.11 state-vector
  propagation by Runge–Kutta integration).
- **`Sidereon.GNSS.Ionosphere`** (broadcast Klobuchar, frequency-aware across L1/E1/B1I)
  and **`Sidereon.GNSS.Troposphere`** (Saastamoinen zenith delay + Niell mapping)
  correction models.
- **`Sidereon.GNSS.Data`** - an optional product fetch/cache layer: a catalog over
  public archives, HTTPS (`Req`) and FTP downloads, an atomic on-disk cache with
  SHA-256 integrity and provenance sidecars, a gzip-bomb guard, and an offline
  mode. Includes convenience loaders that return `Sidereon.GNSS.SP3` /
  `Sidereon.GNSS.Broadcast` handles. `Req` is an optional dependency.
- **`Sidereon.GNSS.Time`** - GNSS epoch/seconds-of-week and day-of-year helpers.

### Notes

- The GNSS numerical core lives in the Rust `astrodynamics` / `astrodynamics-gnss`
  crate layer. Its libm-bound components (orbit and clock evaluation, ionosphere,
  troposphere, dilution of precision) are held to bit-exact (0 ULP) parity
  against pinned Python references; broadcast orbits are additionally validated
  against precise SP3 products. The least-squares solver's final position is a
  sub-micron solver-agreement result, not a 0-ULP claim.

---

Releases before 0.7.0 predate this changelog.

[Unreleased]: https://github.com/neilberkman/sidereon-ex/compare/v3.0.0...HEAD
[3.0.0]: https://github.com/neilberkman/sidereon-ex/compare/v2.1.1...v3.0.0
