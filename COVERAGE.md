# Core API coverage

Public module-level items of `sidereon-core` and `sidereon` at core revision `e2fb3dfdc392d23087ed8aa1ee028a0056b4021b`,
and the native source files of this binding that use each. Written by
`test/generators/coverage/api_coverage.py`; its docstring states how an item is
found and when it counts as bound.

- Items: 2818
- Bound (used by the native code): 1648
- MISSING: 1170

## `sidereon`

| Item | Kind | Binding |
|---|---|---|
| `Error` | enum | `antex.rs`, `araim.rs`, `astro_observe_almanac.rs`, `astro_phase_b.rs`, `bias.rs`, `broadcast.rs`, `broadcast_comparison.rs`, `cdm.rs`, `clock_stability.rs`, `collision.rs`, `conjunction.rs`, `constellation.rs`, `covariance.rs`, `coverage.rs`, `drag.rs`, `eclipse.rs`, `elements.rs`, `ephemeris.rs`, `error_metrics.rs`, `errors.rs`, `forces.rs`, `geodetic_time_series.rs`, `inertial.rs`, `iono.rs`, `ndm_errors.rs`, `ntrip.rs`, `observable_states.rs`, `observables.rs`, `oem.rs`, `omm.rs`, `opm.rs`, `passes.rs`, `ppp_corrections.rs`, `precise_positioning.rs`, `precise_samples.rs`, `propagation.rs`, `qc.rs`, `reduced_orbit.rs`, `rf.rs`, `rinex_clock.rs`, `rinex_obs.rs`, `rinex_qc.rs`, `rtcm.rs`, `rtk_filter.rs`, `sbas.rs`, `sgp4_batch.rs`, `sidereal.rs`, `sp3.rs`, `spp.rs`, `ssr.rs`, `ssr_bias_exclusion.rs`, `tdm.rs`, `terrain_store.rs`, `tides.rs`, `time.rs`, `tle.rs`, `tropo.rs` |
| `PppFixedConfig` | struct | MISSING |
| `PppFloatConfig` | struct | MISSING |
| `Result` | type | `antex.rs`, `astro_phase_b.rs`, `bias.rs`, `broadcast.rs`, `cache_lock.rs`, `carrier_phase.rs`, `cdm.rs`, `clock_stability.rs`, `conjunction.rs`, `constellation.rs`, `covariance.rs`, `covariance_transport.rs`, `data.rs`, `error_metrics.rs`, `errors.rs`, `frame_catalog.rs`, `fusion.rs`, `gauss.rs`, `geodesic.rs`, `geodetic_time_series.rs`, `geofence.rs`, `geoid.rs`, `ils.rs`, `iod.rs`, `iono.rs`, `nmea.rs`, `normality.rs`, `ntrip.rs`, `observables.rs`, `oem.rs`, `omm.rs`, `opm.rs`, `orbit_determination.rs`, `precise_positioning.rs`, `primitive_estimation.rs`, `qc.rs`, `reduced_orbit.rs`, `rf.rs`, `rinex_clock.rs`, `rinex_obs.rs`, `rtcm.rs`, `rtk_filter.rs`, `sgp4_batch.rs`, `signal.rs`, `source_localization.rs`, `sp3.rs`, `space_weather.rs`, `spp.rs`, `staleness.rs`, `tdm.rs`, `terrain_store.rs`, `tides.rs`, `time.rs`, `tle_fit.rs`, `track_estimation.rs`, `trls.rs`, `unix_compress.rs`, `velocity.rs` |
| `RtkFixedConfig` | struct | MISSING |
| `RtkFloatConfig` | struct | MISSING |
| `SsrIngestRefusal` | struct | MISSING |
| `SsrRtcmIngest` | struct | MISSING |
| `decode_crinex` | fn | `rinex_obs.rs` |
| `encode_crinex` | fn | `rinex_obs.rs`, `rinex_qc.rs` |
| `lint_rinex_nav` | fn | MISSING |
| `lint_rinex_obs` | fn | MISSING |
| `load_antex` | fn | MISSING |
| `load_bias_sinex` | fn | MISSING |
| `load_bias_sinex_lossy` | fn | MISSING |
| `load_bias_sinex_lossy_with_policy` | fn | `bias.rs` |
| `load_bias_sinex_with_policy` | fn | `bias.rs` |
| `load_code_dcb` | fn | MISSING |
| `load_code_dcb_lossy` | fn | MISSING |
| `load_code_dcb_lossy_with_policy` | fn | `bias.rs` |
| `load_code_dcb_with_policy` | fn | `bias.rs` |
| `load_crinex` | fn | MISSING |
| `load_rinex_clock` | fn | MISSING |
| `load_rinex_clock_lossy` | fn | MISSING |
| `load_rinex_nav` | fn | MISSING |
| `load_rinex_obs` | fn | MISSING |
| `load_sp3` | fn | MISSING |
| `nmea_epochs` | fn | MISSING |
| `parse_antex` | fn | MISSING |
| `parse_bias_sinex` | fn | MISSING |
| `parse_bias_sinex_lossy` | fn | MISSING |
| `parse_bias_sinex_lossy_with_policy` | fn | `bias.rs` |
| `parse_bias_sinex_with_policy` | fn | `bias.rs` |
| `parse_code_dcb` | fn | MISSING |
| `parse_code_dcb_lossy` | fn | MISSING |
| `parse_code_dcb_lossy_with_policy` | fn | `bias.rs` |
| `parse_code_dcb_with_policy` | fn | `bias.rs` |
| `parse_nmea` | fn | MISSING |
| `parse_rinex_clock` | fn | MISSING |
| `parse_rinex_clock_lossy` | fn | MISSING |
| `parse_rinex_nav` | fn | MISSING |
| `parse_rinex_obs` | fn | MISSING |
| `repair_rinex_nav` | fn | MISSING |
| `repair_rinex_obs` | fn | MISSING |
| `solve_ppp_fixed` | fn | MISSING |
| `solve_ppp_fixed_with` | fn | MISSING |
| `solve_ppp_float` | fn | MISSING |
| `solve_ppp_float_with` | fn | MISSING |
| `solve_rtk_fixed` | fn | MISSING |
| `solve_rtk_fixed_with` | fn | MISSING |
| `solve_rtk_float` | fn | MISSING |
| `solve_rtk_float_with` | fn | MISSING |
| `solve_spp` | fn | MISSING |
| `solve_spp_batch` | fn | MISSING |
| `solve_spp_batch_serial` | fn | `spp.rs` |
| `solve_velocity` | fn | MISSING |
| `ssr_store_from_rtcm` | fn | `ssr.rs` |
| `ssr_store_from_rtcm_strict` | fn | `ssr.rs` |
| `write_gga` | fn | `nmea.rs` |

## `sidereon_core::ambiguity`

| Item | Kind | Binding |
|---|---|---|
| `CycleSlipPolicy` | enum | `rtk_filter.rs` |

## `sidereon_core::antex`

| Item | Kind | Binding |
|---|---|---|
| `Antenna` | struct | `antex.rs` |
| `AntennaKind` | enum | `antex.rs` |
| `Antex` | struct | `antex.rs` |
| `AntexDateTime` | struct | `antex.rs` |
| `AntexError` | enum | `antex.rs` |
| `AntexHeader` | struct | `antex.rs` |
| `AntexVersion` | struct | MISSING |
| `Calibration` | struct | `antex.rs` |
| `DEFAULT_RELATIVE_REFERENCE_ANTENNA` | const | MISSING |
| `Frequency` | struct | `antex.rs`, `rtcm.rs` |
| `FrequencyRms` | struct | `antex.rs` |
| `OuterComment` | struct | `antex.rs` |
| `PcvGrid` | enum | `antex.rs` |
| `PcvSample` | struct | `antex.rs`, `precise_positioning.rs` |
| `PcvType` | enum | `antex.rs` |
| `PcvTypeRecord` | struct | MISSING |
| `SecondFraction` | struct | `antex.rs` |
| `ZenithGrid` | struct | `antex.rs` |

## `sidereon_core::araim`

| Item | Kind | Binding |
|---|---|---|
| `AraimError` | enum | `araim.rs`, `reliability.rs` |
| `AraimGeometry` | struct | `araim.rs`, `reliability.rs` |
| `AraimRow` | struct | `araim.rs` |
| `IntegrityAllocation` | struct | `araim.rs` |

## `sidereon_core::araim::fault_modes`

| Item | Kind | Binding |
|---|---|---|
| `FaultHypothesis` | struct | MISSING |
| `enumerate_fault_modes` | fn | MISSING |

## `sidereon_core::araim::ism`

| Item | Kind | Binding |
|---|---|---|
| `ConstellationIsm` | struct | `araim.rs` |
| `Ism` | struct | `araim.rs`, `reliability.rs` |
| `SatelliteIsm` | struct | `araim.rs` |
| `SatelliteIsmModel` | struct | `araim.rs` |

## `sidereon_core::araim::mhss`

| Item | Kind | Binding |
|---|---|---|
| `AraimResult` | struct | `araim.rs` |
| `FaultMode` | struct | MISSING |
| `araim` | fn | `araim.rs`, `lib.rs`, `reliability.rs`, `sbas.rs` |

## `sidereon_core::araim::protection`

| Item | Kind | Binding |
|---|---|---|
| `ProtectionModel` | trait | MISSING |

## `sidereon_core::araim::reliability`

| Item | Kind | Binding |
|---|---|---|
| `ObservationReliability` | struct | `reliability.rs` |
| `RangeReliabilityRow` | struct | `reliability.rs` |
| `ReliabilityOptions` | struct | `reliability.rs` |
| `ReliabilityReport` | struct | `reliability.rs` |
| `ReliabilitySummary` | struct | `reliability.rs` |
| `WtestNoncentralityComponents` | struct | MISSING |
| `reliability_araim` | fn | `reliability.rs` |
| `reliability_design` | fn | `reliability.rs` |
| `wtest_noncentrality` | fn | MISSING |
| `wtest_noncentrality_components` | fn | `reliability.rs` |

## `sidereon_core::artifact_bytes`

| Item | Kind | Binding |
|---|---|---|
| `ArtifactBytes` | enum | MISSING |
| `DigestProvenance` | enum | `observable_states.rs`, `terrain_store.rs` |
| `map_file_read_only` | fn | MISSING |

## `sidereon_core::astro::almanac`

| Item | Kind | Binding |
|---|---|---|
| `AlmanacError` | enum | MISSING |
| `CulminationEvent` | struct | MISSING |
| `CulminationKind` | enum | `astro_observe_almanac.rs` |
| `EclipseEvent` | struct | MISSING |
| `EclipseKind` | enum | `astro_observe_almanac.rs` |
| `EphemerisSource` | enum | `astro_observe_almanac.rs`, `broadcast.rs`, `observable_states.rs`, `qc.rs`, `sbas.rs`, `sp3.rs`, `spp.rs` |
| `MoonPhaseEvent` | struct | MISSING |
| `MoonPhaseKind` | enum | `astro_observe_almanac.rs` |
| `Planet` | enum | `astro_observe_almanac.rs` |
| `PlanetaryEvent` | struct | MISSING |
| `PlanetaryEventKind` | enum | `astro_observe_almanac.rs` |
| `SeasonEvent` | struct | MISSING |
| `SeasonKind` | enum | `astro_observe_almanac.rs` |
| `TransitBody` | enum | `astro_observe_almanac.rs` |

## `sidereon_core::astro::almanac::eclipse`

| Item | Kind | Binding |
|---|---|---|
| `lunar_solar_eclipses` | fn | `astro_observe_almanac.rs` |

## `sidereon_core::astro::almanac::ecliptic`

| Item | Kind | Binding |
|---|---|---|
| `EclipticLonLat` | struct | MISSING |
| `geocentric_ecliptic` | fn | MISSING |

## `sidereon_core::astro::almanac::phases`

| Item | Kind | Binding |
|---|---|---|
| `moon_phase_deg` | fn | MISSING |
| `moon_phases` | fn | `astro_observe_almanac.rs` |

## `sidereon_core::astro::almanac::planets`

| Item | Kind | Binding |
|---|---|---|
| `planetary_events` | fn | `astro_observe_almanac.rs` |

## `sidereon_core::astro::almanac::seasons`

| Item | Kind | Binding |
|---|---|---|
| `seasons` | fn | `astro_observe_almanac.rs` |

## `sidereon_core::astro::angles`

| Item | Kind | Binding |
|---|---|---|
| `AngleError` | enum | MISSING |
| `angular_separation` | fn | `angles.rs` |
| `angular_separation_coords` | fn | `angles.rs` |
| `beta_angle` | fn | `angles.rs` |
| `beta_angle_from_state` | fn | `angles.rs` |
| `earth_angular_radius` | fn | `angles.rs` |
| `moon_angle` | fn | `angles.rs` |
| `normalize_geodetic_lon_rad` | fn | MISSING |
| `phase_angle` | fn | `angles.rs` |
| `position_angle` | fn | `angles.rs` |
| `rad_to_deg_ref` | fn | MISSING |
| `sun_angle` | fn | `angles.rs` |
| `sun_elevation` | fn | `angles.rs` |

## `sidereon_core::astro::anomaly`

| Item | Kind | Binding |
|---|---|---|
| `AnomalyError` | enum | `astro_phase_b.rs` |
| `KeplerSolution` | struct | MISSING |
| `eccentric_to_mean` | fn | `astro_phase_b.rs` |
| `eccentric_to_true` | fn | `astro_phase_b.rs` |
| `mean_to_eccentric` | fn | `astro_phase_b.rs` |
| `mean_to_true` | fn | `astro_phase_b.rs` |
| `propagate_kepler` | fn | `astro_phase_b.rs` |
| `solve_kepler` | fn | `astro_phase_b.rs` |
| `true_to_eccentric` | fn | `astro_phase_b.rs` |
| `true_to_mean` | fn | `astro_phase_b.rs` |

## `sidereon_core::astro::apparent`

| Item | Kind | Binding |
|---|---|---|
| `RaDec` | struct | MISSING |
| `TopocentricApparent` | struct | MISSING |
| `apparent_geocentric` | fn | MISSING |
| `topocentric_apparent` | fn | MISSING |

## `sidereon_core::astro::atmosphere`

| Item | Kind | Binding |
|---|---|---|
| `ApArray` | type | MISSING |
| `AtmosphereError` | enum | `errors.rs` |
| `DEFAULT_AP` | const | MISSING |
| `DEFAULT_F107` | const | MISSING |
| `DEFAULT_F107A` | const | MISSING |
| `Flags` | struct | MISSING |
| `MAX_ALTITUDE_KM` | const | MISSING |
| `NrlmsiseInput` | struct | `atmosphere.rs` |
| `NrlmsiseOutput` | struct | MISSING |
| `gtd7` | fn | MISSING |
| `gtd7d` | fn | MISSING |
| `local_solar_time` | fn | `atmosphere.rs` |
| `nrlmsise00` | fn | `atmosphere.rs` |
| `nrlmsise00_with_lst` | fn | MISSING |

## `sidereon_core::astro::bodies::observe`

| Item | Kind | Binding |
|---|---|---|
| `BodyAzEl` | struct | `bodies.rs` |
| `BodyObservationError` | enum | MISSING |
| `Ecliptic` | struct | `astro_observe_almanac.rs` |
| `Equatorial` | struct | `astro_observe_almanac.rs` |
| `Horizontal` | struct | `astro_observe_almanac.rs` |
| `MoonIllumination` | struct | MISSING |
| `Observation` | struct | `astro_observe_almanac.rs`, `rtk.rs`, `rtk_filter.rs`, `spp.rs` |
| `ObserveError` | enum | MISSING |
| `ObserveOptions` | struct | `astro_observe_almanac.rs` |
| `Refraction` | struct | `astro_observe_almanac.rs` |
| `Target` | enum | `astro_observe_almanac.rs` |
| `moon_az_el` | fn | `bodies.rs` |
| `moon_az_el_with_validity` | fn | MISSING |
| `moon_illumination` | fn | `bodies.rs` |
| `moon_illumination_with_validity` | fn | MISSING |
| `observe` | fn | `astro_observe_almanac.rs`, `bodies.rs`, `rtcm.rs` |
| `observe_spk_body` | fn | `astro_observe_almanac.rs` |
| `observe_spk_body_with_validity` | fn | MISSING |
| `observe_with_time_scales` | fn | MISSING |
| `observe_with_validity` | fn | MISSING |
| `sun_az_el` | fn | `bodies.rs` |
| `sun_az_el_with_validity` | fn | MISSING |

## `sidereon_core::astro::bodies::rise_set`

| Item | Kind | Binding |
|---|---|---|
| `MoonElevationCrossing` | struct | `bodies.rs` |
| `MoonElevationCrossingKind` | enum | `bodies.rs` |
| `MoonElevationOptions` | struct | `bodies.rs` |
| `MoonTransit` | struct | `bodies.rs` |
| `MoonTransitKind` | enum | `bodies.rs` |
| `SunElevationCrossing` | struct | MISSING |
| `SunElevationCrossingKind` | enum | MISSING |
| `SunElevationOptions` | struct | MISSING |
| `find_moon_elevation_crossings` | fn | `bodies.rs` |
| `find_moon_elevation_crossings_with_validity` | fn | MISSING |
| `find_moon_transits` | fn | `bodies.rs` |
| `find_moon_transits_with_validity` | fn | MISSING |
| `find_sun_elevation_crossings` | fn | MISSING |
| `find_sun_elevation_crossings_with_validity` | fn | MISSING |
| `moon_elevation_deg` | fn | `bodies.rs` |
| `moon_elevation_deg_with_validity` | fn | MISSING |
| `sun_elevation_deg` | fn | MISSING |
| `sun_elevation_deg_with_validity` | fn | MISSING |

## `sidereon_core::astro::bodies::sun_moon`

| Item | Kind | Binding |
|---|---|---|
| `SunMoon` | struct | `tides.rs` |
| `SunMoonError` | enum | `tides.rs` |
| `sun_moon_ecef` | fn | `lib.rs`, `tides.rs` |
| `sun_moon_ecef_with_polar_motion` | fn | MISSING |
| `sun_moon_eci` | fn | MISSING |
| `sun_moon_eci_at` | fn | `tides.rs` |

## `sidereon_core::astro::cdm`

| Item | Kind | Binding |
|---|---|---|
| `CdmAdditionalParameters` | struct | `cdm.rs` |
| `CdmError` | enum | `cdm.rs`, `ndm_errors.rs` |
| `CdmInputErrorKind` | enum | `ndm_errors.rs` |
| `CdmKvn` | struct | `cdm.rs` |
| `CdmObject` | struct | `cdm.rs` |
| `CdmOdParameters` | struct | `cdm.rs` |
| `encode_kvn` | fn | `cdm.rs`, `oem.rs`, `omm.rs`, `opm.rs`, `tdm.rs`, `tle_fit.rs` |
| `encode_xml` | fn | `cdm.rs`, `oem.rs`, `omm.rs`, `opm.rs` |
| `parse_kvn` | fn | `cdm.rs`, `oem.rs`, `omm.rs`, `opm.rs`, `tdm.rs` |
| `parse_xml` | fn | `cdm.rs`, `oem.rs`, `omm.rs`, `opm.rs` |

## `sidereon_core::astro::conjunction`

| Item | Kind | Binding |
|---|---|---|
| `CollisionPc` | struct | `collision.rs` |
| `ConjunctionError` | enum | `collision.rs` |
| `ConjunctionState` | struct | `collision.rs` |
| `EncounterFrame` | struct | `collision.rs` |
| `PcMethod` | enum | `collision.rs`, `conjunction.rs` |
| `collision_probability` | fn | `cdm.rs`, `collision.rs`, `conjunction.rs`, `lib.rs` |
| `encounter_frame` | fn | `collision.rs`, `lib.rs` |
| `encounter_plane_covariance` | fn | `collision.rs`, `lib.rs` |

## `sidereon_core::astro::constants`

| Item | Kind | Binding |
|---|---|---|
| `J2_EARTH` | const | `consts.rs` |
| `J3_EARTH` | const | MISSING |
| `J4_EARTH` | const | MISSING |
| `J5_EARTH` | const | MISSING |
| `J6_EARTH` | const | MISSING |
| `MU_EARTH` | const | `propagation.rs` |
| `RE_EARTH` | const | `propagation.rs` |

## `sidereon_core::astro::covariance`

| Item | Kind | Binding |
|---|---|---|
| `Covariance6` | struct | `covariance_transport.rs` |
| `Covariance6Error` | enum | `covariance_transport.rs` |
| `Mat6` | type | `covariance_transport.rs` |
| `RtnFrameError` | enum | MISSING |
| `covariance6_km_to_m` | fn | `covariance_transport.rs` |
| `covariance6_m_to_km` | fn | `covariance_transport.rs` |
| `eci_to_rtn_covariance6` | fn | `covariance_transport.rs` |
| `interpolate_covariance_psd` | fn | `covariance_transport.rs` |
| `positive_semidefinite` | fn | `covariance.rs`, `covariance_transport.rs` |
| `rtn_to_eci` | fn | `covariance.rs` |
| `rtn_to_eci_covariance6` | fn | `covariance_transport.rs` |
| `rtn_to_eci_rotation` | fn | MISSING |
| `symmetric` | fn | `covariance.rs`, `covariance_transport.rs` |

## `sidereon_core::astro::coverage`

| Item | Kind | Binding |
|---|---|---|
| `LookAngleGrid` | type | MISSING |
| `access_counts` | fn | MISSING |
| `look_angles_batch` | fn | `coverage.rs` |
| `look_angles_batch_with_validity` | fn | MISSING |
| `max_elevation` | fn | MISSING |
| `visible_mask` | fn | MISSING |

## `sidereon_core::astro::data::iau2000a`

| Item | Kind | Binding |
|---|---|---|
| `LUNISOLAR_LONGITUDE_COEFFICIENTS` | static | MISSING |
| `LUNISOLAR_OBLIQUITY_COEFFICIENTS` | static | MISSING |
| `NALS_T` | static | MISSING |
| `NAPL_T` | static | MISSING |
| `NUTATION_COEFFICIENTS_LONGITUDE` | static | MISSING |
| `NUTATION_COEFFICIENTS_OBLIQUITY` | static | MISSING |

## `sidereon_core::astro::data::iers`

| Item | Kind | Binding |
|---|---|---|
| `UT1_DATA` | static | MISSING |
| `Ut1Entry` | struct | MISSING |

## `sidereon_core::astro::doppler`

| Item | Kind | Binding |
|---|---|---|
| `DopplerError` | enum | MISSING |
| `DopplerShift` | struct | MISSING |
| `doppler_shift` | fn | `lib.rs` |
| `range_rate_and_ratio` | fn | MISSING |

## `sidereon_core::astro::elements`

| Item | Kind | Binding |
|---|---|---|
| `ClassicalElements` | struct | `astro_phase_b.rs`, `elements.rs` |
| `ElementsError` | enum | `elements.rs` |
| `OrbitType` | enum | `astro_phase_b.rs`, `elements.rs` |
| `coe2rv` | fn | `elements.rs` |
| `rv2coe` | fn | `elements.rs` |

## `sidereon_core::astro::equinoctial`

| Item | Kind | Binding |
|---|---|---|
| `EquinoctialElements` | struct | `astro_phase_b.rs` |
| `EquinoctialError` | enum | MISSING |
| `ModifiedEquinoctialElements` | struct | `astro_phase_b.rs` |
| `RetrogradeFactor` | enum | `astro_phase_b.rs` |
| `coe2eq` | fn | `astro_phase_b.rs` |
| `coe2mee` | fn | `astro_phase_b.rs` |
| `eq2coe` | fn | `astro_phase_b.rs` |
| `eq2mee` | fn | `astro_phase_b.rs` |
| `eq2rv` | fn | `astro_phase_b.rs` |
| `mee2coe` | fn | `astro_phase_b.rs` |
| `mee2eq` | fn | `astro_phase_b.rs` |
| `mee2rv` | fn | `astro_phase_b.rs` |
| `rv2eq` | fn | `astro_phase_b.rs` |
| `rv2mee` | fn | `astro_phase_b.rs` |

## `sidereon_core::astro::error`

| Item | Kind | Binding |
|---|---|---|
| `PropagationError` | enum | MISSING |

## `sidereon_core::astro::events`

| Item | Kind | Binding |
|---|---|---|
| `DetectedEvent` | struct | MISSING |

## `sidereon_core::astro::events::eclipse`

| Item | Kind | Binding |
|---|---|---|
| `EarthShadowModel` | enum | `eclipse.rs` |
| `EclipseError` | enum | MISSING |
| `EclipseStatus` | enum | `eclipse.rs` |
| `WGS84_FLATTENING` | const | MISSING |
| `shadow_fraction` | fn | `eclipse.rs` |
| `shadow_fraction_with_model` | fn | `eclipse.rs` |
| `status` | fn | `astro_phase_b.rs`, `bias.rs`, `constellation.rs`, `eclipse.rs`, `error_metrics.rs`, `fusion.rs`, `geodetic_time_series.rs`, `iono.rs`, `nmea.rs`, `ntrip.rs`, `observables.rs`, `precise_positioning.rs`, `rinex_clock.rs`, `rinex_obs.rs`, `rtcm.rs`, `rtk_filter.rs`, `sbas.rs`, `source_localization.rs`, `sp3.rs`, `spp.rs`, `ssr.rs`, `ssr_bias_exclusion.rs`, `static_positioning.rs`, `tle_fit.rs`, `trls.rs` |
| `status_with_model` | fn | `eclipse.rs` |

## `sidereon_core::astro::events::root`

| Item | Kind | Binding |
|---|---|---|
| `RootError` | enum | MISSING |
| `bisect_crossing_by_iterations` | fn | MISSING |
| `bisect_crossing_until` | fn | MISSING |
| `sign_change_bracketed` | fn | MISSING |
| `try_bisect_crossing_until` | fn | MISSING |

## `sidereon_core::astro::forces::albedo`

| Item | Kind | Binding |
|---|---|---|
| `EarthRadiationPressure` | struct | MISSING |

## `sidereon_core::astro::forces::composite`

| Item | Kind | Binding |
|---|---|---|
| `CompositeForceModel` | struct | MISSING |

## `sidereon_core::astro::forces::drag`

| Item | Kind | Binding |
|---|---|---|
| `DragForce` | struct | MISSING |
| `DragParameters` | struct | `drag.rs`, `propagation.rs` |
| `SourcedDragForce` | struct | MISSING |
| `SpaceWeather` | struct | `drag.rs`, `space_weather.rs` |
| `SpaceWeatherSource` | enum | `space_weather.rs` |

## `sidereon_core::astro::forces::geopotential`

| Item | Kind | Binding |
|---|---|---|
| `EGM96_DEGREE_ORDER_36` | const | MISSING |
| `EGM96_EMBEDDED_MAX_DEGREE` | const | `propagation.rs` |
| `EGM96_EMBEDDED_MAX_ORDER` | const | `propagation.rs` |
| `EGM96_MU_KM3_S2` | const | MISSING |
| `EGM96_REFERENCE_RADIUS_KM` | const | MISSING |
| `SphericalHarmonicCoefficient` | struct | MISSING |
| `SphericalHarmonicGravity` | struct | MISSING |
| `SphericalHarmonicGravityConfig` | struct | `propagation.rs` |
| `TideSystem` | enum | `propagation.rs` |

## `sidereon_core::astro::forces::j2`

| Item | Kind | Binding |
|---|---|---|
| `J2Gravity` | struct | `forces.rs` |

## `sidereon_core::astro::forces::relativity`

| Item | Kind | Binding |
|---|---|---|
| `SchwarzschildRelativity` | struct | `propagation.rs` |

## `sidereon_core::astro::forces::srp`

| Item | Kind | Binding |
|---|---|---|
| `SolarRadiationPressure` | struct | `propagation.rs` |

## `sidereon_core::astro::forces::third_body`

| Item | Kind | Binding |
|---|---|---|
| `ThirdBodyBodies` | struct | MISSING |
| `ThirdBodyGravity` | struct | `propagation.rs` |

## `sidereon_core::astro::forces::tides`

| Item | Kind | Binding |
|---|---|---|
| `PERMANENT_TIDE_H0_M` | const | MISSING |
| `SOLID_EARTH_POLE_TIDE_IMAG_COUPLING` | const | MISSING |
| `SOLID_EARTH_POLE_TIDE_SCALE` | const | MISSING |
| `SOLID_EARTH_TIDE_A0_PER_M` | const | MISSING |
| `SOLID_EARTH_TIDE_K20_IMAG` | const | MISSING |
| `SOLID_EARTH_TIDE_K20_PLUS` | const | MISSING |
| `SOLID_EARTH_TIDE_K20_REAL` | const | MISSING |
| `SOLID_EARTH_TIDE_K21_IMAG` | const | MISSING |
| `SOLID_EARTH_TIDE_K21_PLUS` | const | MISSING |
| `SOLID_EARTH_TIDE_K21_REAL` | const | MISSING |
| `SOLID_EARTH_TIDE_K22_IMAG` | const | MISSING |
| `SOLID_EARTH_TIDE_K22_PLUS` | const | MISSING |
| `SOLID_EARTH_TIDE_K22_REAL` | const | MISSING |
| `SOLID_EARTH_TIDE_K30_REAL` | const | MISSING |
| `SOLID_EARTH_TIDE_K31_REAL` | const | MISSING |
| `SOLID_EARTH_TIDE_K32_REAL` | const | MISSING |
| `SOLID_EARTH_TIDE_K33_REAL` | const | MISSING |
| `SolidEarthPoleTideGravity` | struct | `propagation.rs` |
| `SolidEarthTideGravity` | struct | `propagation.rs` |

