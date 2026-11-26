use crate::broadcast::BroadcastResource;
use crate::errors::{detail_map, encode_result, Refusal};
use crate::precise_samples::{epoch_fields, instant_from_fields, EpochTerm};
use crate::sp3::{system_from_letter, Sp3Resource};
use crate::{vector_tuple, Vec3};
use rustler::{Encoder, Env, NifMap, NifResult, NifTaggedEnum, NifUnitEnum, ResourceArc, Term};
use sidereon_core::astro::time::model::Instant;
use sidereon_core::ephemeris::{Sp3FrameLabelSet, Sp3FrameReconciliationOptions};
use sidereon_core::orbit_scoring as scoring;
use sidereon_core::orbit_scoring::{OrbitScoreError, OrbitSource};
use sidereon_core::{Error, GnssSatelliteId};

rustler::atoms! { asserted_equivalent, broadcast_datums, degenerate_reference_state, detail, epoch_index, epoch_out_of_range, error, expected, field, found, frame_mismatch, frame_transform, helmert, index, instant_time_system_mismatch, insufficient_precise_nodes, invalid_input, kind, label, message, missing_epoch, missing_satellite, no_prediction_origin, no_sisre_weights, nodes, non_finite_result, non_finite_source_state, orbit_source, product, reason, reference, regime, required, same_label, satellite, time_system_label_mismatch, time_system_mismatch, undetermined_orbit_regime, unknown, unknown_satellite }
pub(crate) fn orbit_score_error(env: Env<'_>, error: OrbitScoreError) -> Refusal<'_> {
    let (kind, detail) = match &error {
        OrbitScoreError::InvalidInput { field, reason } => (
            invalid_input(),
            detail_map(
                env,
                &[
                    (self::field(), (field).encode(env)),
                    (self::reason(), (reason).encode(env)),
                ],
            ),
        ),
        OrbitScoreError::TimeSystemMismatch {
            orbit_source,
            reference,
        } => (
            time_system_mismatch(),
            detail_map(
                env,
                &[
                    (self::orbit_source(), (orbit_source.abbrev()).encode(env)),
                    (self::reference(), (reference.abbrev()).encode(env)),
                ],
            ),
        ),
        OrbitScoreError::TimeSystemLabelMismatch {
            orbit_source,
            reference,
        } => (
            time_system_label_mismatch(),
            detail_map(
                env,
                &[
                    (self::orbit_source(), (orbit_source.label()).encode(env)),
                    (self::reference(), (reference.label()).encode(env)),
                ],
            ),
        ),
        OrbitScoreError::InstantTimeSystemMismatch {
            field,
            index,
            found,
            expected,
        } => (
            instant_time_system_mismatch(),
            detail_map(
                env,
                &[
                    (self::field(), (field).encode(env)),
                    (self::index(), (index).encode(env)),
                    (self::found(), (found.abbrev()).encode(env)),
                    (self::expected(), (expected.abbrev()).encode(env)),
                ],
            ),
        ),
        OrbitScoreError::FrameMismatch {
            orbit_source,
            reference,
        } => (
            frame_mismatch(),
            detail_map(
                env,
                &[
                    (self::orbit_source(), (orbit_source).encode(env)),
                    (self::reference(), (reference).encode(env)),
                ],
            ),
        ),
        OrbitScoreError::FrameTransform(value) => (
            frame_transform(),
            detail_map(
                env,
                &[(
                    self::error(),
                    (crate::frame_catalog::error_term(*value)).encode(env),
                )],
            ),
        ),
        OrbitScoreError::MissingSatellite { product, satellite } => (
            missing_satellite(),
            detail_map(
                env,
                &[
                    (self::product(), (Product::from(*product)).encode(env)),
                    (self::satellite(), (satellite.to_string()).encode(env)),
                ],
            ),
        ),
        OrbitScoreError::MissingEpoch {
            product,
            satellite,
            epoch_index,
            error,
        } => (
            missing_epoch(),
            detail_map(
                env,
                &[
                    (self::product(), (Product::from(*product)).encode(env)),
                    (self::satellite(), (satellite.to_string()).encode(env)),
                    (self::epoch_index(), (epoch_index).encode(env)),
                    (self::error(), (source_error(env, error)).encode(env)),
                ],
            ),
        ),
        OrbitScoreError::NoPredictionOrigin { satellite } => (
            no_prediction_origin(),
            detail_map(
                env,
                &[(self::satellite(), (satellite.to_string()).encode(env))],
            ),
        ),
        OrbitScoreError::NoSisreWeights { satellite, regime } => (
            no_sisre_weights(),
            detail_map(
                env,
                &[
                    (self::satellite(), (satellite.to_string()).encode(env)),
                    (self::regime(), (Regime::from(*regime)).encode(env)),
                ],
            ),
        ),
        OrbitScoreError::UndeterminedOrbitRegime { satellite } => (
            undetermined_orbit_regime(),
            detail_map(
                env,
                &[(self::satellite(), (satellite.to_string()).encode(env))],
            ),
        ),
        OrbitScoreError::NonFiniteSourceState {
            satellite,
            epoch_index,
        } => (
            non_finite_source_state(),
            detail_map(
                env,
                &[
                    (self::satellite(), (satellite.to_string()).encode(env)),
                    (self::epoch_index(), (epoch_index).encode(env)),
                ],
            ),
        ),
        OrbitScoreError::DegenerateReferenceState {
            satellite,
            epoch_index,
        } => (
            degenerate_reference_state(),
            detail_map(
                env,
                &[
                    (self::satellite(), (satellite.to_string()).encode(env)),
                    (self::epoch_index(), (epoch_index).encode(env)),
                ],
            ),
        ),
        OrbitScoreError::NonFiniteResult { satellite } => (
            non_finite_result(),
            detail_map(
                env,
                &[(self::satellite(), (satellite.to_string()).encode(env))],
            ),
        ),
        _ => (unknown(), Term::map_new(env)),
    };
    Refusal {
        kind,
        detail,
        message: error.to_string(),
    }
}

#[derive(NifUnitEnum)]
enum Regime {
    Meo,
    Igso,
    Geo,
}

impl From<scoring::OrbitRegime> for Regime {
    fn from(value: scoring::OrbitRegime) -> Self {
        match value {
            scoring::OrbitRegime::Meo => Self::Meo,
            scoring::OrbitRegime::Igso => Self::Igso,
            scoring::OrbitRegime::Geo => Self::Geo,
        }
    }
}

impl From<Regime> for scoring::OrbitRegime {
    fn from(value: Regime) -> Self {
        match value {
            Regime::Meo => Self::Meo,
            Regime::Igso => Self::Igso,
            Regime::Geo => Self::Geo,
        }
    }
}

#[derive(NifUnitEnum)]
enum Product {
    Source,
    Reference,
}

impl From<scoring::ScoredProduct> for Product {
    fn from(value: scoring::ScoredProduct) -> Self {
        match value {
            scoring::ScoredProduct::Source => Self::Source,
            scoring::ScoredProduct::Reference => Self::Reference,
        }
    }
}

#[derive(NifUnitEnum)]
enum Triad {
    Inertial,
    EarthFixed,
}

impl From<Triad> for scoring::TriadVelocity {
    fn from(value: Triad) -> Self {
        match value {
            Triad::Inertial => Self::Inertial,
            Triad::EarthFixed => Self::EarthFixed,
        }
    }
}

#[derive(NifUnitEnum)]
enum Datum {
    EpochSystemMedian,
    Unadjusted,
}

impl From<Datum> for scoring::ClockDatum {
    fn from(value: Datum) -> Self {
        match value {
            Datum::EpochSystemMedian => Self::EpochSystemMedian,
            Datum::Unadjusted => Self::Unadjusted,
        }
    }
}

#[derive(NifUnitEnum)]
enum Gaps {
    Count,
    Refuse,
}

impl From<Gaps> for scoring::GapPolicy {
    fn from(value: Gaps) -> Self {
        match value {
            Gaps::Count => Self::Count,
            Gaps::Refuse => Self::Refuse,
        }
    }
}

#[derive(NifUnitEnum)]
enum ReferencePoint {
    CenterOfMass,
    AntennaPhaseCenter,
}

impl From<scoring::OrbitReferencePoint> for ReferencePoint {
    fn from(value: scoring::OrbitReferencePoint) -> Self {
        match value {
            scoring::OrbitReferencePoint::CenterOfMass => Self::CenterOfMass,
            scoring::OrbitReferencePoint::AntennaPhaseCenter => Self::AntennaPhaseCenter,
        }
    }
}

#[derive(NifMap)]
struct Rtn {
    radial_m: f64,
    transverse_m: f64,
    normal_m: f64,
}

impl From<scoring::RtnComponents> for Rtn {
    fn from(value: scoring::RtnComponents) -> Self {
        Self {
            radial_m: value.radial_m,
            transverse_m: value.transverse_m,
            normal_m: value.normal_m,
        }
    }
}

#[derive(NifMap)]
#[rustler(encode)]
struct SourceState {
    position_ecef_m: Vec3,
    clock_s: Option<f64>,
}

impl From<scoring::OrbitSourceState> for SourceState {
    fn from(value: scoring::OrbitSourceState) -> Self {
        Self {
            position_ecef_m: vector_tuple(value.position_ecef_m),
            clock_s: value.clock_s,
        }
    }
}

#[derive(NifMap)]
#[rustler(encode)]
struct Stats {
    rms_m: f64,
    mean_m: f64,
    max_abs_m: f64,
}

impl From<scoring::ErrorStats> for Stats {
    fn from(value: scoring::ErrorStats) -> Self {
        Self {
            rms_m: value.rms_m,
            mean_m: value.mean_m,
            max_abs_m: value.max_abs_m,
        }
    }
}

#[derive(NifMap)]
#[rustler(encode)]
struct Bin {
    horizon_start_s: f64,
    horizon_end_s: f64,
    count: usize,
    radial: Option<Stats>,
    transverse: Option<Stats>,
    normal: Option<Stats>,
    orbit_3d: Option<Stats>,
    sisre_orbit: Option<Stats>,
    clock_count: usize,
    clock: Option<Stats>,
    sisre: Option<Stats>,
}

impl From<scoring::HorizonBinStats> for Bin {
    fn from(value: scoring::HorizonBinStats) -> Self {
        Self {
            horizon_start_s: value.horizon_start_s,
            horizon_end_s: value.horizon_end_s,
            count: value.count,
            radial: value.radial.map(Stats::from),
            transverse: value.transverse.map(Stats::from),
            normal: value.normal.map(Stats::from),
            orbit_3d: value.orbit_3d.map(Stats::from),
            sisre_orbit: value.sisre_orbit.map(Stats::from),
            clock_count: value.clock_count,
            clock: value.clock.map(Stats::from),
            sisre: value.sisre.map(Stats::from),
        }
    }
}

#[derive(NifMap)]
#[rustler(encode)]
struct Coverage {
    epochs: usize,
    scored: usize,
    clocked: usize,
    outside_horizon_bins: usize,
    no_prediction_origin: usize,
    source_satellite_missing: usize,
    source_epoch_missing: usize,
    reference_satellite_missing: usize,
    reference_epoch_missing: usize,
}

impl From<scoring::ScoreCoverage> for Coverage {
    fn from(value: scoring::ScoreCoverage) -> Self {
        Self {
            epochs: value.epochs,
            scored: value.scored,
            clocked: value.clocked,
            outside_horizon_bins: value.outside_horizon_bins,
            no_prediction_origin: value.no_prediction_origin,
            source_satellite_missing: value.source_satellite_missing,
            source_epoch_missing: value.source_epoch_missing,
            reference_satellite_missing: value.reference_satellite_missing,
            reference_epoch_missing: value.reference_epoch_missing,
        }
    }
}

#[derive(NifMap)]
#[rustler(encode)]
struct Satellite {
    satellite: String,
    prediction_origin_j2000_s: Option<f64>,
    orbit_regime: Option<Regime>,
    sisre_weights: Option<Weights>,
    bins: Vec<Bin>,
    coverage: Coverage,
}

impl From<scoring::SatelliteScore> for Satellite {
    fn from(value: scoring::SatelliteScore) -> Self {
        Self {
            satellite: value.satellite.to_string(),
            prediction_origin_j2000_s: value.prediction_origin_j2000_s,
            orbit_regime: value.orbit_regime.map(Regime::from),
            sisre_weights: value.sisre_weights.map(Weights::from),
            bins: value.bins.into_iter().map(Bin::from).collect(),
            coverage: value.coverage.into(),
        }
    }
}

#[derive(NifMap)]
#[rustler(encode)]
struct System {
    system: String,
    bins: Vec<Bin>,
    coverage: Coverage,
}

impl From<scoring::SystemScore> for System {
    fn from(value: scoring::SystemScore) -> Self {
        Self {
            system: value.system.letter().to_string(),
            bins: value.bins.into_iter().map(Bin::from).collect(),
            coverage: value.coverage.into(),
        }
    }
}

#[derive(NifMap)]
#[rustler(encode)]
struct Report<'a> {
    horizon_bin_edges_s: Vec<f64>,
    frame: Term<'a>,
    source_reference_point: ReferencePoint,
    per_satellite: Vec<Satellite>,
    per_system: Vec<System>,
    coverage: Coverage,
}

