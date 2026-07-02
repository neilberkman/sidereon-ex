//! Rustler boundary for TLE pass prediction.
//!
//! The pass search itself lives in `sidereon_core::astro::passes`; this module only
//! decodes Sidereon terms and encodes unix-microsecond pass rows.

use crate::propagation::{elements_from_map, get_map_val, opsmode_from_term};
use rustler::{Encoder, Env, Error, NifResult, Term};
use sidereon_core::astro::passes::{
    find_passes_for_satellite, ground_track, look_angle_batch_serial, visible_from_satellites,
    GroundStation, PassFinderOptions, UtcInstant,
};
use sidereon_core::astro::sgp4::Satellite;

type DateTuple = (i32, i32, i32);
type TimeTuple = (i32, i32, i32, i32);
type PassTerm = (i64, i64, f64, i64);
type Vec3 = (f64, f64, f64);
type VisibleTerm = (String, f64, f64, f64, Vec3);
/// One satellite's arc as `[{azimuth_deg, elevation_deg, range_km}, ...]` (look
/// angles) or `[{lat_deg, lon_deg, alt_km}, ...]` (ground track), one per epoch.
type Arc = Vec<Vec3>;
/// One constellation pass: fleet-order satellite index, catalog number, and the
/// `(aos_us, los_us, max_elevation_deg, culmination_us)` pass geometry.
type FleetPassTerm = (u32, String, i64, i64, f64, i64);

#[allow(clippy::too_many_arguments)]
pub(crate) fn predict_passes_impl<'a>(
    env: Env<'a>,
    tle_map: Term<'a>,
    station_latitude_deg: f64,
    station_longitude_deg: f64,
    station_altitude_m: f64,
    start_datetime: Term<'a>,
    end_datetime: Term<'a>,
    min_elevation_deg: f64,
    step_seconds: i64,
    opsmode: Term<'a>,
) -> NifResult<Vec<PassTerm>> {
    let elements = elements_from_map(env, tle_map)?;
    let opsmode = opsmode_from_term(env, opsmode)?;
    let start_time = instant_from_datetime_tuple(start_datetime)?;
    let end_time = instant_from_datetime_tuple(end_datetime)?;
    let station = GroundStation {
        latitude_deg: station_latitude_deg,
        longitude_deg: station_longitude_deg,
        altitude_m: station_altitude_m,
    };
    // `:min_elevation` is a *peak-elevation* filter (see `Sidereon.Passes`): it
    // drops passes whose maximum elevation is below the threshold, while rise/
    // set/duration always reference the 0-degree horizon. The finder's
    // `elevation_mask_deg` instead moves AOS/LOS to the threshold crossing, so
    // we must NOT route `min_elevation` there. Validate it separately (matching
    // the range the finder's mask validation used to enforce when this value was
    // incorrectly passed as the mask) before falling back to the peak filter.
    if !(min_elevation_deg.is_finite() && (-90.0..=90.0).contains(&min_elevation_deg)) {
        return Err(crate::errors::invalid_input(()));
    }
    // Build the SGP4 satellite with the *requested* opsmode and run the
    // satellite-based pass finder, so the pass times come from the same
    // initialized handle (and same opsmode) the look-angle path uses, instead
    // of the element-set helper that silently forces AFSPC. An init failure on
    // a degenerate element set yields no passes, matching the core element-set
    // finders' `Ok(empty)` contract.
    let satellite = match Satellite::from_elements_with_opsmode(&elements, opsmode) {
        Ok(satellite) => satellite,
        Err(_) => return Ok(Vec::new()),
    };
    // Find ALL horizon passes (mask = 0 deg) so AOS/LOS stay on the horizon,
    // then apply `:min_elevation` as a peak filter below.
    let options = PassFinderOptions {
        elevation_mask_deg: 0.0,
        coarse_step_seconds: step_seconds as f64,
        ..PassFinderOptions::default()
    };

    Ok(
        find_passes_for_satellite(&satellite, station, start_time, end_time, options)
            .map_err(crate::errors::invalid_input)?
            .into_iter()
            .filter(|pass| pass.max_elevation_deg >= min_elevation_deg)
            .map(|pass| {
                (
                    pass.aos.unix_microseconds(),
                    pass.los.unix_microseconds(),
                    pass.max_elevation_deg,
                    pass.culmination.unix_microseconds(),
                )
            })
            .collect(),
    )
}