## `sidereon_core::astro::forces::two_body`

| Item | Kind | Binding |
|---|---|---|
| `TwoBodyGravity` | struct | `forces.rs` |

## `sidereon_core::astro::forces::zonal`

| Item | Kind | Binding |
|---|---|---|
| `ZonalCoefficients` | struct | `propagation.rs` |
| `ZonalDegrees` | struct | `propagation.rs` |
| `ZonalGravity` | struct | `propagation.rs` |

## `sidereon_core::astro::frames::nutation`

| Item | Kind | Binding |
|---|---|---|
| `NutationError` | enum | MISSING |
| `build_skyfield_nutation_matrix` | fn | MISSING |
| `skyfield_equation_of_the_equinoxes_complimentary_terms` | fn | MISSING |
| `skyfield_fundamental_arguments` | fn | MISSING |
| `skyfield_iau2000a_radians` | fn | MISSING |
| `skyfield_mean_obliquity_radians` | fn | MISSING |

## `sidereon_core::astro::frames::orientation`

| Item | Kind | Binding |
|---|---|---|
| `EarthOrientation` | struct | `broadcast.rs` |
| `EarthOrientationProvider` | trait | MISSING |
| `PolarMotionSample` | struct | MISSING |
| `PolarMotionSeriesEarthOrientationProvider` | struct | MISSING |
| `TdbEarthOrientationProvider` | struct | `orbit_determination.rs`, `propagation.rs` |

## `sidereon_core::astro::frames::precession`

| Item | Kind | Binding |
|---|---|---|
| `PrecessionError` | enum | MISSING |
| `build_icrs_to_j2000` | fn | MISSING |
| `compute_skyfield_precession_matrix` | fn | MISSING |

## `sidereon_core::astro::frames::transforms`

| Item | Kind | Binding |
|---|---|---|
| `FrameTransformError` | enum | `coverage.rs`, `tides.rs` |
| `GeodeticStationKm` | struct | `astro_observe_almanac.rs`, `bodies.rs`, `lib.rs` |
| `PolarMotion` | struct | `astro_observe_almanac.rs` |
| `TemeStateKm` | struct | `lib.rs` |
| `Vec3` | type | `angles.rs`, `antex.rs`, `araim.rs`, `astro_observe_almanac.rs`, `astro_phase_b.rs`, `collision.rs`, `conjunction.rs`, `covariance.rs`, `covariance_transport.rs`, `dgnss.rs`, `drag.rs`, `eclipse.rs`, `elements.rs`, `error_metrics.rs`, `forces.rs`, `frame_catalog.rs`, `gauss.rs`, `geodetic_time_series.rs`, `geometry.rs`, `iod.rs`, `lambert.rs`, `lib.rs`, `observables.rs`, `observation.rs`, `orbit_determination.rs`, `passes.rs`, `ppp_corrections.rs`, `precise_positioning.rs`, `precise_samples.rs`, `reduced_orbit.rs`, `reliability.rs`, `rtk.rs`, `rtk_filter.rs`, `sbas.rs`, `sgp4_batch.rs`, `ssr.rs`, `static_positioning.rs`, `tides.rs`, `tle_fit.rs`, `velocity.rs` |
| `gcrs_to_itrs_compute` | fn | `lib.rs` |
| `gcrs_to_itrs_compute_with_polar_motion` | fn | MISSING |
| `gcrs_to_itrs_matrix` | fn | MISSING |
| `gcrs_to_itrs_matrix_with_polar_motion` | fn | MISSING |
| `gcrs_to_teme_compute` | fn | MISSING |
| `gcrs_to_topocentric_compute` | fn | `lib.rs` |
| `gcrs_to_true_of_date_matrix` | fn | MISSING |
| `geodetic_from_ecef_proj` | fn | MISSING |
| `geodetic_to_itrs` | fn | `lib.rs` |
| `greenwich_apparent_sidereal_time_radians` | fn | MISSING |
| `greenwich_mean_sidereal_time_radians` | fn | MISSING |
| `greenwich_mean_sidereal_time_radians_from_j2000_seconds` | fn | MISSING |
| `itrs_to_gcrs_compute` | fn | `lib.rs` |
| `itrs_to_gcrs_compute_with_polar_motion` | fn | MISSING |
| `itrs_to_gcrs_matrix` | fn | MISSING |
| `itrs_to_gcrs_matrix_with_polar_motion` | fn | MISSING |
| `itrs_to_geodetic_compute` | fn | `lib.rs` |
| `itrs_to_topocentric` | fn | MISSING |
| `mat3_vec3_mul` | fn | MISSING |
| `mean_of_date_to_itrs_matrix` | fn | MISSING |
| `mean_of_date_to_itrs_matrix_with_polar_motion` | fn | MISSING |
| `polar_motion_matrix` | fn | MISSING |
| `teme_to_gcrs_compute` | fn | `lib.rs` |
| `with_ut1_validity` | fn | MISSING |

## `sidereon_core::astro::integrators`

| Item | Kind | Binding |
|---|---|---|
| `DynamicsModel` | trait | `rtk_filter.rs` |
| `Integrator` | trait | MISSING |

## `sidereon_core::astro::integrators::dp54`

| Item | Kind | Binding |
|---|---|---|
| `DP54` | struct | MISSING |

## `sidereon_core::astro::integrators::rk4`

| Item | Kind | Binding |
|---|---|---|
| `RK4` | struct | MISSING |

## `sidereon_core::astro::integrators::tableau`

| Item | Kind | Binding |
|---|---|---|
| `DP54Tableau` | struct | MISSING |

## `sidereon_core::astro::iod`

| Item | Kind | Binding |
|---|---|---|
| `IodError` | enum | `gauss.rs`, `iod.rs` |
| `gauss_angles` | fn | `gauss.rs` |
| `gibbs` | fn | `iod.rs` |
| `hgibbs` | fn | `iod.rs` |

## `sidereon_core::astro::lambert`

| Item | Kind | Binding |
|---|---|---|
| `DirectionOfEnergy` | enum | `lambert.rs` |
| `DirectionOfMotion` | enum | `lambert.rs` |
| `LambertError` | enum | MISSING |
| `battin` | fn | `lambert.rs` |

## `sidereon_core::astro::math::interp`

| Item | Kind | Binding |
|---|---|---|
| `lerp` | fn | MISSING |
| `lerp_ratio` | fn | MISSING |

## `sidereon_core::astro::math::least_squares`

| Item | Kind | Binding |
|---|---|---|
| `FD_REL_STEP_2POINT` | const | MISSING |
| `FdStep` | struct | MISSING |
| `LeastSquaresProblem` | struct | MISSING |
| `LeastSquaresReport` | struct | MISSING |
| `SolveError` | enum | `covariance.rs`, `spp.rs` |
| `SolveOptions` | struct | MISSING |
| `Status` | enum | `spp.rs` |
| `TrustRegionSolve` | enum | MISSING |
| `cost` | fn | `covariance.rs`, `geodetic_time_series.rs`, `lib.rs`, `source_localization.rs`, `tle_fit.rs`, `trls.rs` |
| `covariance_from_jacobian` | fn | `covariance.rs`, `lib.rs` |
| `covariance_from_report` | fn | MISSING |
| `fd_steps` | fn | MISSING |
| `hessian_trace` | fn | `covariance.rs` |
| `jacobian_2point` | fn | MISSING |
| `normal_covariance` | fn | `covariance.rs` |
| `solve_trf` | fn | MISSING |
| `solve_trf_with` | fn | MISSING |

## `sidereon_core::astro::math::linear`

| Item | Kind | Binding |
|---|---|---|
| `FlatCholeskySolveScratch` | struct | MISSING |
| `FlatLinearScratch` | struct | MISSING |
| `FlatNormalSolveScratch` | struct | MISSING |
| `LinearError` | enum | MISSING |
| `det4_cofactor` | fn | MISSING |
| `dot4` | fn | MISSING |
| `invert_3x3_adjugate` | fn | MISSING |
| `invert_4x4_cofactor` | fn | `geometry.rs` |
| `invert_flat_first_tie_into` | fn | MISSING |
| `invert_matrix_first_tie` | fn | MISSING |
| `invert_matrix_last_tie` | fn | MISSING |
| `invert_symmetric_pd` | fn | MISSING |
| `mat4_vec4` | fn | MISSING |
| `matmul` | fn | MISSING |
| `matrix_sub` | fn | MISSING |
| `minor3_of_4` | fn | MISSING |
| `normal_equations_weighted` | fn | MISSING |
| `normal_matrix_4_unweighted_row_outer` | fn | MISSING |
| `normal_matrix_4_weighted_column_outer` | fn | MISSING |
| `solve_augmented_flat_first_tie_in_place` | fn | MISSING |
| `solve_flat_normal_first_tie` | fn | MISSING |
| `solve_flat_normal_first_tie_into` | fn | MISSING |
| `solve_flat_normal_square_root_into` | fn | MISSING |
| `solve_linear_first_tie` | fn | MISSING |
| `solve_linear_last_tie` | fn | MISSING |
| `solve_matrix_flat_first_tie_into` | fn | MISSING |
| `solve_matrix_last_tie` | fn | MISSING |
| `transpose` | fn | `antex.rs`, `astro_observe_almanac.rs`, `bias.rs`, `broadcast.rs`, `cdm.rs`, `constellation.rs`, `data.rs`, `frame_catalog.rs`, `fusion.rs`, `geodetic_time_series.rs`, `nmea.rs`, `omm.rs`, `opm.rs`, `ppp_corrections.rs`, `precise_positioning.rs`, `propagation.rs`, `rtcm.rs`, `sp3.rs`, `ssr_bias_exclusion.rs`, `tle_fit.rs` |

## `sidereon_core::astro::math::mat3`

| Item | Kind | Binding |
|---|---|---|
| `Mat3` | type | `inertial.rs` |
| `inline_mxmxm` | fn | MISSING |
| `inline_rxr` | fn | MISSING |
| `inline_tr` | fn | MISSING |
| `mul_vec3` | fn | MISSING |

## `sidereon_core::astro::math::portable`

| Item | Kind | Binding |
|---|---|---|
| `Portable` | struct | MISSING |
| `cholesky_lower` | fn | MISSING |
| `cholesky_lower_dynamic` | fn | MISSING |
| `matrix_from_f64` | fn | MISSING |
| `matrix_from_row_slice` | fn | MISSING |
| `matrix_to_f64` | fn | MISSING |
| `product` | fn | `antex.rs`, `bias.rs`, `broadcast.rs`, `broadcast_comparison.rs`, `cache_lock.rs`, `data.rs`, `iono.rs`, `observable_states.rs`, `observables.rs`, `orbit_determination.rs`, `precise_samples.rs`, `rinex_clock.rs`, `rinex_obs.rs`, `rinex_qc.rs`, `sp3.rs`, `spp.rs`, `staleness.rs`, `terrain_store.rs` |
| `product_fixed` | fn | MISSING |
| `product_vector` | fn | MISSING |
| `solve_cholesky` | fn | MISSING |
| `solve_lu` | fn | MISSING |
| `svd` | fn | `trls.rs` |
| `symmetric_eigen6` | fn | MISSING |
| `symmetric_eigen_dynamic` | fn | MISSING |
| `thin_svd` | fn | MISSING |
| `vector_from_f64` | fn | MISSING |
| `vector_to_f64` | fn | MISSING |

## `sidereon_core::astro::math::robust`

| Item | Kind | Binding |
|---|---|---|
| `HUBER_K` | const | `consts.rs` |
| `MAD_NORMAL_CONST` | const | MISSING |
| `RobustError` | enum | MISSING |
| `huber_weight` | fn | MISSING |
| `mad_scale` | fn | MISSING |
| `median` | fn | `sp3.rs` |

## `sidereon_core::astro::math::special`

| Item | Kind | Binding |
|---|---|---|
| `erf` | fn | MISSING |
| `erfc` | fn | MISSING |
| `erfc_inv` | fn | MISSING |
| `normal_q` | fn | MISSING |
| `normal_q_inv` | fn | MISSING |
| `portable_log` | fn | MISSING |

## `sidereon_core::astro::math::vec3`

| Item | Kind | Binding |
|---|---|---|
| `Vec3Error` | enum | MISSING |
| `add3` | fn | MISSING |
| `checked_add3` | fn | MISSING |
| `cross3` | fn | MISSING |
| `cross3_ref` | fn | MISSING |
| `dot3` | fn | MISSING |
| `dot3_fused_z_yx_ref` | fn | MISSING |
| `dot3_ref` | fn | MISSING |
| `dot3_z_yx_ref` | fn | MISSING |
| `neg3` | fn | MISSING |
| `norm3` | fn | MISSING |
| `norm3_ref` | fn | MISSING |
| `scale3` | fn | MISSING |
| `sub3` | fn | MISSING |
| `unit3` | fn | MISSING |
| `unit3_ref_unchecked` | fn | MISSING |

## `sidereon_core::astro::ndm::text`

| Item | Kind | Binding |
|---|---|---|
| `TextIssue` | enum | `ndm_errors.rs` |

## `sidereon_core::astro::observation`

| Item | Kind | Binding |
|---|---|---|
| `ObservationError` | enum | MISSING |
| `SurfacePoint` | struct | `observation.rs` |
| `parallactic_angle_deg` | fn | `observation.rs` |
| `satellite_visual_magnitude` | fn | `observation.rs` |
| `sub_observer_point` | fn | `observation.rs` |
| `sub_solar_point` | fn | `observation.rs` |
| `terminator_latitude_deg` | fn | `observation.rs` |

## `sidereon_core::astro::oem`

| Item | Kind | Binding |
|---|---|---|
| `Oem` | struct | `oem.rs` |
| `OemComment` | struct | `oem.rs` |
| `OemCovariance` | struct | `oem.rs` |
| `OemError` | enum | `ndm_errors.rs`, `oem.rs` |
| `OemInputErrorKind` | enum | `ndm_errors.rs` |
| `OemMetadata` | struct | `oem.rs` |
| `OemSegment` | struct | `oem.rs` |
| `OemSkippedState` | struct | `oem.rs` |
| `OemState` | struct | `oem.rs` |
| `OemStateLineError` | enum | `ndm_errors.rs`, `oem.rs` |
| `encode_kvn` | fn | `cdm.rs`, `oem.rs`, `omm.rs`, `opm.rs`, `tdm.rs`, `tle_fit.rs` |
| `encode_xml` | fn | `cdm.rs`, `oem.rs`, `omm.rs`, `opm.rs` |
| `parse_kvn` | fn | `cdm.rs`, `oem.rs`, `omm.rs`, `opm.rs`, `tdm.rs` |
| `parse_xml` | fn | `cdm.rs`, `oem.rs`, `omm.rs`, `opm.rs` |

## `sidereon_core::astro::omm`

| Item | Kind | Binding |
|---|---|---|
| `Omm` | struct | `constellation.rs`, `omm.rs` |
| `OmmArray` | struct | `omm.rs` |
| `OmmComments` | struct | `omm.rs` |
| `OmmCovariance` | struct | `omm.rs` |
| `OmmEpoch` | struct | `constellation.rs`, `omm.rs` |
| `OmmError` | enum | `ndm_errors.rs`, `omm.rs`, `tle_fit.rs` |
| `OmmInputErrorKind` | enum | `ndm_errors.rs` |
| `OmmSkippedRecord` | struct | `constellation.rs` |
| `OmmSpacecraft` | struct | `omm.rs` |
| `OmmUserDefined` | struct | `omm.rs` |
| `encode_csv` | fn | `space_weather.rs` |
| `encode_csv_discarding_comments` | fn | MISSING |
| `encode_json` | fn | `omm.rs` |
| `encode_json_array` | fn | MISSING |
| `encode_json_array_discarding_comments` | fn | MISSING |
| `encode_json_discarding_comments` | fn | `omm.rs` |
| `encode_kvn` | fn | `cdm.rs`, `oem.rs`, `omm.rs`, `opm.rs`, `tdm.rs`, `tle_fit.rs` |
| `encode_xml` | fn | `cdm.rs`, `oem.rs`, `omm.rs`, `opm.rs` |
| `parse` | fn | `antex.rs`, `araim.rs`, `astro_phase_b.rs`, `bias.rs`, `broadcast.rs`, `broadcast_comparison.rs`, `data.rs`, `ephemeris.rs`, `fusion.rs`, `geometry.rs`, `iono.rs`, `nmea.rs`, `observable_states.rs`, `passes.rs`, `ppp_corrections.rs`, `precise_positioning.rs`, `precise_samples.rs`, `propagation.rs`, `rinex_clock.rs`, `rinex_obs.rs`, `rinex_qc.rs`, `sbas.rs`, `sp3.rs`, `space_weather.rs`, `spp.rs`, `ssr.rs`, `ssr_bias_exclusion.rs`, `terrain_store.rs`, `tle.rs` |
| `parse_csv` | fn | MISSING |
| `parse_csv_array` | fn | MISSING |
| `parse_epoch` | fn | `constellation.rs` |
| `parse_json` | fn | `omm.rs` |
| `parse_json_array` | fn | `constellation.rs`, `omm.rs` |
| `parse_kvn` | fn | `cdm.rs`, `oem.rs`, `omm.rs`, `opm.rs`, `tdm.rs` |
| `parse_xml` | fn | `cdm.rs`, `oem.rs`, `omm.rs`, `opm.rs` |
| `parse_xml_all` | fn | `omm.rs` |

## `sidereon_core::astro::opm`

| Item | Kind | Binding |
|---|---|---|
| `Opm` | struct | `opm.rs` |
| `OpmAnomaly` | enum | `opm.rs` |
| `OpmCovariance` | struct | `opm.rs` |
| `OpmError` | enum | `ndm_errors.rs`, `opm.rs` |
| `OpmInputErrorKind` | enum | `ndm_errors.rs` |
| `OpmKeplerian` | struct | `opm.rs` |
| `OpmManeuver` | struct | `opm.rs` |
| `OpmMetadata` | struct | `opm.rs` |
| `OpmSpacecraft` | struct | `opm.rs` |
| `OpmState` | struct | `opm.rs` |
| `OpmUserDefined` | struct | `opm.rs` |
| `encode_kvn` | fn | `cdm.rs`, `oem.rs`, `omm.rs`, `opm.rs`, `tdm.rs`, `tle_fit.rs` |
| `encode_xml` | fn | `cdm.rs`, `oem.rs`, `omm.rs`, `opm.rs` |
| `parse_kvn` | fn | `cdm.rs`, `oem.rs`, `omm.rs`, `opm.rs`, `tdm.rs` |
| `parse_xml` | fn | `cdm.rs`, `oem.rs`, `omm.rs`, `opm.rs` |

## `sidereon_core::astro::passes`

| Item | Kind | Binding |
|---|---|---|
| `ConstellationMember` | struct | MISSING |
| `GroundStation` | struct | `coverage.rs`, `look_angle.rs`, `passes.rs` |
| `LookAngle` | struct | MISSING |
| `LookAngleError` | enum | `coverage.rs`, `look_angle.rs`, `passes.rs` |
| `PassError` | enum | `passes.rs` |
| `PassFinderOptions` | struct | `passes.rs` |
| `PassPredictionOptions` | struct | MISSING |
| `PredictedPass` | struct | MISSING |
| `SatellitePass` | struct | MISSING |
| `UtcInstant` | struct | `astro_observe_almanac.rs`, `bodies.rs`, `constellation.rs`, `passes.rs` |
| `VisibleSatellite` | struct | MISSING |
| `find_passes` | fn | MISSING |
| `find_passes_batch_parallel` | fn | MISSING |
| `find_passes_batch_parallel_with_opsmode` | fn | MISSING |
| `find_passes_batch_parallel_with_validity` | fn | MISSING |
| `find_passes_batch_serial` | fn | MISSING |
| `find_passes_batch_serial_with_opsmode` | fn | MISSING |
| `find_passes_batch_serial_with_validity` | fn | MISSING |
| `find_passes_for_satellite` | fn | `passes.rs` |
| `find_passes_for_satellite_with_validity` | fn | MISSING |
| `find_passes_with_opsmode` | fn | MISSING |
| `find_passes_with_validity` | fn | MISSING |
| `ground_track` | fn | `lib.rs`, `passes.rs` |
| `ground_track_with_validity` | fn | MISSING |
| `look_angle` | fn | `lib.rs`, `look_angle.rs`, `passes.rs` |
| `look_angle_arc` | fn | `look_angle.rs` |
| `look_angle_arc_with_validity` | fn | MISSING |
| `look_angle_batch_parallel` | fn | MISSING |
| `look_angle_batch_parallel_with_validity` | fn | MISSING |
| `look_angle_batch_serial` | fn | `passes.rs` |
| `look_angle_batch_serial_with_validity` | fn | MISSING |
| `look_angle_with_validity` | fn | MISSING |
| `predict_passes` | fn | `lib.rs`, `passes.rs` |
| `predict_passes_with_opsmode` | fn | MISSING |
| `predict_passes_with_validity` | fn | MISSING |
| `propagate_teme_arc` | fn | MISSING |
| `propagate_teme_batch_parallel` | fn | MISSING |
| `propagate_teme_batch_serial` | fn | MISSING |
| `visible_from_constellation` | fn | MISSING |
| `visible_from_constellation_with_validity` | fn | MISSING |
| `visible_from_satellites` | fn | `passes.rs` |
| `visible_from_satellites_with_validity` | fn | MISSING |

## `sidereon_core::astro::propagator::api`

| Item | Kind | Binding |
|---|---|---|
| `IntegratorOptions` | struct | `covariance_transport.rs`, `drag.rs`, `propagation.rs` |
| `PropagationContext` | struct | `drag.rs`, `forces.rs`, `propagation.rs` |

## `sidereon_core::astro::propagator::controller`

| Item | Kind | Binding |
|---|---|---|
| `PIController` | struct | MISSING |

## `sidereon_core::astro::propagator::covariance`

| Item | Kind | Binding |
|---|---|---|
| `CovarianceEphemeris` | struct | MISSING |
| `CovarianceFrame` | enum | `covariance_transport.rs` |
| `CovarianceNode` | struct | MISSING |
| `CovariancePropagationOptions` | struct | `covariance_transport.rs` |
| `CovarianceSegment` | struct | `covariance_transport.rs` |
| `LabeledCovariance6` | struct | `covariance_transport.rs` |
| `ProcessNoise` | enum | `covariance_transport.rs` |
| `transport_covariance` | fn | `covariance_transport.rs` |

## `sidereon_core::astro::propagator::decay`

| Item | Kind | Binding |
|---|---|---|
| `DecayConfig` | struct | `drag.rs` |
| `DecayError` | enum | `drag.rs` |
| `DecayEstimate` | struct | MISSING |
| `estimate_decay` | fn | `drag.rs` |
| `estimate_decay_with_source` | fn | `space_weather.rs` |

## `sidereon_core::astro::propagator::dense_output`

| Item | Kind | Binding |
|---|---|---|
| `DenseOutput` | struct | MISSING |
| `DenseOutputError` | enum | MISSING |
| `DenseSegment` | struct | MISSING |

## `sidereon_core::astro::propagator::driver`

| Item | Kind | Binding |
|---|---|---|
| `PropagationConfig` | struct | MISSING |
| `PropagationForceModel` | enum | `drag.rs` |
| `propagate_states` | fn | MISSING |
| `propagate_states_with_context` | fn | MISSING |

## `sidereon_core::astro::propagator::dynamics`

| Item | Kind | Binding |
|---|---|---|
| `OrbitalDynamics` | struct | MISSING |

## `sidereon_core::astro::propagator::numerical`

| Item | Kind | Binding |
|---|---|---|
| `ForceModelComponents` | struct | `propagation.rs` |
| `ForceModelKind` | enum | `covariance_transport.rs`, `propagation.rs` |
| `IntegratorKind` | enum | `covariance_transport.rs`, `propagation.rs` |
| `StatePropagator` | struct | `covariance_transport.rs`, `propagation.rs` |
| `StateTransitionMatrix` | type | `covariance_transport.rs` |

## `sidereon_core::astro::propagator::result`

| Item | Kind | Binding |
|---|---|---|
| `PropagationPoint` | struct | MISSING |
| `PropagationResult` | struct | MISSING |
| `PropagationStats` | struct | MISSING |

## `sidereon_core::astro::relative`

| Item | Kind | Binding |
|---|---|---|
| `absolute_from_relative` | fn | `astro_phase_b.rs` |
| `cw_propagate` | fn | `astro_phase_b.rs` |
| `cw_stm` | fn | `astro_phase_b.rs` |
| `lvlh_to_inertial_rotation` | fn | `astro_phase_b.rs` |
| `mean_motion_circular` | fn | `astro_phase_b.rs` |
| `mean_motion_from_state` | fn | `astro_phase_b.rs` |
| `relative_state` | fn | `astro_phase_b.rs` |
| `ric_to_inertial_rotation` | fn | `astro_phase_b.rs` |
| `rsw_to_inertial_rotation` | fn | `astro_phase_b.rs` |
| `rtn_to_inertial_rotation` | fn | `astro_phase_b.rs` |

## `sidereon_core::astro::rf`

| Item | Kind | Binding |
|---|---|---|
| `LinkBudget` | struct | `rf.rs` |
| `RfError` | enum | MISSING |
| `cn0` | fn | `qc.rs`, `rf.rs` |
| `dish_gain` | fn | `rf.rs` |
| `eirp` | fn | `rf.rs` |
| `fspl` | fn | `rf.rs` |
| `fspl_batch` | fn | `rf.rs` |
| `link_margin` | fn | `rf.rs` |
| `link_margin_batch` | fn | `rf.rs` |
| `wavelength` | fn | `frequencies.rs`, `rf.rs`, `rinex_obs.rs`, `rtk_filter.rs` |

## `sidereon_core::astro::sgp4`

| Item | Kind | Binding |
|---|---|---|
| `DecayLatch` | struct | `sgp4_batch.rs` |
| `DecayLatchedError` | enum | `sgp4_batch.rs` |
| `ElementSet` | struct | `propagation.rs`, `tle_fit.rs` |
| `Error` | enum | `antex.rs`, `araim.rs`, `astro_observe_almanac.rs`, `astro_phase_b.rs`, `bias.rs`, `broadcast.rs`, `broadcast_comparison.rs`, `cdm.rs`, `clock_stability.rs`, `collision.rs`, `conjunction.rs`, `constellation.rs`, `covariance.rs`, `coverage.rs`, `drag.rs`, `eclipse.rs`, `elements.rs`, `ephemeris.rs`, `error_metrics.rs`, `errors.rs`, `forces.rs`, `geodetic_time_series.rs`, `inertial.rs`, `iono.rs`, `ndm_errors.rs`, `ntrip.rs`, `observable_states.rs`, `observables.rs`, `oem.rs`, `omm.rs`, `opm.rs`, `passes.rs`, `ppp_corrections.rs`, `precise_positioning.rs`, `precise_samples.rs`, `propagation.rs`, `qc.rs`, `reduced_orbit.rs`, `rf.rs`, `rinex_clock.rs`, `rinex_obs.rs`, `rinex_qc.rs`, `rtcm.rs`, `rtk_filter.rs`, `sbas.rs`, `sgp4_batch.rs`, `sidereal.rs`, `sp3.rs`, `spp.rs`, `ssr.rs`, `ssr_bias_exclusion.rs`, `tdm.rs`, `terrain_store.rs`, `tides.rs`, `time.rs`, `tle.rs`, `tropo.rs` |
| `JulianDate` | struct | `conjunction.rs`, `iono.rs`, `omm.rs`, `precise_samples.rs`, `propagation.rs`, `sp3.rs`, `tle_fit.rs` |
| `MinutesSinceEpoch` | struct | `sgp4_batch.rs` |
| `NamedSatellite` | struct | MISSING |
| `OpsMode` | enum | `coverage.rs`, `propagation.rs`, `tle.rs`, `tle_fit.rs` |
| `Prediction` | struct | `sgp4_batch.rs` |
| `RejectedTleRecord` | struct | MISSING |
| `Satellite` | struct | `antex.rs`, `bias.rs`, `coverage.rs`, `look_angle.rs`, `observable_states.rs`, `passes.rs`, `propagation.rs`, `rtk.rs`, `rtk_filter.rs`, `sgp4_batch.rs` |
| `Sgp4InputErrorKind` | enum | `coverage.rs`, `ndm_errors.rs` |
| `TleFile` | struct | MISSING |
| `TleRecordIssue` | enum | `tle.rs` |
| `parse_tle_file` | fn | `tle.rs` |
| `parse_tle_file_with_opsmode` | fn | MISSING |
| `parse_tle_file_with_policy` | fn | `tle.rs` |
| `propagate_batch` | fn | `sgp4_batch.rs` |
| `propagate_batch_parallel` | fn | `sgp4_batch.rs` |
| `propagate_elements` | fn | MISSING |
| `propagate_elements_with_opsmode` | fn | MISSING |

## `sidereon_core::astro::sgp4::fit`