fn score_report<'a>(env: Env<'a>, value: scoring::OrbitScoreReport) -> Report<'a> {
    Report {
        horizon_bin_edges_s: value.horizon_bin_edges_s,
        frame: frame_agreement(env, value.frame),
        source_reference_point: value.source_reference_point.into(),
        per_satellite: value
            .per_satellite
            .into_iter()
            .map(Satellite::from)
            .collect(),
        per_system: value.per_system.into_iter().map(System::from).collect(),
        coverage: value.coverage.into(),
    }
}

impl From<Rtn> for scoring::RtnComponents {
    fn from(value: Rtn) -> Self {
        let Rtn {
            radial_m,
            transverse_m,
            normal_m,
        } = value;
        Self {
            radial_m,
            transverse_m,
            normal_m,
        }
    }
}

fn frame_agreement(env: Env<'_>, value: scoring::FrameAgreement) -> Term<'_> {
    use scoring::FrameAgreement;
    match value {
        FrameAgreement::SameLabel => same_label().encode(env),
        FrameAgreement::AssertedEquivalent => asserted_equivalent().encode(env),
        FrameAgreement::BroadcastDatums => broadcast_datums().encode(env),
        FrameAgreement::Helmert { from, to } => {
            (helmert(), from.to_string(), to.to_string()).encode(env)
        }
    }
}

fn orbit_frame(env: Env<'_>, value: scoring::OrbitFrame) -> Term<'_> {
    match value {
        scoring::OrbitFrame::Label(value) => (label(), value).encode(env),
        scoring::OrbitFrame::BroadcastDatums => broadcast_datums().encode(env),
    }
}

fn source_error<'a>(env: Env<'a>, error: &Error) -> Refusal<'a> {
    let (kind, detail) = match error {
        Error::UnknownSatellite(id) => (
            unknown_satellite(),
            detail_map(env, &[(satellite(), id.to_string().encode(env))]),
        ),
        Error::EpochOutOfRange => (epoch_out_of_range(), Term::map_new(env)),
        Error::InsufficientPreciseNodes {
            sat,
            nodes: count,
            required: need,
        } => (
            insufficient_precise_nodes(),
            detail_map(
                env,
                &[
                    (satellite(), sat.to_string().encode(env)),
                    (nodes(), count.encode(env)),
                    (required(), need.encode(env)),
                ],
            ),
        ),
        Error::InvalidInput(value) => (
            invalid_input(),
            detail_map(env, &[(message(), value.encode(env))]),
        ),
        _ => (unknown(), Term::map_new(env)),
    };
    Refusal {
        kind,
        detail,
        message: error.to_string(),
    }
}

