use crate::analytic::{BrouwerLyddanePropagator, EcksteinHechlerPropagator};
use crate::broadcast::BroadcastResource;
use crate::de::DeResource;
use crate::earth_orientation::BodyFixedProvider;
use crate::errors::{detail_map, encode_result, Refusal};
use crate::orbit_scoring::{decode_satellite, orbit_score_error, Source};
use crate::sp3::Sp3Resource;
use crate::variational::DenseOutputResource;
use crate::{vector_tuple, Vec3};
use rustler::{Encoder, Env, NifMap, NifResult, ResourceArc, Term};
use sidereon_core::astro::attitude::gnss::{
    self, AttitudeMode, AttitudeTrajectory, CosineTurnParameters, CosineTurnStartAngle, DybAxes,
    GnssAttitude, GnssAttitudeError, GnssAttitudeLaw, NominalYaw, OrbitAttitudeTrajectory,
};
use sidereon_core::astro::attitude::gnss::{
    BeidouManufacturer, BeidouOrbitClass, GnssBlock, GnssBlockError,
};
use sidereon_core::astro::frames::TdbEarthOrientationProvider;
use sidereon_core::orbit_scoring::OrbitScoreError;

rustler::atoms! { trajectory_unavailable, invalid_parameter, beidou_manufacturer_required, turn_end_not_found, outside_validated_domain, value, reason, nominal, noon_turn, midnight_turn, shadow, modified_yaw_steering, beidou2_geo, beidou2_igso, beidou2_meo, beidou3_geo, beidou3_igso, beidou3_meo, beidou3_meo_unknown_manufacturer, beidou_orbit_class_required, beidou_orbit_normal_switch, beta0_rad, beta_x_rad, beta_y_rad, block_type, cast, colinearity, cosine_turn, degenerate_geometry, field, fixed_beta_yaw_steering, galileo_foc, galileo_iov, glonass_m, gps_iia, gps_iif, gps_iii, gps_iir, gps_iirm, name, no_default_yaw_rate, non_finite, on_to_ys_beta_rad, orbit_angle, orbit_normal, prn, secm_beta0_rad, shadow_limit_rad, t_s, unknown, unsupported, yaw_bias_rad, yaw_rate_rad_s, ys_to_on_beta_rad, zero_length }