| Item | Kind | Binding |
|---|---|---|
| `FitConfig` | struct | `tle_fit.rs` |
| `FitEpoch` | enum | `tle_fit.rs` |
| `FitSample` | struct | `tle_fit.rs` |
| `FitStatistics` | struct | MISSING |
| `TleFit` | struct | `tle_fit.rs` |
| `TleFitError` | enum | `tle_fit.rs` |
| `TleMetadata` | struct | `tle_fit.rs` |
| `fit_tle` | fn | `tle_fit.rs` |

## `sidereon_core::astro::sgp4::vallado`

| Item | Kind | Binding |
|---|---|---|
| `sgp4` | fn | `conjunction.rs`, `coverage.rs`, `look_angle.rs`, `ndm_errors.rs`, `omm.rs`, `passes.rs`, `propagation.rs`, `sgp4_batch.rs`, `tle.rs`, `tle_fit.rs` |

## `sidereon_core::astro::space_weather`

| Item | Kind | Binding |
|---|---|---|
| `ApHistorySample` | struct | `space_weather.rs` |
| `ObservationClass` | enum | `space_weather.rs` |
| `SpaceWeatherCoverage` | struct | `space_weather.rs` |
| `SpaceWeatherDay` | struct | MISSING |
| `SpaceWeatherError` | enum | `space_weather.rs` |
| `SpaceWeatherPolicy` | struct | `space_weather.rs` |
| `SpaceWeatherSample` | struct | `space_weather.rs` |
| `SpaceWeatherTable` | struct | `space_weather.rs` |
| `encode_csv` | fn | `space_weather.rs` |
| `encode_txt` | fn | `space_weather.rs` |
| `parse` | fn | `antex.rs`, `araim.rs`, `astro_phase_b.rs`, `bias.rs`, `broadcast.rs`, `broadcast_comparison.rs`, `data.rs`, `ephemeris.rs`, `fusion.rs`, `geometry.rs`, `iono.rs`, `nmea.rs`, `observable_states.rs`, `passes.rs`, `ppp_corrections.rs`, `precise_positioning.rs`, `precise_samples.rs`, `propagation.rs`, `rinex_clock.rs`, `rinex_obs.rs`, `rinex_qc.rs`, `sbas.rs`, `sp3.rs`, `space_weather.rs`, `spp.rs`, `ssr.rs`, `ssr_bias_exclusion.rs`, `terrain_store.rs`, `tle.rs` |
| `parse_csv` | fn | MISSING |
| `parse_txt` | fn | MISSING |

## `sidereon_core::astro::spk`

| Item | Kind | Binding |
|---|---|---|
| `DafByteOrder` | enum | MISSING |
| `DafFileRecord` | struct | MISSING |
| `DafSpk` | struct | MISSING |
| `NAIF_INERTIAL_FRAMES` | const | MISSING |
| `Spk` | struct | `astro_observe_almanac.rs`, `ephemeris.rs` |
| `SpkError` | enum | `ephemeris.rs` |
| `SpkKernels` | struct | MISSING |
| `SpkSegmentDescriptor` | struct | `ephemeris.rs` |
| `SpkState` | struct | `ephemeris.rs` |
| `SpkStateVector` | struct | MISSING |
| `evaluate_type21_state` | fn | MISSING |
| `evaluate_type2_position` | fn | MISSING |
| `evaluate_type2_state` | fn | MISSING |
| `evaluate_type3_state` | fn | MISSING |
| `inertial_frame_name` | fn | MISSING |
| `inertial_frame_rotation` | fn | MISSING |
| `parse_daf_spk` | fn | MISSING |
| `spk_state` | fn | `ephemeris.rs` |

## `sidereon_core::astro::state`

| Item | Kind | Binding |
|---|---|---|
| `CartesianState` | struct | `astro_phase_b.rs`, `covariance_transport.rs`, `drag.rs`, `forces.rs`, `propagation.rs` |
| `StateDerivative` | struct | MISSING |

## `sidereon_core::astro::tca`

| Item | Kind | Binding |
|---|---|---|
| `CatalogCollision` | struct | MISSING |
| `CatalogScreeningCandidate` | struct | MISSING |
| `CatalogScreeningOptions` | struct | MISSING |
| `CatalogScreeningResult` | struct | MISSING |
| `CatalogStateVector` | struct | MISSING |
| `DEFAULT_TCA_POSITION_COVARIANCE_KM2` | const | MISSING |
| `TcaCandidate` | struct | `conjunction.rs` |
| `TcaConjunction` | struct | `conjunction.rs` |
| `TcaError` | enum | `conjunction.rs` |
| `TcaFinderOptions` | struct | `conjunction.rs` |
| `TcaObject` | enum | MISSING |
| `TcaPcCovariances` | struct | MISSING |
| `TcaPcOptions` | struct | `conjunction.rs` |
| `TcaPropagatedCovarianceOptions` | struct | MISSING |
| `TcaPropagatedCovariancePcOptions` | struct | MISSING |
| `TcaScreeningConjunctionHit` | struct | `conjunction.rs` |
| `TcaScreeningHit` | struct | `conjunction.rs` |
| `TcaTle` | struct | `conjunction.rs` |
| `TcaTleWithCovariance` | struct | MISSING |
| `TcaWindow` | struct | `conjunction.rs` |
| `find_tca_candidates` | fn | MISSING |
| `find_tca_candidates_between_tles` | fn | `conjunction.rs` |
| `find_tca_candidates_from_tles` | fn | MISSING |
| `find_tca_conjunctions` | fn | MISSING |
| `find_tca_conjunctions_between_tles` | fn | `conjunction.rs` |
| `find_tca_conjunctions_from_tles` | fn | MISSING |
| `find_tca_conjunctions_with_propagated_covariance` | fn | MISSING |
| `find_tca_conjunctions_with_propagated_covariance_between_tles` | fn | MISSING |
| `find_tca_conjunctions_with_propagated_covariance_from_tles` | fn | MISSING |
| `screen_catalog_pairs` | fn | MISSING |
| `screen_state_vector_catalog` | fn | MISSING |
| `screen_tca_candidates_from_tle_catalog_parallel` | fn | `conjunction.rs` |
| `screen_tca_candidates_from_tle_catalog_serial` | fn | MISSING |
| `screen_tca_candidates_parallel` | fn | MISSING |
| `screen_tca_candidates_serial` | fn | MISSING |
| `screen_tca_conjunctions_from_tle_catalog_parallel` | fn | `conjunction.rs` |
| `screen_tca_conjunctions_from_tle_catalog_serial` | fn | MISSING |
| `screen_tca_conjunctions_parallel` | fn | MISSING |
| `screen_tca_conjunctions_serial` | fn | MISSING |
| `screen_tca_conjunctions_with_propagated_covariance_from_tle_catalog_parallel` | fn | MISSING |
| `screen_tca_conjunctions_with_propagated_covariance_from_tle_catalog_serial` | fn | MISSING |
| `tca_collision_probability` | fn | MISSING |
| `tca_collision_probability_with_propagated_covariance` | fn | MISSING |

## `sidereon_core::astro::tdm`

| Item | Kind | Binding |
|---|---|---|
| `Tdm` | struct | `tdm.rs` |
| `TdmComment` | struct | `tdm.rs` |
| `TdmDataRecord` | struct | `tdm.rs` |
| `TdmDataSection` | struct | `tdm.rs` |
| `TdmDeparture` | enum | `tdm.rs` |
| `TdmError` | enum | `tdm.rs` |
| `TdmField` | struct | `tdm.rs` |
| `TdmInputErrorKind` | enum | `tdm.rs` |
| `TdmLeniency` | enum | `tdm.rs` |
| `TdmMetadata` | struct | `tdm.rs` |
| `TdmObservable` | enum | `tdm.rs` |
| `TdmParticipant` | struct | `tdm.rs` |
| `TdmPath` | struct | `tdm.rs` |
| `TdmPolicy` | struct | `tdm.rs` |
| `TdmScalar` | struct | `tdm.rs` |
| `TdmSegment` | struct | `tdm.rs` |
| `TdmUnit` | enum | `tdm.rs` |
| `TdmWarning` | enum | `tdm.rs` |
| `TdmWritePolicy` | struct | `tdm.rs` |
| `encode_kvn` | fn | `cdm.rs`, `oem.rs`, `omm.rs`, `opm.rs`, `tdm.rs`, `tle_fit.rs` |
| `encode_kvn_with_policy` | fn | `tdm.rs` |
| `parse_kvn` | fn | `cdm.rs`, `oem.rs`, `omm.rs`, `opm.rs`, `tdm.rs` |
| `parse_kvn_with_policy` | fn | `tdm.rs` |

## `sidereon_core::astro::time`

| Item | Kind | Binding |
|---|---|---|
| `Time` | struct | `broadcast.rs`, `observable_states.rs` |

## `sidereon_core::astro::time::civil`

| Item | Kind | Binding |
|---|---|---|
| `J2000_JULIAN_DAY_NUMBER` | const | MISSING |
| `J2000_NOON_OFFSET_S` | const | MISSING |
| `MJD_JD_OFFSET` | const | MISSING |
| `civil_from_j2000_seconds` | fn | MISSING |
| `civil_from_julian_day_number` | fn | MISSING |
| `civil_from_split_julian_date` | fn | MISSING |
| `day_of_year` | fn | `data.rs`, `dgnss.rs`, `qc.rs`, `sbas.rs`, `spp.rs`, `ssr.rs`, `static_positioning.rs`, `time.rs` |
| `day_of_year_int` | fn | MISSING |
| `days_in_month` | fn | MISSING |
| `fractional_day_of_year_from_instant` | fn | MISSING |
| `is_leap_year` | fn | MISSING |
| `j2000_seconds` | fn | `sbas.rs`, `spp.rs`, `ssr.rs`, `time.rs` |
| `j2000_seconds_from_split` | fn | `geometry.rs`, `lib.rs`, `observables.rs`, `ppp_corrections.rs`, `precise_positioning.rs`, `velocity.rs` |
| `julian_date_from_instant` | fn | MISSING |
| `mjd_from_jd` | fn | MISSING |
| `second_of_day` | fn | `time.rs` |
| `second_of_day_from_instant` | fn | MISSING |
| `seconds_between_splits` | fn | MISSING |
| `split_julian_date` | fn | `propagation.rs`, `time.rs` |
| `split_julian_date_add_seconds` | fn | MISSING |
| `split_julian_date_from_j2000_seconds` | fn | `bias.rs` |

## `sidereon_core::astro::time::eop`

| Item | Kind | Binding |
|---|---|---|
| `CoverageError` | enum | `tides.rs` |
| `DegradeReason` | enum | `coverage.rs`, `errors.rs`, `passes.rs`, `ppp_corrections.rs`, `rtk_filter.rs`, `spp.rs`, `ssr_bias_exclusion.rs`, `tides.rs` |
| `LeapSecondTable` | struct | MISSING |
| `TimeScaleInputErrorKind` | enum | `tides.rs` |
| `Ut1Provenance` | struct | MISSING |
| `Validated` | struct | `tides.rs`, `time.rs` |
| `ValidityMode` | enum | `ppp_corrections.rs`, `tides.rs` |
| `check_ut1_coverage` | fn | MISSING |

## `sidereon_core::astro::time::exact`

| Item | Kind | Binding |
|---|---|---|
| `ExactEpoch` | struct | `rtk_filter.rs`, `spp.rs`, `time.rs` |
| `ExactEpochQuery` | struct | `observable_states.rs`, `time.rs` |

## `sidereon_core::astro::time::gnss`

| Item | Kind | Binding |
|---|---|---|
| `seconds_of_week_from_calendar` | fn | MISSING |
| `week_and_seconds_of_week` | fn | MISSING |
| `week_epoch_julian_day_number` | fn | MISSING |
| `week_from_calendar` | fn | MISSING |

## `sidereon_core::astro::time::model`

| Item | Kind | Binding |
|---|---|---|
| `Duration` | struct | `cache_lock.rs`, `sidereal.rs` |
| `GnssWeekTow` | struct | `broadcast.rs`, `sbas.rs`, `ssr.rs` |
| `Instant` | struct | `bias.rs`, `iono.rs`, `precise_samples.rs`, `sp3.rs`, `staleness.rs`, `time.rs`, `tropo.rs` |
| `InstantRepr` | enum | `iono.rs`, `precise_samples.rs`, `sp3.rs` |
| `JulianDateSplit` | struct | `bias.rs`, `broadcast_comparison.rs`, `iono.rs`, `precise_samples.rs`, `sp3.rs`, `time.rs`, `tropo.rs` |
| `TimeModelError` | enum | `iono.rs`, `time.rs`, `tropo.rs` |
| `TimeScale` | enum | `bias.rs`, `broadcast.rs`, `iono.rs`, `reduced_orbit.rs`, `rinex_clock.rs`, `sbas.rs`, `sp3.rs`, `spp.rs`, `ssr.rs`, `staleness.rs`, `tides.rs`, `time.rs`, `tropo.rs` |

## `sidereon_core::astro::time::scales`

| Item | Kind | Binding |
|---|---|---|
| `GLONASST_MINUS_UTC_S` | const | MISSING |
| `LeapSecondEntry` | struct | MISSING |
| `TCG_TCB_REFERENCE_JD` | const | MISSING |
| `TDB_TCB_OFFSET_TDB0_S` | const | MISSING |
| `TDB_TCB_RATE_L_B` | const | MISSING |
| `TT_TCG_RATE_L_G` | const | MISSING |
| `TimeOffsetError` | enum | `time.rs` |
| `TimeOffsetErrorCode` | enum | MISSING |
| `TimeScales` | struct | `lib.rs`, `tides.rs` |
| `TimeTables` | struct | MISSING |
| `find_leap_seconds` | fn | `time.rs` |
| `gps_utc_offset_s` | fn | `time.rs` |
| `julian_day_number` | fn | `time.rs` |
| `leap_second_table` | fn | `time.rs` |
| `tai_utc_offset_s` | fn | `time.rs` |
| `tcb_to_tdb_jd` | fn | MISSING |
| `tcg_to_tt_jd` | fn | MISSING |
| `tdb_to_tcb_jd` | fn | MISSING |
| `timescale_offset_at_s` | fn | `time.rs` |
| `timescale_offset_s` | fn | `time.rs` |
| `tt_to_tcg_jd` | fn | MISSING |
| `ut1_coverage` | fn | `time.rs` |

## `sidereon_core::astro::tle`

| Item | Kind | Binding |
|---|---|---|
| `ChecksumWarning` | struct | `tle.rs` |
| `ChecksumWarningKind` | enum | `tle.rs` |
| `MAX_NUMERIC_TLE_CATALOG_NUMBER` | const | MISSING |
| `MAX_TLE_CATALOG_NUMBER` | const | MISSING |
| `ParsedTle` | struct | MISSING |
| `TleElements` | struct | `propagation.rs`, `tle.rs` |
| `TleError` | enum | `ndm_errors.rs` |
| `TlePolicy` | enum | `tle.rs` |
| `decode_catalog_number` | fn | `propagation.rs` |
| `encode` | fn | `antex.rs`, `araim.rs`, `astro_observe_almanac.rs`, `astro_phase_b.rs`, `bias.rs`, `bodies.rs`, `broadcast.rs`, `broadcast_comparison.rs`, `cache_lock.rs`, `carrier_phase.rs`, `cdm.rs`, `clock_stability.rs`, `collision.rs`, `conjunction.rs`, `constellation.rs`, `covariance.rs`, `covariance_transport.rs`, `coverage.rs`, `data.rs`, `dgnss.rs`, `drag.rs`, `eclipse.rs`, `elements.rs`, `ephemeris.rs`, `error_metrics.rs`, `errors.rs`, `frame_catalog.rs`, `frequencies.rs`, `fusion.rs`, `geodesic.rs`, `geodetic_time_series.rs`, `geofence.rs`, `geoid.rs`, `geometry.rs`, `geometry_quality.rs`, `ils.rs`, `iod.rs`, `iono.rs`, `lib.rs`, `lnav.rs`, `look_angle.rs`, `ndm_errors.rs`, `nmea.rs`, `normality.rs`, `ntrip.rs`, `observable_states.rs`, `observables.rs`, `oem.rs`, `omm.rs`, `opm.rs`, `orbit_determination.rs`, `passes.rs`, `ppp_corrections.rs`, `precise_positioning.rs`, `precise_samples.rs`, `primitive_estimation.rs`, `propagation.rs`, `qc.rs`, `reduced_orbit.rs`, `reliability.rs`, `rinex_clock.rs`, `rinex_obs.rs`, `rinex_qc.rs`, `rtcm.rs`, `rtk.rs`, `rtk_filter.rs`, `sbas.rs`, `scenario.rs`, `sgp4_batch.rs`, `sidereal.rs`, `signal.rs`, `source_localization.rs`, `sp3.rs`, `space_weather.rs`, `spp.rs`, `ssr.rs`, `staleness.rs`, `static_positioning.rs`, `tdm.rs`, `terrain_store.rs`, `tides.rs`, `time.rs`, `tle.rs`, `tle_fit.rs`, `track_estimation.rs`, `trls.rs`, `velocity.rs` |
| `encode_catalog_number` | fn | MISSING |
| `line_checksum` | fn | MISSING |
| `parse` | fn | `antex.rs`, `araim.rs`, `astro_phase_b.rs`, `bias.rs`, `broadcast.rs`, `broadcast_comparison.rs`, `data.rs`, `ephemeris.rs`, `fusion.rs`, `geometry.rs`, `iono.rs`, `nmea.rs`, `observable_states.rs`, `passes.rs`, `ppp_corrections.rs`, `precise_positioning.rs`, `precise_samples.rs`, `propagation.rs`, `rinex_clock.rs`, `rinex_obs.rs`, `rinex_qc.rs`, `sbas.rs`, `sp3.rs`, `space_weather.rs`, `spp.rs`, `ssr.rs`, `ssr_bias_exclusion.rs`, `terrain_store.rs`, `tle.rs` |
| `parse_with_policy` | fn | `tle.rs` |

## `sidereon_core::astro::tolerances`

| Item | Kind | Binding |
|---|---|---|
| `PIVOT_EPSILON` | const | MISSING |

## `sidereon_core::bias`

| Item | Kind | Binding |
|---|---|---|
| `BiasDeparture` | enum | `bias.rs` |
| `BiasEpoch` | struct | MISSING |
| `BiasError` | enum | `bias.rs` |
| `BiasInfoRow` | struct | MISSING |
| `BiasKind` | enum | `bias.rs` |
| `BiasLineCounts` | struct | MISSING |
| `BiasLineRole` | enum | MISSING |
| `BiasLineTerminator` | enum | MISSING |
| `BiasLookup` | enum | `bias.rs` |
| `BiasMode` | enum | `bias.rs` |
| `BiasNotice` | enum | `bias.rs` |
| `BiasObservableFamily` | enum | `bias.rs` |
| `BiasReadPolicy` | enum | `bias.rs` |
| `BiasRecord` | struct | `bias.rs`, `ssr_bias_exclusion.rs` |
| `BiasSet` | struct | `bias.rs` |
| `BiasSetHeader` | struct | MISSING |
| `BiasSinexHeader` | struct | MISSING |
| `BiasSlopeReference` | enum | MISSING |
| `BiasSourceLine` | struct | MISSING |
| `BiasTarget` | enum | `bias.rs` |
| `BiasTargetKey` | struct | MISSING |
| `BiasUnit` | enum | MISSING |
| `ClockReferenceObservables` | struct | MISSING |
| `CodeDcbOptions` | struct | `bias.rs` |
| `SINEX_BIAS_SLOPE_DENOMINATOR_S` | const | MISSING |
| `bias_epoch_instant` | fn | MISSING |
| `civil_datetime_instant` | fn | MISSING |
| `ionosphere_free_coefficients` | fn | MISSING |
| `write_bias_sinex` | fn | `bias.rs` |
| `write_bias_sinex_bytes` | fn | `bias.rs` |
| `write_code_dcb` | fn | `bias.rs` |
| `write_code_dcb_bytes` | fn | `bias.rs` |

## `sidereon_core::broadcast`

| Item | Kind | Binding |
|---|---|---|
| `ClockOffset` | struct | MISSING |
| `ClockPolynomial` | struct | `broadcast.rs` |
| `CnavRates` | struct | MISSING |
| `ConstellationConstants` | struct | MISSING |
| `EccentricAnomaly` | struct | MISSING |
| `KeplerianElements` | struct | `broadcast.rs` |
| `OrbitState` | struct | MISSING |
| `SatelliteState` | struct | MISSING |
| `eccentric_anomaly` | fn | MISSING |
| `relativistic_clock_correction_s` | fn | MISSING |
| `satellite_clock_bias_s` | fn | MISSING |
| `satellite_clock_offset_s` | fn | MISSING |
| `satellite_position_ecef` | fn | MISSING |
| `satellite_position_ecef_cnav` | fn | MISSING |
| `satellite_state` | fn | MISSING |
| `satellite_state_cnav` | fn | MISSING |

## `sidereon_core::broadcast_comparison`

| Item | Kind | Binding |
|---|---|---|
| `CompareReport` | struct | MISSING |
| `CompareStats` | struct | `broadcast_comparison.rs` |
| `CompareWindow` | struct | `broadcast_comparison.rs` |
| `EpochInputs` | struct | MISSING |
| `compare` | fn | `sp3.rs` |
| `compare_window` | fn | `broadcast_comparison.rs` |
| `compare_window_epochs` | fn | MISSING |

## `sidereon_core::carrier_phase`

| Item | Kind | Binding |
|---|---|---|
| `ArcEpoch` | struct | `carrier_phase.rs` |
| `CarrierPhaseError` | enum | `carrier_phase.rs` |
| `CycleSlipOptions` | struct | `carrier_phase.rs`, `rtk_filter.rs` |
| `DEFAULT_GF_THRESHOLD_M` | const | MISSING |
| `DEFAULT_HATCH_WINDOW_CAP` | const | MISSING |
| `DEFAULT_MIN_ARC_GAP_S` | const | MISSING |
| `DEFAULT_MW_THRESHOLD_CYCLES` | const | MISSING |
| `IonoFreeSmoothResult` | struct | MISSING |
| `SlipReason` | enum | `carrier_phase.rs`, `rtk_filter.rs` |
| `SlipResult` | struct | MISSING |
| `SmoothCodeResult` | struct | MISSING |
| `code_minus_carrier` | fn | `carrier_phase.rs` |
| `detect_cycle_slips` | fn | `carrier_phase.rs` |
| `geometry_free` | fn | `carrier_phase.rs`, `rtk_filter.rs` |
| `melbourne_wubbena` | fn | `carrier_phase.rs`, `rtk_filter.rs` |
| `narrow_lane_code` | fn | `carrier_phase.rs` |
| `phase_meters` | fn | `carrier_phase.rs` |
| `smooth_code` | fn | `carrier_phase.rs` |
| `smooth_iono_free_code` | fn | `carrier_phase.rs` |
| `wide_lane_cycles` | fn | `carrier_phase.rs`, `rtk_filter.rs` |
| `wide_lane_wavelength` | fn | `carrier_phase.rs` |

## `sidereon_core::clock_stability`

| Item | Kind | Binding |
|---|---|---|
| `AllanDeviationCurves` | struct | `clock_stability.rs` |
| `AllanError` | enum | `clock_stability.rs` |
| `AllanEstimator` | enum | `clock_stability.rs` |
| `AllanEstimatorSet` | struct | `clock_stability.rs` |
| `AllanInput` | struct | `clock_stability.rs` |
| `AllanOptions` | struct | `clock_stability.rs` |
| `AllanResult` | struct | `clock_stability.rs` |
| `AllanSeries` | enum | `clock_stability.rs` |
| `GapPolicy` | enum | `clock_stability.rs` |
| `PowerLawNoiseError` | enum | `clock_stability.rs` |
| `PowerLawNoiseFit` | struct | `clock_stability.rs` |
| `PowerLawNoiseOptions` | struct | `clock_stability.rs` |
| `PowerLawNoiseRegion` | struct | `clock_stability.rs` |
| `PowerLawNoiseType` | enum | `clock_stability.rs` |
| `PowerLawOctave` | struct | `clock_stability.rs` |
| `PowerLawOctaveDominance` | enum | `clock_stability.rs` |
| `PowerLawOctaveFlag` | enum | `clock_stability.rs` |
| `TauGrid` | enum | `clock_stability.rs` |
| `allan_deviation` | fn | `clock_stability.rs` |
| `allan_deviation_power_law_slope` | fn | `clock_stability.rs` |
| `allan_variance_power_law_tau_exponent` | fn | MISSING |
| `compute_allan_deviations` | fn | `clock_stability.rs` |
| `fit_power_law_noise` | fn | `clock_stability.rs` |
| `hadamard_deviation` | fn | `clock_stability.rs` |
| `modified_adev` | fn | `clock_stability.rs` |
| `modified_allan_deviation_power_law_slope` | fn | `clock_stability.rs` |
| `overlapping_adev` | fn | `clock_stability.rs` |
| `receiver_clock_phase_deviations` | fn | `clock_stability.rs` |
| `time_deviation` | fn | `clock_stability.rs` |

## `sidereon_core::combinations`

| Item | Kind | Binding |
|---|---|---|
| `CombinedPseudoranges` | type | MISSING |
| `DroppedPseudoranges` | type | MISSING |
| `IonosphereFreeError` | enum | `iono.rs`, `rtk_filter.rs` |
| `PseudorangeCombinationResult` | type | MISSING |
| `PseudorangeDropReason` | enum | `iono.rs` |
| `PseudorangeObservation` | type | MISSING |
| `carrier_frequencies` | fn | MISSING |
| `carrier_frequency_hz` | fn | MISSING |
| `default_pair` | fn | MISSING |
| `frequency_hz` | fn | `frequencies.rs`, `iono.rs`, `lib.rs`, `rf.rs`, `rinex_obs.rs`, `rtcm.rs` |
| `gamma` | fn | `astro_observe_almanac.rs`, `iono.rs` |
| `ionosphere_free` | fn | `iono.rs`, `rtk_filter.rs`, `spp.rs` |
| `ionosphere_free_phase_cycles` | fn | `iono.rs` |
| `ionosphere_free_phase_m` | fn | `iono.rs` |
| `ionosphere_free_pseudoranges` | fn | `iono.rs` |
| `noise_amplification` | fn | `iono.rs` |

## `sidereon_core::constants`

| Item | Kind | Binding |
|---|---|---|
| `BDS_EPOCH_MINUS_GPS_EPOCH_S` | const | MISSING |
| `C_KM_S` | const | MISSING |
| `C_M_S` | const | `consts.rs` |
| `F_B1I_HZ` | const | MISSING |
| `F_B3I_HZ` | const | MISSING |
| `F_E1_HZ` | const | MISSING |
| `F_E5A_HZ` | const | MISSING |
| `F_L1_HZ` | const | MISSING |
| `F_L2_HZ` | const | MISSING |
| `GPST_MINUS_BDT_S` | const | MISSING |
| `GPS_EPOCH_TO_J2000_S` | const | MISSING |
| `HALF_WEEK_S` | const | MISSING |
| `OBSERVABLE_TRANSMIT_TIME_ITERATIONS` | const | MISSING |
| `SP3_DEFAULT_PROVENANCE_COMMENT` | const | MISSING |
| `SPP_TRANSMIT_TIME_ITERATIONS` | const | MISSING |

## `sidereon_core::constellation`

| Item | Kind | Binding |
|---|---|---|
| `BoolStyle` | enum | `constellation.rs` |
| `Catalog` | struct | `constellation.rs`, `data.rs`, `sp3.rs` |
| `CelestrakSource` | struct | `constellation.rs` |
| `ConstellationError` | enum | `constellation.rs` |
| `Diff` | struct | `constellation.rs` |
| `FieldChange` | struct | MISSING |
| `NavcenAssessment` | struct | `constellation.rs` |
| `NavcenEffectiveInterval` | struct | MISSING |
| `NavcenSource` | struct | `constellation.rs` |
| `NavcenStatus` | struct | `constellation.rs` |
| `NavcenTiming` | enum | `constellation.rs` |
| `Record` | struct | `constellation.rs`, `rtcm.rs` |
| `RecordSource` | struct | `constellation.rs` |
| `SkippedOmm` | struct | MISSING |
| `Validation` | struct | `constellation.rs`, `qc.rs`, `spp.rs` |
| `changed` | fn | `rinex_obs.rs` |
| `diff` | fn | `constellation.rs` |
| `from_celestrak_omm` | fn | `constellation.rs` |
| `from_celestrak_omm_lenient` | fn | `constellation.rs` |
| `galileo_prn_for_gsat` | fn | `constellation.rs` |
| `glonass_fdma_channel` | fn | `constellation.rs` |
| `glonass_slot_for_number` | fn | `constellation.rs` |
| `gnss_sp3_id` | fn | `constellation.rs` |
| `is_valid` | fn | `iono.rs`, `tides.rs` |
| `merge_navcen` | fn | `constellation.rs` |
| `merge_navcen_at` | fn | MISSING |
| `parse_navcen` | fn | `constellation.rs` |
| `parse_navcen_at` | fn | `constellation.rs` |
| `to_csv` | fn | `constellation.rs` |
| `validate` | fn | `constellation.rs`, `data.rs`, `fusion.rs`, `passes.rs`, `sp3.rs`, `trls.rs` |
| `validate_against_sp3` | fn | MISSING |
| `validate_against_sp3_ids` | fn | `constellation.rs` |
| `validate_against_sp3_ids_strict` | fn | `constellation.rs` |

## `sidereon_core::crinex`