fn result<'a>(env: Env<'a>, value: Result<impl Encoder, OrbitScoreError>) -> Term<'a> {
    encode_result(env, value.map_err(|error| orbit_score_error(env, error)))
}

#[derive(NifMap)]
struct Weights {
    radial: f64,
    transverse_normal_squared: f64,
}

impl From<scoring::SisreWeights> for Weights {
    fn from(value: scoring::SisreWeights) -> Self {
        Self {
            radial: value.radial(),
            transverse_normal_squared: value.transverse_normal_squared(),
        }
    }
}

impl TryFrom<Weights> for scoring::SisreWeights {
    type Error = OrbitScoreError;
    fn try_from(value: Weights) -> Result<Self, Self::Error> {
        Self::new(value.radial, value.transverse_normal_squared)
    }
}

#[derive(NifTaggedEnum)]
enum ScoreEpochs {
    ReferenceRecords,
    Instants(Vec<EpochTerm>),
}

#[derive(NifTaggedEnum)]
enum WeightSelection {
    Montenbruck2018,
    Fixed(Weights),
}

#[derive(NifMap)]
struct Reconciliation {
    asserted_equivalent_label_sets: Vec<Vec<String>>,
    helmert: bool,
}

#[derive(NifMap)]
struct ScoreOptions {
    epochs: Option<ScoreEpochs>,
    horizon_bin_edges_s: Vec<f64>,
    triad: Option<Triad>,
    velocity_half_step_s: Option<f64>,
    sisre_weights: Option<WeightSelection>,
    clock_datum: Option<Datum>,
    gaps: Option<Gaps>,
    frame_reconciliation: Option<Reconciliation>,
}