fn gnss_attitude_error(env: Env<'_>, error: GnssAttitudeError) -> Refusal<'_> {
    let (kind, detail) = match &error {
        GnssAttitudeError::NonFinite { field } => (
            self::non_finite(),
            detail_map(env, &[(self::field(), (field).encode(env))]),
        ),
        GnssAttitudeError::ZeroLength { field } => (
            self::zero_length(),
            detail_map(env, &[(self::field(), (field).encode(env))]),
        ),
        GnssAttitudeError::NoDefaultYawRate { prn } => (
            self::no_default_yaw_rate(),
            detail_map(env, &[(self::prn(), (prn).encode(env))]),
        ),
        GnssAttitudeError::DegenerateGeometry { t_s } => (
            self::degenerate_geometry(),
            detail_map(env, &[(self::t_s(), (t_s).encode(env))]),
        ),
        GnssAttitudeError::TrajectoryUnavailable { t_s } => (
            trajectory_unavailable(),
            detail_map(env, &[(self::t_s(), t_s.encode(env))]),
        ),
        GnssAttitudeError::InvalidParameter { field, value } => (
            invalid_parameter(),
            detail_map(
                env,
                &[
                    (self::field(), field.encode(env)),
                    (self::value(), value.encode(env)),
                ],
            ),
        ),
        GnssAttitudeError::BeidouManufacturerRequired { t_s } => (
            beidou_manufacturer_required(),
            detail_map(env, &[(self::t_s(), t_s.encode(env))]),
        ),
        GnssAttitudeError::TurnEndNotFound { t_s } => (
            turn_end_not_found(),
            detail_map(env, &[(self::t_s(), t_s.encode(env))]),
        ),
        GnssAttitudeError::OutsideValidatedDomain { t_s, reason } => (
            outside_validated_domain(),
            detail_map(
                env,
                &[
                    (self::t_s(), t_s.encode(env)),
                    (self::reason(), reason.encode(env)),
                ],
            ),
        ),
        _ => (self::unknown(), Term::map_new(env)),
    };
    Refusal {
        kind,
        detail,
        message: error.to_string(),
    }
}

fn gnss_block_error(env: Env<'_>, error: GnssBlockError) -> Refusal<'_> {
    let (kind, detail) = match &error {
        GnssBlockError::Unknown { name } => (
            self::unknown(),
            detail_map(env, &[(self::name(), (name).encode(env))]),
        ),
        GnssBlockError::Unsupported { name } => (
            self::unsupported(),
            detail_map(env, &[(self::name(), (name).encode(env))]),
        ),
        GnssBlockError::BeidouOrbitClassRequired { block_type } => (
            self::beidou_orbit_class_required(),
            detail_map(env, &[(self::block_type(), (block_type).encode(env))]),
        ),
        _ => (self::unknown(), Term::map_new(env)),
    };
    Refusal {
        kind,
        detail,
        message: error.to_string(),
    }
}

#[derive(NifMap)]
#[rustler(encode)]
pub(crate) struct Dyb {
    d: Vec3,
    y: Vec3,
    b: Vec3,
}

impl From<DybAxes> for Dyb {
    fn from(axes: DybAxes) -> Self {
        Self {
            d: vector_tuple(axes.d),
            y: vector_tuple(axes.y),
            b: vector_tuple(axes.b),
        }
    }
}

#[derive(NifMap)]
#[rustler(encode)]
struct Yaw {
    yaw_rad: f64,
    beta_rad: f64,
    body_x: Vec3,
    body_y: Vec3,
    body_z: Vec3,
}

impl From<NominalYaw> for Yaw {
    fn from(yaw: NominalYaw) -> Self {
        Self {
            yaw_rad: yaw.yaw_rad,
            beta_rad: yaw.beta_rad,
            body_x: vector_tuple(yaw.body_x),
            body_y: vector_tuple(yaw.body_y),
            body_z: vector_tuple(yaw.body_z),
        }
    }
}

#[rustler::nif]
fn attitude_nominal_yaw(env: Env<'_>, position: Vec3, velocity: Vec3, sun: Vec3) -> Term<'_> {
    encode_result(
        env,
        gnss::nominal_yaw(position.into(), velocity.into(), sun.into())
            .map(Yaw::from)
            .map_err(|error| gnss_attitude_error(env, error)),
    )
}

#[rustler::nif]
fn attitude_dyb_axes(env: Env<'_>, position: Vec3, sun: Vec3) -> Term<'_> {
    encode_result(
        env,
        gnss::dyb_axes(position.into(), sun.into())
            .map(Dyb::from)
            .map_err(|error| gnss_attitude_error(env, error)),
    )
}

#[rustler::nif]
fn attitude_gps_iia_default_yaw_rate_rad_s(prn: u8) -> Option<f64> {
    gnss::gps_iia_default_yaw_rate_rad_s(prn)
}

#[derive(rustler::NifUnitEnum)]
enum Manufacturer {
    Cast,
    Secm,
}

#[derive(rustler::NifUnitEnum)]
enum OrbitClass {
    Geo,
    Igso,
    Meo,
}

impl From<Manufacturer> for BeidouManufacturer {
    fn from(value: Manufacturer) -> Self {
        match value {
            Manufacturer::Cast => Self::Cast,
            Manufacturer::Secm => Self::Secm,
        }
    }
}

impl From<BeidouManufacturer> for Manufacturer {
    fn from(value: BeidouManufacturer) -> Self {
        match value {
            BeidouManufacturer::Cast => Self::Cast,
            BeidouManufacturer::Secm => Self::Secm,
        }
    }
}

impl From<OrbitClass> for BeidouOrbitClass {
    fn from(value: OrbitClass) -> Self {
        match value {
            OrbitClass::Geo => Self::Geo,
            OrbitClass::Igso => Self::Igso,
            OrbitClass::Meo => Self::Meo,
        }
    }
}

fn encode_block(env: Env<'_>, block: GnssBlock) -> Term<'_> {
    match block {
        GnssBlock::GpsIIA => gps_iia().encode(env),
        GnssBlock::GpsIIR => gps_iir().encode(env),
        GnssBlock::GpsIIRM => gps_iirm().encode(env),
        GnssBlock::GpsIIF => gps_iif().encode(env),
        GnssBlock::GpsIII => gps_iii().encode(env),
        GnssBlock::GlonassM => glonass_m().encode(env),
        GnssBlock::GalileoIov => galileo_iov().encode(env),
        GnssBlock::GalileoFoc => galileo_foc().encode(env),
        GnssBlock::Beidou2Geo => beidou2_geo().encode(env),
        GnssBlock::Beidou2Igso => beidou2_igso().encode(env),
        GnssBlock::Beidou2Meo => beidou2_meo().encode(env),
        GnssBlock::Beidou3Geo => beidou3_geo().encode(env),
        GnssBlock::Beidou3Igso => beidou3_igso().encode(env),
        GnssBlock::Beidou3Meo { manufacturer } => {
            (self::beidou3_meo(), manufacturer.map(Manufacturer::from)).encode(env)
        }
    }
}

fn decode_block(value: Term<'_>) -> NifResult<GnssBlock> {
    if let Ok((tag, manufacturer)) = value.decode::<(rustler::Atom, Option<Manufacturer>)>() {
        if tag == beidou3_meo() {
            return Ok(GnssBlock::Beidou3Meo {
                manufacturer: manufacturer.map(Into::into),
            });
        }
    }
    let tag: rustler::Atom = value.decode()?;
    Ok(match tag {
        tag if tag == gps_iia() => GnssBlock::GpsIIA,
        tag if tag == gps_iir() => GnssBlock::GpsIIR,
        tag if tag == gps_iirm() => GnssBlock::GpsIIRM,
        tag if tag == gps_iif() => GnssBlock::GpsIIF,
        tag if tag == gps_iii() => GnssBlock::GpsIII,
        tag if tag == glonass_m() => GnssBlock::GlonassM,
        tag if tag == galileo_iov() => GnssBlock::GalileoIov,
        tag if tag == galileo_foc() => GnssBlock::GalileoFoc,
        tag if tag == beidou2_geo() => GnssBlock::Beidou2Geo,
        tag if tag == beidou2_igso() => GnssBlock::Beidou2Igso,
        tag if tag == beidou2_meo() => GnssBlock::Beidou2Meo,
        tag if tag == beidou3_geo() => GnssBlock::Beidou3Geo,
        tag if tag == beidou3_igso() => GnssBlock::Beidou3Igso,
        _ => return Err(rustler::Error::BadArg),
    })
}

#[rustler::nif]
fn attitude_block_from_igs_name(env: Env<'_>, name: String) -> Term<'_> {
    encode_result(
        env,
        GnssBlock::from_igs_name(&name)
            .map(|block| encode_block(env, block))
            .map_err(|error| gnss_block_error(env, error)),
    )
}

#[rustler::nif]
fn attitude_block_from_constellation_block_type(
    env: Env<'_>,
    system: String,
    block_type: String,
    orbit_class: Option<OrbitClass>,
) -> NifResult<Term<'_>> {
    let system = crate::sp3::system_from_letter(&system)?;
    Ok(encode_result(
        env,
        GnssBlock::from_constellation_block_type(system, &block_type, orbit_class.map(Into::into))
            .map(|block| encode_block(env, block))
            .map_err(|error| gnss_block_error(env, error)),
    ))
}

#[rustler::nif]
fn attitude_block_igs_name(block: Term<'_>) -> NifResult<&'static str> {
    Ok(decode_block(block)?.igs_name())
}

#[rustler::nif]
fn attitude_block_system(block: Term<'_>) -> NifResult<String> {
    Ok(decode_block(block)?.system().letter().to_string())
}

#[derive(NifMap)]
struct CosineTurn {
    beta_limit_rad: f64,
    beta_limit_inclusive: bool,
    start_angle: rustler::Atom,
    start_angle_rad: f64,
    period_s: f64,
}

fn cosine_term(value: CosineTurnParameters) -> CosineTurn {
    CosineTurn {
        beta_limit_rad: value.beta_limit_rad,
        beta_limit_inclusive: value.beta_limit_inclusive,
        start_angle: match value.start_angle {
            CosineTurnStartAngle::Colinearity => colinearity(),
            CosineTurnStartAngle::OrbitAngle => orbit_angle(),
            _ => unknown(),
        },
        start_angle_rad: value.start_angle_rad,
        period_s: value.period_s,
    }
}

fn encode_law(env: Env<'_>, law: GnssAttitudeLaw) -> Term<'_> {
    match law {
        GnssAttitudeLaw::GpsIIA {
            yaw_rate_rad_s,
            yaw_bias_rad,
            shadow_limit_rad,
        } => (
            self::gps_iia(),
            detail_map(
                env,
                &[
                    (self::yaw_rate_rad_s(), yaw_rate_rad_s.encode(env)),
                    (self::yaw_bias_rad(), yaw_bias_rad.encode(env)),
                    (self::shadow_limit_rad(), shadow_limit_rad.encode(env)),
                ],
            ),
        )
            .encode(env),
        GnssAttitudeLaw::GpsIIR { yaw_rate_rad_s } => (
            self::gps_iir(),
            detail_map(env, &[(self::yaw_rate_rad_s(), yaw_rate_rad_s.encode(env))]),
        )
            .encode(env),
        GnssAttitudeLaw::GpsIIF {
            yaw_rate_rad_s,
            yaw_bias_rad,
            shadow_limit_rad,
        } => (
            self::gps_iif(),
            detail_map(
                env,
                &[
                    (self::yaw_rate_rad_s(), yaw_rate_rad_s.encode(env)),
                    (self::yaw_bias_rad(), yaw_bias_rad.encode(env)),
                    (self::shadow_limit_rad(), shadow_limit_rad.encode(env)),
                ],
            ),
        )
            .encode(env),
        GnssAttitudeLaw::GlonassM {
            yaw_rate_rad_s,
            shadow_limit_rad,
        } => (
            self::glonass_m(),
            detail_map(
                env,
                &[
                    (self::yaw_rate_rad_s(), yaw_rate_rad_s.encode(env)),
                    (self::shadow_limit_rad(), shadow_limit_rad.encode(env)),
                ],
            ),
        )
            .encode(env),
        GnssAttitudeLaw::GalileoIov {
            beta_x_rad,
            beta_y_rad,
        } => (
            self::galileo_iov(),
            detail_map(
                env,
                &[
                    (self::beta_x_rad(), beta_x_rad.encode(env)),
                    (self::beta_y_rad(), beta_y_rad.encode(env)),
                ],
            ),
        )
            .encode(env),
        GnssAttitudeLaw::CosineTurn(parameters) => {
            (self::cosine_turn(), cosine_term(parameters)).encode(env)
        }
        GnssAttitudeLaw::BeidouOrbitNormalSwitch {
            ys_to_on_beta_rad,
            on_to_ys_beta_rad,
        } => (
            self::beidou_orbit_normal_switch(),
            detail_map(
                env,
                &[
                    (self::ys_to_on_beta_rad(), ys_to_on_beta_rad.encode(env)),
                    (self::on_to_ys_beta_rad(), on_to_ys_beta_rad.encode(env)),
                ],
            ),
        )
            .encode(env),
        GnssAttitudeLaw::FixedBetaYawSteering { beta0_rad } => (
            self::fixed_beta_yaw_steering(),
            detail_map(env, &[(self::beta0_rad(), beta0_rad.encode(env))]),
        )
            .encode(env),
        GnssAttitudeLaw::Beidou3MeoUnknownManufacturer {
            cast,
            secm_beta0_rad,
        } => (
            self::beidou3_meo_unknown_manufacturer(),
            detail_map(
                env,
                &[
                    (self::cast(), cosine_term(cast).encode(env)),
                    (self::secm_beta0_rad(), secm_beta0_rad.encode(env)),
                ],
            ),
        )
            .encode(env),
        GnssAttitudeLaw::OrbitNormal => orbit_normal().encode(env),
        _ => unknown().encode(env),
    }
}

#[rustler::nif]
fn attitude_law_for_block<'a>(
    env: Env<'a>,
    block: Term<'a>,
    prn: Option<u8>,
) -> NifResult<Term<'a>> {
    Ok(encode_result(
        env,
        GnssAttitudeLaw::for_block(decode_block(block)?, prn)
            .map(|law| encode_law(env, law))
            .map_err(|error| gnss_attitude_error(env, error)),
    ))
}

#[rustler::nif]
fn attitude_gps_iia_default_yaw_bias_rad() -> f64 {
    gnss::GPS_IIA_DEFAULT_YAW_BIAS_RAD
}

#[rustler::nif]
fn attitude_gps_iir_default_yaw_rate_rad_s() -> f64 {
    gnss::GPS_IIR_DEFAULT_YAW_RATE_RAD_S
}

#[rustler::nif]
fn attitude_gps_iif_default_yaw_rate_rad_s() -> f64 {
    gnss::GPS_IIF_DEFAULT_YAW_RATE_RAD_S
}

#[rustler::nif]
fn attitude_gps_iif_default_yaw_bias_rad() -> f64 {
    gnss::GPS_IIF_DEFAULT_YAW_BIAS_RAD
}

#[rustler::nif]
fn attitude_gps_shadow_limit_rad() -> f64 {
    gnss::GPS_SHADOW_LIMIT_RAD
}

#[rustler::nif]
fn attitude_glonass_m_default_yaw_rate_rad_s() -> f64 {
    gnss::GLONASS_M_DEFAULT_YAW_RATE_RAD_S
}

#[rustler::nif]
fn attitude_glonass_m_shadow_limit_rad() -> f64 {
    gnss::GLONASS_M_SHADOW_LIMIT_RAD
}

#[rustler::nif]
fn attitude_galileo_iov_beta_x_rad() -> f64 {
    gnss::GALILEO_IOV_BETA_X_RAD
}

#[rustler::nif]
fn attitude_galileo_iov_beta_y_rad() -> f64 {
    gnss::GALILEO_IOV_BETA_Y_RAD
}

#[rustler::nif]
fn attitude_gps_iii_beta_x_rad() -> f64 {
    gnss::GPS_III_BETA_X_RAD
}

#[rustler::nif]
fn attitude_gps_iii_beta_y_rad() -> f64 {
    gnss::GPS_III_BETA_Y_RAD
}

#[rustler::nif]
fn attitude_galileo_foc_turn() -> CosineTurn {
    cosine_term(gnss::GALILEO_FOC_TURN)
}

#[rustler::nif]
fn attitude_beidou3_cast_meo_turn() -> CosineTurn {
    cosine_term(gnss::BEIDOU3_CAST_MEO_TURN)
}

#[rustler::nif]
fn attitude_beidou3_cast_igso_turn() -> CosineTurn {
    cosine_term(gnss::BEIDOU3_CAST_IGSO_TURN)
}

#[rustler::nif]
fn attitude_beidou3_secm_beta0_rad() -> f64 {
    gnss::BEIDOU3_SECM_BETA0_RAD
}

#[rustler::nif]
fn attitude_beidou2_ys_to_on_beta_rad() -> f64 {
    gnss::BEIDOU2_YS_TO_ON_BETA_RAD
}

#[rustler::nif]
fn attitude_beidou2_on_to_ys_beta_rad() -> f64 {
    gnss::BEIDOU2_ON_TO_YS_BETA_RAD
}

#[rustler::nif]
fn attitude_block_compare(first: Term<'_>, second: Term<'_>) -> NifResult<rustler::Atom> {
    Ok(crate::errors::ordering_atom(
        decode_block(first)?.cmp(&decode_block(second)?),
    ))
}

#[rustler::nif]
fn attitude_manufacturer_compare(first: Manufacturer, second: Manufacturer) -> rustler::Atom {
    let first = BeidouManufacturer::from(first);
    crate::errors::ordering_atom(first.cmp(&second.into()))
}

#[rustler::nif]
fn attitude_orbit_class_compare(first: OrbitClass, second: OrbitClass) -> rustler::Atom {
    let first = BeidouOrbitClass::from(first);
    crate::errors::ordering_atom(first.cmp(&second.into()))
}

impl TryFrom<CosineTurn> for CosineTurnParameters {
    type Error = rustler::Error;

    fn try_from(turn: CosineTurn) -> NifResult<Self> {
        let start_angle = match turn.start_angle {
            angle if angle == colinearity() => CosineTurnStartAngle::Colinearity,
            angle if angle == orbit_angle() => CosineTurnStartAngle::OrbitAngle,
            _ => return Err(rustler::Error::BadArg),
        };
        Ok(Self {
            beta_limit_rad: turn.beta_limit_rad,
            beta_limit_inclusive: turn.beta_limit_inclusive,
            start_angle,
            start_angle_rad: turn.start_angle_rad,
            period_s: turn.period_s,
        })
    }
}

fn decode_law(term: Term<'_>) -> NifResult<GnssAttitudeLaw> {
    if term
        .decode::<rustler::Atom>()
        .is_ok_and(|tag| tag == orbit_normal())
    {
        return Ok(GnssAttitudeLaw::OrbitNormal);
    }
    let (tag, parameters): (rustler::Atom, Term<'_>) = term.decode()?;
    let number = |key: rustler::Atom| parameters.map_get(key)?.decode::<f64>();
    Ok(match tag {
        tag if tag == gps_iia() => GnssAttitudeLaw::GpsIIA {
            yaw_rate_rad_s: number(yaw_rate_rad_s())?,
            yaw_bias_rad: number(yaw_bias_rad())?,
            shadow_limit_rad: number(shadow_limit_rad())?,
        },
        tag if tag == gps_iir() => GnssAttitudeLaw::GpsIIR {
            yaw_rate_rad_s: number(yaw_rate_rad_s())?,
        },
        tag if tag == gps_iif() => GnssAttitudeLaw::GpsIIF {
            yaw_rate_rad_s: number(yaw_rate_rad_s())?,
            yaw_bias_rad: number(yaw_bias_rad())?,
            shadow_limit_rad: number(shadow_limit_rad())?,
        },
        tag if tag == glonass_m() => GnssAttitudeLaw::GlonassM {
            yaw_rate_rad_s: number(yaw_rate_rad_s())?,
            shadow_limit_rad: number(shadow_limit_rad())?,
        },
        tag if tag == galileo_iov() => GnssAttitudeLaw::GalileoIov {
            beta_x_rad: number(beta_x_rad())?,
            beta_y_rad: number(beta_y_rad())?,
        },
        tag if tag == cosine_turn() => {
            GnssAttitudeLaw::CosineTurn(parameters.decode::<CosineTurn>()?.try_into()?)
        }
        tag if tag == beidou_orbit_normal_switch() => GnssAttitudeLaw::BeidouOrbitNormalSwitch {
            ys_to_on_beta_rad: number(ys_to_on_beta_rad())?,
            on_to_ys_beta_rad: number(on_to_ys_beta_rad())?,
        },
        tag if tag == fixed_beta_yaw_steering() => GnssAttitudeLaw::FixedBetaYawSteering {
            beta0_rad: number(beta0_rad())?,
        },
        tag if tag == beidou3_meo_unknown_manufacturer() => {
            GnssAttitudeLaw::Beidou3MeoUnknownManufacturer {
                cast: parameters
                    .map_get(cast())?
                    .decode::<CosineTurn>()?
                    .try_into()?,
                secm_beta0_rad: number(secm_beta0_rad())?,
            }
        }
        _ => return Err(rustler::Error::BadArg),
    })
}

type Satellite = (String, String);
#[derive(rustler::NifTaggedEnum)]
enum TrajectorySource {
    Sp3(ResourceArc<Sp3Resource>, Satellite, BodyFixedProvider),
    Broadcast(ResourceArc<BroadcastResource>, Satellite, BodyFixedProvider),
    OrbitSource(ResourceArc<Source>, Satellite, BodyFixedProvider),
    EcksteinHechler(ResourceArc<EcksteinHechlerPropagator>),
    BrouwerLyddane(ResourceArc<BrouwerLyddanePropagator>),
    DenseOutput(ResourceArc<DenseOutputResource>),
}

#[derive(NifMap)]
struct Trajectory {
    source: TrajectorySource,
    de_ephemeris: Option<ResourceArc<DeResource>>,
    velocity_half_step_s: Option<f64>,
}

impl Trajectory {
    fn configured<'a>(
        &'a self,
        mut trajectory: OrbitAttitudeTrajectory<'a>,
    ) -> Result<OrbitAttitudeTrajectory<'a>, OrbitScoreError> {
        if let Some(de) = &self.de_ephemeris {
            trajectory = trajectory.with_de_ephemeris(&de.0);
        }
        if let Some(step) = self.velocity_half_step_s {
            trajectory = trajectory.with_velocity_half_step_s(step)?;
        }
        Ok(trajectory)
    }

    fn with_trajectory<T>(
        &self,
        run: impl FnOnce(&OrbitAttitudeTrajectory<'_>) -> T,
    ) -> NifResult<Result<T, OrbitScoreError>> {
        let tdb = match &self.source {
            TrajectorySource::Sp3(_, _, provider)
            | TrajectorySource::Broadcast(_, _, provider)
            | TrajectorySource::OrbitSource(_, _, provider) => provider.tdb_provider(),
            _ => TdbEarthOrientationProvider::new(),
        };
        let trajectory = match &self.source {
            TrajectorySource::Sp3(source, satellite, provider) => {
                OrbitAttitudeTrajectory::from_sp3(
                    &source.sp3,
                    decode_satellite(satellite.clone())?,
                    provider.as_provider(&tdb),
                )
            }
            TrajectorySource::Broadcast(source, satellite, provider) => {
                OrbitAttitudeTrajectory::from_broadcast(
                    &source.store,
                    decode_satellite(satellite.clone())?,
                    provider.as_provider(&tdb),
                )
            }
            TrajectorySource::OrbitSource(source, satellite, provider) => {
                let satellite = decode_satellite(satellite.clone())?;
                let orientation = provider.as_provider(&tdb);
                return Ok(source
                    .with_source(|source| {
                        self.configured(OrbitAttitudeTrajectory::from_orbit_source(
                            source,
                            satellite,
                            orientation,
                        ))
                        .map(|trajectory| run(&trajectory))
                    })
                    .and_then(|result| result));
            }
            TrajectorySource::EcksteinHechler(source) => {
                OrbitAttitudeTrajectory::from_eckstein_hechler(&source.0)
            }
            TrajectorySource::BrouwerLyddane(source) => {
                OrbitAttitudeTrajectory::from_brouwer_lyddane(&source.0)
            }
            TrajectorySource::DenseOutput(source) => {
                OrbitAttitudeTrajectory::from_dense_output(&source.0)
            }
        };
        Ok(self
            .configured(trajectory)
            .map(|trajectory| run(&trajectory)))
    }
}

#[derive(NifMap)]
#[rustler(encode)]
struct Sample {
    position_m: Vec3,
    velocity_m_s: Vec3,
    sun_position_m: Vec3,
}

impl From<gnss::AttitudeSample> for Sample {
    fn from(sample: gnss::AttitudeSample) -> Self {
        Self {
            position_m: vector_tuple(sample.position_m),
            velocity_m_s: vector_tuple(sample.velocity_m_s),
            sun_position_m: vector_tuple(sample.sun_position_m),
        }
    }
}

#[derive(NifMap)]
#[rustler(encode)]
struct Attitude {
    mode: rustler::Atom,
    yaw_rad: f64,
    nominal_yaw_rad: f64,
    beta_rad: f64,
    orbit_angle_rad: f64,
    body_x: Vec3,
    body_y: Vec3,
    body_z: Vec3,
    dyb: Option<Dyb>,
}

impl From<GnssAttitude> for Attitude {
    fn from(attitude: GnssAttitude) -> Self {
        let mode = match attitude.mode {
            AttitudeMode::Nominal => nominal(),
            AttitudeMode::NoonTurn => noon_turn(),
            AttitudeMode::MidnightTurn => midnight_turn(),
            AttitudeMode::Shadow => shadow(),
            AttitudeMode::OrbitNormal => orbit_normal(),
            AttitudeMode::ModifiedYawSteering => modified_yaw_steering(),
            _ => unknown(),
        };
        Self {
            mode,
            yaw_rad: attitude.yaw_rad,
            nominal_yaw_rad: attitude.nominal_yaw_rad,
            beta_rad: attitude.beta_rad,
            orbit_angle_rad: attitude.orbit_angle_rad,
            body_x: vector_tuple(attitude.body_x),
            body_y: vector_tuple(attitude.body_y),
            body_z: vector_tuple(attitude.body_z),
            dyb: attitude.dyb.map(Into::into),
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn attitude_trajectory_validate(env: Env<'_>, trajectory: Trajectory) -> NifResult<Term<'_>> {
    Ok(encode_result(
        env,
        trajectory
            .with_trajectory(|_| ())?
            .map_err(|error| orbit_score_error(env, error)),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn attitude_trajectory_sample(
    env: Env<'_>,
    trajectory: Trajectory,
    epoch: f64,
) -> NifResult<Term<'_>> {
    let result = trajectory
        .with_trajectory(|trajectory| trajectory.sample(epoch))?
        .map_err(|error| orbit_score_error(env, error))
        .and_then(|sample| {
            sample.map(Sample::from).ok_or_else(|| {
                gnss_attitude_error(env, GnssAttitudeError::TrajectoryUnavailable { t_s: epoch })
            })
        });
    Ok(encode_result(env, result))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn gnss_attitude<'a>(
    env: Env<'a>,
    law: Term<'a>,
    trajectory: Trajectory,
    epoch: f64,
) -> NifResult<Term<'a>> {
    let law = decode_law(law)?;
    let result = trajectory
        .with_trajectory(|trajectory| gnss::gnss_attitude(&law, trajectory, epoch))?
        .map_err(|error| orbit_score_error(env, error))
        .and_then(|attitude| {
            attitude
                .map(Attitude::from)
                .map_err(|error| gnss_attitude_error(env, error))
        });
    Ok(encode_result(env, result))
}