| Item | Kind | Binding |
|---|---|---|
| `decode` | fn | `angles.rs`, `astro_observe_almanac.rs`, `bodies.rs`, `carrier_phase.rs`, `cdm.rs`, `collision.rs`, `constellation.rs`, `covariance.rs`, `drag.rs`, `eclipse.rs`, `iono.rs`, `lib.rs`, `lnav.rs`, `observable_states.rs`, `observables.rs`, `oem.rs`, `omm.rs`, `opm.rs`, `passes.rs`, `precise_positioning.rs`, `precise_samples.rs`, `propagation.rs`, `qc.rs`, `reduced_orbit.rs`, `rinex_obs.rs`, `rtcm.rs`, `rtk_filter.rs`, `sbas.rs`, `spp.rs`, `ssr.rs`, `ssr_bias_exclusion.rs`, `tides.rs`, `tle.rs`, `unix_compress.rs` |
| `decode_to` | fn | MISSING |
| `encode_crinex` | fn | `rinex_obs.rs`, `rinex_qc.rs` |

## `sidereon_core::data`

| Item | Kind | Binding |
|---|---|---|
| `AnalysisCenter` | enum | `data.rs`, `rinex_clock.rs` |
| `ArchiveCompression` | enum | `sp3.rs` |
| `ArchiveLayout` | enum | MISSING |
| `ArchiveProtocol` | enum | MISSING |
| `CenterCatalogEntry` | struct | MISSING |
| `CenterProductConvention` | struct | MISSING |
| `DataCatalogError` | enum | `data.rs`, `sp3.rs` |
| `DistributionLocation` | struct | MISSING |
| `DistributionSource` | enum | `cache_lock.rs`, `data.rs`, `sp3.rs` |
| `ExactProductSetError` | enum | MISSING |
| `HgtConversionError` | enum | `data.rs` |
| `NoOpenMirrorProduct` | struct | MISSING |
| `NominalCoverage` | struct | MISSING |
| `NominalCoverageInterval` | struct | `data.rs` |
| `NominalIssue` | struct | MISSING |
| `ProductCampaign` | enum | `data.rs` |
| `ProductDate` | struct | `data.rs`, `sp3.rs` |
| `ProductDateTime` | struct | `data.rs` |
| `ProductFilenameKind` | enum | MISSING |
| `ProductFormat` | enum | `data.rs` |
| `ProductIdentity` | struct | `data.rs` |
| `ProductPublisher` | enum | `data.rs` |
| `ProductRequest` | struct | `data.rs` |
| `ProductSpec` | struct | MISSING |
| `ProductType` | enum | `data.rs`, `sp3.rs` |
| `ProductTypeConvention` | struct | MISSING |
| `PublishedObject` | struct | `data.rs` |
| `PublishedProduct` | struct | `data.rs` |
| `SolutionClass` | enum | `data.rs` |
| `Sp3ContentStartConvention` | enum | MISSING |
| `SpaceWeatherProduct` | enum | `data.rs` |
| `SpaceWeatherSourceEntry` | struct | MISSING |
| `StationObservationSpec` | struct | `data.rs` |
| `TerrainSourceEntry` | struct | MISSING |
| `UltraIssue` | struct | `data.rs` |
| `UltraSp3Location` | struct | MISSING |
| `allowed_hosts` | fn | `data.rs` |
| `archive_url` | fn | `data.rs` |
| `canonical_filename` | fn | `data.rs` |
| `catalog` | fn | `constellation.rs`, `data.rs`, `frame_catalog.rs`, `omm.rs`, `passes.rs`, `propagation.rs`, `sp3.rs` |
| `cddis_archive_url` | fn | MISSING |
| `center_catalog` | fn | `data.rs` |
| `centers` | fn | `data.rs`, `sp3.rs` |
| `day_of_year` | fn | `data.rs`, `dgnss.rs`, `qc.rs`, `sbas.rs`, `spp.rs`, `ssr.rs`, `static_positioning.rs`, `time.rs` |
| `default_sample` | fn | `data.rs` |
| `default_sample_for_date` | fn | `data.rs` |
| `distribution_location` | fn | MISSING |
| `distribution_location_for_identity` | fn | `data.rs` |
| `dted_block_dir` | fn | `data.rs` |
| `dted_cache_relpath` | fn | `data.rs` |
| `dted_tile_filename` | fn | `data.rs` |
| `gim_date_candidates` | fn | `data.rs` |
| `gps_week` | fn | `data.rs`, `sp3.rs` |
| `hgt_to_dted` | fn | `data.rs` |
| `latest_ops_ultra_sp3` | fn | MISSING |
| `latest_ultra_issue` | fn | `data.rs` |
| `mgex_clk` | fn | MISSING |
| `mgex_ionex` | fn | MISSING |
| `mgex_nav` | fn | MISSING |
| `mgex_sp3` | fn | MISSING |
| `newest_published_product` | fn | `data.rs` |
| `next_issue_due` | fn | `data.rs` |
| `no_open_mirrors` | fn | MISSING |
| `open_mirror` | fn | MISSING |
| `open_mirror_code` | fn | `data.rs` |
| `ops_ultra_clk` | fn | MISSING |
| `ops_ultra_sp3` | fn | MISSING |
| `parse_archive_listing` | fn | `data.rs` |
| `parse_skadi_tile_id` | fn | `data.rs` |
| `predicted_day_offset` | fn | `data.rs` |
| `predicted_ionex` | fn | MISSING |
| `predicted_ionex_line_candidates` | fn | `data.rs` |
| `product` | fn | `antex.rs`, `bias.rs`, `broadcast.rs`, `broadcast_comparison.rs`, `cache_lock.rs`, `data.rs`, `iono.rs`, `observable_states.rs`, `observables.rs`, `orbit_determination.rs`, `precise_samples.rs`, `rinex_clock.rs`, `rinex_obs.rs`, `rinex_qc.rs`, `sp3.rs`, `spp.rs`, `staleness.rs`, `terrain_store.rs` |
| `product_convention` | fn | `data.rs` |
| `product_identity` | fn | `cache_lock.rs`, `data.rs`, `sp3.rs` |
| `product_solution_class` | fn | `data.rs` |
| `product_types` | fn | `data.rs` |
| `publication_listing_urls` | fn | `data.rs` |
| `published_issue_age_minutes` | fn | `data.rs` |
| `rapid_ionex` | fn | MISSING |
| `resolve_first_published` | fn | `data.rs` |
| `skadi_archive_url` | fn | `data.rs` |
| `skadi_band` | fn | `data.rs` |
| `skadi_source_entry` | fn | `data.rs` |
| `skadi_tile_id` | fn | `data.rs` |
| `sp3_content_start_convention` | fn | `data.rs` |
| `space_weather_archive_url` | fn | `data.rs` |
| `space_weather_cache_relpath` | fn | `data.rs` |
| `space_weather_filename` | fn | `data.rs` |
| `space_weather_source_entry` | fn | `data.rs` |
| `station_obs` | fn | MISSING |
| `station_obs_filename` | fn | MISSING |
| `station_obs_protocol` | fn | MISSING |
| `station_obs_url` | fn | MISSING |
| `supported_samples` | fn | `data.rs` |
| `terrain_tile_index` | fn | `data.rs` |
| `ultra_issue_candidates` | fn | `data.rs` |
| `ultra_sp3_locations` | fn | `data.rs` |
| `validate_exact_product_set` | fn | `data.rs` |

## `sidereon_core::dgnss`

| Item | Kind | Binding |
|---|---|---|
| `AppliedCorrections` | struct | MISSING |
| `CodeObservation` | struct | `dgnss.rs` |
| `DgnssError` | enum | `dgnss.rs` |
| `PositionSolution` | struct | `dgnss.rs` |
| `apply_corrections` | fn | `dgnss.rs` |
| `pseudorange_corrections` | fn | `dgnss.rs` |
| `pseudorange_corrections_validated` | fn | MISSING |
| `solve_position` | fn | `dgnss.rs` |

## `sidereon_core::dop`

| Item | Kind | Binding |
|---|---|---|
| `DesignGeometryCofactor` | struct | MISSING |
| `Dop` | struct | `geofence.rs`, `geometry.rs`, `source_localization.rs` |
| `DopError` | enum | `covariance.rs`, `geometry.rs`, `source_localization.rs` |
| `EnuConvention` | enum | `geometry.rs` |
| `GeometryCofactor` | struct | MISSING |
| `HorizontalErrorEllipse` | struct | MISSING |
| `LineOfSight` | struct | `araim.rs`, `geometry.rs` |
| `PositionCovariance` | struct | `error_metrics.rs`, `precise_positioning.rs` |
| `dop` | fn | `geometry.rs`, `source_localization.rs`, `spp.rs` |
| `dop_from_design_rows` | fn | MISSING |
| `dop_with_convention` | fn | `geometry.rs` |
| `ecef_to_enu_rotation` | fn | MISSING |
| `error_ellipse_2x2` | fn | `covariance.rs` |
| `error_ellipse_2x2_unit` | fn | MISSING |
| `error_ellipse_from_geometry` | fn | MISSING |
| `geometry_cofactor` | fn | MISSING |
| `geometry_cofactor_from_design_rows` | fn | MISSING |
| `geometry_cofactor_with_convention` | fn | MISSING |
| `horizontal_error_ellipse` | fn | MISSING |
| `line_of_sight_from_az_el_deg` | fn | `araim.rs` |
| `position_covariance_from_geometry_m2` | fn | MISSING |
| `rotate_covariance_ecef_to_enu_m2` | fn | MISSING |

## `sidereon_core::ephemeris`

| Item | Kind | Binding |
|---|---|---|
| `BroadcastEphemeris` | type | `broadcast.rs` |
| `EphemerisSampleRow` | struct | `astro_phase_b.rs`, `sbas.rs`, `ssr.rs` |
| `EphemerisSampleStatus` | enum | `astro_phase_b.rs`, `sbas.rs`, `ssr.rs` |
| `SP3` | type | `broadcast_comparison.rs`, `data.rs`, `fusion.rs`, `geometry.rs`, `iono.rs`, `observable_states.rs`, `observables.rs`, `orbit_determination.rs`, `precise_samples.rs`, `sp3.rs`, `spp.rs`, `staleness.rs`, `static_positioning.rs` |
| `broadcast_group_delay_s` | fn | MISSING |
| `broadcast_message_group_delay_s` | fn | MISSING |
| `broadcast_record_group_delay_s` | fn | MISSING |
| `sample` | fn | `antex.rs`, `astro_phase_b.rs`, `clock_stability.rs`, `data.rs`, `fusion.rs`, `geodetic_time_series.rs`, `geofence.rs`, `geometry.rs`, `iono.rs`, `observable_states.rs`, `observables.rs`, `oem.rs`, `orbit_determination.rs`, `precise_positioning.rs`, `precise_samples.rs`, `primitive_estimation.rs`, `reduced_orbit.rs`, `rtk_filter.rs`, `sbas.rs`, `sp3.rs`, `space_weather.rs`, `ssr.rs`, `tle_fit.rs` |

## `sidereon_core::error`

| Item | Kind | Binding |
|---|---|---|
| `Error` | enum | `antex.rs`, `araim.rs`, `astro_observe_almanac.rs`, `astro_phase_b.rs`, `bias.rs`, `broadcast.rs`, `broadcast_comparison.rs`, `cdm.rs`, `clock_stability.rs`, `collision.rs`, `conjunction.rs`, `constellation.rs`, `covariance.rs`, `coverage.rs`, `drag.rs`, `eclipse.rs`, `elements.rs`, `ephemeris.rs`, `error_metrics.rs`, `errors.rs`, `forces.rs`, `geodetic_time_series.rs`, `inertial.rs`, `iono.rs`, `ndm_errors.rs`, `ntrip.rs`, `observable_states.rs`, `observables.rs`, `oem.rs`, `omm.rs`, `opm.rs`, `passes.rs`, `ppp_corrections.rs`, `precise_positioning.rs`, `precise_samples.rs`, `propagation.rs`, `qc.rs`, `reduced_orbit.rs`, `rf.rs`, `rinex_clock.rs`, `rinex_obs.rs`, `rinex_qc.rs`, `rtcm.rs`, `rtk_filter.rs`, `sbas.rs`, `sgp4_batch.rs`, `sidereal.rs`, `sp3.rs`, `spp.rs`, `ssr.rs`, `ssr_bias_exclusion.rs`, `tdm.rs`, `terrain_store.rs`, `tides.rs`, `time.rs`, `tle.rs`, `tropo.rs` |
| `Result` | type | `antex.rs`, `astro_phase_b.rs`, `bias.rs`, `broadcast.rs`, `cache_lock.rs`, `carrier_phase.rs`, `cdm.rs`, `clock_stability.rs`, `conjunction.rs`, `constellation.rs`, `covariance.rs`, `covariance_transport.rs`, `data.rs`, `error_metrics.rs`, `errors.rs`, `frame_catalog.rs`, `fusion.rs`, `gauss.rs`, `geodesic.rs`, `geodetic_time_series.rs`, `geofence.rs`, `geoid.rs`, `ils.rs`, `iod.rs`, `iono.rs`, `nmea.rs`, `normality.rs`, `ntrip.rs`, `observables.rs`, `oem.rs`, `omm.rs`, `opm.rs`, `orbit_determination.rs`, `precise_positioning.rs`, `primitive_estimation.rs`, `qc.rs`, `reduced_orbit.rs`, `rf.rs`, `rinex_clock.rs`, `rinex_obs.rs`, `rtcm.rs`, `rtk_filter.rs`, `sgp4_batch.rs`, `signal.rs`, `source_localization.rs`, `sp3.rs`, `space_weather.rs`, `spp.rs`, `staleness.rs`, `tdm.rs`, `terrain_store.rs`, `tides.rs`, `time.rs`, `tle_fit.rs`, `track_estimation.rs`, `trls.rs`, `unix_compress.rs`, `velocity.rs` |

## `sidereon_core::error_metrics`

| Item | Kind | Binding |
|---|---|---|
| `ErrorEllipse` | struct | `error_metrics.rs` |
| `ErrorMetricsError` | enum | `error_metrics.rs`, `geofence.rs` |
| `PercentileRadius` | struct | `error_metrics.rs`, `geofence.rs` |
| `PositionErrorMetrics` | struct | `error_metrics.rs` |
| `error_ellipse_from_enu_m2` | fn | `error_metrics.rs` |
| `horizontal_radius_at` | fn | `error_metrics.rs` |
| `metrics_from_ecef_covariance_m2` | fn | `error_metrics.rs` |
| `metrics_from_enu_covariance_m2` | fn | `error_metrics.rs` |
| `metrics_from_kinematic_solution` | fn | `error_metrics.rs` |
| `metrics_from_position_covariance` | fn | `error_metrics.rs` |
| `spherical_radius_at` | fn | `error_metrics.rs` |
| `vertical_radius_at` | fn | `error_metrics.rs` |

## `sidereon_core::estimation::primitives`

| Item | Kind | Binding |
|---|---|---|
| `AlphaBetaGains` | struct | `primitive_estimation.rs` |
| `AlphaBetaState` | struct | `primitive_estimation.rs` |
| `AlphaBetaStep` | struct | MISSING |
| `MAD_GAUSSIAN_CONSISTENCY` | const | `primitive_estimation.rs` |
| `NisGate` | struct | `track_estimation.rs` |
| `PrimitiveError` | enum | `primitive_estimation.rs` |
| `ScalarKalmanGains` | struct | MISSING |
| `alpha_beta_apply_measurement` | fn | `primitive_estimation.rs` |
| `alpha_beta_filter_step` | fn | `primitive_estimation.rs` |
| `alpha_beta_predict` | fn | `primitive_estimation.rs` |
| `alpha_beta_steady_state_gains` | fn | `primitive_estimation.rs` |
| `cfar_ca_false_alarm_probability` | fn | `primitive_estimation.rs` |
| `cfar_ca_multiplier_from_pfa` | fn | `primitive_estimation.rs` |
| `cfar_ca_pfa_from_multiplier` | fn | `primitive_estimation.rs` |
| `cfar_ca_threshold` | fn | `primitive_estimation.rs` |
| `ewma_update` | fn | `primitive_estimation.rs` |
| `ewma_update_power_of_two` | fn | `primitive_estimation.rs` |
| `kalman_cv_steady_state_gains` | fn | `primitive_estimation.rs` |
| `mad_spread` | fn | `primitive_estimation.rs` |
| `nis_expected_value` | fn | `primitive_estimation.rs` |
| `nis_gate_test` | fn | `primitive_estimation.rs` |
| `nis_gate_threshold` | fn | `primitive_estimation.rs` |
| `nis_statistic` | fn | `primitive_estimation.rs` |
| `normalized_innovation` | fn | `primitive_estimation.rs` |

## `sidereon_core::estimation::recipe`

| Item | Kind | Binding |
|---|---|---|
| `AmbiguityIdPolicy` | struct | MISSING |
| `DifferencingMode` | enum | MISSING |
| `EstimationRecipe` | struct | MISSING |
| `FrameRecipe` | enum | MISSING |
| `NormalRecipe` | enum | MISSING |
| `PartialResolution` | enum | MISSING |
| `RangeRecipe` | enum | MISSING |
| `ReferenceTarget` | enum | MISSING |
| `ResidualNormRecipe` | enum | MISSING |
| `SagnacRecipe` | enum | MISSING |
| `ScreenKind` | enum | MISSING |
| `SolverRecipe` | enum | MISSING |
| `StrategyId` | enum | `spp.rs` |
| `Technique` | enum | MISSING |

## `sidereon_core::estimation::strategies`

| Item | Kind | Binding |
|---|---|---|
| `EstimateError` | enum | `spp.rs` |
| `EstimateInput` | enum | `spp.rs` |
| `EstimateOptions` | struct | `spp.rs` |
| `EstimateOutput` | enum | `spp.rs` |
| `ResolvedStrategy` | struct | MISSING |
| `estimate` | fn | `drag.rs`, `observables.rs`, `precise_samples.rs`, `sp3.rs`, `space_weather.rs`, `spp.rs` |

## `sidereon_core::estimation::track`

| Item | Kind | Binding |
|---|---|---|
| `SmoothedTrack` | struct | `track_estimation.rs` |
| `SmoothedTrackEpoch` | struct | `track_estimation.rs` |
| `TrackCoordinateFrame` | enum | `track_estimation.rs` |
| `TrackError` | enum | `track_estimation.rs` |
| `TrackFilter` | struct | `track_estimation.rs` |
| `TrackFilterConfig` | struct | `track_estimation.rs` |
| `TrackGatedUpdate` | struct | `track_estimation.rs` |
| `TrackInnovation` | struct | `track_estimation.rs` |
| `TrackPrediction` | struct | `track_estimation.rs` |
| `TrackRtsEpoch` | struct | `track_estimation.rs` |
| `TrackRtsHistory` | struct | `track_estimation.rs` |
| `TrackRtsHistoryBuilder` | struct | `track_estimation.rs` |
| `TrackState` | struct | `track_estimation.rs` |
| `TrackUpdate` | struct | `track_estimation.rs` |
| `rts_smooth` | fn | MISSING |
| `smooth_track_rts` | fn | `track_estimation.rs` |

## `sidereon_core::exact_cache`

| Item | Kind | Binding |
|---|---|---|
| `EXACT_CACHE_CONTROL_DIRECTORY` | const | MISSING |
| `EXACT_CACHE_MARKER_FILENAME` | const | MISSING |
| `EXACT_CACHE_SCHEMA_VERSION` | const | MISSING |
| `ExactCacheDigests` | struct | MISSING |
| `ExactCacheError` | enum | `cache_lock.rs` |
| `ExactCacheSingleFlightDecision` | enum | MISSING |
| `ExactCacheSingleFlightOptions` | struct | `cache_lock.rs` |
| `ExactCacheSingleFlightWait` | struct | MISSING |
| `VerifiedExactCacheCommit` | struct | MISSING |
| `build_commit_record` | fn | MISSING |
| `identity_sha256` | fn | MISSING |
| `verify_commit_record` | fn | MISSING |

## `sidereon_core::format`

| Item | Kind | Binding |
|---|---|---|
| `Diagnostics` | struct | `nmea.rs`, `space_weather.rs` |
| `Parsed` | struct | `bias.rs`, `constellation.rs`, `ntrip.rs`, `sp3.rs`, `terrain_store.rs` |
| `RecordRef` | struct | `nmea.rs` |
| `Skip` | struct | MISSING |
| `SkipReason` | enum | `nmea.rs`, `oem.rs` |
| `Warning` | struct | `iono.rs`, `nmea.rs`, `rinex_qc.rs` |
| `WarningKind` | enum | `nmea.rs` |

## `sidereon_core::frame`

| Item | Kind | Binding |
|---|---|---|
| `FrameValueError` | enum | `iono.rs`, `tropo.rs` |
| `ItrfPositionM` | struct | MISSING |
| `ItrfVelocityMS` | struct | MISSING |
| `Wgs84Geodetic` | struct | `araim.rs`, `error_metrics.rs`, `geodetic_time_series.rs`, `geofence.rs`, `geometry.rs`, `iono.rs`, `rtk_filter.rs`, `tides.rs`, `tropo.rs` |
| `geocentric_east` | fn | MISSING |
| `geocentric_neu_basis` | fn | MISSING |
| `geocentric_up` | fn | MISSING |
| `geodetic_to_itrf` | fn | MISSING |
| `itrf_to_geodetic` | fn | MISSING |

## `sidereon_core::frame_catalog`

| Item | Kind | Binding |
|---|---|---|
| `FrameCatalogError` | enum | `frame_catalog.rs` |
| `HelmertParameters` | struct | `frame_catalog.rs` |
| `HelmertRates` | struct | `frame_catalog.rs` |
| `HelmertTransform` | struct | `frame_catalog.rs` |
| `TERRESTRIAL_FRAME_CATALOG` | const | MISSING |
| `TerrestrialFrame` | enum | `frame_catalog.rs` |
| `TerrestrialPositionM` | struct | `frame_catalog.rs` |
| `TerrestrialState` | struct | `frame_catalog.rs` |
| `TerrestrialVelocityMPerYear` | struct | `frame_catalog.rs` |
| `catalog` | fn | `constellation.rs`, `data.rs`, `frame_catalog.rs`, `omm.rs`, `passes.rs`, `propagation.rs`, `sp3.rs` |
| `catalog_entry` | fn | `frame_catalog.rs` |
| `propagate_position` | fn | `frame_catalog.rs` |
| `transform` | fn | `frame_catalog.rs`, `fusion.rs`, `lib.rs` |
| `transform_from_epoch` | fn | `frame_catalog.rs` |

## `sidereon_core::frequencies`

| Item | Kind | Binding |
|---|---|---|
| `CarrierBand` | enum | `frequencies.rs`, `iono.rs` |
| `CarrierFrequency` | struct | MISSING |
| `CarrierPair` | struct | MISSING |
| `default_iono_free_pair` | fn | `frequencies.rs`, `iono.rs` |
| `default_spp_carrier` | fn | MISSING |
| `default_spp_frequency_hz` | fn | MISSING |
| `fixed_carrier_frequencies` | fn | MISSING |
| `frequency_hz` | fn | `frequencies.rs`, `iono.rs`, `lib.rs`, `rf.rs`, `rinex_obs.rs`, `rtcm.rs` |
| `glonass_g1_frequency_hz` | fn | MISSING |
| `iono_free_carrier_frequencies` | fn | `iono.rs` |
| `rinex_band_frequency_hz` | fn | `frequencies.rs`, `rinex_obs.rs` |
| `rinex_band_frequency_hz_classified` | fn | MISSING |
| `rinex_band_wavelength_m` | fn | `frequencies.rs` |
| `rinex_observation_frequency_hz` | fn | `frequencies.rs` |
| `rinex_observation_wavelength_m` | fn | `frequencies.rs` |
| `wavelength_m` | fn | `frequencies.rs`, `rinex_obs.rs` |

## `sidereon_core::fusion::ekf`

| Item | Kind | Binding |
|---|---|---|
| `EkfCorrection` | struct | MISSING |
| `EkfCorrectionReport` | struct | `fusion.rs` |
| `EkfUpdateOptions` | struct | `fusion.rs` |
| `InnovationGate` | struct | `fusion.rs` |
| `InnovationGateReport` | struct | `fusion.rs` |
| `apply_closed_loop_error` | fn | MISSING |
| `ekf_correct_closed_loop` | fn | MISSING |
| `joseph_covariance_update` | fn | MISSING |

## `sidereon_core::fusion::error_state`

| Item | Kind | Binding |
|---|---|---|
| `ErrorStateImuKinematics` | struct | MISSING |
| `ErrorStateLinearization` | struct | MISSING |
| `error_state_process_noise_discrete` | fn | MISSING |
| `error_state_system_matrix_ecef` | fn | MISSING |
| `error_state_system_matrix_ecef_with_imu_to_body` | fn | MISSING |
| `error_state_transition_matrix` | fn | MISSING |
| `linearize_error_state_ecef` | fn | MISSING |
| `linearize_error_state_ecef_with_imu_to_body` | fn | MISSING |
| `predict_error_state_covariance` | fn | MISSING |

## `sidereon_core::fusion::loose`

| Item | Kind | Binding |
|---|---|---|
| `FusionUpdate` | struct | `fusion.rs` |
| `GnssFixMeasurement` | struct | `fusion.rs` |
| `GnssFixStatus` | enum | `fusion.rs` |
| `GnssFixStatusWeighting` | struct | `fusion.rs` |
| `IggIiiMeasurementReweighting` | struct | `fusion.rs` |
| `InertialFilter` | struct | `fusion.rs` |
| `InertialFilterConfig` | struct | `fusion.rs` |
| `LooseCouplingConfig` | struct | `fusion.rs` |
| `NonHolonomicConstraintConfig` | struct | `fusion.rs` |
| `StationaryDetectorConfig` | struct | `fusion.rs` |
| `StationaryUpdateConfig` | struct | `fusion.rs` |
| `VelocityMatchState` | struct | `fusion.rs` |
| `VelocityMatchedTrajectory` | struct | `fusion.rs` |
| `VelocityMatchingConfig` | struct | `fusion.rs` |
| `YangPredictionAdaptiveFactor` | struct | `fusion.rs` |
| `loose_coupling_correction` | fn | MISSING |
| `velocity_match_outage` | fn | `fusion.rs` |
| `velocity_match_outage_to_state` | fn | MISSING |

## `sidereon_core::fusion::serial`

| Item | Kind | Binding |
|---|---|---|
| `F64Bits` | struct | MISSING |
| `FUSION_STATE_CODEC_VERSION` | const | MISSING |
| `FusionStateCodecError` | enum | `fusion.rs` |
| `SerializableErrorStateLayout` | enum | MISSING |
| `SerializableFusionSnapshot` | struct | MISSING |
| `SerializableFusionState` | struct | MISSING |
| `SerializableGnssFixStatus` | enum | MISSING |
| `SerializableImuSample` | struct | MISSING |
| `SerializableImuSampleKind` | enum | MISSING |
| `SerializableInsFilterState` | struct | MISSING |
| `SerializableLooseMeasurement` | struct | MISSING |
| `SerializableNavState` | struct | MISSING |
| `SerializableRateEndpoint` | struct | MISSING |
| `SerializableSatelliteId` | struct | MISSING |
| `SerializableStationarityDetectorSample` | struct | MISSING |
| `SerializableStoredCheckpoint` | struct | `fusion.rs` |
| `SerializableStoredGnssMeasurement` | enum | MISSING |
| `SerializableStoredImuSample` | struct | MISSING |
| `SerializableTightCarrierPhaseObservation` | struct | MISSING |
| `SerializableTightFilterState` | struct | MISSING |
| `SerializableTightGnssEpoch` | struct | MISSING |
| `SerializableTightGnssObservation` | struct | MISSING |
| `SerializableTightRangeRateObservation` | struct | MISSING |
| `SerializableTimeSyncHistory` | struct | MISSING |
| `SerializableTimeSyncHistoryConfig` | struct | MISSING |

## `sidereon_core::fusion::smoother`

| Item | Kind | Binding |
|---|---|---|
| `FusionRtsEpoch` | struct | `fusion.rs` |
| `FusionRtsHistory` | struct | `fusion.rs` |
| `FusionRtsHistoryBuilder` | struct | `fusion.rs` |
| `SmoothedFusionEpoch` | struct | `fusion.rs` |
| `SmoothedFusionTrajectory` | struct | `fusion.rs` |
| `smooth_fusion_rts` | fn | `fusion.rs` |

## `sidereon_core::fusion::state`

| Item | Kind | Binding |
|---|---|---|
| `ERROR_ACCEL_BIAS_INDEX` | const | MISSING |
| `ERROR_ACCEL_SCALE_INDEX` | const | MISSING |
| `ERROR_ATTITUDE_INDEX` | const | MISSING |
| `ERROR_GYRO_BIAS_INDEX` | const | MISSING |
| `ERROR_GYRO_SCALE_INDEX` | const | MISSING |
| `ERROR_MOUNTING_MISALIGNMENT_INDEX` | const | MISSING |
| `ERROR_MOUNTING_MISALIGNMENT_STATE_COUNT` | const | MISSING |
| `ERROR_POSITION_INDEX` | const | MISSING |
| `ERROR_STATE_DIMENSION_15` | const | MISSING |
| `ERROR_STATE_DIMENSION_21` | const | MISSING |
| `ERROR_VELOCITY_INDEX` | const | MISSING |
| `ErrorStateLayout` | enum | `fusion.rs` |
| `ErrorStateVector` | struct | MISSING |
| `FusionError` | enum | `fusion.rs` |
| `FusionFilterKind` | enum | `fusion.rs` |
| `InsFilterState` | struct | `fusion.rs` |
| `covariance_is_positive_semidefinite` | fn | MISSING |
| `reproject_covariance_psd` | fn | MISSING |
| `validate_covariance_matrix` | fn | MISSING |