impl ScoreOptions {
    fn into_core(self) -> NifResult<Result<scoring::OrbitScoreOptions, OrbitScoreError>> {
        let mut value = scoring::OrbitScoreOptions::new(self.horizon_bin_edges_s);
        value.epochs = match self.epochs {
            None => value.epochs,
            Some(ScoreEpochs::ReferenceRecords) => scoring::ScoreEpochs::ReferenceRecords,
            Some(ScoreEpochs::Instants(epochs)) => scoring::ScoreEpochs::Instants(
                epochs
                    .into_iter()
                    .map(instant_from_fields)
                    .collect::<NifResult<Vec<_>>>()?,
            ),
        };
        value.triad = self.triad.map(Into::into).unwrap_or(value.triad);
        value.velocity_half_step_s = self
            .velocity_half_step_s
            .unwrap_or(value.velocity_half_step_s);
        value.sisre_weights = match self.sisre_weights {
            None => value.sisre_weights,
            Some(WeightSelection::Montenbruck2018) => {
                scoring::SisreWeightSelection::Montenbruck2018
            }
            Some(WeightSelection::Fixed(weights)) => match scoring::SisreWeights::try_from(weights)
            {
                Ok(weights) => scoring::SisreWeightSelection::Fixed(weights),
                Err(error) => return Ok(Err(error)),
            },
        };
        value.clock_datum = self
            .clock_datum
            .map(Into::into)
            .unwrap_or(value.clock_datum);
        value.gaps = self.gaps.map(Into::into).unwrap_or(value.gaps);
        if let Some(frame_reconciliation) = self.frame_reconciliation {
            let mut reconciliation = Sp3FrameReconciliationOptions::default();
            reconciliation.asserted_equivalent_label_sets = frame_reconciliation
                .asserted_equivalent_label_sets
                .into_iter()
                .map(Sp3FrameLabelSet::new)
                .collect();
            reconciliation.helmert = frame_reconciliation.helmert;
            value.frame_reconciliation = reconciliation;
        }
        Ok(Ok(value))
    }
}

