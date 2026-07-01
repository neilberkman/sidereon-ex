checksum_file = Path.expand("../../checksum-Elixir.Sidereon.NIF.exs", __DIR__)
version = Mix.Project.config()[:version]
source_checkout? = File.exists?(Path.expand("../../.git", __DIR__))

checksum_current? =
  File.exists?(checksum_file) and
    checksum_file |> File.read!() |> String.contains?("-v#{version}-")

# Consumers (no .git, checksum matching this version) download the precompiled
# NIF; a source checkout, a stale/missing checksum, or SIDEREON_BUILD forces a
# local build from source (requires a Rust toolchain).
force_build =
  System.get_env("SIDEREON_BUILD") in ["1", "true"] or source_checkout? or not checksum_current?

defmodule Sidereon.NIF do
  @moduledoc false

  use RustlerPrecompiled,
    otp_app: :sidereon,
    crate: "sidereon_nif",
    base_url: "https://github.com/neilberkman/sidereon-ex/releases/download/v#{version}",
    force_build: force_build,
    nif_versions: ["2.15"],
    targets: [
      "aarch64-apple-darwin",
      "aarch64-unknown-linux-gnu",
      "x86_64-apple-darwin",
      "x86_64-pc-windows-msvc",
      "x86_64-unknown-linux-gnu"
    ],
    version: version

  def propagate_with_elements(_tle_map, _datetime_tuple), do: :erlang.nif_error(:nif_not_loaded)

  def propagate_dp54(_position_km, _velocity_km_s, _dt_seconds, _forces, _abs_tol, _rel_tol),
    do: :erlang.nif_error(:nif_not_loaded)

  def predict_passes(
        _tle_map,
        _station_latitude_deg,
        _station_longitude_deg,
        _station_altitude_m,
        _start_datetime,
        _end_datetime,
        _min_elevation_deg,
        _step_seconds,
        _opsmode
      ), do: :erlang.nif_error(:nif_not_loaded)

  def constellation_visible(
        _tle_maps,
        _station_latitude_deg,
        _station_longitude_deg,
        _station_altitude_m,
        _datetime_tuple,
        _min_elevation_deg,
        _opsmode
      ), do: :erlang.nif_error(:nif_not_loaded)

  def ground_track(_tle_map, _datetimes, _opsmode), do: :erlang.nif_error(:nif_not_loaded)

  def constellation_look_angle_arcs(
        _tle_maps,
        _station_latitude_deg,
        _station_longitude_deg,
        _station_altitude_m,
        _datetimes,
        _opsmode
      ), do: :erlang.nif_error(:nif_not_loaded)

  def constellation_ground_tracks(_tle_maps, _datetimes, _opsmode), do: :erlang.nif_error(:nif_not_loaded)

  def constellation_passes(
        _tle_maps,
        _station_latitude_deg,
        _station_longitude_deg,
        _station_altitude_m,
        _start_datetime,
        _end_datetime,
        _min_elevation_deg,
        _step_seconds,
        _opsmode
      ), do: :erlang.nif_error(:nif_not_loaded)

  def tle_look_angle(
        _tle_map,
        _station_latitude_deg,
        _station_longitude_deg,
        _station_altitude_m,
        _datetime_tuple,
        _opsmode
      ), do: :erlang.nif_error(:nif_not_loaded)

  def tle_parse(_line1, _line2), do: :erlang.nif_error(:nif_not_loaded)

  def tle_encode(_fields), do: :erlang.nif_error(:nif_not_loaded)

  def parse_tle_file(_text), do: :erlang.nif_error(:nif_not_loaded)

  def cdm_parse_kvn(_text), do: :erlang.nif_error(:nif_not_loaded)

  def cdm_encode_kvn(_fields), do: :erlang.nif_error(:nif_not_loaded)

  def cdm_parse_xml(_text), do: :erlang.nif_error(:nif_not_loaded)

  def cdm_encode_xml(_fields), do: :erlang.nif_error(:nif_not_loaded)

  def omm_parse_kvn(_text), do: :erlang.nif_error(:nif_not_loaded)

  def omm_parse_xml(_text), do: :erlang.nif_error(:nif_not_loaded)

  def omm_parse_json(_text), do: :erlang.nif_error(:nif_not_loaded)

  def omm_encode_kvn(_fields), do: :erlang.nif_error(:nif_not_loaded)

  def omm_encode_xml(_fields), do: :erlang.nif_error(:nif_not_loaded)

  def omm_encode_json(_fields), do: :erlang.nif_error(:nif_not_loaded)

  def oem_parse_kvn(_text), do: :erlang.nif_error(:nif_not_loaded)

  def oem_parse_xml(_text), do: :erlang.nif_error(:nif_not_loaded)

  def oem_encode_kvn(_fields), do: :erlang.nif_error(:nif_not_loaded)

  def oem_encode_xml(_fields), do: :erlang.nif_error(:nif_not_loaded)

  def opm_parse_kvn(_text), do: :erlang.nif_error(:nif_not_loaded)

  def opm_parse_xml(_text), do: :erlang.nif_error(:nif_not_loaded)

  def opm_encode_kvn(_fields), do: :erlang.nif_error(:nif_not_loaded)

  def opm_encode_xml(_fields), do: :erlang.nif_error(:nif_not_loaded)

  def force_twobody_acceleration(_position, _velocity), do: :erlang.nif_error(:nif_not_loaded)

  def force_j2_acceleration(_position, _velocity), do: :erlang.nif_error(:nif_not_loaded)

  def eclipse_shadow_fraction(_sat_pos, _sun_pos), do: :erlang.nif_error(:nif_not_loaded)

  def eclipse_status(_sat_pos, _sun_pos), do: :erlang.nif_error(:nif_not_loaded)

  def angles_sun_angle(_sat_pos, _sun_pos), do: :erlang.nif_error(:nif_not_loaded)

  def angles_moon_angle(_sat_pos, _moon_pos), do: :erlang.nif_error(:nif_not_loaded)

  def angles_sun_elevation(_sat_pos, _sun_pos), do: :erlang.nif_error(:nif_not_loaded)

  def angles_phase_angle(_sat_pos, _sun_pos, _observer_pos), do: :erlang.nif_error(:nif_not_loaded)

  def angles_earth_angular_radius(_sat_pos), do: :erlang.nif_error(:nif_not_loaded)

  def rf_fspl(_distance_km, _frequency_mhz), do: :erlang.nif_error(:nif_not_loaded)

  def rf_fspl_batch(_distances_km, _frequency_mhz), do: :erlang.nif_error(:nif_not_loaded)

  def rf_eirp(_tx_power_dbm, _tx_antenna_gain_dbi), do: :erlang.nif_error(:nif_not_loaded)

  def rf_cn0(_eirp_dbw, _fspl_db, _receiver_gt_dbk, _other_losses_db), do: :erlang.nif_error(:nif_not_loaded)

  def rf_link_margin(_eirp_dbw, _fspl_db, _receiver_gt_dbk, _other_losses_db, _required_cn0_dbhz),
    do: :erlang.nif_error(:nif_not_loaded)

  def rf_link_margin_batch(_budgets), do: :erlang.nif_error(:nif_not_loaded)

  def rf_wavelength(_frequency_hz), do: :erlang.nif_error(:nif_not_loaded)

  def rf_dish_gain(_diameter_m, _frequency_hz, _efficiency), do: :erlang.nif_error(:nif_not_loaded)

  def covariance_rtn_to_eci(_cov_rtn, _r, _v), do: :erlang.nif_error(:nif_not_loaded)

  def covariance_positive_semidefinite(_m), do: :erlang.nif_error(:nif_not_loaded)

  def covariance_symmetric(_m), do: :erlang.nif_error(:nif_not_loaded)

  def encounter_frame(_r1, _v1, _r2, _v2), do: :erlang.nif_error(:nif_not_loaded)

  def encounter_plane_covariance(_x_hat, _z_hat, _cov), do: :erlang.nif_error(:nif_not_loaded)

  def collision_probability(_r1, _v1, _cov1, _r2, _v2, _cov2, _hbr, _method), do: :erlang.nif_error(:nif_not_loaded)

  def coverage_look_angles(_tle_maps, _stations, _datetime_tuple), do: :erlang.nif_error(:nif_not_loaded)

  def teme_to_gcrs(_x, _y, _z, _vx, _vy, _vz, _datetime, _skyfield_compat), do: :erlang.nif_error(:nif_not_loaded)

  def gcrs_to_itrs(_x, _y, _z, _datetime, _skyfield_compat), do: :erlang.nif_error(:nif_not_loaded)

  def itrs_to_gcrs(_x, _y, _z, _datetime), do: :erlang.nif_error(:nif_not_loaded)

  def itrs_to_geodetic(_x, _y, _z), do: :erlang.nif_error(:nif_not_loaded)

  def geodetic_to_itrs(_latitude_deg, _longitude_deg, _altitude_km), do: :erlang.nif_error(:nif_not_loaded)

  def gcrs_to_topocentric(_sat_x, _sat_y, _sat_z, _lat, _lon, _alt, _datetime, _skyfield_compat),
    do: :erlang.nif_error(:nif_not_loaded)

  def atmosphere_density(_lat, _lon, _alt, _year, _doy, _sec, _f107, _f107a, _ap),
    do: :erlang.nif_error(:nif_not_loaded)

  def spk_load(_bytes), do: :erlang.nif_error(:nif_not_loaded)

  def spk_internal_name(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def spk_segments(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def spk_state(_handle, _target, _center, _et), do: :erlang.nif_error(:nif_not_loaded)

  def j2000_seconds_from_split(_jd_whole, _jd_fraction), do: :erlang.nif_error(:nif_not_loaded)

  def utc_to_tdb_jd(_year, _month, _day, _hour, _minute, _second), do: :erlang.nif_error(:nif_not_loaded)

  def utc_to_tdb_jd_split(_year, _month, _day, _hour, _minute, _second), do: :erlang.nif_error(:nif_not_loaded)

  def doppler_shift(
        _sat_x,
        _sat_y,
        _sat_z,
        _sat_vx,
        _sat_vy,
        _sat_vz,
        _station_lat_deg,
        _station_lon_deg,
        _station_alt_km,
        _datetime_tuple,
        _frequency_hz
      ), do: :erlang.nif_error(:nif_not_loaded)

  def sun_moon_ecef(_datetime_tuple), do: :erlang.nif_error(:nif_not_loaded)

  def sun_moon_eci_batch(_epochs_unix_us), do: :erlang.nif_error(:nif_not_loaded)

  def sun_moon_ecef_batch(_epochs_unix_us), do: :erlang.nif_error(:nif_not_loaded)

  def solid_earth_tide(_sta_x, _sta_y, _sta_z, _year, _month, _day, _fhr, _sun, _moon),
    do: :erlang.nif_error(:nif_not_loaded)

  def solid_earth_pole_tide(_sta_x, _sta_y, _sta_z, _year, _month, _day, _fhr, _xp_arcsec, _yp_arcsec),
    do: :erlang.nif_error(:nif_not_loaded)

  def ocean_tide_loading(_sta_x, _sta_y, _sta_z, _year, _month, _day, _fhr, _amplitude_m, _phase_deg),
    do: :erlang.nif_error(:nif_not_loaded)

  def antex_parse(_text), do: :erlang.nif_error(:nif_not_loaded)

  def antex_encode(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def antex_satellite_antenna(_antennas, _prn, _datetime_tuple), do: :erlang.nif_error(:nif_not_loaded)

  def antex_pco(_antenna, _frequency), do: :erlang.nif_error(:nif_not_loaded)

  def antex_pcv(_antenna, _frequency, _zenith_deg, _azimuth_deg), do: :erlang.nif_error(:nif_not_loaded)

  def ppp_corrections_build(
        _handle,
        _epochs,
        _receiver_ecef_m,
        _solid_earth_tide,
        _phase_windup,
        _satellite_antenna,
        _pole_tide,
        _ocean_loading
      ), do: :erlang.nif_error(:nif_not_loaded)

  def precise_positioning_solve_float(_handle, _epoch, _initial_state, _weights, _solve_options, _tropo, _corrections),
    do: :erlang.nif_error(:nif_not_loaded)

  def precise_positioning_solve_ppp_float(
        _handle,
        _epochs,
        _initial_state,
        _weights,
        _solve_options,
        _tropo,
        _corrections,
        _residual_screen
      ), do: :erlang.nif_error(:nif_not_loaded)

  def precise_positioning_solve_ppp_fixed(
        _handle,
        _epochs,
        _float_solution,
        _weights,
        _solve_options,
        _tropo,
        _corrections,
        _ambiguity
      ), do: :erlang.nif_error(:nif_not_loaded)

  def precise_positioning_solve_ppp_auto_init_float(
        _handle,
        _epochs,
        _auto_init,
        _weights,
        _solve_options,
        _tropo,
        _corrections,
        _residual_screen
      ), do: :erlang.nif_error(:nif_not_loaded)

  def precise_positioning_solve_ppp_auto_init_fixed(
        _handle,
        _epochs,
        _auto_init,
        _weights,
        _solve_options,
        _tropo,
        _corrections,
        _residual_screen,
        _ambiguity
      ), do: :erlang.nif_error(:nif_not_loaded)

  def iod_gibbs(_r1, _r2, _r3), do: :erlang.nif_error(:nif_not_loaded)
  def iod_hgibbs(_r1, _r2, _r3, _jd1, _jd2, _jd3), do: :erlang.nif_error(:nif_not_loaded)

  def lambert_battin(_r1, _r2, _v1, _dm, _de, _nrev, _dtsec), do: :erlang.nif_error(:nif_not_loaded)

  def tca_find_candidates(
        _primary_line1,
        _primary_line2,
        _secondary_line1,
        _secondary_line2,
        _start_whole,
        _start_fraction,
        _end_whole,
        _end_fraction,
        _coarse_step_seconds,
        _time_tolerance_seconds
      ), do: :erlang.nif_error(:nif_not_loaded)

  def tca_find_conjunctions(
        _primary_line1,
        _primary_line2,
        _secondary_line1,
        _secondary_line2,
        _start_whole,
        _start_fraction,
        _end_whole,
        _end_fraction,
        _hard_body_radius_km,
        _method,
        _primary_covariance_km2,
        _secondary_covariance_km2,
        _coarse_step_seconds,
        _time_tolerance_seconds
      ), do: :erlang.nif_error(:nif_not_loaded)

  def tca_screen_candidates(
        _primary_line1,
        _primary_line2,
        _secondaries,
        _start_whole,
        _start_fraction,
        _end_whole,
        _end_fraction,
        _miss_distance_threshold_km,
        _coarse_step_seconds,
        _time_tolerance_seconds
      ), do: :erlang.nif_error(:nif_not_loaded)

  def tca_screen_conjunctions(
        _primary_line1,
        _primary_line2,
        _secondaries,
        _start_whole,
        _start_fraction,
        _end_whole,
        _end_fraction,
        _miss_distance_threshold_km,
        _hard_body_radius_km,
        _method,
        _primary_covariance_km2,
        _secondary_covariance_km2,
        _coarse_step_seconds,
        _time_tolerance_seconds
      ), do: :erlang.nif_error(:nif_not_loaded)

  def sp3_parse(_bytes), do: :erlang.nif_error(:nif_not_loaded)

  def sp3_time_scale(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def sp3_satellite_ids(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def sp3_epoch_count(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def sp3_epochs_j2000_seconds(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def sp3_state(_handle, _system_letter, _prn, _epoch_index), do: :erlang.nif_error(:nif_not_loaded)

  def sp3_states_at(_handle, _epoch_index), do: :erlang.nif_error(:nif_not_loaded)

  def sp3_to_iodata(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def sp3_precise_ephemeris_samples(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def precise_samples_from_samples(_samples), do: :erlang.nif_error(:nif_not_loaded)

  def broadcast_parse(_text), do: :erlang.nif_error(:nif_not_loaded)

  def broadcast_record_count(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def broadcast_records(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def broadcast_glonass_record_count(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def broadcast_glonass_records(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def broadcast_iono_corrections(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def broadcast_leap_seconds(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def broadcast_position(_handle, _system_letter, _prn, _t_j2000_s), do: :erlang.nif_error(:nif_not_loaded)

  def broadcast_encode_nav(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def broadcast_comparison(
        _broadcast,
        _precise,
        _satellites,
        _broadcast_t0_j2000_s,
        _broadcast_t1_j2000_s,
        _precise_start_jd_whole,
        _precise_start_fraction,
        _step_s,
        _velocity_half_s
      ), do: :erlang.nif_error(:nif_not_loaded)

  def sp3_position(_handle, _system_letter, _prn, _scale, _jd_whole, _jd_fraction),
    do: :erlang.nif_error(:nif_not_loaded)

  def sp3_observables(
        _handle,
        _system_letter,
        _prn,
        _jd_whole,
        _jd_fraction,
        _receiver_ecef_m,
        _carrier_hz,
        _light_time,
        _sagnac
      ), do: :erlang.nif_error(:nif_not_loaded)

  def broadcast_observables(
        _handle,
        _system_letter,
        _prn,
        _t_rx_j2000_s,
        _receiver_ecef_m,
        _carrier_hz,
        _light_time,
        _sagnac
      ), do: :erlang.nif_error(:nif_not_loaded)

  def velocity_doppler_to_range_rate(_doppler_hz, _carrier_hz), do: :erlang.nif_error(:nif_not_loaded)

  def velocity_range_rate_to_doppler(_range_rate_m_s, _carrier_hz), do: :erlang.nif_error(:nif_not_loaded)

  def sp3_velocity_solve(
        _handle,
        _observations,
        _jd_whole,
        _jd_fraction,
        _receiver_ecef_m,
        _observable,
        _light_time,
        _sagnac
      ), do: :erlang.nif_error(:nif_not_loaded)

  def broadcast_velocity_solve(
        _handle,
        _observations,
        _t_rx_j2000_s,
        _receiver_ecef_m,
        _observable,
        _light_time,
        _sagnac
      ), do: :erlang.nif_error(:nif_not_loaded)

  def dgnss_corrections(_handle, _base_position_m, _base_observations, _t_rx_j2000_s),
    do: :erlang.nif_error(:nif_not_loaded)

  def dgnss_apply(_rover_observations, _corrections), do: :erlang.nif_error(:nif_not_loaded)

  def dgnss_position(
        _handle,
        _base_position_m,
        _base_observations,
        _rover_observations,
        _t_rx_j2000_s,
        _t_rx_second_of_day_s,
        _day_of_year,
        _initial_guess,
        _with_geodetic
      ), do: :erlang.nif_error(:nif_not_loaded)

  def geometry_dop(_rows, _receiver_lat_rad, _receiver_lon_rad), do: :erlang.nif_error(:nif_not_loaded)

  def sp3_geometry_visible(_handle, _receiver_ecef_m, _jd_whole, _jd_fraction, _elevation_mask_deg, _systems),
    do: :erlang.nif_error(:nif_not_loaded)

  def sp3_geometry_dop(
        _handle,
        _receiver_ecef_m,
        _jd_whole,
        _jd_fraction,
        _elevation_mask_deg,
        _systems,
        _weighting,
        _light_time,
        _use_explicit_satellites,
        _satellites
      ), do: :erlang.nif_error(:nif_not_loaded)

  def sp3_geometry_dop_series(
        _handle,
        _receiver_ecef_m,
        _start_jd_whole,
        _start_jd_fraction,
        _end_jd_whole,
        _end_jd_fraction,
        _step_seconds,
        _elevation_mask_deg,
        _systems,
        _weighting,
        _light_time,
        _use_explicit_satellites,
        _satellites
      ), do: :erlang.nif_error(:nif_not_loaded)

  def sp3_geometry_visibility_series(
        _handle,
        _receiver_ecef_m,
        _start_jd_whole,
        _start_jd_fraction,
        _end_jd_whole,
        _end_jd_fraction,
        _step_seconds,
        _elevation_mask_deg,
        _systems
      ), do: :erlang.nif_error(:nif_not_loaded)

  def sp3_geometry_passes(
        _handle,
        _receiver_ecef_m,
        _start_jd_whole,
        _start_jd_fraction,
        _end_jd_whole,
        _end_jd_fraction,
        _step_seconds,
        _elevation_mask_deg,
        _systems
      ), do: :erlang.nif_error(:nif_not_loaded)

  def geometry_inv4(_matrix), do: :erlang.nif_error(:nif_not_loaded)

  def sp3_clock_reference_offset(_reference, _other, _min_common), do: :erlang.nif_error(:nif_not_loaded)

  def sp3_align_clock_reference(_reference, _other, _min_common), do: :erlang.nif_error(:nif_not_loaded)

  def sp3_merge(
        _handles,
        _position_tolerance_m,
        _clock_tolerance_s,
        _min_agree,
        _clock_min_common,
        _combine,
        _target_epoch_interval_s,
        _system_letters
      ), do: :erlang.nif_error(:nif_not_loaded)

  def crinex_decode(_text), do: :erlang.nif_error(:nif_not_loaded)

  def crinex_encode(_text), do: :erlang.nif_error(:nif_not_loaded)

  def rinex_clock_parse(_text), do: :erlang.nif_error(:nif_not_loaded)

  def rinex_clock_parse_lossy(_text), do: :erlang.nif_error(:nif_not_loaded)

  def rinex_clock_to_string(_series), do: :erlang.nif_error(:nif_not_loaded)

  def rinex_clock_clock_s(_series, _satellite_id, _datetime_tuple), do: :erlang.nif_error(:nif_not_loaded)

  def rinex_obs_parse(_text), do: :erlang.nif_error(:nif_not_loaded)

  def rinex_obs_to_string(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def crinex_obs_parse(_text), do: :erlang.nif_error(:nif_not_loaded)

  def rinex_obs_approx_position(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def rinex_obs_antenna_delta_hen(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def rinex_obs_phase_shifts(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def rinex_obs_codes(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def rinex_obs_glonass_slots(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def rinex_obs_epoch_count(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def rinex_obs_epochs(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def rinex_obs_pseudoranges(_handle, _epoch_index, _overrides), do: :erlang.nif_error(:nif_not_loaded)

  def rinex_obs_values(_handle, _epoch_index, _overrides), do: :erlang.nif_error(:nif_not_loaded)

  def rinex_obs_phases(_handle, _epoch_index, _overrides), do: :erlang.nif_error(:nif_not_loaded)

  def rinex_obs_band_frequency_hz(_system, _band, _channel), do: :erlang.nif_error(:nif_not_loaded)

  def frequencies_carrier_frequency_hz(_system, _band), do: :erlang.nif_error(:nif_not_loaded)

  def frequencies_wavelength_m(_system, _band), do: :erlang.nif_error(:nif_not_loaded)

  def frequencies_rinex_band_frequency_hz(_system, _band, _glonass_channel), do: :erlang.nif_error(:nif_not_loaded)

  def frequencies_rinex_band_wavelength_m(_system, _band, _glonass_channel), do: :erlang.nif_error(:nif_not_loaded)

  def frequencies_default_pair(_system), do: :erlang.nif_error(:nif_not_loaded)

  def lnav_word_length, do: :erlang.nif_error(:nif_not_loaded)

  def lnav_subframe_length, do: :erlang.nif_error(:nif_not_loaded)

  def lnav_preamble, do: :erlang.nif_error(:nif_not_loaded)

  def lnav_parity(_data24, _d29_prev, _d30_prev), do: :erlang.nif_error(:nif_not_loaded)

  def lnav_parity_valid(_word30, _d29_prev, _d30_prev), do: :erlang.nif_error(:nif_not_loaded)

  def lnav_tow(_bits), do: :erlang.nif_error(:nif_not_loaded)

  def lnav_subframe_id(_bits), do: :erlang.nif_error(:nif_not_loaded)

  def lnav_encode(_params, _opts), do: :erlang.nif_error(:nif_not_loaded)

  def lnav_decode(_sf1, _sf2, _sf3), do: :erlang.nif_error(:nif_not_loaded)

  def signal_ca_code_length, do: :erlang.nif_error(:nif_not_loaded)

  def signal_ca_chip_rate_hz, do: :erlang.nif_error(:nif_not_loaded)

  def signal_ca_code(_prn), do: :erlang.nif_error(:nif_not_loaded)

  def signal_ca_chip(_prn, _index), do: :erlang.nif_error(:nif_not_loaded)

  def signal_ca_autocorrelation(_code), do: :erlang.nif_error(:nif_not_loaded)

  def signal_ca_cross_correlation(_code_a, _code_b), do: :erlang.nif_error(:nif_not_loaded)

  def signal_ca_correlation_at(_code_a, _code_b, _lag), do: :erlang.nif_error(:nif_not_loaded)

  def signal_correlator_replica(_prn, _num_samples, _sample_rate_hz, _code_phase_chips, _code_doppler_hz),
    do: :erlang.nif_error(:nif_not_loaded)

  def signal_correlator_correlate(_iq, _prn, _sample_rate_hz, _doppler_hz, _code_phase_chips, _code_doppler_hz),
    do: :erlang.nif_error(:nif_not_loaded)

  def signal_correlator_correlate_against(_iq, _code, _sample_rate_hz, _doppler_hz),
    do: :erlang.nif_error(:nif_not_loaded)

  def signal_correlator_acquire(_samples, _prn, _sample_rate_hz, _doppler_min_hz, _doppler_max_hz, _doppler_step_hz),
    do: :erlang.nif_error(:nif_not_loaded)

  def signal_coherent_loss(_freq_error_hz, _integration_time_s), do: :erlang.nif_error(:nif_not_loaded)

  def signal_coherent_loss_db(_freq_error_hz, _integration_time_s), do: :erlang.nif_error(:nif_not_loaded)

  def signal_snr_post_db(_cn0_dbhz, _integration_time_s), do: :erlang.nif_error(:nif_not_loaded)

  def reduced_orbit_fit(_samples, _scale, _model), do: :erlang.nif_error(:nif_not_loaded)

  def reduced_orbit_piecewise_fit(_samples, _scale, _model, _window_start, _window_end, _segment_s),
    do: :erlang.nif_error(:nif_not_loaded)

  def ils_search(_float_cycles, _covariance, _radius, _candidate_limit, _ratio_threshold),
    do: :erlang.nif_error(:nif_not_loaded)

  def ils_lambda_search(_float_cycles, _covariance, _ratio_threshold), do: :erlang.nif_error(:nif_not_loaded)

  def rtk_double_differences(_base_observations, _rover_observations, _reference),
    do: :erlang.nif_error(:nif_not_loaded)

  def rtk_baseline_reference_satellites(_base_m, _epochs, _reference), do: :erlang.nif_error(:nif_not_loaded)

  def rtk_preprocess_arc_epochs(_epochs, _base_m, _preprocessing), do: :erlang.nif_error(:nif_not_loaded)

  def rtk_filter_update_epoch(
        _state,
        _epoch,
        _base,
        _model,
        _wavelengths,
        _offsets,
        _opts,
        _receiver_antenna_corrections
      ), do: :erlang.nif_error(:nif_not_loaded)

  def rtk_filter_update_epochs(
        _state,
        _epochs,
        _base,
        _model,
        _wavelengths,
        _offsets,
        _opts,
        _receiver_antenna_corrections
      ), do: :erlang.nif_error(:nif_not_loaded)

  def rtk_solve_arc(_epochs, _config), do: :erlang.nif_error(:nif_not_loaded)

  def rtk_solve_float(
        _epochs,
        _base,
        _ambiguity_ids,
        _initial_baseline_m,
        _model,
        _float_opts,
        _receiver_antenna_corrections
      ), do: :erlang.nif_error(:nif_not_loaded)

  def rtk_solve_fixed(
        _epochs,
        _base,
        _ambiguity_ids,
        _ambiguity_satellites,
        _wavelengths_m,
        _offsets_m,
        _float_only_systems,
        _initial_baseline_m,
        _model,
        _float_opts,
        _fixed_opts,
        _residual_opts,
        _receiver_antenna_corrections
      ), do: :erlang.nif_error(:nif_not_loaded)

  def rtk_solve_static_arc(_epochs, _config), do: :erlang.nif_error(:nif_not_loaded)

  def rtk_fix_wide_lane_arc(_epochs, _config), do: :erlang.nif_error(:nif_not_loaded)

  def rtk_prepare_ionosphere_free_arc(_epochs, _wide_lane_cycles, _config), do: :erlang.nif_error(:nif_not_loaded)

  def reduced_orbit_position(_epoch, _scale, _elements, _query, _frame), do: :erlang.nif_error(:nif_not_loaded)

  def reduced_orbit_position_velocity(_epoch, _scale, _elements, _query, _frame), do: :erlang.nif_error(:nif_not_loaded)

  def reduced_orbit_drift(_epoch, _scale, _elements, _truth, _threshold_m), do: :erlang.nif_error(:nif_not_loaded)

  def reduced_orbit_piecewise_position(_window_start, _window_end, _segment_s, _segments, _scale, _query, _frame),
    do: :erlang.nif_error(:nif_not_loaded)

  def reduced_orbit_piecewise_select_segment(_window_start, _window_end, _segment_s, _segments, _query),
    do: :erlang.nif_error(:nif_not_loaded)

  def reduced_orbit_piecewise_position_velocity(
        _window_start,
        _window_end,
        _segment_s,
        _segments,
        _scale,
        _query,
        _frame
      ), do: :erlang.nif_error(:nif_not_loaded)

  def reduced_orbit_piecewise_drift(_window_start, _window_end, _segment_s, _segments, _scale, _truth, _threshold_m),
    do: :erlang.nif_error(:nif_not_loaded)

  def spp_solve(
        _handle,
        _observations,
        _t_rx_j2000_s,
        _t_rx_second_of_day_s,
        _day_of_year,
        _initial_guess,
        _apply_iono,
        _apply_tropo,
        _alpha,
        _beta,
        _pressure_hpa,
        _temperature_k,
        _relative_humidity,
        _with_geodetic,
        _robust,
        _max_pdop,
        _coarse_search_seeds,
        _glonass_channels
      ), do: :erlang.nif_error(:nif_not_loaded)

  def spp_solve_broadcast(
        _handle,
        _observations,
        _t_rx_j2000_s,
        _t_rx_second_of_day_s,
        _day_of_year,
        _initial_guess,
        _apply_iono,
        _apply_tropo,
        _alpha,
        _beta,
        _pressure_hpa,
        _temperature_k,
        _relative_humidity,
        _with_geodetic,
        _robust,
        _max_pdop,
        _coarse_search_seeds,
        _glonass_channels
      ), do: :erlang.nif_error(:nif_not_loaded)

  def spp_solve_with_fallback(
        _precise_handles,
        _broadcast_handle,
        _observations,
        _t_rx_j2000_s,
        _t_rx_second_of_day_s,
        _day_of_year,
        _initial_guess,
        _apply_iono,
        _apply_tropo,
        _alpha,
        _beta,
        _pressure_hpa,
        _temperature_k,
        _relative_humidity,
        _with_geodetic,
        _max_staleness_s,
        _glonass_channels
      ), do: :erlang.nif_error(:nif_not_loaded)

  def spp_solve_batch_serial(_handle, _epochs, _with_geodetic, _robust, _max_pdop, _coarse_search_seeds),
    do: :erlang.nif_error(:nif_not_loaded)

  def spp_solve_batch_parallel(_handle, _epochs, _with_geodetic, _robust, _max_pdop, _coarse_search_seeds),
    do: :erlang.nif_error(:nif_not_loaded)

  def spp_residual_rms_m(_residuals_m), do: :erlang.nif_error(:nif_not_loaded)

  def staleness_select_sp3(_handles, _requested_epoch_j2000_s, _max_staleness_s), do: :erlang.nif_error(:nif_not_loaded)

  def staleness_select_sp3_over_range(_handles, _start_epoch_j2000_s, _end_epoch_j2000_s, _max_staleness_s),
    do: :erlang.nif_error(:nif_not_loaded)

  def staleness_select_ionex(_handles, _requested_epoch_j2000_s, _max_staleness_s),
    do: :erlang.nif_error(:nif_not_loaded)

  def staleness_select_ionex_over_range(_handles, _start_epoch_j2000_s, _end_epoch_j2000_s, _max_staleness_s),
    do: :erlang.nif_error(:nif_not_loaded)

  def qc_pseudorange_variance(_elevation_deg, _a_m, _b_m, _model, _cn0, _cn0_scale_m2),
    do: :erlang.nif_error(:nif_not_loaded)

  def qc_sigmas(_entries, _a_m, _b_m, _model, _cn0, _cn0_scale_m2), do: :erlang.nif_error(:nif_not_loaded)

  def qc_weight_vector(_entries, _a_m, _b_m, _model, _cn0, _cn0_scale_m2), do: :erlang.nif_error(:nif_not_loaded)

  def qc_chi2_inv(_p, _dof), do: :erlang.nif_error(:nif_not_loaded)

  def qc_raim(_used_sats, _residuals_m, _p_fa, _unit_weights, _weights, _n_systems),
    do: :erlang.nif_error(:nif_not_loaded)

  def qc_raim_fde_design(_rows, _p_fa, _max_exclusions, _min_redundancy), do: :erlang.nif_error(:nif_not_loaded)

  def qc_fde_sp3(
        _handle,
        _observations,
        _t_rx_j2000_s,
        _t_rx_second_of_day_s,
        _day_of_year,
        _initial_guess,
        _apply_iono,
        _apply_tropo,
        _alpha,
        _beta,
        _pressure_hpa,
        _temperature_k,
        _relative_humidity,
        _with_geodetic,
        _p_fa,
        _unit_weights,
        _weights,
        _n_systems,
        _max_iterations,
        _max_pdop
      ), do: :erlang.nif_error(:nif_not_loaded)

  def qc_fde_broadcast(
        _handle,
        _observations,
        _t_rx_j2000_s,
        _t_rx_second_of_day_s,
        _day_of_year,
        _initial_guess,
        _apply_iono,
        _apply_tropo,
        _alpha,
        _beta,
        _pressure_hpa,
        _temperature_k,
        _relative_humidity,
        _with_geodetic,
        _p_fa,
        _unit_weights,
        _weights,
        _n_systems,
        _max_iterations,
        _max_pdop
      ), do: :erlang.nif_error(:nif_not_loaded)

  def klobuchar_delay(_lat_deg, _lon_deg, _azimuth_deg, _elevation_deg, _t_gps_s, _frequency_hz, _alpha, _beta),
    do: :erlang.nif_error(:nif_not_loaded)

  def galileo_nequick_g_delay(
        _lat_rad,
        _lon_rad,
        _elevation_rad,
        _azimuth_rad,
        _jd_whole,
        _jd_fraction,
        _frequency_hz,
        _ai0,
        _ai1,
        _ai2
      ), do: :erlang.nif_error(:nif_not_loaded)

  def nequick_g_stec_tecu(
        _ai0,
        _ai1,
        _ai2,
        _month,
        _utc_hours,
        _station_lon_deg,
        _station_lat_deg,
        _station_height_m,
        _satellite_lon_deg,
        _satellite_lat_deg,
        _satellite_height_m
      ), do: :erlang.nif_error(:nif_not_loaded)

  def nequick_g_delay_m(
        _ai0,
        _ai1,
        _ai2,
        _month,
        _utc_hours,
        _station_lon_deg,
        _station_lat_deg,
        _station_height_m,
        _satellite_lon_deg,
        _satellite_lat_deg,
        _satellite_height_m,
        _frequency_hz
      ), do: :erlang.nif_error(:nif_not_loaded)

  def ionex_parse(_bytes), do: :erlang.nif_error(:nif_not_loaded)

  def ionex_to_string(_handle), do: :erlang.nif_error(:nif_not_loaded)

  def ionex_slant(_handle, _lat_rad, _lon_rad, _elevation_rad, _azimuth_rad, _epoch_j2000_s, _frequency_hz),
    do: :erlang.nif_error(:nif_not_loaded)

  def iono_free_frequencies, do: :erlang.nif_error(:nif_not_loaded)

  def iono_free_default_pair(_system), do: :erlang.nif_error(:nif_not_loaded)

  def iono_free_frequency(_system, _band), do: :erlang.nif_error(:nif_not_loaded)

  def iono_free_gamma(_f1_hz, _f2_hz), do: :erlang.nif_error(:nif_not_loaded)

  def iono_free_noise_amplification(_f1_hz, _f2_hz), do: :erlang.nif_error(:nif_not_loaded)

  def iono_free_code(_pr1_m, _pr2_m, _f1_hz, _f2_hz), do: :erlang.nif_error(:nif_not_loaded)

  def iono_free_phase(_phase1_m, _phase2_m, _f1_hz, _f2_hz), do: :erlang.nif_error(:nif_not_loaded)

  def iono_free_phase_cycles(_phi1_cycles, _phi2_cycles, _f1_hz, _f2_hz), do: :erlang.nif_error(:nif_not_loaded)

  def iono_free_pseudoranges(_band1, _band2, _overrides), do: :erlang.nif_error(:nif_not_loaded)

  def carrier_phase_phase_meters(_phi_cycles, _f_hz), do: :erlang.nif_error(:nif_not_loaded)

  def carrier_phase_geometry_free(_l1_m, _l2_m), do: :erlang.nif_error(:nif_not_loaded)

  def carrier_phase_wide_lane_wavelength(_f1_hz, _f2_hz), do: :erlang.nif_error(:nif_not_loaded)

  def carrier_phase_narrow_lane_code(_p1_m, _p2_m, _f1_hz, _f2_hz), do: :erlang.nif_error(:nif_not_loaded)

  def carrier_phase_melbourne_wubbena(_phi1_cycles, _phi2_cycles, _p1_m, _p2_m, _f1_hz, _f2_hz),
    do: :erlang.nif_error(:nif_not_loaded)

  def carrier_phase_wide_lane_cycles(_phi1_cycles, _phi2_cycles, _p1_m, _p2_m, _f1_hz, _f2_hz),
    do: :erlang.nif_error(:nif_not_loaded)

  def carrier_phase_code_minus_carrier(_p_m, _phi_cycles, _f_hz), do: :erlang.nif_error(:nif_not_loaded)

  def carrier_phase_detect_cycle_slips(_arc, _gf_threshold_m, _mw_threshold_cycles, _min_arc_gap_s),
    do: :erlang.nif_error(:nif_not_loaded)

  def carrier_phase_smooth_code(_arc, _gf_threshold_m, _mw_threshold_cycles, _min_arc_gap_s, _hatch_window_cap),
    do: :erlang.nif_error(:nif_not_loaded)

  def carrier_phase_smooth_iono_free_code(
        _arc,
        _gf_threshold_m,
        _mw_threshold_cycles,
        _min_arc_gap_s,
        _hatch_window_cap
      ), do: :erlang.nif_error(:nif_not_loaded)

  def tropo_zenith_delay(_lat_rad, _height_m, _pressure_hpa, _temperature_k, _relative_humidity),
    do: :erlang.nif_error(:nif_not_loaded)

  def tropo_mapping_factors(_elevation_rad, _lat_rad, _height_m, _jd_whole, _jd_fraction),
    do: :erlang.nif_error(:nif_not_loaded)

  def tropo_slant_delay(
        _elevation_rad,
        _lat_rad,
        _lon_rad,
        _height_m,
        _pressure_hpa,
        _temperature_k,
        _relative_humidity,
        _jd_whole,
        _jd_fraction
      ), do: :erlang.nif_error(:nif_not_loaded)

  def iod_gauss(
        _decl1,
        _decl2,
        _decl3,
        _rtasc1,
        _rtasc2,
        _rtasc3,
        _jd1,
        _jdf1,
        _jd2,
        _jdf2,
        _jd3,
        _jdf3,
        _rseci1,
        _rseci2,
        _rseci3
      ), do: :erlang.nif_error(:nif_not_loaded)

  def timescale_offset(_from, _to), do: :erlang.nif_error(:nif_not_loaded)

  def timescale_offset_at(_from, _to, _utc_jd), do: :erlang.nif_error(:nif_not_loaded)

  def leap_seconds(_year, _month, _day), do: :erlang.nif_error(:nif_not_loaded)

  def leap_seconds_batch(_dates), do: :erlang.nif_error(:nif_not_loaded)

  def leap_second_table_info, do: :erlang.nif_error(:nif_not_loaded)

  def ut1_coverage_info, do: :erlang.nif_error(:nif_not_loaded)

  def civil_split_julian_date(_year, _month, _day, _hour, _minute, _second), do: :erlang.nif_error(:nif_not_loaded)

  def civil_j2000_seconds(_year, _month, _day, _hour, _minute, _second), do: :erlang.nif_error(:nif_not_loaded)

  def civil_second_of_day(_hour, _minute, _second), do: :erlang.nif_error(:nif_not_loaded)

  def civil_day_of_year(_year, _month, _day, _hour, _minute, _second), do: :erlang.nif_error(:nif_not_loaded)

  def core_constants, do: :erlang.nif_error(:nif_not_loaded)

  def core_defaults, do: :erlang.nif_error(:nif_not_loaded)

  def constellation_from_celestrak_omm(_system_letter, _omms), do: :erlang.nif_error(:nif_not_loaded)

  def constellation_from_celestrak_json(_system_letter, _json), do: :erlang.nif_error(:nif_not_loaded)

  def constellation_from_celestrak_omm_lenient(_system_letter, _omms), do: :erlang.nif_error(:nif_not_loaded)

  def constellation_from_celestrak_json_lenient(_system_letter, _json), do: :erlang.nif_error(:nif_not_loaded)

  def constellation_parse_navcen(_html), do: :erlang.nif_error(:nif_not_loaded)

  def constellation_merge_navcen(_records, _statuses), do: :erlang.nif_error(:nif_not_loaded)

  def constellation_to_csv(_records, _booleans), do: :erlang.nif_error(:nif_not_loaded)

  def constellation_validate(_records), do: :erlang.nif_error(:nif_not_loaded)

  def constellation_validate_against_sp3_ids(_records, _sp3_ids), do: :erlang.nif_error(:nif_not_loaded)

  def constellation_validate_against_sp3_ids_strict(_records, _sp3_ids), do: :erlang.nif_error(:nif_not_loaded)

  def constellation_diff(_previous, _current), do: :erlang.nif_error(:nif_not_loaded)

  def constellation_glonass_fdma_channel(_slot), do: :erlang.nif_error(:nif_not_loaded)

  def constellation_galileo_prn_for_gsat(_gsat), do: :erlang.nif_error(:nif_not_loaded)

  def constellation_glonass_slot_for_number(_number), do: :erlang.nif_error(:nif_not_loaded)

  def constellation_sp3_id(_system_letter, _prn), do: :erlang.nif_error(:nif_not_loaded)

  def observation_sub_solar_point(_sun_ecef), do: :erlang.nif_error(:nif_not_loaded)

  def observation_terminator_latitude_deg(_sub_solar_lat_deg, _sub_solar_lon_deg, _longitude_deg),
    do: :erlang.nif_error(:nif_not_loaded)

  def observation_parallactic_angle_deg(_observer_lat_deg, _hour_angle_deg, _declination_deg),
    do: :erlang.nif_error(:nif_not_loaded)

  def observation_satellite_visual_magnitude(_range_km, _phase_angle_deg, _standard_magnitude, _reference_range_km),
    do: :erlang.nif_error(:nif_not_loaded)

  def observation_sub_observer_point(_observer_from_body, _pole_ra_deg, _pole_dec_deg, _prime_meridian_deg),
    do: :erlang.nif_error(:nif_not_loaded)

  def elements_rv2coe(_r, _v, _mu), do: :erlang.nif_error(:nif_not_loaded)

  def elements_coe2rv(_p, _ecc, _incl, _raan, _argp, _nu, _arglat, _truelon, _lonper, _orbit_type, _mu),
    do: :erlang.nif_error(:nif_not_loaded)

  def geoid_undulation_rad(_lat_rad, _lon_rad), do: :erlang.nif_error(:nif_not_loaded)

  def geoid_orthometric_height_m(_ellipsoidal_height, _lat_rad, _lon_rad), do: :erlang.nif_error(:nif_not_loaded)

  def geoid_ellipsoidal_height_m(_orthometric_height, _lat_rad, _lon_rad), do: :erlang.nif_error(:nif_not_loaded)

  def geoid_grid_from_text(_text), do: :erlang.nif_error(:nif_not_loaded)

  def geoid_grid_new(_lat_min_deg, _lon_min_deg, _dlat_deg, _dlon_deg, _n_lat, _n_lon, _values_m),
    do: :erlang.nif_error(:nif_not_loaded)

  def geoid_grid_undulation_deg(_handle, _lat_deg, _lon_deg), do: :erlang.nif_error(:nif_not_loaded)

  def geoid_grid_undulation_rad(_handle, _lat_rad, _lon_rad), do: :erlang.nif_error(:nif_not_loaded)

  def sgp4_propagate_batch(_tle_maps, _times_minutes, _opsmode), do: :erlang.nif_error(:nif_not_loaded)

  def sgp4_propagate_batch_parallel(_tle_maps, _times_minutes, _opsmode), do: :erlang.nif_error(:nif_not_loaded)

  def civil_utc_instant_split(_year, _month, _day, _hour, _minute, _second), do: :erlang.nif_error(:nif_not_loaded)

  def rtcm_decode_messages(_bytes), do: :erlang.nif_error(:nif_not_loaded)

  def rtcm_decode_message(_bytes), do: :erlang.nif_error(:nif_not_loaded)

  def rtcm_message_number(_bytes), do: :erlang.nif_error(:nif_not_loaded)

  def rtcm_decode_frame(_bytes), do: :erlang.nif_error(:nif_not_loaded)

  def rtcm_encode_frame_body(_bytes), do: :erlang.nif_error(:nif_not_loaded)

  def rtcm_encode_message(_kind, _fields), do: :erlang.nif_error(:nif_not_loaded)

  def rtcm_encode(_kind, _fields), do: :erlang.nif_error(:nif_not_loaded)

  def rtcm_encode_frame(_kind, _fields), do: :erlang.nif_error(:nif_not_loaded)

  def rtk_solve_moving_baseline(_epoch_terms, _opts, _receiver_antenna_corrections),
    do: :erlang.nif_error(:nif_not_loaded)

  # --- generic data-driven trust-region least squares ----------------

  def trls_solve(
        _kind,
        _a,
        _b,
        _m,
        _n,
        _t,
        _y,
        _degree,
        _x0,
        _loss,
        _f_scale,
        _x_scale_kind,
        _x_scale_values,
        _max_nfev,
        _ftol,
        _xtol,
        _gtol,
        _backend
      ), do: :erlang.nif_error(:nif_not_loaded)

  def trls_solve_drop_one(
        _kind,
        _a,
        _b,
        _m,
        _n,
        _t,
        _y,
        _degree,
        _x0,
        _loss,
        _f_scale,
        _x_scale_kind,
        _x_scale_values,
        _max_nfev,
        _ftol,
        _xtol,
        _gtol,
        _backend
      ), do: :erlang.nif_error(:nif_not_loaded)

  # --- covariance / geometry from a Jacobian -------------------------

  def covariance_normal_covariance(_jacobian, _variance_scale), do: :erlang.nif_error(:nif_not_loaded)

  def covariance_hessian_trace(_jacobian), do: :erlang.nif_error(:nif_not_loaded)

  def covariance_from_jacobian(_jacobian, _cost), do: :erlang.nif_error(:nif_not_loaded)

  def covariance_error_ellipse_2x2(_covariance_2x2, _confidence), do: :erlang.nif_error(:nif_not_loaded)

  # --- DOP convention ------------------------------------------------

  def geometry_dop_with_convention(_rows, _receiver_lat_rad, _receiver_lon_rad, _convention),
    do: :erlang.nif_error(:nif_not_loaded)

  # --- residual-distribution diagnostics -----------------------------

  def normality_skewness(_x, _bias), do: :erlang.nif_error(:nif_not_loaded)

  def normality_kurtosis(_x, _fisher, _bias), do: :erlang.nif_error(:nif_not_loaded)

  def normality_moments(_x, _fisher, _bias), do: :erlang.nif_error(:nif_not_loaded)

  def normality_jarque_bera(_x), do: :erlang.nif_error(:nif_not_loaded)

  def normality_shapiro_wilk(_x), do: :erlang.nif_error(:nif_not_loaded)

  # --- batch observable prediction -----------------------------------

  def sp3_predict_batch(_handle, _requests, _carrier_hz, _light_time, _sagnac), do: :erlang.nif_error(:nif_not_loaded)

  def predict_ranges_batch(_source, _requests, _light_time, _sagnac), do: :erlang.nif_error(:nif_not_loaded)

  # --- leap-second accessors -----------------------------------------

  def gps_utc_offset_s(_year, _month, _day), do: :erlang.nif_error(:nif_not_loaded)

  def tai_utc_offset_s(_year, _month, _day), do: :erlang.nif_error(:nif_not_loaded)

  # --- EGM96 geoid ---------------------------------------------------

  def egm96_undulation_rad(_lat_rad, _lon_rad), do: :erlang.nif_error(:nif_not_loaded)

  def egm96_orthometric_height(_ellipsoidal_height, _lat_rad, _lon_rad), do: :erlang.nif_error(:nif_not_loaded)

  def egm96_ellipsoidal_height(_orthometric_height, _lat_rad, _lon_rad), do: :erlang.nif_error(:nif_not_loaded)

  # --- ground-observer Sun/Moon geometry -----------------------------

  def bodies_sun_az_el(_lat_deg, _lon_deg, _alt_km, _datetime), do: :erlang.nif_error(:nif_not_loaded)

  def bodies_moon_az_el(_lat_deg, _lon_deg, _alt_km, _datetime), do: :erlang.nif_error(:nif_not_loaded)

  def bodies_moon_illumination(_lat_deg, _lon_deg, _alt_km, _datetime), do: :erlang.nif_error(:nif_not_loaded)

  def bodies_moon_elevation_deg(_lat_deg, _lon_deg, _alt_km, _datetime), do: :erlang.nif_error(:nif_not_loaded)

  def bodies_find_moon_elevation_crossings(
        _lat_deg,
        _lon_deg,
        _alt_km,
        _start_datetime,
        _end_datetime,
        _elevation_threshold_deg,
        _step_seconds,
        _time_tolerance_seconds
      ), do: :erlang.nif_error(:nif_not_loaded)

  def bodies_find_moon_transits(
        _lat_deg,
        _lon_deg,
        _alt_km,
        _start_datetime,
        _end_datetime,
        _step_seconds,
        _time_tolerance_seconds
      ), do: :erlang.nif_error(:nif_not_loaded)
end