## `sidereon_core::fusion::tight`

| Item | Kind | Binding |
|---|---|---|
| `TIGHT_CLOCK_BIAS_OFFSET` | const | MISSING |
| `TIGHT_CLOCK_DRIFT_OFFSET` | const | MISSING |
| `TIGHT_CLOCK_STATE_COUNT` | const | MISSING |
| `TightCarrierPhaseObservation` | struct | `fusion.rs` |
| `TightClockState` | struct | `fusion.rs` |
| `TightCouplingConfig` | struct | `fusion.rs` |
| `TightFilterSnapshot` | struct | `fusion.rs` |
| `TightGnssEpoch` | struct | `fusion.rs` |
| `TightGnssObservation` | struct | `fusion.rs` |
| `TightRangeRateObservation` | struct | `fusion.rs` |

## `sidereon_core::fusion::timesync`

| Item | Kind | Binding |
|---|---|---|
| `DEFAULT_TIME_SYNC_CHECKPOINT_CAPACITY` | const | MISSING |
| `DEFAULT_TIME_SYNC_IMU_CAPACITY` | const | MISSING |
| `InertialFilterSnapshot` | struct | `fusion.rs` |
| `StationarityDetectorSnapshotSample` | struct | MISSING |
| `TimeSyncHistoryConfig` | struct | `fusion.rs` |
| `TimeSyncHistoryStatus` | struct | `fusion.rs` |
| `TimeSyncUpdate` | struct | `fusion.rs` |
| `validate_time_sync_gnss_order` | fn | MISSING |
| `validate_time_sync_imu_order` | fn | MISSING |

## `sidereon_core::fusion::ukf`

| Item | Kind | Binding |
|---|---|---|
| `UkfUpdateOptions` | struct | `fusion.rs` |
| `UnscentedTransformOptions` | struct | `fusion.rs` |
| `ukf_correct_closed_loop` | fn | MISSING |

## `sidereon_core::geodesic`

| Item | Kind | Binding |
|---|---|---|
| `GeodesicError` | enum | `geodesic.rs` |
| `geodesic_direct` | fn | `geodesic.rs` |
| `geodesic_inverse` | fn | `geodesic.rs` |

## `sidereon_core::geodetic_time_series`

| Item | Kind | Binding |
|---|---|---|
| `GeodeticTimeSeriesError` | enum | `geodetic_time_series.rs` |
| `MidasComponentStats` | struct | `geodetic_time_series.rs` |
| `MidasOptions` | struct | `geodetic_time_series.rs` |
| `MotionField` | struct | `geodetic_time_series.rs` |
| `NetworkFrame` | struct | `geodetic_time_series.rs` |
| `NetworkStation` | struct | `geodetic_time_series.rs` |
| `PositionFrame` | enum | `geodetic_time_series.rs` |
| `PositionSample` | struct | `geodetic_time_series.rs` |
| `PositionSeries` | struct | `geodetic_time_series.rs` |
| `StationMotion` | struct | `geodetic_time_series.rs` |
| `StepCandidate` | struct | `geodetic_time_series.rs` |
| `StepDetectionHeuristic` | enum | MISSING |
| `StepDetectionOptions` | struct | `geodetic_time_series.rs` |
| `TimeSeriesQuality` | enum | `geodetic_time_series.rs` |
| `Trajectory` | struct | `geodetic_time_series.rs` |
| `TrajectoryComponent` | struct | `geodetic_time_series.rs` |
| `TrajectoryFitOptions` | struct | `geodetic_time_series.rs` |
| `TrajectoryModel` | struct | `geodetic_time_series.rs` |
| `TrajectoryTerm` | enum | `geodetic_time_series.rs` |
| `Velocity` | struct | `geodetic_time_series.rs` |
| `detect_steps` | fn | `geodetic_time_series.rs` |
| `fit_trajectory` | fn | `geodetic_time_series.rs` |
| `network_field` | fn | `geodetic_time_series.rs` |
| `velocity_midas` | fn | `geodetic_time_series.rs` |

## `sidereon_core::geofence`

| Item | Kind | Binding |
|---|---|---|
| `CrossingEvent` | struct | `geofence.rs` |
| `CrossingKind` | enum | `geofence.rs` |
| `Fence` | struct | `geofence.rs` |
| `GEOFENCE_BOUNDARY_TOLERANCE_M` | const | MISSING |
| `GeofenceError` | enum | `geofence.rs` |
| `GeofencePositionEstimate` | struct | `geofence.rs` |
| `PLANAR_FAST_PATH_MAX_RADIUS_M` | const | MISSING |
| `PositionUncertainty` | enum | `geofence.rs` |
| `ProbabilityHysteresis` | struct | `geofence.rs` |
| `ProbabilityMethod` | enum | `geofence.rs` |
| `ProbabilityOptions` | struct | `geofence.rs` |
| `containment` | fn | `geofence.rs` |
| `containment_probability` | fn | MISSING |
| `containment_probability_with_options` | fn | `geofence.rs` |
| `crossing` | fn | `bodies.rs`, `geofence.rs`, `iono.rs`, `observables.rs`, `passes.rs`, `rinex_obs.rs`, `trls.rs` |
| `crossing_probability` | fn | MISSING |
| `crossing_probability_with_options` | fn | `geofence.rs` |
| `distance_to_boundary` | fn | `geofence.rs` |

## `sidereon_core::geoid`

| Item | Kind | Binding |
|---|---|---|
| `Egm2008GridSpacing` | enum | `geoid.rs` |
| `Egm2008RasterWindow` | struct | `geoid.rs` |
| `GeoidError` | enum | `geoid.rs`, `terrain_store.rs` |
| `GeoidGrid` | struct | `geoid.rs` |
| `ProjVgridshiftArithmetic` | enum | `geoid.rs` |
| `ProjVgridshiftError` | enum | `geoid.rs` |
| `egm96_ellipsoidal_height_m` | fn | `geoid.rs` |
| `egm96_grid` | fn | MISSING |
| `egm96_orthometric_height_m` | fn | `geoid.rs` |
| `egm96_undulation` | fn | `geoid.rs` |
| `egm96_undulations_deg` | fn | `geoid.rs` |
| `egm96_undulations_rad` | fn | `geoid.rs` |
| `ellipsoidal_height_m` | fn | `geoid.rs` |
| `geoid_undulation` | fn | `geoid.rs` |
| `geoid_undulations_deg` | fn | `geoid.rs` |
| `geoid_undulations_rad` | fn | `geoid.rs` |
| `orthometric_height_m` | fn | `geoid.rs`, `terrain_store.rs` |

## `sidereon_core::geometry`

| Item | Kind | Binding |
|---|---|---|
| `DopAtEpoch` | struct | MISSING |
| `DopOptions` | struct | `geometry.rs` |
| `DopSeriesPoint` | struct | MISSING |
| `DopWeighting` | enum | `geometry.rs` |
| `Error` | type | `antex.rs`, `araim.rs`, `astro_observe_almanac.rs`, `astro_phase_b.rs`, `bias.rs`, `broadcast.rs`, `broadcast_comparison.rs`, `cdm.rs`, `clock_stability.rs`, `collision.rs`, `conjunction.rs`, `constellation.rs`, `covariance.rs`, `coverage.rs`, `drag.rs`, `eclipse.rs`, `elements.rs`, `ephemeris.rs`, `error_metrics.rs`, `errors.rs`, `forces.rs`, `geodetic_time_series.rs`, `inertial.rs`, `iono.rs`, `ndm_errors.rs`, `ntrip.rs`, `observable_states.rs`, `observables.rs`, `oem.rs`, `omm.rs`, `opm.rs`, `passes.rs`, `ppp_corrections.rs`, `precise_positioning.rs`, `precise_samples.rs`, `propagation.rs`, `qc.rs`, `reduced_orbit.rs`, `rf.rs`, `rinex_clock.rs`, `rinex_obs.rs`, `rinex_qc.rs`, `rtcm.rs`, `rtk_filter.rs`, `sbas.rs`, `sgp4_batch.rs`, `sidereal.rs`, `sp3.rs`, `spp.rs`, `ssr.rs`, `ssr_bias_exclusion.rs`, `tdm.rs`, `terrain_store.rs`, `tides.rs`, `time.rs`, `tle.rs`, `tropo.rs` |
| `VisibilityOptions` | struct | `geometry.rs` |
| `VisibilityPass` | struct | MISSING |
| `VisibilitySeriesPoint` | struct | MISSING |
| `VisibleSatellite` | struct | MISSING |
| `dop_at_epoch` | fn | `geometry.rs` |
| `dop_series` | fn | `geometry.rs` |
| `passes` | fn | `antex.rs`, `astro_observe_almanac.rs`, `bodies.rs`, `constellation.rs`, `coverage.rs`, `ephemeris.rs`, `geometry.rs`, `iono.rs`, `lib.rs`, `look_angle.rs`, `passes.rs`, `propagation.rs`, `qc.rs`, `sp3.rs`, `spp.rs`, `static_positioning.rs` |
| `sagnac_range_first_order_m` | fn | MISSING |
| `sagnac_range_first_order_m_with_rate` | fn | MISSING |
| `sagnac_rotate_ecef_m` | fn | MISSING |
| `sagnac_rotate_ecef_m_with_rate` | fn | MISSING |
| `visibility_series` | fn | `geometry.rs` |
| `visible` | fn | `geometry.rs` |
| `visible_at_elevation_mask` | fn | MISSING |

## `sidereon_core::geometry_quality`

| Item | Kind | Binding |
|---|---|---|
| `GeometryQuality` | struct | `geodetic_time_series.rs`, `geometry_quality.rs`, `orbit_determination.rs` |
| `GeometryQualityThresholds` | struct | MISSING |
| `ObservabilityTier` | enum | `geodetic_time_series.rs`, `geometry_quality.rs`, `orbit_determination.rs` |
| `classify` | fn | MISSING |

## `sidereon_core::has`

| Item | Kind | Binding |
|---|---|---|
| `HAS_CLOCK_DO_NOT_USE` | const | MISSING |
| `HAS_CLOCK_INVALID` | const | MISSING |
| `HAS_CODE_BIAS_INVALID` | const | MISSING |
| `HAS_ORBIT_ALONG_CROSS_INVALID` | const | MISSING |
| `HAS_ORBIT_RADIAL_INVALID` | const | MISSING |
| `HAS_PHASE_BIAS_INVALID` | const | MISSING |
| `HasClockBlock` | struct | MISSING |
| `HasClockCorrection` | struct | MISSING |
| `HasClockSystem` | struct | MISSING |
| `HasCodeBias` | struct | MISSING |
| `HasCodeBiasBlock` | struct | MISSING |
| `HasGnssMask` | struct | MISSING |
| `HasMaskBlock` | struct | MISSING |
| `HasMt1Context` | struct | MISSING |
| `HasMt1Header` | struct | MISSING |
| `HasMt1Message` | struct | MISSING |
| `HasOrbitBlock` | struct | MISSING |
| `HasOrbitCorrection` | struct | MISSING |
| `HasPhaseBias` | struct | MISSING |
| `HasPhaseBiasBlock` | struct | MISSING |
| `HasPhaseBiasConversion` | enum | MISSING |
| `dcm_multiplier` | fn | MISSING |
| `has_mt1_reference_j2000_s` | fn | MISSING |
| `has_validity_interval_s` | fn | MISSING |

## `sidereon_core::id`

| Item | Kind | Binding |
|---|---|---|
| `GnssSatelliteId` | struct | `araim.rs`, `astro_phase_b.rs`, `bias.rs`, `broadcast.rs`, `broadcast_comparison.rs`, `fusion.rs`, `geometry.rs`, `observable_states.rs`, `observables.rs`, `orbit_determination.rs`, `ppp_corrections.rs`, `precise_positioning.rs`, `precise_samples.rs`, `sbas.rs`, `sidereal.rs`, `sp3.rs`, `spp.rs`, `ssr.rs`, `ssr_bias_exclusion.rs`, `velocity.rs` |
| `GnssSystem` | enum | `araim.rs`, `broadcast.rs`, `broadcast_comparison.rs`, `constellation.rs`, `frequencies.rs`, `geometry.rs`, `iono.rs`, `nmea.rs`, `observables.rs`, `ppp_corrections.rs`, `precise_positioning.rs`, `rinex_obs.rs`, `rinex_qc.rs`, `rtcm.rs`, `rtk_filter.rs`, `sp3.rs`, `spp.rs`, `ssr_bias_exclusion.rs`, `velocity.rs` |
| `SatelliteIdError` | enum | `rtcm.rs` |

## `sidereon_core::ils`

| Item | Kind | Binding |
|---|---|---|
| `IlsError` | enum | `ils.rs`, `precise_positioning.rs`, `rtk_filter.rs` |
| `IlsResult` | struct | `ils.rs` |
| `bounded_ils_search` | fn | `ils.rs` |
| `lambda_ils_search` | fn | `ils.rs` |

## `sidereon_core::inertial`

| Item | Kind | Binding |
|---|---|---|
| `InertialError` | enum | `inertial.rs` |

## `sidereon_core::inertial::config`

| Item | Kind | Binding |
|---|---|---|
| `ConingCorrection` | enum | `fusion.rs` |
| `ImuGrade` | enum | `fusion.rs` |
| `ImuSpec` | struct | `fusion.rs` |
| `MechanizationConfig` | struct | `fusion.rs` |
| `RANDOM_WALK_BIAS_TAU_S` | const | MISSING |
| `gauss_markov_bias_decay` | fn | `inertial.rs` |
| `gauss_markov_bias_variance_increment` | fn | `inertial.rs` |

## `sidereon_core::inertial::frames`

| Item | Kind | Binding |
|---|---|---|
| `WGS84_NORMAL_GRAVITY_EQUATOR_MPS2` | const | MISSING |
| `WGS84_NORMAL_GRAVITY_POLE_MPS2` | const | MISSING |
| `WGS84_SOMIGLIANA_K` | const | MISSING |
| `gravity_ecef_mps2` | fn | `inertial.rs` |
| `normal_gravity_mps2` | fn | `inertial.rs` |

## `sidereon_core::inertial::imu`

| Item | Kind | Binding |
|---|---|---|
| `CorrectedImuIncrement` | struct | `fusion.rs` |
| `ImuBias` | struct | `fusion.rs` |
| `ImuCalibration` | struct | `fusion.rs` |
| `ImuErrorModel` | struct | `fusion.rs` |
| `ImuSample` | struct | `fusion.rs` |
| `ImuSampleKind` | enum | `fusion.rs` |

## `sidereon_core::inertial::mechanization`

| Item | Kind | Binding |
|---|---|---|
| `StrapdownMechanizer` | struct | `fusion.rs` |
| `mechanize_ecef` | fn | MISSING |
| `rodrigues_delta_dcm` | fn | MISSING |

## `sidereon_core::inertial::sim`

| Item | Kind | Binding |
|---|---|---|
| `DEFAULT_IMU_SIM_SEED` | const | `fusion.rs` |
| `ImuRateRandomWalk` | struct | `fusion.rs` |
| `ImuSimulationOptions` | struct | `fusion.rs` |
| `ImuSimulationOutput` | enum | `fusion.rs` |
| `ImuSimulator` | struct | `fusion.rs` |
| `SimulatedImuSequence` | struct | MISSING |
| `simulate_imu_samples` | fn | `fusion.rs` |
| `simulate_imu_samples_from_increments` | fn | `fusion.rs` |
| `true_imu_increment_between` | fn | `fusion.rs` |

## `sidereon_core::inertial::state`

| Item | Kind | Binding |
|---|---|---|
| `AttitudeQuaternion` | struct | `inertial.rs` |
| `NavState` | struct | `fusion.rs` |
| `attitude_yaw_pitch_roll_rad` | fn | `inertial.rs` |
| `dcm_to_quaternion` | fn | `inertial.rs` |
| `quaternion_to_dcm` | fn | `inertial.rs` |
| `reorthonormalize_dcm` | fn | MISSING |

## `sidereon_core::integrity`

| Item | Kind | Binding |
|---|---|---|
| `ErrorEllipse2` | struct | `covariance.rs` |
| `IntegrityError` | enum | MISSING |
| `error_ellipse_2x2` | fn | `covariance.rs` |
| `error_ellipse_2x2_unit` | fn | MISSING |
| `metric_cross` | fn | MISSING |
| `metric_sigma` | fn | MISSING |

## `sidereon_core::ionex`

| Item | Kind | Binding |
|---|---|---|
| `GalileoNequickCoeffs` | struct | `iono.rs` |
| `GalileoNequickEval` | struct | MISSING |
| `IonexCoverageError` | enum | `iono.rs`, `observables.rs`, `spp.rs` |
| `IonexCoveragePolicy` | enum | `iono.rs` |
| `IonexEpochError` | enum | `spp.rs`, `staleness.rs` |
| `IonexMappingPolicy` | enum | `iono.rs`, `spp.rs` |
| `IonexMissingNodePolicy` | enum | `iono.rs` |
| `IonexMissingNodes` | struct | `iono.rs`, `observables.rs` |
| `IonexNodeGap` | struct | `iono.rs`, `spp.rs` |
| `IonexSlantDelayEvaluation` | struct | `iono.rs` |
| `IonexSlantDelayStatus` | struct | `iono.rs` |
| `IonexSlantPolicy` | struct | `iono.rs` |
| `IonexSlantRefusal` | enum | `iono.rs`, `observables.rs`, `spp.rs` |
| `IonexSlantRequest` | struct | `iono.rs` |
| `IonoModel` | enum | `iono.rs`, `observables.rs` |
| `KlobucharParams` | struct | `iono.rs`, `observables.rs` |
| `galileo_effective_ionisation_level` | fn | MISSING |
| `galileo_nequick_g_native` | fn | MISSING |
| `ionex_slant_delay` | fn | MISSING |
| `ionex_slant_delay_results` | fn | `iono.rs` |
| `ionex_slant_delay_with_policy` | fn | `iono.rs` |
| `ionex_slant_delays` | fn | MISSING |
| `ionosphere_delay` | fn | `iono.rs` |
| `klobuchar` | fn | `observables.rs`, `spp.rs` |
| `klobuchar_native` | fn | `iono.rs` |

## `sidereon_core::ionex::grid`

| Item | Kind | Binding |
|---|---|---|
| `Ionex` | struct | `data.rs`, `iono.rs`, `observables.rs`, `staleness.rs` |

## `sidereon_core::ionex::header`

| Item | Kind | Binding |
|---|---|---|
| `IonexAssumedMapping` | enum | `iono.rs` |
| `IonexHeader` | struct | `iono.rs` |
| `IonexMappingDeclaration` | enum | `iono.rs`, `observables.rs`, `spp.rs` |
| `IonexMappingFunction` | enum | `iono.rs`, `observables.rs` |
| `IonexWarning` | enum | `iono.rs` |

## `sidereon_core::ionex::nequick_g`

| Item | Kind | Binding |
|---|---|---|
| `NequickGRayEval` | struct | `iono.rs` |
| `nequick_g_delay_m` | fn | `iono.rs` |
| `nequick_g_stec_tecu` | fn | `iono.rs` |

## `sidereon_core::ionex::samples`

| Item | Kind | Binding |
|---|---|---|
| `TecGridSamples` | struct | `iono.rs` |
| `TecSample` | struct | `iono.rs` |
| `TecSamplesError` | enum | `iono.rs` |

## `sidereon_core::ionex::tec_grid`

| Item | Kind | Binding |
|---|---|---|
| `TecGrid` | struct | `iono.rs` |
| `TecGridDelayXyzConversion` | struct | `iono.rs` |
| `TecGridDelayXyzStep` | enum | `iono.rs` |
| `TecGridEpoch` | struct | `iono.rs` |
| `TecGridError` | enum | `iono.rs` |
| `TecGridEvalOptions` | struct | `iono.rs` |
| `TecGridEvaluation` | struct | `iono.rs` |
| `TecGridShellGeometry` | struct | MISSING |
| `TecGridXyzConversion` | struct | `iono.rs` |
| `TecGridXyzStep` | enum | `iono.rs` |
| `TecGridXyzTarget` | enum | MISSING |

## `sidereon_core::navigation::lnav`

| Item | Kind | Binding |
|---|---|---|
| `LnavDecoded` | struct | `lnav.rs` |
| `LnavError` | enum | `lnav.rs` |
| `LnavField` | enum | MISSING |
| `LnavNumber` | enum | `lnav.rs` |
| `LnavOptions` | struct | `lnav.rs` |
| `LnavParams` | struct | `lnav.rs` |
| `PREAMBLE` | const | `lnav.rs` |
| `SUBFRAME_LENGTH` | const | `lnav.rs` |
| `WORD_LENGTH` | const | `lnav.rs` |
| `decode` | fn | `angles.rs`, `astro_observe_almanac.rs`, `bodies.rs`, `carrier_phase.rs`, `cdm.rs`, `collision.rs`, `constellation.rs`, `covariance.rs`, `drag.rs`, `eclipse.rs`, `iono.rs`, `lib.rs`, `lnav.rs`, `observable_states.rs`, `observables.rs`, `oem.rs`, `omm.rs`, `opm.rs`, `passes.rs`, `precise_positioning.rs`, `precise_samples.rs`, `propagation.rs`, `qc.rs`, `reduced_orbit.rs`, `rinex_obs.rs`, `rtcm.rs`, `rtk_filter.rs`, `sbas.rs`, `spp.rs`, `ssr.rs`, `ssr_bias_exclusion.rs`, `tides.rs`, `tle.rs`, `unix_compress.rs` |
| `encode` | fn | `antex.rs`, `araim.rs`, `astro_observe_almanac.rs`, `astro_phase_b.rs`, `bias.rs`, `bodies.rs`, `broadcast.rs`, `broadcast_comparison.rs`, `cache_lock.rs`, `carrier_phase.rs`, `cdm.rs`, `clock_stability.rs`, `collision.rs`, `conjunction.rs`, `constellation.rs`, `covariance.rs`, `covariance_transport.rs`, `coverage.rs`, `data.rs`, `dgnss.rs`, `drag.rs`, `eclipse.rs`, `elements.rs`, `ephemeris.rs`, `error_metrics.rs`, `errors.rs`, `frame_catalog.rs`, `frequencies.rs`, `fusion.rs`, `geodesic.rs`, `geodetic_time_series.rs`, `geofence.rs`, `geoid.rs`, `geometry.rs`, `geometry_quality.rs`, `ils.rs`, `iod.rs`, `iono.rs`, `lib.rs`, `lnav.rs`, `look_angle.rs`, `ndm_errors.rs`, `nmea.rs`, `normality.rs`, `ntrip.rs`, `observable_states.rs`, `observables.rs`, `oem.rs`, `omm.rs`, `opm.rs`, `orbit_determination.rs`, `passes.rs`, `ppp_corrections.rs`, `precise_positioning.rs`, `precise_samples.rs`, `primitive_estimation.rs`, `propagation.rs`, `qc.rs`, `reduced_orbit.rs`, `reliability.rs`, `rinex_clock.rs`, `rinex_obs.rs`, `rinex_qc.rs`, `rtcm.rs`, `rtk.rs`, `rtk_filter.rs`, `sbas.rs`, `scenario.rs`, `sgp4_batch.rs`, `sidereal.rs`, `signal.rs`, `source_localization.rs`, `sp3.rs`, `space_weather.rs`, `spp.rs`, `ssr.rs`, `staleness.rs`, `static_positioning.rs`, `tdm.rs`, `terrain_store.rs`, `tides.rs`, `time.rs`, `tle.rs`, `tle_fit.rs`, `track_estimation.rs`, `trls.rs`, `velocity.rs` |
| `parity` | fn | `lnav.rs`, `rtk_filter.rs`, `trls.rs` |
| `parity_valid` | fn | `lnav.rs` |
| `subframe_id` | fn | `lnav.rs` |
| `tow` | fn | `lnav.rs` |

## `sidereon_core::nmea`

| Item | Kind | Binding |
|---|---|---|
| `NmeaError` | enum | `nmea.rs` |
| `NmeaLog` | struct | MISSING |
| `group_epochs` | fn | `nmea.rs` |
| `parse_nmea` | fn | MISSING |
| `parse_nmea_str` | fn | `nmea.rs` |
| `parse_sentence` | fn | `nmea.rs` |

## `sidereon_core::nmea::epoch`

| Item | Kind | Binding |
|---|---|---|
| `EpochSnapshot` | struct | `nmea.rs` |
| `GsaEntry` | struct | `nmea.rs` |
| `GsvGroup` | struct | `nmea.rs` |
| `NmeaAccumulator` | struct | `nmea.rs` |
| `NmeaChunkOutput` | struct | `nmea.rs` |

## `sidereon_core::nmea::fields`

| Item | Kind | Binding |
|---|---|---|
| `Gga` | struct | `nmea.rs` |
| `GgaQuality` | enum | `nmea.rs` |
| `Gll` | struct | `nmea.rs` |
| `Gsa` | struct | `nmea.rs` |
| `GsaFixMode` | enum | `nmea.rs` |
| `GsaSelectionMode` | enum | `nmea.rs` |
| `Gst` | struct | `bias.rs`, `broadcast.rs`, `nmea.rs`, `reduced_orbit.rs`, `sbas.rs`, `sp3.rs`, `ssr.rs`, `time.rs` |
| `Gsv` | struct | `nmea.rs` |
| `GsvSatellite` | struct | `nmea.rs` |
| `NmeaCoordinate` | struct | `nmea.rs` |
| `NmeaDate` | struct | `nmea.rs` |
| `NmeaSatNumber` | struct | `nmea.rs` |
| `NmeaSignalId` | struct | `nmea.rs` |
| `NmeaTalker` | enum | `nmea.rs` |
| `NmeaTime` | struct | `nmea.rs` |
| `Rmc` | struct | `nmea.rs` |
| `RmcStatus` | enum | `nmea.rs` |
| `Vtg` | struct | `nmea.rs` |
| `Zda` | struct | `nmea.rs` |

## `sidereon_core::nmea::sentence`

| Item | Kind | Binding |
|---|---|---|
| `NmeaBody` | enum | `nmea.rs` |
| `NmeaSentence` | struct | `nmea.rs` |

## `sidereon_core::nmea::write`

| Item | Kind | Binding |
|---|---|---|
| `write_gga` | fn | `nmea.rs` |

## `sidereon_core::ntrip::chunk`

| Item | Kind | Binding |
|---|---|---|
| `ChunkedDecoder` | struct | MISSING |

## `sidereon_core::ntrip::gga`

| Item | Kind | Binding |
|---|---|---|
| `GgaPosition` | struct | `ntrip.rs` |
| `format_gga` | fn | `ntrip.rs` |

## `sidereon_core::ntrip::machine`

| Item | Kind | Binding |
|---|---|---|
| `NtripClientMachine` | struct | `ntrip.rs` |
| `NtripEvent` | enum | `ntrip.rs` |
| `NtripHandshake` | struct | `ntrip.rs` |
| `NtripState` | enum | `ntrip.rs` |

## `sidereon_core::ntrip::request`

| Item | Kind | Binding |
|---|---|---|
| `NtripConfig` | struct | `ntrip.rs` |
| `NtripCredentials` | struct | `ntrip.rs` |
| `NtripVersion` | enum | `ntrip.rs` |

## `sidereon_core::ntrip::response`

| Item | Kind | Binding |
|---|---|---|
| `HttpClassification` | enum | `ntrip.rs` |
| `NtripRejection` | enum | `ntrip.rs` |
| `classify_http_response` | fn | `ntrip.rs` |

## `sidereon_core::ntrip::sourcetable`

| Item | Kind | Binding |
|---|---|---|
| `CasRecord` | struct | `ntrip.rs` |
| `Field` | enum | `ndm_errors.rs`, `ntrip.rs` |
| `NetRecord` | struct | `ntrip.rs` |
| `OtherRecord` | struct | `ntrip.rs` |
| `Sourcetable` | struct | `ntrip.rs` |
| `SourcetableRecord` | enum | `ntrip.rs` |
| `StrAuth` | enum | `ntrip.rs` |
| `StrRecord` | struct | `ntrip.rs` |
| `parse_sourcetable` | fn | `ntrip.rs` |

## `sidereon_core::observables`