pub(crate) enum Source {
    PredictedSp3(ResourceArc<Sp3Resource>, Option<Instant>),
    Broadcast(ResourceArc<BroadcastResource>, Instant),
    Trajectory(scoring::OrbitTrajectory),
}

#[rustler::resource_impl]
impl rustler::Resource for Source {}

fn predicted(
    product: &Sp3Resource,
    cutoff: Option<Instant>,
) -> Result<scoring::PredictedSp3<'_>, OrbitScoreError> {
    match cutoff {
        None => scoring::PredictedSp3::from_prediction_flags(&product.sp3),
        Some(cutoff) => scoring::PredictedSp3::with_cutoff(&product.sp3, cutoff),
    }
}

impl Source {
    pub(crate) fn with_source<T>(
        &self,
        f: impl FnOnce(&dyn OrbitSource) -> T,
    ) -> Result<T, OrbitScoreError> {
        match self {
            Self::PredictedSp3(product, cutoff) => {
                predicted(product, *cutoff).map(|source| f(&source))
            }
            Self::Broadcast(ephemeris, origin) => {
                scoring::BroadcastOrbit::new(&ephemeris.store, *origin).map(|source| f(&source))
            }
            Self::Trajectory(trajectory) => Ok(f(trajectory)),
        }
    }
}

#[derive(NifMap)]
struct TrajectorySample {
    satellite: (String, String),
    epoch: EpochTerm,
    position_ecef_m: Vec3,
    clock_s: Option<f64>,
}

struct SatelliteIdRefusal(sidereon_core::SatelliteIdError);

impl Encoder for SatelliteIdRefusal {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        let sidereon_core::SatelliteIdError::InvalidInput {
            field: name,
            reason: value,
        } = self.0;
        Refusal {
            kind: invalid_input(),
            detail: detail_map(
                env,
                &[(field(), name.encode(env)), (reason(), value.encode(env))],
            ),
            message: self.0.to_string(),
        }
        .encode(env)
    }
}