pub(crate) fn instant_from_datetime_tuple(datetime: Term) -> NifResult<UtcInstant> {
    let ((year, month, day), (hour, minute, second, microsecond)): (DateTuple, TimeTuple) =
        datetime.decode()?;
    UtcInstant::from_utc(year, month, day, hour, minute, second, microsecond).ok_or(Error::BadArg)
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn constellation_visible_impl<'a>(
    env: Env<'a>,
    tle_maps: Vec<Term<'a>>,
    station_latitude_deg: f64,
    station_longitude_deg: f64,
    station_altitude_m: f64,
    datetime: Term<'a>,
    min_elevation_deg: f64,
    opsmode: Term<'a>,
) -> NifResult<Vec<VisibleTerm>> {
    let opsmode = opsmode_from_term(env, opsmode)?;
    let instant = instant_from_datetime_tuple(datetime)?;
    let station = GroundStation {
        latitude_deg: station_latitude_deg,
        longitude_deg: station_longitude_deg,
        altitude_m: station_altitude_m,
    };

    // Build each satellite with the requested opsmode and hand the parallel
    // (satellites, ids) slices to the shared core finder. A degenerate element
    // set that fails SGP4 init is skipped (along with its id), matching the core
    // `visible_from_satellites` per-satellite skip contract. Building with the
    // requested opsmode keeps visibility bit-consistent with the look-angle and
    // pass paths run under the same opsmode.
    let mut satellites = Vec::with_capacity(tle_maps.len());
    let mut ids = Vec::with_capacity(tle_maps.len());
    for tle_map in tle_maps {
        let catalog_number: String = get_map_val(env, tle_map, "catalog_number")?;
        let elements = elements_from_map(env, tle_map)?;
        if let Ok(satellite) = Satellite::from_elements_with_opsmode(&elements, opsmode) {
            satellites.push(satellite);
            ids.push(catalog_number);
        }
    }

    // One shared core call does the propagate/topocentric/threshold-filter/sort;
    // the NIF only re-encodes the typed rows as Elixir terms (preserving the
    // existing `{catalog_number, elevation, azimuth, range_km, position}` order).
    // The station/threshold validation now lives in the core finder, surfacing a
    // bad input as a raised `:invalid_input` term.
    Ok(
        visible_from_satellites(&satellites, &ids, station, instant, min_elevation_deg)
            .map_err(crate::errors::invalid_input)?
            .into_iter()
            .map(|v| {
                (
                    v.catalog_number,
                    v.elevation_deg,
                    v.azimuth_deg,
                    v.range_km,
                    (v.position_km[0], v.position_km[1], v.position_km[2]),
                )
            })
            .collect(),
    )
}

/// Per-epoch sub-satellite (ground-track) geodetic points for one satellite.
///
/// Wraps core `passes::ground_track`, which composes the existing
/// propagate -> TEME->GCRS -> GCRS->ECEF -> geodetic transforms. The NIF only
/// builds the satellite with the requested opsmode and bridges the core's
/// radians + meters back to the degrees + kilometres convention used by
/// `Sidereon.Geodetic`.
pub(crate) fn ground_track_impl<'a>(
    env: Env<'a>,
    tle_map: Term<'a>,
    datetimes: Vec<Term<'a>>,
    opsmode: Term<'a>,
) -> NifResult<Term<'a>> {
    let ok = rustler::types::atom::Atom::from_str(env, "ok")?;
    let error = rustler::types::atom::Atom::from_str(env, "error")?;

    let elements = elements_from_map(env, tle_map)?;
    let opsmode = opsmode_from_term(env, opsmode)?;
    let instants = datetimes
        .into_iter()
        .map(instant_from_datetime_tuple)
        .collect::<NifResult<Vec<_>>>()?;
    // An empty input list has no sub-points to compute and never needs a
    // satellite, so `{:ok, []}` is the answer regardless of element validity.
    // Reserve that empty result for empty input ONLY.
    if instants.is_empty() {
        return Ok((ok, Vec::<Vec3>::new()).encode(env));
    }
    // For a non-empty list a failed SGP4 init is a real failure: surface it as
    // `{:error, "SGP4 init: ..."}` (matching `tle_look_angle`) instead of
    // masking it as `{:ok, []}`, honoring the "one geodetic point per datetime,
    // or an error" contract shared by `geodetic/2` and `look_angle/4`.
    let satellite = match Satellite::from_elements_with_opsmode(&elements, opsmode) {
        Ok(satellite) => satellite,
        Err(err) => return Ok((error, format!("SGP4 init: {err}")).encode(env)),
    };
    let points: Vec<Vec3> = ground_track(&satellite, &instants)
        .map_err(crate::errors::invalid_input)?
        .into_iter()
        .map(|p| {
            (
                p.lat_rad.to_degrees(),
                p.lon_rad.to_degrees(),
                p.height_m / 1000.0,
            )
        })
        .collect();
    Ok((ok, points).encode(env))
}