| Item | Kind | Binding |
|---|---|---|
| `AppliedMediaCorrections` | struct | MISSING |
| `EmissionMediaBatch` | struct | `observables.rs` |
| `EmissionMediaBatchOptions` | struct | `observables.rs` |
| `EmissionMediaReceiverContext` | struct | MISSING |
| `EmissionMediaStatus` | enum | `observables.rs` |
| `MediaPredictOptions` | struct | MISSING |
| `MediaPredictedObservables` | struct | MISSING |
| `MediaRangePrediction` | struct | MISSING |
| `NOMINAL_SIGNAL_FLIGHT_TIME_S` | const | MISSING |
| `OBSERVABLE_STATE_MISSING_POSITION_ECEF_M` | const | `observable_states.rs` |
| `ObservableEphemerisSource` | trait | `observable_states.rs`, `observables.rs` |
| `ObservableIonosphereCorrection` | enum | `observables.rs` |
| `ObservableMediaOptions` | struct | `observables.rs` |
| `ObservableState` | struct | MISSING |
| `ObservableStateBatch` | struct | `observable_states.rs` |
| `ObservableStateElementStatus` | enum | `observable_states.rs` |
| `ObservableTroposphereCorrection` | struct | `observables.rs` |
| `ObservablesError` | enum | `observable_states.rs`, `observables.rs` |
| `ObservablesInputErrorKind` | enum | `observables.rs` |
| `PredictOptions` | struct | `observables.rs` |
| `PredictRequest` | type | `observables.rs` |
| `PredictedObservables` | struct | `observables.rs` |
| `RangePrediction` | struct | `observables.rs` |
| `RangePredictionRequest` | struct | `observables.rs` |
| `TransmitGeometry` | struct | MISSING |
| `TransmitTimeOptions` | struct | MISSING |
| `TransmitTimeSatelliteState` | struct | MISSING |
| `emission_media_batch_at_j2000_s` | fn | `observables.rs` |
| `emission_media_batch_at_j2000_s_into` | fn | MISSING |
| `emission_media_batch_at_j2000_s_with_receiver_context_into` | fn | MISSING |
| `flight_time_seed_s` | fn | MISSING |
| `is_observable_state_gap` | fn | MISSING |
| `j2000_seconds_from_split` | fn | `geometry.rs`, `lib.rs`, `observables.rs`, `ppp_corrections.rs`, `precise_positioning.rs`, `velocity.rs` |
| `observable_media_corrections` | fn | MISSING |
| `observable_states_at_j2000_s` | fn | `observable_states.rs` |
| `observable_states_at_shared_j2000_s` | fn | `observable_states.rs` |
| `predict` | fn | `observables.rs`, `passes.rs`, `track_estimation.rs` |
| `predict_batch` | fn | `observables.rs` |
| `predict_batch_parallel` | fn | MISSING |
| `predict_batch_with_media` | fn | MISSING |
| `predict_batch_with_media_parallel` | fn | MISSING |
| `predict_ranges` | fn | `observables.rs` |
| `predict_ranges_with_media` | fn | MISSING |
| `predict_transmit_geometry` | fn | MISSING |
| `predict_with_media` | fn | MISSING |
| `pseudorange_clock_epoch_j2000_s` | fn | MISSING |
| `pseudorange_transmit_epoch_from_clock_j2000_s` | fn | MISSING |
| `pseudorange_transmit_epoch_j2000_s` | fn | `observables.rs` |
| `pseudorange_transmit_geometry` | fn | `observables.rs` |
| `pseudorange_transmit_satellite_state` | fn | MISSING |
| `pseudorange_transmit_velocity_m_s` | fn | MISSING |
| `transmit_epoch_j2000_s` | fn | MISSING |
| `transmit_time_satellite_state` | fn | MISSING |
| `transmit_velocity_m_s` | fn | MISSING |

## `sidereon_core::observation_qc`

| Item | Kind | Binding |
|---|---|---|
| `ClockJump` | struct | `rinex_qc.rs` |
| `CycleSlipQc` | struct | `rinex_qc.rs` |
| `DEFAULT_CLOCK_JUMP_THRESHOLD_S` | const | `rinex_qc.rs` |
| `IntervalSource` | enum | `rinex_qc.rs` |
| `ObservationDataGap` | struct | `rinex_qc.rs` |
| `ObservationQcAntenna` | struct | `rinex_qc.rs` |
| `ObservationQcError` | enum | `rinex_qc.rs` |
| `ObservationQcFinding` | struct | `rinex_qc.rs` |
| `ObservationQcHeader` | struct | `rinex_qc.rs` |
| `ObservationQcNote` | enum | `rinex_qc.rs` |
| `ObservationQcOptions` | struct | `rinex_qc.rs` |
| `ObservationQcReceiver` | struct | `rinex_qc.rs` |
| `ObservationQcReport` | struct | `rinex_qc.rs` |
| `ObservationQcTime` | struct | `rinex_qc.rs` |
| `SatelliteObservationQc` | struct | `rinex_qc.rs` |
| `SatelliteSignalQc` | struct | `rinex_qc.rs` |
| `SnrStats` | struct | `rinex_qc.rs` |
| `SsiHistogram` | struct | `rinex_qc.rs` |
| `SystemCycleSlipQc` | struct | `rinex_qc.rs` |
| `SystemObservationQc` | struct | `rinex_qc.rs` |
| `SystemSignalQc` | struct | `rinex_qc.rs` |
| `aggregate_cycle_slips` | fn | MISSING |
| `detect_clock_jumps` | fn | MISSING |
| `observation_qc` | fn | `rinex_qc.rs` |
| `observation_qc_with_options` | fn | `rinex_qc.rs` |

## `sidereon_core::observation_qc::multipath`

| Item | Kind | Binding |
|---|---|---|
| `MpStats` | struct | `rinex_qc.rs` |
| `MultipathReport` | struct | `rinex_qc.rs` |
| `SatelliteMultipathQc` | struct | `rinex_qc.rs` |
| `SystemMultipathQc` | struct | `rinex_qc.rs` |
| `arc_multipath_rms` | fn | MISSING |
| `mp_combination` | fn | MISSING |
| `multipath_stats` | fn | MISSING |

## `sidereon_core::observation_qc::report_html`

| Item | Kind | Binding |
|---|---|---|
| `render_html` | fn | `rinex_qc.rs` |

## `sidereon_core::observation_qc::report_text`

| Item | Kind | Binding |
|---|---|---|
| `render_text` | fn | `rinex_qc.rs` |

## `sidereon_core::orbit`

| Item | Kind | Binding |
|---|---|---|
| `Error` | type | `antex.rs`, `araim.rs`, `astro_observe_almanac.rs`, `astro_phase_b.rs`, `bias.rs`, `broadcast.rs`, `broadcast_comparison.rs`, `cdm.rs`, `clock_stability.rs`, `collision.rs`, `conjunction.rs`, `constellation.rs`, `covariance.rs`, `coverage.rs`, `drag.rs`, `eclipse.rs`, `elements.rs`, `ephemeris.rs`, `error_metrics.rs`, `errors.rs`, `forces.rs`, `geodetic_time_series.rs`, `inertial.rs`, `iono.rs`, `ndm_errors.rs`, `ntrip.rs`, `observable_states.rs`, `observables.rs`, `oem.rs`, `omm.rs`, `opm.rs`, `passes.rs`, `ppp_corrections.rs`, `precise_positioning.rs`, `precise_samples.rs`, `propagation.rs`, `qc.rs`, `reduced_orbit.rs`, `rf.rs`, `rinex_clock.rs`, `rinex_obs.rs`, `rinex_qc.rs`, `rtcm.rs`, `rtk_filter.rs`, `sbas.rs`, `sgp4_batch.rs`, `sidereal.rs`, `sp3.rs`, `spp.rs`, `ssr.rs`, `ssr_bias_exclusion.rs`, `tdm.rs`, `terrain_store.rs`, `tides.rs`, `time.rs`, `tle.rs`, `tropo.rs` |
| `ReducedOrbitModel` | type | MISSING |

## `sidereon_core::orbit_determination`

| Item | Kind | Binding |
|---|---|---|
| `OrbitArcSpan` | struct | MISSING |
| `OrbitFitCovariance` | enum | `orbit_determination.rs` |
| `OrbitFitError` | enum | `orbit_determination.rs` |
| `OrbitFitOptions` | struct | `orbit_determination.rs` |
| `OrbitFitReport` | struct | `orbit_determination.rs` |
| `OrbitFitSolution` | struct | `orbit_determination.rs` |
| `OrbitResidualLedger` | struct | `orbit_determination.rs` |
| `OrbitResidualStats` | struct | `orbit_determination.rs` |
| `OrientedPreciseEphemerisStateSample` | struct | MISSING |
| `Ut1ProviderRole` | enum | MISSING |
| `fit_all_sp3_ecef_precise_orbits` | fn | `orbit_determination.rs` |
| `fit_all_sp3_ecef_precise_orbits_with_validity` | fn | MISSING |
| `fit_all_sp3_precise_orbits` | fn | MISSING |
| `fit_all_sp3_precise_orbits_with_validity` | fn | MISSING |
| `fit_precise_ephemeris_sample_orbit` | fn | `orbit_determination.rs` |
| `fit_precise_ephemeris_sample_orbit_with_initial_state` | fn | MISSING |
| `fit_precise_ephemeris_sample_orbit_with_initial_state_with_validity` | fn | MISSING |
| `fit_precise_ephemeris_sample_orbit_with_validity` | fn | MISSING |
| `fit_precise_ephemeris_sample_orbits` | fn | MISSING |
| `fit_precise_ephemeris_sample_orbits_with_validity` | fn | MISSING |
| `fit_precise_ephemeris_state_sample_orbit` | fn | MISSING |
| `fit_precise_ephemeris_state_sample_orbit_with_validity` | fn | MISSING |
| `fit_precise_ephemeris_state_sample_orbits` | fn | MISSING |
| `fit_precise_ephemeris_state_sample_orbits_with_validity` | fn | MISSING |
| `fit_sp3_ecef_precise_orbit` | fn | `orbit_determination.rs` |
| `fit_sp3_ecef_precise_orbit_with_validity` | fn | MISSING |
| `fit_sp3_ecef_precise_orbits` | fn | `orbit_determination.rs` |
| `fit_sp3_ecef_precise_orbits_with_validity` | fn | MISSING |
| `fit_sp3_precise_orbit` | fn | `orbit_determination.rs` |
| `fit_sp3_precise_orbit_with_initial_state` | fn | MISSING |
| `fit_sp3_precise_orbit_with_initial_state_with_validity` | fn | MISSING |
| `fit_sp3_precise_orbit_with_validity` | fn | MISSING |
| `fit_sp3_precise_orbits` | fn | MISSING |
| `fit_sp3_precise_orbits_with_validity` | fn | MISSING |

## `sidereon_core::positioning`

| Item | Kind | Binding |
|---|---|---|
| `Error` | type | `antex.rs`, `araim.rs`, `astro_observe_almanac.rs`, `astro_phase_b.rs`, `bias.rs`, `broadcast.rs`, `broadcast_comparison.rs`, `cdm.rs`, `clock_stability.rs`, `collision.rs`, `conjunction.rs`, `constellation.rs`, `covariance.rs`, `coverage.rs`, `drag.rs`, `eclipse.rs`, `elements.rs`, `ephemeris.rs`, `error_metrics.rs`, `errors.rs`, `forces.rs`, `geodetic_time_series.rs`, `inertial.rs`, `iono.rs`, `ndm_errors.rs`, `ntrip.rs`, `observable_states.rs`, `observables.rs`, `oem.rs`, `omm.rs`, `opm.rs`, `passes.rs`, `ppp_corrections.rs`, `precise_positioning.rs`, `precise_samples.rs`, `propagation.rs`, `qc.rs`, `reduced_orbit.rs`, `rf.rs`, `rinex_clock.rs`, `rinex_obs.rs`, `rinex_qc.rs`, `rtcm.rs`, `rtk_filter.rs`, `sbas.rs`, `sgp4_batch.rs`, `sidereal.rs`, `sp3.rs`, `spp.rs`, `ssr.rs`, `ssr_bias_exclusion.rs`, `tdm.rs`, `terrain_store.rs`, `tides.rs`, `time.rs`, `tle.rs`, `tropo.rs` |
| `RinexSppAssemblySource` | trait | MISSING |
| `RinexSppBroadcastCorrections` | struct | MISSING |
| `RinexSppEpochInputs` | struct | `spp.rs` |
| `RinexSppEpochSolution` | struct | `spp.rs` |
| `RinexSppError` | enum | `spp.rs` |
| `RinexSppOptions` | struct | `rtk_filter.rs`, `spp.rs` |
| `RinexSppSource` | struct | MISSING |
| `RtcmSppEpochInputs` | struct | MISSING |
| `Solution` | type | `qc.rs`, `spp.rs` |
| `solve_spp_from_rinex_obs` | fn | `spp.rs` |
| `solve_spp_from_rinex_obs_exact` | fn | MISSING |
| `solve_spp_from_rinex_obs_exact_with_policy` | fn | MISSING |
| `spp_inputs_from_rinex_obs` | fn | `spp.rs` |
| `spp_inputs_from_rtcm_msm` | fn | MISSING |

## `sidereon_core::ppp_corrections`

| Item | Kind | Binding |
|---|---|---|
| `CivilDateTime` | struct | `ppp_corrections.rs`, `precise_positioning.rs` |
| `CodeBiasOptions` | struct | MISSING |
| `EpochVectorCorrection` | struct | `ppp_corrections.rs` |
| `PoleTideOptions` | struct | `ppp_corrections.rs` |
| `PppCorrectionEpoch` | struct | `ppp_corrections.rs` |
| `PppCorrectionObservation` | struct | `ppp_corrections.rs` |
| `PppCorrections` | struct | MISSING |
| `PppCorrectionsError` | enum | MISSING |
| `PppCorrectionsOptions` | struct | `ppp_corrections.rs`, `precise_positioning.rs` |
| `SatScalarCorrection` | struct | `ppp_corrections.rs` |
| `SatVectorCorrection` | struct | `ppp_corrections.rs` |
| `SatelliteAntenna` | struct | `ppp_corrections.rs`, `precise_positioning.rs` |
| `SatelliteAntennaFrequency` | struct | `ppp_corrections.rs`, `precise_positioning.rs` |
| `SatelliteAntennaOptions` | struct | `ppp_corrections.rs`, `precise_positioning.rs` |
| `build` | fn | `collision.rs`, `ntrip.rs`, `precise_samples.rs`, `propagation.rs`, `rtk_filter.rs`, `sp3.rs`, `ssr_bias_exclusion.rs`, `tdm.rs`, `tides.rs`, `time.rs` |
| `build_with_validity` | fn | MISSING |
| `build_with_validity_and_tide_constants` | fn | `ppp_corrections.rs` |

## `sidereon_core::precise_positioning::auto_init`

| Item | Kind | Binding |
|---|---|---|
| `PppAutoInitError` | enum | `precise_positioning.rs` |
| `PppAutoInitOptions` | struct | `precise_positioning.rs` |
| `PppAutoInitStrategy` | enum | MISSING |
| `PppInitialGuess` | struct | `precise_positioning.rs` |
| `solve_ppp_auto_init_fixed` | fn | `precise_positioning.rs` |
| `solve_ppp_auto_init_fixed_with_strategy` | fn | MISSING |
| `solve_ppp_auto_init_float` | fn | `precise_positioning.rs` |
| `solve_ppp_auto_init_float_with_strategy` | fn | MISSING |

## `sidereon_core::precise_positioning`

| Item | Kind | Binding |
|---|---|---|
| `build_ppp_lookup` | fn | `precise_positioning.rs` |
| `build_ppp_lookup_with_validity` | fn | MISSING |

## `sidereon_core::precise_positioning::cycle_slip`

| Item | Kind | Binding |
|---|---|---|
| `CycleSlipConfig` | struct | MISSING |
| `CycleSlipConfigError` | enum | MISSING |
| `CycleSlipDetectorState` | struct | MISSING |
| `CycleSlipError` | enum | MISSING |
| `CycleSlipFlagEpoch` | struct | MISSING |
| `CycleSlipFlagObservation` | struct | MISSING |
| `CycleSlipStateKey` | type | MISSING |
| `DEFAULT_MINIMUM_ARC_LENGTH` | const | MISSING |
| `DEFAULT_RUNNING_STATISTIC_K_FACTOR` | const | MISSING |
| `GeometryFreeUpdate` | struct | MISSING |
| `MelbourneWubbenaUpdate` | struct | MISSING |
| `RunningMeanVariance` | struct | MISSING |
| `SatelliteCycleSlipState` | struct | MISSING |
| `detect_cycle_slips` | fn | `carrier_phase.rs` |
| `geometry_free_m` | fn | MISSING |
| `melbourne_wubbena_cycles` | fn | MISSING |
| `update_geometry_free` | fn | MISSING |
| `update_melbourne_wubbena` | fn | MISSING |

## `sidereon_core::precise_positioning::fixed`

| Item | Kind | Binding |
|---|---|---|
| `solve_fixed_from_float` | fn | `precise_positioning.rs` |

## `sidereon_core::precise_positioning::float`

| Item | Kind | Binding |
|---|---|---|
| `solve_float_epoch` | fn | `precise_positioning.rs` |
| `solve_float_epochs` | fn | `precise_positioning.rs` |

## `sidereon_core::precise_positioning::kinematic`

| Item | Kind | Binding |
|---|---|---|
| `KinematicConfig` | struct | MISSING |
| `KinematicEpochSolution` | struct | `error_metrics.rs` |
| `KinematicEpochStatus` | enum | `error_metrics.rs` |
| `KinematicMotionModel` | enum | MISSING |
| `KinematicPositionProcessNoise` | enum | MISSING |
| `KinematicProcessNoise` | struct | MISSING |
| `KinematicSolveError` | enum | MISSING |
| `KinematicState` | struct | MISSING |
| `KinematicUpdateSummary` | struct | MISSING |
| `correct_kinematic_state` | fn | MISSING |
| `predict_kinematic_state` | fn | MISSING |
| `solve_kinematic_ppp` | fn | MISSING |

## `sidereon_core::precise_positioning::prep`

| Item | Kind | Binding |
|---|---|---|
| `DualFrequencyEpoch` | struct | MISSING |
| `DualFrequencyObservation` | struct | MISSING |
| `FloatCycleSlipEpoch` | struct | MISSING |
| `FloatCycleSlipObservation` | struct | MISSING |
| `FloatCycleSlipTaggedEpoch` | struct | MISSING |
| `FloatCycleSlipTaggedObservation` | struct | MISSING |
| `PppSplitArc` | struct | MISSING |
| `PreparedFloatEpoch` | struct | MISSING |
| `PreparedFloatObservation` | struct | MISSING |
| `WideLanePrepError` | enum | MISSING |
| `WideLanePrepOptions` | struct | MISSING |
| `WideLanePrepResult` | struct | MISSING |
| `prepare_widelane_fixed_epochs` | fn | MISSING |
| `split_float_cycle_slip_epochs` | fn | MISSING |

## `sidereon_core::precise_positioning::raim`

| Item | Kind | Binding |
|---|---|---|
| `ProtectionLevels` | struct | MISSING |
| `RaimConfig` | struct | MISSING |
| `RaimError` | enum | MISSING |
| `RaimFdeError` | enum | MISSING |
| `RaimFdeResult` | struct | MISSING |
| `RaimFdeStatus` | enum | MISSING |
| `RaimGeometryRow` | struct | MISSING |
| `RaimIdentification` | struct | MISSING |
| `RaimResult` | struct | `qc.rs` |
| `RaimStatus` | enum | MISSING |
| `SatelliteTestStatistic` | struct | MISSING |
| `fde_float_epoch` | fn | MISSING |
| `global_test` | fn | `qc.rs` |
| `global_test_with_geometry` | fn | MISSING |
| `per_satellite_statistics` | fn | MISSING |
| `protection_levels` | fn | MISSING |
| `solve_float_epoch_with_raim` | fn | MISSING |

## `sidereon_core::precise_positioning::tec`

| Item | Kind | Binding |
|---|---|---|
| `CodeSlantTecEstimate` | struct | MISSING |
| `DEFAULT_IONOSPHERIC_SHELL_HEIGHT_M` | const | MISSING |
| `ELECTRONS_PER_TECU_M2` | const | MISSING |
| `IonosphericPiercePoint` | struct | MISSING |
| `LeveledTecSample` | struct | MISSING |
| `PhaseSlantTecEstimate` | struct | MISSING |
| `TEC_GROUP_DELAY_COEFFICIENT` | const | MISSING |
| `TecConfig` | struct | MISSING |
| `TecEpoch` | struct | MISSING |
| `TecError` | enum | MISSING |
| `TecEstimate` | struct | MISSING |
| `TecEstimateSample` | struct | MISSING |
| `TecLevelingResult` | struct | MISSING |
| `TecLevelingSample` | struct | MISSING |
| `TecObservation` | struct | MISSING |
| `TecSatelliteArc` | struct | MISSING |
| `code_geometry_free_m` | fn | MISSING |
| `estimate_code_slant_tec` | fn | MISSING |
| `estimate_phase_slant_tec` | fn | MISSING |
| `estimate_tec` | fn | MISSING |
| `ionospheric_pierce_point` | fn | MISSING |
| `level_slant_tec_arc` | fn | MISSING |
| `phase_geometry_free_m` | fn | MISSING |
| `slant_tec_from_code_geometry_free_m` | fn | MISSING |
| `slant_tec_from_phase_geometry_free_m` | fn | MISSING |
| `thin_shell_mapping_function` | fn | MISSING |
| `vertical_tec_from_slant_tec` | fn | MISSING |

## `sidereon_core::precise_positioning::types`

| Item | Kind | Binding |
|---|---|---|
| `AmbiguitySearch` | struct | MISSING |
| `FixedSolveError` | enum | `precise_positioning.rs`, `rtk_filter.rs` |
| `FloatResidual` | struct | `precise_positioning.rs`, `rtk_filter.rs` |
| `FloatSolveError` | enum | `precise_positioning.rs`, `rtk_filter.rs` |
| `IntegerStatus` | enum | `precise_positioning.rs`, `rtk_filter.rs` |

## `sidereon_core::precise_positioning::velocity`

| Item | Kind | Binding |
|---|---|---|
| `RangeRatePrediction` | struct | MISSING |
| `ReceiverVelocityState` | struct | MISSING |
| `VelocityConfig` | struct | MISSING |
| `VelocityObservation` | struct | `velocity.rs` |
| `VelocityRobustConfig` | struct | MISSING |
| `VelocitySolution` | struct | `spp.rs`, `velocity.rs` |
| `VelocitySolveError` | enum | MISSING |
| `predict_range_rate_m_s` | fn | MISSING |
| `solve_velocity` | fn | MISSING |
| `solve_velocity_least_squares` | fn | MISSING |

## `sidereon_core::quality`

| Item | Kind | Binding |
|---|---|---|
| `DEFAULT_FDE_MAX_EXCLUSION_RMS_M` | const | MISSING |
| `DEFAULT_P_FA` | const | MISSING |
| `DEFAULT_VARIANCE_A_M` | const | MISSING |
| `DEFAULT_VARIANCE_B_M` | const | MISSING |
| `FDE_MIN_CANDIDATE_SATELLITES` | const | MISSING |
| `FDE_MIN_OBSERVATIONS` | const | MISSING |
| `FdeError` | enum | `qc.rs` |
| `FdeOptions` | struct | `qc.rs` |
| `FdeResult` | struct | `qc.rs` |
| `FdeSolveFailure` | trait | MISSING |
| `FdeSppError` | enum | `qc.rs` |
| `FdeSppOptions` | struct | `qc.rs` |
| `FdeUnresolved` | struct | MISSING |
| `FdeUnresolvedReason` | enum | `qc.rs` |
| `PseudorangeVarianceModel` | enum | `qc.rs` |
| `PseudorangeVarianceOptions` | struct | `qc.rs` |
| `QualityError` | enum | `qc.rs`, `reliability.rs` |
| `RaimInput` | struct | `qc.rs` |
| `RaimOptions` | struct | `qc.rs` |
| `RaimResult` | struct | `qc.rs` |
| `RaimSolution` | trait | MISSING |
| `RaimWeights` | enum | `qc.rs` |
| `RangeChiSquareTest` | struct | `qc.rs` |
| `RangeFdeOptions` | struct | `qc.rs` |
| `RangeFdeResult` | struct | `qc.rs` |
| `RangeFdeRow` | struct | `qc.rs` |
| `RangeMeasurementDiagnostic` | struct | `qc.rs` |
| `ResidualDiagnostics` | struct | MISSING |
| `SolutionValidationError` | enum | `qc.rs`, `spp.rs` |
| `SolutionValidationOptions` | struct | `qc.rs`, `sbas.rs`, `spp.rs` |
| `WeightEntry` | struct | `qc.rs` |
| `chi2_inv` | fn | `qc.rs` |
| `fde` | fn | `qc.rs` |
| `fde_spp` | fn | `qc.rs` |
| `pseudorange_variance` | fn | `qc.rs` |
| `raim` | fn | `qc.rs` |
| `raim_fde_design` | fn | `qc.rs` |
| `raim_for_solution` | fn | MISSING |
| `residual_diagnostics` | fn | MISSING |
| `sigmas` | fn | `araim.rs`, `qc.rs` |
| `spp_robust_fde_driver` | fn | `qc.rs` |
| `validate_receiver_solution` | fn | MISSING |
| `weight_vector` | fn | `qc.rs` |

## `sidereon_core::quality::normality`

| Item | Kind | Binding |
|---|---|---|
| `JarqueBera` | struct | MISSING |
| `MomentStats` | struct | MISSING |
| `NormalityError` | enum | `normality.rs` |
| `ShapiroWilk` | struct | MISSING |
| `jarque_bera` | fn | `normality.rs` |
| `kurtosis` | fn | `normality.rs` |
| `moments` | fn | `normality.rs` |
| `shapiro_wilk` | fn | `normality.rs` |
| `skewness` | fn | `normality.rs` |

## `sidereon_core::reduced_orbit`

| Item | Kind | Binding |
|---|---|---|
| `DriftEntry` | struct | MISSING |
| `DriftReport` | struct | MISSING |
| `EcefSample` | struct | `reduced_orbit.rs` |
| `Elements` | struct | `propagation.rs`, `reduced_orbit.rs`, `tle.rs` |
| `FitStats` | struct | `reduced_orbit.rs` |
| `Frame` | enum | `collision.rs`, `covariance_transport.rs`, `orbit_determination.rs`, `reduced_orbit.rs`, `rtk_filter.rs`, `scenario.rs` |
| `MIN_SAMPLES` | const | MISSING |
| `Model` | enum | `reduced_orbit.rs` |
| `PiecewiseOrbit` | struct | `reduced_orbit.rs` |
| `PiecewiseOrbitError` | enum | `reduced_orbit.rs` |
| `PiecewiseOrbitSourceFit` | struct | MISSING |
| `PiecewiseOrbitSourceFitOptions` | struct | MISSING |
| `PiecewiseSegment` | struct | `reduced_orbit.rs` |
| `PositionVelocity` | type | MISSING |
| `ReducedOrbit` | struct | `reduced_orbit.rs` |
| `ReducedOrbitError` | enum | `reduced_orbit.rs` |
| `ReducedOrbitSource` | enum | MISSING |
| `ReducedOrbitSourceDrift` | struct | MISSING |
| `ReducedOrbitSourceDriftOptions` | struct | MISSING |
| `ReducedOrbitSourceError` | enum | MISSING |
| `ReducedOrbitSourceFit` | struct | MISSING |
| `ReducedOrbitSourceFitOptions` | struct | MISSING |
| `ReducedOrbitSourceSampling` | struct | MISSING |
| `drift` | fn | `consts.rs`, `propagation.rs`, `reduced_orbit.rs` |
| `drift_piecewise_reduced_orbit_source` | fn | MISSING |
| `drift_reduced_orbit_source` | fn | MISSING |
| `fit` | fn | `clock_stability.rs`, `covariance.rs`, `nmea.rs`, `precise_positioning.rs`, `reduced_orbit.rs`, `rtcm.rs`, `spp.rs`, `ssr_bias_exclusion.rs`, `tle_fit.rs` |
| `fit_piecewise` | fn | `reduced_orbit.rs` |
| `fit_piecewise_reduced_orbit_source` | fn | MISSING |
| `fit_reduced_orbit_source` | fn | MISSING |
| `fit_with_model` | fn | `reduced_orbit.rs` |
| `piecewise_drift` | fn | `reduced_orbit.rs` |
| `piecewise_position` | fn | `reduced_orbit.rs` |
| `piecewise_position_velocity` | fn | `reduced_orbit.rs` |
| `position` | fn | `angles.rs`, `antex.rs`, `cdm.rs`, `covariance.rs`, `covariance_transport.rs`, `drag.rs`, `elements.rs`, `ephemeris.rs`, `error_metrics.rs`, `forces.rs`, `frame_catalog.rs`, `fusion.rs`, `geodetic_time_series.rs`, `geofence.rs`, `geoid.rs`, `iono.rs`, `lib.rs`, `nmea.rs`, `ntrip.rs`, `observable_states.rs`, `observables.rs`, `oem.rs`, `omm.rs`, `passes.rs`, `precise_positioning.rs`, `precise_samples.rs`, `propagation.rs`, `reduced_orbit.rs`, `rinex_clock.rs`, `rinex_obs.rs`, `rtk_filter.rs`, `sbas.rs`, `sgp4_batch.rs`, `sp3.rs`, `spp.rs`, `ssr.rs`, `staleness.rs`, `static_positioning.rs`, `tides.rs`, `unix_compress.rs`, `velocity.rs` |
| `position_velocity` | fn | `reduced_orbit.rs` |
| `select_piecewise_segment` | fn | `reduced_orbit.rs` |

## `sidereon_core::reduced_orbit::time`

| Item | Kind | Binding |
|---|---|---|
| `CalendarEpoch` | struct | `reduced_orbit.rs` |

## `sidereon_core::rinex_clock`

| Item | Kind | Binding |
|---|---|---|
| `RinexClock` | struct | `data.rs`, `rinex_clock.rs` |