pub(crate) fn decode_satellite((letter, prn): (String, String)) -> NifResult<GnssSatelliteId> {
    let system = system_from_letter(&letter)?;
    match prn.parse::<u8>() {
        Ok(prn) => GnssSatelliteId::new(system, prn)
            .map_err(|error| rustler::Error::Term(Box::new(SatelliteIdRefusal(error)))),
        Err(_) => format!("{letter}{prn}")
            .parse::<GnssSatelliteId>()
            .map_err(|error| rustler::Error::Term(Box::new(error.to_string()))),
    }
}

impl TryFrom<TrajectorySample> for scoring::TrajectorySample {
    type Error = rustler::Error;

    fn try_from(value: TrajectorySample) -> NifResult<Self> {
        Ok(Self {
            satellite: decode_satellite(value.satellite)?,
            epoch: instant_from_fields(value.epoch)?,
            position_ecef_m: value.position_ecef_m.into(),
            clock_s: value.clock_s,
        })
    }
}

type SourceMetadata<'a> = (String, Option<&'static str>, Term<'a>, ReferencePoint, bool);

#[rustler::nif(schedule = "DirtyCpu")]
fn orbit_score_predicted_sp3(
    env: Env<'_>,
    product: ResourceArc<Sp3Resource>,
    cutoff: Option<EpochTerm>,
) -> NifResult<Term<'_>> {
    let cutoff = cutoff.map(instant_from_fields).transpose()?;
    let source = predicted(&product, cutoff).map(|_| ());
    Ok(result(
        env,
        source.map(|()| ResourceArc::new(Source::PredictedSp3(product, cutoff))),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn orbit_score_broadcast(
    env: Env<'_>,
    ephemeris: ResourceArc<BroadcastResource>,
    origin: EpochTerm,
) -> NifResult<Term<'_>> {
    let origin = instant_from_fields(origin)?;
    let source = scoring::BroadcastOrbit::new(&ephemeris.store, origin).map(|_| ());
    Ok(result(
        env,
        source.map(|()| ResourceArc::new(Source::Broadcast(ephemeris, origin))),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn orbit_score_trajectory(
    env: Env<'_>,
    frame: String,
    origin: EpochTerm,
    samples: Vec<TrajectorySample>,
) -> NifResult<Term<'_>> {
    let samples = samples
        .into_iter()
        .map(scoring::TrajectorySample::try_from)
        .collect::<NifResult<Vec<_>>>()?;
    let origin = instant_from_fields(origin)?;
    Ok(result(
        env,
        scoring::OrbitTrajectory::new(frame, origin, samples)
            .map(Source::Trajectory)
            .map(ResourceArc::new),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn orbit_score_trajectory_configure(
    env: Env<'_>,
    handle: ResourceArc<Source>,
    included: bool,
) -> NifResult<Term<'_>> {
    let Source::Trajectory(trajectory) = &*handle else {
        return Err(rustler::Error::BadArg);
    };
    Ok(ResourceArc::new(Source::Trajectory(
        trajectory.clone().with_clock_relativity_included(included),
    ))
    .encode(env))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn orbit_score_trajectory_equal(first: ResourceArc<Source>, second: ResourceArc<Source>) -> bool {
    matches!((&*first, &*second), (Source::Trajectory(first), Source::Trajectory(second)) if first == second)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn orbit_score_trajectory_epochs(handle: ResourceArc<Source>) -> NifResult<Vec<EpochTerm>> {
    let Source::Trajectory(trajectory) = &*handle else {
        return Err(rustler::Error::BadArg);
    };
    Ok(trajectory.epochs().into_iter().map(epoch_fields).collect())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn orbit_score_trajectory_satellites(handle: ResourceArc<Source>) -> NifResult<Vec<String>> {
    let Source::Trajectory(trajectory) = &*handle else {
        return Err(rustler::Error::BadArg);
    };
    Ok(trajectory
        .satellites()
        .map(|satellite| satellite.to_string())
        .collect())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn orbit_score_source_metadata(env: Env<'_>, handle: ResourceArc<Source>) -> Term<'_> {
    result(
        env,
        handle.with_source(|source| -> SourceMetadata<'_> {
            (
                source.time_scale().abbrev().to_string(),
                source.sp3_time_system().map(|value| value.label()),
                orbit_frame(env, source.frame()),
                source.reference_point().into(),
                source.clock_includes_relativity(),
            )
        }),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn orbit_score_source_state(
    env: Env<'_>,
    handle: ResourceArc<Source>,
    sat: (String, String),
    epoch: f64,
) -> NifResult<Term<'_>> {
    let satellite = decode_satellite(sat)?;
    let outcome = handle.with_source(|source| source.state_at_j2000_s(satellite, epoch));
    Ok(match outcome {
        Ok(state) => encode_result(
            env,
            state
                .map(SourceState::from)
                .map_err(|error| source_error(env, &error)),
        ),
        Err(error) => result(env, Err::<(), _>(error)),
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn orbit_score_source_origin(
    env: Env<'_>,
    handle: ResourceArc<Source>,
    sat: (String, String),
) -> NifResult<Term<'_>> {
    let satellite = decode_satellite(sat)?;
    Ok(result(
        env,
        handle.with_source(|source| source.prediction_origin_j2000_s(satellite)),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn orbit_score_evaluate(
    env: Env<'_>,
    source: ResourceArc<Source>,
    reference: ResourceArc<Sp3Resource>,
    satellites: Vec<(String, String)>,
    options: ScoreOptions,
) -> NifResult<Term<'_>> {
    let satellites = satellites
        .into_iter()
        .map(decode_satellite)
        .collect::<NifResult<Vec<_>>>()?;
    let options = match options.into_core()? {
        Ok(options) => options,
        Err(error) => return Ok(result(env, Err::<(), _>(error))),
    };
    Ok(result(
        env,
        source
            .with_source(|source| {
                scoring::score_orbit(source, &reference.sp3, &satellites, &options)
            })
            .and_then(|value| value)
            .map(|value| score_report(env, value)),
    ))
}

#[rustler::nif]
fn orbit_score_rtn_components(
    env: Env<'_>,
    difference: Vec3,
    position: Vec3,
    velocity: Vec3,
) -> Term<'_> {
    result(
        env,
        scoring::rtn_components(difference.into(), position.into(), velocity.into()).map(Rtn::from),
    )
}

#[rustler::nif]
fn orbit_score_inertial_velocity_from_earth_fixed(
    env: Env<'_>,
    position: Vec3,
    velocity: Vec3,
) -> Term<'_> {
    result(
        env,
        scoring::inertial_velocity_from_earth_fixed(position.into(), velocity.into())
            .map(vector_tuple),
    )
}

#[rustler::nif]
fn orbit_score_orbit_regime(position: Vec3, velocity: Vec3) -> Option<Regime> {
    scoring::OrbitRegime::from_inertial_state(position.into(), velocity.into()).map(Regime::from)
}

#[rustler::nif]
fn orbit_score_orbit_regime_display(regime: Regime) -> String {
    scoring::OrbitRegime::from(regime).to_string()
}

#[rustler::nif]
fn orbit_score_product_display(product: Product) -> String {
    match product {
        Product::Source => scoring::ScoredProduct::Source,
        Product::Reference => scoring::ScoredProduct::Reference,
    }
    .to_string()
}

#[rustler::nif]
fn orbit_score_sisre_weights(
    env: Env<'_>,
    radial: f64,
    transverse_normal_squared: f64,
) -> Term<'_> {
    result(
        env,
        scoring::SisreWeights::new(radial, transverse_normal_squared).map(Weights::from),
    )
}

#[rustler::nif]
fn orbit_score_sisre_montenbruck_2018(
    system: String,
    regime: Regime,
) -> NifResult<Option<Weights>> {
    Ok(
        scoring::SisreWeights::montenbruck_2018(system_from_letter(&system)?, regime.into())
            .map(Weights::from),
    )
}

#[rustler::nif]
fn orbit_score_sisre_orbit_only_m(env: Env<'_>, weights: Weights, components: Rtn) -> Term<'_> {
    result(
        env,
        scoring::SisreWeights::try_from(weights)
            .and_then(|weights| weights.orbit_only_m(components.into())),
    )
}

#[rustler::nif]
fn orbit_score_sisre_with_clock_m(
    env: Env<'_>,
    weights: Weights,
    components: Rtn,
    clock: f64,
) -> Term<'_> {
    result(
        env,
        scoring::SisreWeights::try_from(weights)
            .and_then(|weights| weights.with_clock_m(components.into(), clock)),
    )
}

#[rustler::nif]
fn orbit_score_default_velocity_half_step_s() -> f64 {
    scoring::DEFAULT_VELOCITY_HALF_STEP_S
}

#[rustler::nif]
fn orbit_score_min_velocity_half_step_s() -> f64 {
    scoring::MIN_VELOCITY_HALF_STEP_S
}