/// Topocentric az/el/range arcs for a whole constellation over a shared epoch
/// grid, in fleet order (element `i` is satellite `i`'s arc).
///
/// Builds each satellite once with the requested opsmode and hands the valid
/// fleet to the shared core `look_angle_batch_serial`. A satellite whose
/// well-formed element set fails SGP4 init (or whose arc errors on propagation)
/// yields an empty arc, so the result stays index-aligned with the constellation
/// (mirroring the WASM `Constellation.lookAngleArcs`).
#[allow(clippy::too_many_arguments)]
pub(crate) fn constellation_look_angle_arcs_impl<'a>(
    env: Env<'a>,
    tle_maps: Vec<Term<'a>>,
    station_latitude_deg: f64,
    station_longitude_deg: f64,
    station_altitude_m: f64,
    datetimes: Vec<Term<'a>>,
    opsmode: Term<'a>,
) -> NifResult<Vec<Arc>> {
    let opsmode = opsmode_from_term(env, opsmode)?;
    let station = GroundStation {
        latitude_deg: station_latitude_deg,
        longitude_deg: station_longitude_deg,
        altitude_m: station_altitude_m,
    };
    let instants = datetimes
        .into_iter()
        .map(instant_from_datetime_tuple)
        .collect::<NifResult<Vec<_>>>()?;

    let satellite_count = tle_maps.len();
    let mut satellites = Vec::with_capacity(satellite_count);
    let mut fleet_indices = Vec::with_capacity(satellite_count);
    for (index, tle_map) in tle_maps.into_iter().enumerate() {
        let elements = elements_from_map(env, tle_map)?;
        if let Ok(satellite) = Satellite::from_elements_with_opsmode(&elements, opsmode) {
            satellites.push(satellite);
            fleet_indices.push(index);
        }
    }

    // Empty arc placeholder for every fleet slot; filled in for the satellites
    // that built, by mapping the compact batch result back to its fleet index.
    let mut arcs: Vec<Arc> = vec![Vec::new(); satellite_count];
    for (compact_index, arc) in look_angle_batch_serial(&satellites, station, &instants)
        .into_iter()
        .enumerate()
    {
        if let Ok(looks) = arc {
            arcs[fleet_indices[compact_index]] = looks
                .into_iter()
                .map(|l| (l.azimuth_deg, l.elevation_deg, l.range_km))
                .collect();
        }
    }
    Ok(arcs)
}