## `sidereon_core::rinex_nav`

| Item | Kind | Binding |
|---|---|---|
| `BroadcastGroupDelayTerm` | enum | MISSING |
| `BroadcastGroupDelays` | struct | `broadcast.rs` |
| `BroadcastIssue` | struct | `broadcast.rs` |
| `BroadcastRecord` | struct | `broadcast.rs` |
| `CnavParameters` | struct | `broadcast.rs` |
| `CnavSignal` | enum | `broadcast.rs` |
| `GlonassRecord` | struct | `broadcast.rs` |
| `IonoCorrections` | struct | `broadcast.rs`, `rinex_qc.rs` |
| `KlobucharAlphaBeta` | struct | `broadcast.rs`, `rinex_qc.rs` |
| `LnavRecordError` | enum | `rtcm.rs` |
| `NavMessage` | enum | `broadcast.rs` |
| `StatedNavFields` | struct | `broadcast.rs` |
| `cnav_ura_ned_m` | fn | `broadcast.rs` |
| `cnav_ura_nominal_m` | fn | `broadcast.rs` |
| `is_beidou_geo` | fn | MISSING |
| `parse_glonass` | fn | `broadcast.rs` |
| `parse_iono_corrections` | fn | MISSING |
| `parse_leap_seconds` | fn | `broadcast.rs` |
| `parse_nav` | fn | `broadcast.rs` |

## `sidereon_core::rinex_nav::frames`

| Item | Kind | Binding |
|---|---|---|
| `EarthOrientation` | struct | `broadcast.rs` |

## `sidereon_core::rinex_nav::geo`

| Item | Kind | Binding |
|---|---|---|
| `SbasRecord` | struct | MISSING |

## `sidereon_core::rinex_nav::store`

| Item | Kind | Binding |
|---|---|---|
| `NavMessagePreference` | enum | `broadcast.rs` |

## `sidereon_core::rinex_obs`

| Item | Kind | Binding |
|---|---|---|
| `pseudoranges` | fn | `precise_positioning.rs`, `rinex_obs.rs`, `spp.rs`, `ssr_bias_exclusion.rs` |

## `sidereon_core::rtcm`

| Item | Kind | Binding |
|---|---|---|
| `FrameSkip` | struct | `rtcm.rs` |
| `FrameSkipReason` | enum | `rtcm.rs` |
| `Message` | enum | `ntrip.rs`, `rtcm.rs`, `sp3.rs`, `spp.rs`, `tdm.rs` |
| `RtcmDeparture` | enum | `rtcm.rs` |
| `RtcmPolicy` | enum | `rtcm.rs` |
| `RtcmStream` | struct | MISSING |
| `SsrStreamAssembler` | struct | `ntrip.rs` |
| `StreamDeparture` | struct | MISSING |
| `StreamDiagnostics` | struct | `rtcm.rs` |
| `UnsupportedMessage` | struct | `rtcm.rs` |
| `decode_messages` | fn | `rtcm.rs` |
| `decode_stream` | fn | MISSING |
| `decode_stream_with_policy` | fn | `rtcm.rs` |
| `message_number` | fn | `nmea.rs`, `rtcm.rs`, `spp.rs`, `ssr.rs` |

## `sidereon_core::rtcm::antenna`

| Item | Kind | Binding |
|---|---|---|
| `AntennaDescriptor` | struct | `rtcm.rs` |

## `sidereon_core::rtcm::code_phase_bias`

| Item | Kind | Binding |
|---|---|---|
| `GLONASS_CODE_PHASE_BIAS_INVALID` | const | MISSING |
| `GlonassCodePhaseBiases` | struct | `rtcm.rs` |

## `sidereon_core::rtcm::encode_error`

| Item | Kind | Binding |
|---|---|---|
| `MsmMaskProblem` | enum | `rtcm.rs` |
| `MsmOptionalField` | enum | `rtcm.rs` |
| `MsmOptionalProblem` | enum | `rtcm.rs` |
| `RtcmConversionError` | enum | `rtcm.rs`, `spp.rs` |
| `RtcmEncodeError` | enum | `rtcm.rs`, `spp.rs` |
| `RtcmFieldEncoding` | enum | `rtcm.rs` |
| `RtcmRecordKind` | enum | `rtcm.rs` |
| `VtecEvaluationProblem` | enum | `rtcm.rs` |

## `sidereon_core::rtcm::ephemeris`

| Item | Kind | Binding |
|---|---|---|
| `BeidouEphemeris` | struct | `rtcm.rs` |
| `GalileoFnavEphemeris` | struct | `rtcm.rs` |
| `GalileoInavEphemeris` | struct | `rtcm.rs` |
| `GlonassEphemeris` | struct | `rtcm.rs` |
| `GpsEphemeris` | struct | `rtcm.rs` |
| `NavicEphemeris` | struct | `rtcm.rs` |
| `QzssEphemeris` | struct | `rtcm.rs` |

## `sidereon_core::rtcm::framing`

| Item | Kind | Binding |
|---|---|---|
| `DecodedFrame` | struct | MISSING |
| `FRAME_OVERHEAD` | const | MISSING |
| `FrameScanner` | struct | MISSING |
| `MAX_BODY_LEN` | const | MISSING |
| `PREAMBLE` | const | `lnav.rs` |
| `decode_frame` | fn | `frame_catalog.rs`, `rtcm.rs` |
| `encode_frame` | fn | `collision.rs` |
| `encode_frame_with_reserved` | fn | `rtcm.rs` |

## `sidereon_core::rtcm::legacy`

| Item | Kind | Binding |
|---|---|---|
| `LEGACY_PHASE_RANGE_INVALID` | const | MISSING |
| `LEGACY_PSEUDORANGE_DIFFERENCE_INVALID` | const | MISSING |
| `LegacyL1` | struct | `rtcm.rs` |
| `LegacyL2` | struct | `rtcm.rs` |
| `LegacyObservations` | struct | `rtcm.rs` |
| `LegacySatellite` | struct | `rtcm.rs` |

## `sidereon_core::rtcm::lli`

| Item | Kind | Binding |
|---|---|---|
| `CellLli` | struct | `rtcm.rs` |
| `LLI_HALF_CYCLE` | const | `rtcm.rs` |
| `LLI_LOSS_OF_LOCK` | const | `rtcm.rs` |
| `LockTimeTracker` | struct | `rtcm.rs` |
| `PreviousLock` | struct | `rtcm.rs` |
| `derive_lli` | fn | `rtcm.rs` |
| `minimum_lock_time_ms` | fn | `rtcm.rs` |
| `msm_epoch_dt_ms` | fn | `rtcm.rs` |
| `msm_signal_rinex_code` | fn | `rtcm.rs` |

## `sidereon_core::rtcm::msm`

| Item | Kind | Binding |
|---|---|---|
| `MSM4_FINE_PHASE_RANGE_INVALID` | const | MISSING |
| `MSM4_FINE_PSEUDORANGE_INVALID` | const | MISSING |
| `MSM7_FINE_PHASE_RANGE_INVALID` | const | MISSING |
| `MSM7_FINE_PSEUDORANGE_INVALID` | const | MISSING |
| `MSM_FINE_PHASE_RANGE_RATE_INVALID` | const | MISSING |
| `MSM_ROUGH_PHASE_RANGE_RATE_INVALID` | const | MISSING |
| `MSM_ROUGH_RANGE_INVALID` | const | MISSING |
| `MsmHeader` | struct | `rtcm.rs` |
| `MsmKind` | enum | `rtcm.rs` |
| `MsmMessage` | struct | `rtcm.rs` |
| `MsmSatellite` | struct | `rtcm.rs` |
| `MsmSignal` | struct | `rtcm.rs` |
| `msm_signal_mask` | fn | `rtcm.rs` |

## `sidereon_core::rtcm::network`

| Item | Kind | Binding |
|---|---|---|
| `FkpGradient` | struct | `rtcm.rs` |
| `FkpGradients` | struct | `rtcm.rs` |
| `NetworkAuxiliaryStation` | struct | `rtcm.rs` |
| `NetworkCorrectionDifference` | struct | `rtcm.rs` |
| `NetworkCorrectionDifferences` | struct | `rtcm.rs` |
| `NetworkResidual` | struct | `rtcm.rs` |
| `NetworkResiduals` | struct | `rtcm.rs` |
| `PhysicalReferenceStation` | struct | `rtcm.rs` |

## `sidereon_core::rtcm::ssr`

| Item | Kind | Binding |
|---|---|---|
| `IGS_SSR_MESSAGE_NUMBER` | const | MISSING |
| `SsrClockRecord` | struct | MISSING |
| `SsrCodeBiasRecord` | struct | MISSING |
| `SsrHeader` | struct | MISSING |
| `SsrKind` | enum | `rtcm.rs` |
| `SsrMessage` | struct | MISSING |
| `SsrOrbitRecord` | struct | MISSING |
| `SsrPhaseBiasRecord` | struct | MISSING |
| `SsrPhaseBiasSignal` | struct | MISSING |

## `sidereon_core::rtcm::station`

| Item | Kind | Binding |
|---|---|---|
| `StationCoordinates` | struct | `rtcm.rs` |

## `sidereon_core::rtcm::system`

| Item | Kind | Binding |
|---|---|---|
| `MessageAnnouncement` | struct | `rtcm.rs` |
| `SystemParameters` | struct | `rtcm.rs` |
| `TextMessage` | struct | `rtcm.rs` |

## `sidereon_core::rtcm::transformation`

| Item | Kind | Binding |
|---|---|---|
| `GridResidual` | struct | `rtcm.rs` |
| `HelmertTransformation` | struct | `rtcm.rs` |
| `Projection` | struct | `rtcm.rs` |
| `ProjectionParameters` | enum | `rtcm.rs` |
| `RESIDUAL_GRID_POINTS` | const | MISSING |
| `ResidualGrid` | struct | `rtcm.rs` |
| `RotationPoint` | struct | `rtcm.rs` |

## `sidereon_core::rtcm::vtec`

| Item | Kind | Binding |
|---|---|---|
| `SsrVtecEvaluation` | struct | `rtcm.rs` |
| `SsrVtecLayer` | struct | `rtcm.rs` |
| `SsrVtecLayerEvaluation` | struct | MISSING |
| `SsrVtecMessage` | struct | `rtcm.rs` |

## `sidereon_core::rtk`

| Item | Kind | Binding |
|---|---|---|
| `BaselineReferenceEpoch` | struct | `rtk.rs`, `rtk_filter.rs` |
| `BaselineReferenceSelection` | enum | `rtk.rs`, `rtk_filter.rs` |
| `CodeSmoothingEpoch` | struct | `rtk_filter.rs` |
| `CodeSmoothingError` | enum | MISSING |
| `CodeSmoothingObservation` | struct | `rtk_filter.rs` |
| `CycleSlipEpoch` | type | MISSING |
| `CycleSlipObservation` | type | MISSING |
| `CycleSlipPrepError` | enum | `rtk_filter.rs` |
| `CycleSlipPrepResult` | struct | MISSING |
| `CycleSlipReceiver` | enum | `rtk_filter.rs` |
| `CycleSlipSplitArc` | struct | `rtk_filter.rs` |
| `DoubleDifference` | struct | MISSING |
| `DoubleDifferenceError` | enum | `rtk.rs`, `rtk_filter.rs` |
| `DoubleDifferenceResult` | struct | MISSING |
| `DualCycleSlipEpoch` | struct | MISSING |
| `DualCycleSlipObservation` | struct | MISSING |
| `DualCycleSlipPrepResult` | struct | MISSING |
| `DualEpoch` | struct | MISSING |
| `DualIonosphereFreeEpoch` | struct | MISSING |
| `DualIonosphereFreeObservation` | struct | MISSING |
| `DualIonosphereFreeSatelliteObservation` | struct | MISSING |
| `DualIonosphereFreeSetupEpoch` | struct | MISSING |
| `DualObservation` | struct | MISSING |
| `DualSatelliteObservation` | struct | MISSING |
| `ElevationMaskEpoch` | struct | `rtk_filter.rs` |
| `ElevationMaskEpochResult` | struct | MISSING |
| `ElevationMaskResult` | struct | MISSING |
| `IonosphereFreeBaselineEpoch` | struct | MISSING |
| `IonosphereFreeBaselineError` | enum | `rtk_filter.rs` |
| `IonosphereFreeBaselineResult` | struct | MISSING |
| `Observation` | struct | `astro_observe_almanac.rs`, `rtk.rs`, `rtk_filter.rs`, `spp.rs` |
| `ReferenceReport` | enum | `rtk.rs` |
| `ReferenceSelection` | enum | `rtk.rs` |
| `WideLaneError` | enum | `rtk_filter.rs` |
| `WideLaneOptions` | struct | `rtk_filter.rs` |
| `apply_elevation_mask` | fn | `rtk_filter.rs` |
| `baseline_reference_satellites` | fn | `rtk.rs`, `rtk_filter.rs` |
| `build_ionosphere_free_baseline_epochs` | fn | MISSING |
| `double_differences` | fn | `rtk.rs` |
| `estimate_wide_lane_ambiguities` | fn | MISSING |
| `hatch_smooth_baseline_code_epochs` | fn | `rtk_filter.rs` |
| `prepare_cycle_slip_baseline_epochs` | fn | `rtk_filter.rs` |
| `prepare_dual_cycle_slip_baseline_epochs` | fn | MISSING |
| `prepare_ionosphere_free_baseline_epochs` | fn | MISSING |

## `sidereon_core::rtk_filter`

| Item | Kind | Binding |
|---|---|---|
| `AmbiguityScale` | struct | `rtk_filter.rs` |
| `RtkInputErrorKind` | enum | MISSING |

## `sidereon_core::rtk_filter::antenna`

| Item | Kind | Binding |
|---|---|---|
| `ReceiverAntennaCalibration` | struct | `rtk_filter.rs` |
| `ReceiverAntennaCorrections` | struct | `rtk_filter.rs` |
| `ReceiverAntennaError` | enum | MISSING |

## `sidereon_core::rtk_filter::arc`

| Item | Kind | Binding |
|---|---|---|
| `RtkArcConfig` | struct | `rtk_filter.rs` |
| `RtkArcEpoch` | struct | `rtk_filter.rs` |
| `RtkArcEpochSolution` | struct | `rtk_filter.rs` |
| `RtkArcError` | enum | `rtk_filter.rs` |
| `RtkArcObservation` | struct | `rtk_filter.rs` |
| `RtkArcPreprocessing` | struct | `rtk_filter.rs` |
| `RtkArcSolution` | struct | `rtk_filter.rs` |
| `RtkDualCycleSlipConfig` | struct | `rtk_filter.rs` |
| `RtkDualFrequencyArcEpoch` | struct | `rtk_filter.rs` |
| `RtkDualFrequencyObservation` | struct | `rtk_filter.rs` |
| `RtkDualFrequencySatelliteObservation` | struct | `rtk_filter.rs` |
| `RtkIonosphereFreeArcConfig` | struct | `rtk_filter.rs` |
| `RtkIonosphereFreeArcError` | enum | `rtk_filter.rs` |
| `RtkIonosphereFreeArcSolution` | struct | `rtk_filter.rs` |
| `RtkStaticArcConfig` | struct | `rtk_filter.rs` |
| `RtkStaticArcError` | enum | `rtk_filter.rs` |
| `RtkStaticArcSolution` | struct | `rtk_filter.rs` |
| `RtkWideLaneArcConfig` | struct | `rtk_filter.rs` |
| `RtkWideLaneArcError` | enum | `rtk_filter.rs` |
| `RtkWideLaneArcSolution` | struct | `rtk_filter.rs` |
| `RtkWideLaneFixedArcConfig` | struct | `rtk_filter.rs` |
| `RtkWideLaneFixedArcError` | enum | `rtk_filter.rs` |
| `RtkWideLaneFixedArcIntegerMethod` | enum | `rtk_filter.rs` |
| `RtkWideLaneFixedArcMetadata` | struct | `rtk_filter.rs` |
| `RtkWideLaneFixedArcSolution` | enum | `rtk_filter.rs` |
| `RtkWideLaneFixedArcSolveConfig` | enum | `rtk_filter.rs` |
| `RtkWideLaneFixedSequentialArcSolution` | struct | MISSING |
| `RtkWideLaneFixedStaticArcSolution` | struct | MISSING |
| `fix_wide_lane_rtk_arc` | fn | `rtk_filter.rs` |
| `prepare_ionosphere_free_rtk_arc` | fn | `rtk_filter.rs` |
| `solve_rtk_arc` | fn | `rtk_filter.rs` |
| `solve_static_rtk_arc` | fn | `rtk_filter.rs` |
| `solve_wide_lane_fixed_rtk_arc` | fn | `rtk_filter.rs` |

## `sidereon_core::rtk_filter::fixed`

| Item | Kind | Binding |
|---|---|---|
| `AmbiguitySet` | struct | `rtk_filter.rs` |
| `FixedBaselineSolution` | struct | `rtk_filter.rs` |
| `FixedSolveError` | enum | `precise_positioning.rs`, `rtk_filter.rs` |
| `FixedSolveOpts` | struct | `rtk_filter.rs` |
| `FloatPrior` | struct | MISSING |
| `ResidualComponentKind` | enum | `rtk_filter.rs` |
| `ResidualValidationMeta` | struct | `rtk_filter.rs` |
| `ResidualValidationOpts` | struct | `rtk_filter.rs` |
| `ResidualValidationOutlier` | struct | `rtk_filter.rs` |
| `ValidatedFixedBaselineSolution` | struct | `rtk_filter.rs` |
| `ValidatedFixedSolveError` | enum | `rtk_filter.rs` |
| `ValidatedFixedSolveOpts` | struct | `rtk_filter.rs` |
| `solve_fixed_baseline` | fn | MISSING |
| `solve_fixed_baseline_validated` | fn | `rtk_filter.rs` |

## `sidereon_core::rtk_filter::float`

| Item | Kind | Binding |
|---|---|---|
| `FloatBaselineSolution` | struct | `rtk_filter.rs` |
| `FloatResidual` | struct | `precise_positioning.rs`, `rtk_filter.rs` |
| `FloatSolveError` | enum | `precise_positioning.rs`, `rtk_filter.rs` |
| `FloatSolveOpts` | struct | `rtk_filter.rs` |
| `FloatSolveStatus` | enum | `rtk_filter.rs` |
| `solve_float_baseline` | fn | `rtk_filter.rs` |

## `sidereon_core::rtk_filter::model`

| Item | Kind | Binding |
|---|---|---|
| `Epoch` | struct | `iono.rs`, `ndm_errors.rs`, `rtk_filter.rs`, `sp3.rs` |
| `MeasModel` | struct | `rtk_filter.rs` |
| `SatMeas` | struct | `rtk_filter.rs` |
| `StochasticModel` | enum | `rtk_filter.rs` |

## `sidereon_core::rtk_filter::moving_baseline`

| Item | Kind | Binding |
|---|---|---|
| `MovingBaselineEpoch` | struct | `rtk_filter.rs` |
| `MovingBaselineEpochSolution` | struct | `rtk_filter.rs` |
| `MovingBaselineError` | enum | `rtk_filter.rs` |
| `MovingBaselineOpts` | struct | `rtk_filter.rs` |
| `MovingBaselineSequenceError` | struct | MISSING |
| `MovingBaselineStatus` | enum | `rtk_filter.rs` |
| `solve_moving_baseline` | fn | `rtk_filter.rs` |
| `solve_moving_baseline_epoch` | fn | MISSING |

## `sidereon_core::rtk_filter::rinex_arc`

| Item | Kind | Binding |
|---|---|---|
| `RtkRinexArc` | struct | `rtk_filter.rs` |
| `RtkRinexArcError` | enum | `rtk_filter.rs` |
| `RtkRinexArcOptions` | struct | `rtk_filter.rs` |
| `RtkRinexDualArcOptions` | struct | `rtk_filter.rs` |
| `RtkRinexDualFrequencyArc` | struct | `rtk_filter.rs` |
| `RtkRinexDualSignalPair` | struct | `rtk_filter.rs` |
| `RtkRinexReceiver` | enum | `rtk_filter.rs` |
| `RtkRinexSignalPair` | struct | `rtk_filter.rs` |
| `RtkRinexUnresolvedCarrier` | struct | `rtk_filter.rs` |
| `build_dual_frequency_rinex_rtk_arc` | fn | `rtk_filter.rs` |
| `build_rinex_rtk_arc` | fn | `rtk_filter.rs` |

## `sidereon_core::rtk_filter::search`

| Item | Kind | Binding |
|---|---|---|
| `AmbiguitySearch` | struct | MISSING |
| `FullSetIntegerSummary` | struct | `rtk_filter.rs` |
| `IntegerSearchMeta` | struct | `rtk_filter.rs` |
| `IntegerStatus` | enum | `precise_positioning.rs`, `rtk_filter.rs` |
| `PartialSearchMeta` | struct | MISSING |

## `sidereon_core::rtk_filter::state`

| Item | Kind | Binding |
|---|---|---|
| `FILTER_STATE_VERSION` | const | MISSING |
| `FilterState` | struct | `rtk_filter.rs` |
| `FilterStateValidationError` | struct | MISSING |
| `FilterStateValidationKind` | enum | MISSING |

## `sidereon_core::rtk_filter::update`

| Item | Kind | Binding |
|---|---|---|
| `DynamicsModel` | enum | `rtk_filter.rs` |
| `EpochUpdate` | struct | `rtk_filter.rs` |
| `InvalidStateKind` | enum | MISSING |
| `RtkFilterScratch` | struct | MISSING |
| `SearchOpts` | struct | `rtk_filter.rs` |
| `UpdateError` | enum | `rtk_filter.rs` |
| `UpdateOpts` | struct | `rtk_filter.rs` |
| `update_epoch` | fn | `rtk_filter.rs` |
| `update_epoch_with_scratch` | fn | MISSING |

## `sidereon_core::sbas::format`

| Item | Kind | Binding |
|---|---|---|
| `SbasLineDeparture` | struct | MISSING |
| `SbasLineRefusal` | enum | `sbas.rs` |
| `SbasLog` | struct | `sbas.rs` |
| `SbasLogBlock` | struct | `sbas.rs` |
| `SbasLogOptions` | struct | `sbas.rs` |
| `SbasRefusedLine` | struct | MISSING |
| `SbasSkippedLine` | struct | MISSING |
| `SbasSkippedLineKind` | enum | `sbas.rs` |
| `parse_ems_lines` | fn | `sbas.rs` |
| `parse_ems_log` | fn | `sbas.rs` |
| `parse_rtklib_lines` | fn | `sbas.rs` |
| `parse_rtklib_log` | fn | `sbas.rs` |

## `sidereon_core::sbas::message`

| Item | Kind | Binding |
|---|---|---|
| `SbasBlock` | struct | `sbas.rs` |
| `SbasDeparture` | enum | `sbas.rs` |
| `SbasDoNotUse` | struct | MISSING |
| `SbasEncodeError` | enum | `sbas.rs`, `spp.rs` |
| `SbasFastCorrections` | struct | MISSING |
| `SbasFastDegradation` | struct | MISSING |
| `SbasGeoAlmanac` | struct | MISSING |
| `SbasGeoNav` | struct | MISSING |
| `SbasIgpDelay` | struct | MISSING |
| `SbasIgpMask` | struct | MISSING |
| `SbasIntegrity` | struct | MISSING |
| `SbasIonoDelays` | struct | `sbas.rs` |
| `SbasLongTermCorrections` | struct | MISSING |
| `SbasLongTermHalf` | struct | `sbas.rs` |
| `SbasLongTermRecord` | struct | `sbas.rs` |
| `SbasMessage` | enum | `sbas.rs` |
| `SbasMessageType` | type | MISSING |
| `SbasMixedCorrections` | struct | MISSING |
| `SbasMixedFastCorrections` | struct | `sbas.rs` |
| `SbasNetworkTime` | struct | MISSING |
| `SbasPolicy` | enum | `sbas.rs` |
| `SbasPrnMask` | struct | MISSING |
| `SbasUnsupported` | struct | `sbas.rs` |
| `SbasWireForm` | enum | `sbas.rs` |
| `SpareBits` | struct | `sbas.rs` |

## `sidereon_core::sbas::source`

| Item | Kind | Binding |
|---|---|---|
| `IssueAwareBroadcast` | trait | MISSING |
| `SbasCorrectedEphemeris` | struct | `sbas.rs` |
| `SbasCorrectedEphemerisOwned` | struct | MISSING |
| `SbasSolveMode` | enum | `sbas.rs` |

## `sidereon_core::sbas::store`

| Item | Kind | Binding |
|---|---|---|
| `SBAS_GIVE_VARIANCE_M2` | const | MISSING |
| `SBAS_UDRE_VARIANCE_M2` | const | MISSING |
| `SbasCorrectionStore` | struct | `sbas.rs` |
| `SbasFastCorrection` | struct | MISSING |
| `SbasGeoState` | struct | MISSING |
| `SbasIgp` | struct | MISSING |
| `SbasIgpUnavailableReason` | enum | MISSING |
| `SbasIonoGrid` | struct | `sbas.rs` |
| `SbasLongTermCorrection` | struct | MISSING |
| `SbasUnavailableIgp` | struct | MISSING |
| `give_variance_m2_for_givei` | fn | MISSING |
| `sat_to_sbas_prn` | fn | `sbas.rs` |
| `sbas_prn_to_sat` | fn | `sbas.rs` |
| `udre_variance_m2_for_udrei` | fn | MISSING |

## `sidereon_core::sbas_pl`

| Item | Kind | Binding |
|---|---|---|
| `SbasKMultipliers` | struct | `sbas.rs` |
| `SbasPlError` | enum | `sbas.rs` |
| `SbasProtection` | struct | `sbas.rs` |
| `sbas_protection_levels` | fn | `sbas.rs` |

## `sidereon_core::sbas_pl::error_model`

| Item | Kind | Binding |
|---|---|---|
| `AirborneModel` | struct | `sbas.rs` |
| `DegradationParams` | struct | `sbas.rs` |
| `SBAS_IONOSPHERE_SHELL_HEIGHT_KM` | const | MISSING |
| `SbasErrorModel` | struct | `sbas.rs` |
| `SbasSisError` | struct | `sbas.rs` |
| `sbas_obliquity_factor` | fn | MISSING |
| `sigma_air_multipath_m` | fn | MISSING |
| `sigma_flt_m_for_udrei` | fn | MISSING |
| `sigma_tropo_m` | fn | `sbas.rs` |

## `sidereon_core::scenario`

| Item | Kind | Binding |
|---|---|---|
| `DEFAULT_SCENARIO_SEED` | const | MISSING |
| `DeclaredIonexSource` | struct | MISSING |
| `DeclaredScenarioSource` | struct | MISSING |
| `SCENARIO_ENGINE_VERSION` | const | MISSING |
| `SCENARIO_SCHEMA_VERSION` | const | MISSING |
| `Scenario` | struct | `scenario.rs` |
| `ScenarioClockModel` | struct | MISSING |
| `ScenarioConstellation` | enum | MISSING |
| `ScenarioEpochRange` | struct | MISSING |
| `ScenarioError` | enum | `scenario.rs` |
| `ScenarioErrorBudget` | struct | MISSING |
| `ScenarioExternalProduct` | struct | MISSING |
| `ScenarioExternalProductKind` | enum | MISSING |
| `ScenarioGeodeticPosition` | struct | MISSING |
| `ScenarioIonosphereModel` | enum | MISSING |
| `ScenarioMediaSources` | struct | MISSING |
| `ScenarioReceiver` | enum | MISSING |
| `ScenarioReceiverWaypoint` | struct | MISSING |
| `ScenarioSignal` | struct | MISSING |
| `ScenarioSpecularMultipath` | struct | MISSING |
| `ScenarioThermalNoise` | struct | MISSING |
| `ScenarioTroposphereModel` | enum | MISSING |
| `SyntheticKeplerOrbit` | struct | MISSING |
| `SyntheticKeplerSource` | struct | MISSING |
| `SyntheticObservableArrays` | struct | MISSING |
| `SyntheticObservationSet` | struct | MISSING |
| `SyntheticReceiverTruth` | struct | MISSING |
| `SyntheticTermArrays` | struct | MISSING |
| `ionex_content_fingerprint` | fn | MISSING |
| `scenario_source_transcript_fingerprint` | fn | MISSING |
| `simulate_scenario` | fn | `scenario.rs` |
| `simulate_scenario_with_media` | fn | MISSING |
| `simulate_scenario_with_source` | fn | MISSING |
| `simulate_scenario_with_source_and_media` | fn | MISSING |

## `sidereon_core::sidereal`

| Item | Kind | Binding |
|---|---|---|
| `SIDEREAL_DAY_NANOS` | const | MISSING |
| `SIDEREAL_DAY_SECONDS` | const | MISSING |
| `SiderealFilterError` | enum | `sidereal.rs` |
| `SiderealFilterOptions` | struct | `sidereal.rs` |
| `SiderealFilterOutput` | struct | `sidereal.rs` |
| `SiderealTemplateMethod` | enum | `sidereal.rs` |
| `orbit_repeat_lag` | fn | `sidereal.rs` |
| `periodicity_strength` | fn | MISSING |
| `periodicity_strength_with_sample_interval` | fn | `sidereal.rs` |
| `repeat_period` | fn | `sidereal.rs` |
| `sidereal_filter` | fn | `sidereal.rs` |
| `solar_day_period` | fn | MISSING |