/// Sub-satellite WGS84 ground tracks for a whole constellation over a shared
/// epoch grid, in fleet order (element `i` is satellite `i`'s track).
///
/// Per-satellite loop over the core `ground_track`, building each satellite with
/// the requested opsmode. A satellite that fails SGP4 init or whose track errors
/// yields an empty track, keeping the result index-aligned (mirroring the WASM
/// `Constellation.groundTracks`). Radians/metres are bridged back to the
/// degrees/kilometres convention used by `Sidereon.Geodetic`.
pub(crate) fn constellation_ground_tracks_impl<'a>(
    env: Env<'a>,
    tle_maps: Vec<Term<'a>>,
    datetimes: Vec<Term<'a>>,
    opsmode: Term<'a>,
) -> NifResult<Vec<Arc>> {
    let opsmode = opsmode_from_term(env, opsmode)?;
    let instants = datetimes
        .into_iter()
        .map(instant_from_datetime_tuple)
        .collect::<NifResult<Vec<_>>>()?;

    let mut tracks = Vec::with_capacity(tle_maps.len());
    for tle_map in tle_maps {
        let elements = elements_from_map(env, tle_map)?;
        let track: Arc = match Satellite::from_elements_with_opsmode(&elements, opsmode) {
            Ok(satellite) => match ground_track(&satellite, &instants) {
                Ok(points) => points
                    .into_iter()
                    .map(|p| {
                        (
                            p.lat_rad.to_degrees(),
                            p.lon_rad.to_degrees(),
                            p.height_m / 1000.0,
                        )
                    })
                    .collect(),
                Err(_) => Vec::new(),
            },
            Err(_) => Vec::new(),
        };
        tracks.push(track);
    }
    Ok(tracks)
}

/// Passes for a whole constellation over a window, flattened across the fleet:
/// each row carries the fleet-order satellite index and its catalog number.
///
/// Per-satellite loop over the core `find_passes_for_satellite`, building each
/// satellite with the requested opsmode. `min_elevation_deg` is the same
/// peak-elevation filter as `predict_passes` (AOS/LOS stay on the 0-degree
/// horizon; a pass is dropped when its culmination is below the threshold), so
/// constellation passes are consistent with `Sidereon.Passes.predict`. A
/// satellite that fails SGP4 init or whose scan errors contributes no passes;
/// its fleet index is still consumed so the indices match the constellation
/// order.
#[allow(clippy::too_many_arguments)]
pub(crate) fn constellation_passes_impl<'a>(
    env: Env<'a>,
    tle_maps: Vec<Term<'a>>,
    station_latitude_deg: f64,
    station_longitude_deg: f64,
    station_altitude_m: f64,
    start_datetime: Term<'a>,
    end_datetime: Term<'a>,
    min_elevation_deg: f64,
    step_seconds: i64,
    opsmode: Term<'a>,
) -> NifResult<Vec<FleetPassTerm>> {
    let opsmode = opsmode_from_term(env, opsmode)?;
    let start_time = instant_from_datetime_tuple(start_datetime)?;
    let end_time = instant_from_datetime_tuple(end_datetime)?;
    let station = GroundStation {
        latitude_deg: station_latitude_deg,
        longitude_deg: station_longitude_deg,
        altitude_m: station_altitude_m,
    };
    // `min_elevation` is a peak-elevation filter, not the finder's AOS/LOS mask
    // (see `predict_passes_impl`); validate it over the same range before falling
    // back to the peak filter below.
    if !(min_elevation_deg.is_finite() && (-90.0..=90.0).contains(&min_elevation_deg)) {
        return Err(crate::errors::invalid_input(()));
    }
    // Find ALL horizon passes (mask = 0 deg) so AOS/LOS stay on the horizon,
    // then keep only those whose peak clears `min_elevation`.
    let options = PassFinderOptions {
        elevation_mask_deg: 0.0,
        coarse_step_seconds: step_seconds as f64,
        ..PassFinderOptions::default()
    };

    let mut out = Vec::new();
    for (index, tle_map) in tle_maps.into_iter().enumerate() {
        let catalog_number: String = get_map_val(env, tle_map, "catalog_number")?;
        let elements = elements_from_map(env, tle_map)?;
        let satellite = match Satellite::from_elements_with_opsmode(&elements, opsmode) {
            Ok(satellite) => satellite,
            Err(_) => continue,
        };
        let passes =
            match find_passes_for_satellite(&satellite, station, start_time, end_time, options) {
                Ok(passes) => passes,
                Err(_) => continue,
            };
        for pass in passes {
            if pass.max_elevation_deg >= min_elevation_deg {
                out.push((
                    index as u32,
                    catalog_number.clone(),
                    pass.aos.unix_microseconds(),
                    pass.los.unix_microseconds(),
                    pass.max_elevation_deg,
                    pass.culmination.unix_microseconds(),
                ));
            }
        }
    }
    Ok(out)
}