## `sidereon_core::signal`

| Item | Kind | Binding |
|---|---|---|
| `AcquisitionGrid` | struct | MISSING |
| `AcquisitionOptions` | struct | `signal.rs` |
| `AcquisitionResult` | struct | MISSING |
| `CA_CHIP_RATE_HZ` | const | `signal.rs` |
| `CA_CODE_LENGTH` | const | `signal.rs` |
| `CorrelateOptions` | struct | `signal.rs` |
| `CorrelationResult` | struct | MISSING |
| `IqSample` | struct | `signal.rs` |
| `ReplicaOptions` | struct | `signal.rs` |
| `SignalError` | enum | `signal.rs` |
| `acquire` | fn | `signal.rs` |
| `autocorrelation` | fn | `signal.rs` |
| `ca_chip` | fn | `signal.rs` |
| `ca_code` | fn | `signal.rs` |
| `coherent_loss` | fn | `signal.rs` |
| `coherent_loss_db` | fn | `signal.rs` |
| `correlate` | fn | `signal.rs` |
| `correlate_against` | fn | `signal.rs` |
| `correlation_at` | fn | `signal.rs` |
| `cross_correlation` | fn | `signal.rs` |
| `replica` | fn | `signal.rs` |
| `snr_post_db` | fn | `signal.rs` |

## `sidereon_core::signal::analysis`

| Item | Kind | Binding |
|---|---|---|
| `BETZ_L1_RECEIVER_BANDWIDTH_HZ` | const | `signal.rs` |
| `BocPhasing` | enum | MISSING |
| `CbocSign` | enum | MISSING |
| `Cn0Degradation` | struct | MISSING |
| `DllJitter` | struct | `signal.rs` |
| `DllProcessing` | enum | `signal.rs` |
| `DllTrackingOptions` | struct | `signal.rs` |
| `InterferenceTerm` | struct | `signal.rs` |
| `MultipathEnvelopePoint` | struct | MISSING |
| `MultipathOptions` | struct | `signal.rs` |
| `REFERENCE_CHIP_RATE_HZ` | const | `signal.rs` |
| `SignalAnalysisError` | enum | `signal.rs` |
| `SignalModulation` | struct | `signal.rs` |
| `WeightedComponent` | struct | MISSING |
| `autocorrelation` | fn | `signal.rs` |
| `dll_lower_bound` | fn | `signal.rs` |
| `dll_thermal_noise_jitter` | fn | `signal.rs` |
| `effective_cn0_degradation` | fn | `signal.rs` |
| `fraction_power_in_band` | fn | `signal.rs` |
| `multipath_error_envelope` | fn | `signal.rs` |
| `power_in_band` | fn | `signal.rs` |
| `rms_bandwidth_hz` | fn | `signal.rs` |
| `spectral_separation_coefficient_db_hz` | fn | `signal.rs` |
| `spectral_separation_coefficient_hz` | fn | `signal.rs` |
| `white_noise_spectral_separation_hz` | fn | `signal.rs` |

## `sidereon_core::source_localization`

| Item | Kind | Binding |
|---|---|---|
| `Sensor` | struct | `source_localization.rs` |
| `SourceCovariance` | struct | `source_localization.rs` |
| `SourceCrlb` | struct | `source_localization.rs` |
| `SourceInitialGuess` | struct | `source_localization.rs` |
| `SourceLocalizationError` | enum | `source_localization.rs` |
| `SourceLocateConfig` | struct | `source_localization.rs` |
| `SourceLocateOptions` | struct | `source_localization.rs` |
| `SourceResidual` | struct | `source_localization.rs` |
| `SourceSensorInfluence` | struct | `source_localization.rs` |
| `SourceSolution` | struct | `source_localization.rs` |
| `SourceSolveMode` | enum | `source_localization.rs` |
| `chan_ho_initial_guess` | fn | MISSING |
| `closed_form_initial_guess` | fn | `source_localization.rs` |
| `locate_source` | fn | MISSING |
| `locate_source_with` | fn | `source_localization.rs` |
| `source_crlb` | fn | `source_localization.rs` |
| `source_dop` | fn | `source_localization.rs` |

## `sidereon_core::sp3`

| Item | Kind | Binding |
|---|---|---|
| `Sp3` | struct | `data.rs`, `sp3.rs`, `spp.rs`, `staleness.rs` |
| `Sp3AccuracyCodeGroup` | struct | `sp3.rs` |
| `Sp3AccuracyValue` | enum | `precise_samples.rs`, `sp3.rs` |
| `Sp3ClockRecord` | struct | MISSING |
| `Sp3DataType` | enum | MISSING |
| `Sp3EpochPrediction` | struct | MISSING |
| `Sp3Flags` | struct | MISSING |
| `Sp3Header` | struct | MISSING |
| `Sp3PositionClockAccuracy` | struct | MISSING |
| `Sp3PredictionSummary` | struct | MISSING |
| `Sp3RawRecordAccuracy` | struct | MISSING |
| `Sp3RecordAccuracy` | struct | MISSING |
| `Sp3State` | struct | `sp3.rs` |
| `Sp3TimeSystem` | enum | `sp3.rs` |
| `Sp3VelocityAccuracy` | struct | MISSING |
| `Sp3Version` | enum | MISSING |

## `sidereon_core::sp3::combine`

| Item | Kind | Binding |
|---|---|---|
| `AgreementMetric` | struct | `sp3.rs` |
| `CellProvenance` | struct | MISSING |
| `CellSelection` | enum | `sp3.rs` |
| `ClockOmission` | struct | MISSING |
| `ClockOmissionReason` | enum | `sp3.rs` |
| `ClockReferenceOffset` | struct | MISSING |
| `ContributorCoverage` | struct | MISSING |
| `DroppedEpochReason` | enum | `sp3.rs` |
| `DroppedInputEpoch` | struct | MISSING |
| `EpochAgreement` | struct | `sp3.rs` |
| `MergeCombine` | enum | `sp3.rs` |
| `MergeContinuityCell` | struct | `sp3.rs` |
| `MergeContinuityCellRole` | enum | `sp3.rs` |
| `MergeContinuityReport` | struct | `sp3.rs` |
| `MergeContinuityViolation` | struct | `sp3.rs` |
| `MergeFlag` | struct | `sp3.rs` |
| `MergeOptions` | struct | `sp3.rs` |
| `MergePrecedenceScope` | enum | `sp3.rs` |
| `MergeProvenance` | struct | MISSING |
| `MergeReport` | struct | `sp3.rs` |
| `MergeToleranceError` | struct | `sp3.rs`, `spp.rs` |
| `MergeToleranceField` | enum | `sp3.rs`, `spp.rs` |
| `OutlierRejectOptions` | struct | `sp3.rs` |
| `PrecedenceTransition` | struct | MISSING |
| `ProvenanceMode` | enum | `sp3.rs` |
| `Sp3FrameLabelSet` | struct | `sp3.rs` |
| `Sp3FrameReconciliation` | struct | `sp3.rs` |
| `Sp3FrameReconciliationMethod` | enum | `sp3.rs` |
| `Sp3FrameReconciliationOptions` | struct | `sp3.rs` |
| `TransitionReason` | enum | `sp3.rs` |
| `align_clock_reference` | fn | `sp3.rs` |
| `clock_reference_offset` | fn | `sp3.rs` |
| `merge` | fn | `sp3.rs`, `spp.rs` |

## `sidereon_core::sp3::continuity`

| Item | Kind | Binding |
|---|---|---|
| `ContinuityCheck` | enum | MISSING |
| `ContinuityDefect` | enum | `sp3.rs` |
| `ContinuityOptionRejection` | enum | `spp.rs` |
| `ContinuityOptions` | struct | `sp3.rs`, `spp.rs` |
| `ContinuityOptionsError` | struct | `sp3.rs`, `spp.rs` |
| `ContinuityReport` | struct | `sp3.rs` |
| `EpochWindow` | struct | `sp3.rs` |
| `InterpolationNodes` | struct | `sp3.rs` |
| `OrbitClass` | enum | `sp3.rs` |
| `SpeedBound` | enum | `sp3.rs` |
| `StencilExtent` | struct | `sp3.rs` |
| `UnusableSampleReason` | enum | `sp3.rs` |
| `WindowContinuityDecision` | enum | `sp3.rs` |
| `WindowContinuityVerdict` | struct | `sp3.rs` |
| `check_continuity` | fn | `sp3.rs` |

## `sidereon_core::sp3::coverage`

| Item | Kind | Binding |
|---|---|---|
| `Sp3ChannelCoverage` | struct | MISSING |
| `Sp3Coverage` | struct | MISSING |
| `Sp3CoverageGap` | struct | MISSING |
| `Sp3CoverageSpan` | struct | MISSING |
| `Sp3SatelliteCoverage` | struct | MISSING |

## `sidereon_core::sp3::exact`

| Item | Kind | Binding |
|---|---|---|
| `ExactSp3Coverage` | enum | `sp3.rs` |
| `ExactSp3Request` | struct | `sp3.rs` |
| `ExactSp3ValidationError` | enum | `sp3.rs` |
| `parse_exact_sp3` | fn | `sp3.rs` |
| `validate_exact_sp3` | fn | `sp3.rs` |

## `sidereon_core::sp3::grid`

| Item | Kind | Binding |
|---|---|---|
| `Sp3EpochGrid` | struct | MISSING |
| `Sp3EpochIntervalError` | struct | `sp3.rs`, `spp.rs` |
| `Sp3EpochIntervalRejection` | enum | `spp.rs` |

## `sidereon_core::sp3::interp`

| Item | Kind | Binding |
|---|---|---|
| `DEFAULT_GAP_THRESHOLD_FACTOR` | const | MISSING |
| `Sp3InterpolationOptions` | struct | `observable_states.rs`, `precise_samples.rs`, `sp3.rs` |

## `sidereon_core::sp3::interpolant`

| Item | Kind | Binding |
|---|---|---|
| `PreciseEphemerisInterpolant` | struct | `observable_states.rs` |
| `PreciseInterpolantError` | enum | `observable_states.rs` |

## `sidereon_core::sp3::interpolant_store`

| Item | Kind | Binding |
|---|---|---|
| `MmapPreciseEphemerisInterpolant` | struct | `observable_states.rs` |
| `PreciseInterpolantStoreError` | enum | `observable_states.rs` |
| `precise_interpolant_store_checksum64` | fn | `observable_states.rs` |

## `sidereon_core::sp3::provenance`

| Item | Kind | Binding |
|---|---|---|
| `SP3_MERGE_INPUT_ID_PREFIX` | const | MISSING |
| `SP3_MERGE_INPUT_SCHEMA_VERSION` | const | MISSING |
| `Sp3ArtifactIdentity` | struct | `sp3.rs` |
| `Sp3MergeInputIdentity` | struct | `sp3.rs` |
| `Sp3MergeInputIdentityError` | enum | `sp3.rs` |

## `sidereon_core::sp3::samples`

| Item | Kind | Binding |
|---|---|---|
| `PreciseEphemerisAccuracySample` | struct | `precise_samples.rs` |
| `PreciseEphemerisSample` | struct | `precise_samples.rs` |
| `PreciseEphemerisSamples` | struct | `precise_samples.rs` |
| `PreciseEphemerisStateSample` | struct | MISSING |
| `PreciseSamplesError` | enum | `precise_samples.rs` |
| `sp3_ecef_state_to_eci` | fn | MISSING |

## `sidereon_core::sp3::verify`

| Item | Kind | Binding |
|---|---|---|
| `InterpolationComparison` | struct | MISSING |
| `InterpolationDivergence` | struct | MISSING |
| `ReferenceState` | struct | MISSING |
| `compare_position_series` | fn | MISSING |

## `sidereon_core::sp3::write`

| Item | Kind | Binding |
|---|---|---|
| `Sp3WriteError` | enum | `sp3.rs` |

## `sidereon_core::spp`

| Item | Kind | Binding |
|---|---|---|
| `Corrections` | struct | `dgnss.rs`, `sbas.rs`, `spp.rs` |
| `DopplerObservation` | struct | `spp.rs` |
| `DopplerVelocityInputs` | struct | MISSING |
| `ExactSolveInputs` | struct | `spp.rs` |
| `KlobucharCoeffs` | struct | `qc.rs`, `spp.rs`, `ssr.rs`, `static_positioning.rs` |
| `Observation` | struct | `astro_observe_almanac.rs`, `rtk.rs`, `rtk_filter.rs`, `spp.rs` |
| `PseudorangeCode` | enum | `spp.rs` |
| `QzssClock` | enum | `spp.rs` |
| `ReceiverSolution` | struct | `qc.rs`, `spp.rs` |
| `RejectedSat` | struct | MISSING |
| `RejectionReason` | enum | `spp.rs`, `static_positioning.rs` |
| `RobustConfig` | struct | `qc.rs`, `spp.rs`, `static_positioning.rs` |
| `SolutionMetadata` | struct | MISSING |
| `SolveInputs` | struct | `qc.rs`, `spp.rs` |
| `SolvePolicy` | struct | `sbas.rs`, `spp.rs` |
| `SolvePolicyError` | enum | `spp.rs` |
| `SppDopplerSolution` | struct | `spp.rs` |
| `SppError` | enum | `qc.rs`, `spp.rs` |
| `SppInputErrorKind` | enum | `spp.rs` |
| `SurfaceMet` | struct | `consts.rs`, `precise_positioning.rs`, `spp.rs` |
| `TroposphereModel` | enum | `spp.rs` |
| `residual_rms` | fn | `spp.rs` |
| `solve` | fn | `broadcast.rs`, `dgnss.rs`, `precise_positioning.rs`, `qc.rs`, `rtk_filter.rs`, `sbas.rs`, `source_localization.rs`, `spp.rs`, `ssr_bias_exclusion.rs`, `trls.rs`, `velocity.rs` |
| `solve_doppler_velocity` | fn | MISSING |
| `solve_spp_batch_parallel` | fn | `spp.rs` |
| `solve_spp_batch_serial` | fn | `spp.rs` |
| `solve_with_doppler_velocity` | fn | `spp.rs` |
| `solve_with_exact_epoch` | fn | MISSING |
| `solve_with_exact_epoch_and_policy` | fn | `spp.rs` |
| `solve_with_policy` | fn | MISSING |
| `solve_with_solver` | fn | MISSING |

## `sidereon_core::spp::config`

| Item | Kind | Binding |
|---|---|---|
| `DEFAULT_ROBUST_MAX_OUTER` | const | `consts.rs` |
| `DEFAULT_ROBUST_OUTER_TOL_M` | const | `consts.rs`, `spp.rs` |
| `DEFAULT_ROBUST_SCALE_FLOOR_M` | const | `consts.rs` |
| `ELEVATION_MASK_RAD` | const | MISSING |

## `sidereon_core::spp::fallback`

| Item | Kind | Binding |
|---|---|---|
| `BroadcastReason` | enum | `spp.rs` |
| `FallbackError` | enum | `spp.rs` |
| `FixSource` | enum | `spp.rs` |
| `SourcedSolution` | struct | `spp.rs` |
| `solve_broadcast` | fn | MISSING |
| `solve_with_fallback` | fn | `spp.rs` |

## `sidereon_core::spp::source`

| Item | Kind | Binding |
|---|---|---|
| `ClockRelativity` | enum | `observable_states.rs`, `observables.rs`, `sp3.rs` |
| `EphemerisSource` | trait | `astro_observe_almanac.rs`, `broadcast.rs`, `observable_states.rs`, `qc.rs`, `sbas.rs`, `sp3.rs`, `spp.rs` |
| `PositionClock` | type | MISSING |
| `PositionClockGroupDelay` | type | MISSING |

## `sidereon_core::ssr`

| Item | Kind | Binding |
|---|---|---|
| `ActiveProvenanceStatus` | enum | MISSING |
| `HasCodeBiasIngestionRecord` | struct | MISSING |
| `HasIngestionReport` | struct | MISSING |
| `HasPhaseBiasIngestionRecord` | struct | MISSING |
| `IngestionActionReason` | enum | MISSING |
| `MissingCorrectionAction` | enum | `ssr.rs` |
| `OrbitBasis` | enum | MISSING |
| `OrbitReferencePoint` | type | MISSING |
| `PhaseContinuityToken` | struct | `ssr_bias_exclusion.rs` |
| `PhaseDiscontinuityIndicator` | enum | `ssr_bias_exclusion.rs` |
| `RegionalPolicy` | enum | `ssr.rs` |
| `SSR_MAX_CLOCK_CORRECTION_M` | const | MISSING |
| `SSR_MAX_ORBIT_CORRECTION_M` | const | MISSING |
| `SsrBiasResolutionDetails` | enum | `ssr_bias_exclusion.rs` |
| `SsrBiasStatus` | enum | `ssr_bias_exclusion.rs` |
| `SsrClockCorrection` | struct | `ssr.rs` |
| `SsrCodeBias` | struct | MISSING |
| `SsrCodeBiasQueryResult` | struct | `ssr_bias_exclusion.rs` |
| `SsrCorrectedEphemeris` | struct | `ssr.rs` |
| `SsrCorrectedEphemerisOwned` | struct | MISSING |
| `SsrCorrectionSize` | struct | `precise_positioning.rs`, `ssr.rs` |
| `SsrCorrectionSizePolicy` | enum | `ssr.rs` |
| `SsrCorrectionSource` | trait | MISSING |
| `SsrCorrectionStore` | struct | `ssr.rs` |
| `SsrDiscontinuityDetails` | enum | `ssr_bias_exclusion.rs` |
| `SsrFallbackPolicy` | struct | `ssr.rs` |
| `SsrHighRateClock` | struct | MISSING |
| `SsrLifetime` | enum | `ssr_bias_exclusion.rs` |
| `SsrNavigationMessage` | enum | `ssr.rs` |
| `SsrOrbitCorrection` | struct | `ssr.rs` |
| `SsrOversizedCorrection` | struct | `ssr.rs` |
| `SsrPhaseBias` | struct | MISSING |
| `SsrPhaseBiasQueryResult` | struct | `ssr_bias_exclusion.rs` |
| `SsrReferencePoint` | enum | MISSING |
| `SsrSatelliteAttitude` | enum | MISSING |
| `SsrSolution` | struct | `ssr.rs`, `ssr_bias_exclusion.rs` |
| `SsrSource` | enum | `ssr.rs`, `ssr_bias_exclusion.rs` |
| `SsrStateUnavailable` | enum | MISSING |
| `SsrVtecAgePolicy` | enum | MISSING |
| `SsrVtecQuery` | enum | MISSING |

## `sidereon_core::ssr::signal`

| Item | Kind | Binding |
|---|---|---|
| `GnssSignal` | struct | `ssr_bias_exclusion.rs` |
| `SignalCode` | struct | `precise_positioning.rs`, `ssr_bias_exclusion.rs` |
| `SsrRawSignal` | struct | `ssr_bias_exclusion.rs` |
| `SsrSignalKey` | enum | `ssr_bias_exclusion.rs` |
| `has_signal` | fn | MISSING |
| `igs_ssr_signal` | fn | MISSING |
| `rtcm_ssr_signal` | fn | MISSING |

## `sidereon_core::staleness`

| Item | Kind | Binding |
|---|---|---|
| `DEFAULT_MAX_STALENESS_DAYS` | const | MISSING |
| `DegradationKind` | enum | `staleness.rs` |
| `IonexSelection` | struct | MISSING |
| `SelectionError` | enum | `staleness.rs` |
| `Sp3Selection` | struct | MISSING |
| `StalenessMetadata` | struct | `staleness.rs` |
| `StalenessPolicy` | struct | `sbas.rs`, `spp.rs`, `staleness.rs` |
| `select_ionex` | fn | `staleness.rs` |
| `select_ionex_over_range` | fn | `staleness.rs` |
| `select_sp3` | fn | `staleness.rs` |
| `select_sp3_over_range` | fn | `staleness.rs` |

## `sidereon_core::static_positioning`

| Item | Kind | Binding |
|---|---|---|
| `StaticClockBias` | struct | MISSING |
| `StaticCovariance` | struct | MISSING |
| `StaticEpoch` | struct | `static_positioning.rs` |
| `StaticEpochInfluence` | struct | MISSING |
| `StaticInfluenceStatus` | enum | `static_positioning.rs` |
| `StaticResidual` | struct | MISSING |
| `StaticSatelliteBatchInfluence` | struct | MISSING |
| `StaticSatelliteInfluence` | struct | MISSING |
| `StaticSolution` | struct | `static_positioning.rs` |
| `StaticSolutionMetadata` | struct | MISSING |
| `StaticSolveError` | enum | `static_positioning.rs` |
| `StaticSolveOptions` | struct | `static_positioning.rs` |
| `solve_static` | fn | `static_positioning.rs` |
| `solve_static_geometric_light_time_replay` | fn | MISSING |

## `sidereon_core::static_reference_station`

| Item | Kind | Binding |
|---|---|---|
| `StaticReferenceCarrierRinexOptions` | struct | `rtk_filter.rs` |
| `StaticReferenceCarrierSolution` | struct | `rtk_filter.rs` |
| `StaticReferenceCodeSolution` | struct | `rtk_filter.rs` |
| `StaticReferenceEpochDiagnostic` | struct | `rtk_filter.rs` |
| `StaticReferenceFixStatus` | enum | `rtk_filter.rs` |
| `StaticReferenceModeError` | enum | `rtk_filter.rs` |
| `StaticReferenceModeReport` | struct | `rtk_filter.rs` |
| `StaticReferenceModeStatus` | enum | `rtk_filter.rs` |
| `StaticReferenceStationCovariance` | struct | `rtk_filter.rs` |
| `StaticReferenceStationError` | enum | `rtk_filter.rs` |
| `StaticReferenceStationMode` | enum | `rtk_filter.rs` |
| `StaticReferenceStationRinexOptions` | struct | `rtk_filter.rs` |
| `StaticReferenceStationSolution` | struct | `rtk_filter.rs` |
| `solve_static_reference_station_rinex` | fn | `rtk_filter.rs` |

## `sidereon_core::terrain`

| Item | Kind | Binding |
|---|---|---|
| `DtedHorizontalDatum` | enum | `spp.rs`, `terrain_store.rs` |
| `DtedInterpolation` | enum | `astro_phase_b.rs`, `terrain_store.rs` |
| `DtedLookupOptions` | struct | `astro_phase_b.rs`, `terrain_store.rs` |
| `DtedTerrain` | struct | `astro_phase_b.rs` |
| `DtedTile` | struct | `astro_phase_b.rs` |
| `DtedTileError` | enum | `astro_phase_b.rs`, `spp.rs` |

## `sidereon_core::terrain_store`

| Item | Kind | Binding |
|---|---|---|
| `DtedTileListEntry` | struct | `terrain_store.rs` |
| `Egm96FifteenMinuteGeoid` | struct | `terrain_store.rs` |
| `EllipsoidalHeightM` | struct | `terrain_store.rs` |
| `MmapTerrain` | struct | `terrain_store.rs` |
| `OrthometricHeightM` | struct | `terrain_store.rs` |
| `TERRAIN_STORE_NULL_POSTING` | const | MISSING |
| `TerrainDatumError` | enum | `terrain_store.rs` |
| `TerrainGeoidModel` | enum | `terrain_store.rs` |
| `TerrainStoreError` | enum | `terrain_store.rs` |
| `TerrainStoreTileIndex` | struct | `terrain_store.rs` |
| `TerrainTileId` | struct | `terrain_store.rs` |
| `VerticalDatum` | enum | `terrain_store.rs` |
| `dted_tile_list_to_mmap_store` | fn | `terrain_store.rs` |
| `dted_tree_to_mmap_store` | fn | `terrain_store.rs` |
| `terrain_store_checksum64` | fn | `terrain_store.rs` |
| `write_dted_tile_list_to_mmap_store` | fn | `terrain_store.rs` |
| `write_dted_tree_to_mmap_store` | fn | `terrain_store.rs` |

## `sidereon_core::tides`

| Item | Kind | Binding |
|---|---|---|
| `BlqParseErrorKind` | enum | `tides.rs` |
| `BlqWriteErrorKind` | enum | `tides.rs` |
| `StationDisplacement` | struct | `tides.rs` |
| `StationDisplacementEpoch` | struct | `tides.rs` |
| `StationDisplacementOptions` | struct | `tides.rs` |
| `StationDisplacementPosition` | enum | `tides.rs` |
| `StationPolarMotion` | struct | MISSING |
| `StationTideConstants` | enum | `ppp_corrections.rs`, `tides.rs` |
| `TideError` | enum | `tides.rs` |
| `TideInputErrorKind` | enum | `tides.rs` |
| `solid_earth_tide` | fn | `lib.rs`, `ppp_corrections.rs`, `precise_positioning.rs`, `propagation.rs`, `tides.rs` |
| `solid_earth_tide_with_constants` | fn | `tides.rs` |
| `station_displacement_ecef_m` | fn | MISSING |
| `station_displacement_ecef_m_batch` | fn | MISSING |
| `station_displacement_ecef_m_batch_with_validity` | fn | `tides.rs` |
| `station_displacement_ecef_m_with_validity` | fn | `tides.rs` |

## `sidereon_core::tides::ocean`

| Item | Kind | Binding |
|---|---|---|
| `NUM_OCEAN_CONSTITUENTS` | const | `ppp_corrections.rs` |
| `OCEAN_LOADING_CONSTITUENTS` | const | MISSING |
| `OceanLoadingBlq` | struct | `ppp_corrections.rs`, `tides.rs` |
| `OceanLoadingBlqBlock` | struct | MISSING |
| `OceanLoadingBlqComment` | struct | MISSING |
| `OceanLoadingBlqCommentPlacement` | enum | MISSING |
| `OceanTideConstituent` | enum | MISSING |
| `ocean_tide_loading` | fn | `lib.rs`, `tides.rs` |
| `parse_ocean_loading_blq_block` | fn | MISSING |
| `parse_ocean_loading_blq_blocks` | fn | MISSING |
| `write_ocean_loading_blq_blocks` | fn | MISSING |

## `sidereon_core::tides::pole`

| Item | Kind | Binding |
|---|---|---|
| `solid_earth_pole_tide` | fn | `lib.rs`, `propagation.rs`, `tides.rs` |

## `sidereon_core::tolerances`

| Item | Kind | Binding |
|---|---|---|
| `DOPPLER_GRID_EDGE_EPS_HZ` | const | MISSING |
| `ECCENTRICITY_ZERO_EPS` | const | MISSING |
| `FREQUENCY_DENOMINATOR_EPS_HZ` | const | MISSING |
| `FREQUENCY_MATCH_EPS_HZ` | const | MISSING |
| `GLONASS_TIME_EPS_S` | const | MISSING |
| `LAMBDA_REDUCTION_EPS` | const | MISSING |
| `PPP_FREQUENCY_ABS_EPS_HZ` | const | MISSING |
| `PPP_FREQUENCY_REL_EPS` | const | MISSING |
| `REDUCED_ORBIT_KEPLER_STEP_EPS_RAD` | const | MISSING |
| `REDUCED_ORBIT_SOLVER_TOL` | const | MISSING |
| `SBAS_IGP_COORD_EPS_DEG` | const | MISSING |
| `VECTOR_NORM_ZERO_EPS` | const | MISSING |
| `WHOLE_SECOND_EPS_S` | const | MISSING |
| `YAW_SINGULARITY_EPS_RAD` | const | MISSING |

## `sidereon_core::tropo`

| Item | Kind | Binding |
|---|---|---|
| `MappingFactors` | struct | MISSING |
| `MappingModel` | enum | `observables.rs`, `tropo.rs` |
| `Met` | struct | `observables.rs`, `precise_positioning.rs`, `tropo.rs` |
| `NIELL_MIN_MAPPING_ELEVATION_RAD` | const | MISSING |
| `TROPO_MIN_MAPPING_ELEVATION_RAD` | const | MISSING |
| `TropoModel` | enum | `tropo.rs` |
| `ZenithDelay` | struct | MISSING |
| `tropo_mapping` | fn | `tropo.rs` |
| `tropo_slant` | fn | `tropo.rs` |
| `tropo_zenith` | fn | `tropo.rs` |

## `sidereon_core::tropo::zwd`

| Item | Kind | Binding |
|---|---|---|
| `AltitudeClamp` | struct | MISSING |
| `ZwdEpoch` | struct | MISSING |
| `ZwdProfile` | struct | MISSING |
| `ZwdSlantOptions` | struct | MISSING |

## `sidereon_core::validate`

| Item | Kind | Binding |
|---|---|---|
| `FieldError` | enum | `nmea.rs` |

## `sidereon_core::velocity`

| Item | Kind | Binding |
|---|---|---|
| `VelocityError` | enum | `spp.rs`, `velocity.rs` |
| `VelocityObservable` | enum | `velocity.rs` |
| `VelocityObservation` | struct | `velocity.rs` |
| `VelocitySolution` | struct | `spp.rs`, `velocity.rs` |
| `VelocitySolveOptions` | struct | `velocity.rs` |
| `doppler_to_range_rate` | fn | `velocity.rs` |
| `range_rate_to_doppler` | fn | `velocity.rs` |
| `solve` | fn | `broadcast.rs`, `dgnss.rs`, `precise_positioning.rs`, `qc.rs`, `rtk_filter.rs`, `sbas.rs`, `source_localization.rs`, `spp.rs`, `ssr_bias_exclusion.rs`, `trls.rs`, `velocity.rs` |
