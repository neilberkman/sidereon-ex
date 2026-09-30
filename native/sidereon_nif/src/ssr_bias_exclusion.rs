//! Lossless boundary form of a PPP `SsrBiasExclusion`.
//!
//! A float solution's SSR/HAS bias exclusions go out to Elixir with every field
//! the core record holds, the lookup's report row included, and come back into
//! the fixed solve unchanged. Every field is plain data except two the core does
//! not let a caller build: a `PhaseContinuityToken`, whose fields are private,
//! and the `sidereon_core::Error` of `SsrTransmitTimeFailure::Source`. Each of
//! those goes out as its readable fields together with a handle holding the core
//! value, and comes back from the handle once the readable fields are checked
//! against it, so an edited view is refused rather than silently replaced.
//!
//! A core variant added after this binding was written goes out as
//! `:unrecognized` and is refused on the way back, since its content was not
//! carried.

use rustler::{Error, NifMap, NifResult, NifTaggedEnum, NifUnitEnum, ResourceArc};
use sidereon_core::astro::time::DegradeReason;
use sidereon_core::precise_positioning as core;
use sidereon_core::ssr::{
    GnssSignal, PhaseContinuityToken, PhaseDiscontinuityIndicator, SignalCode,
    SsrBiasResolutionDetails, SsrBiasStatus, SsrCodeBiasQueryResult, SsrDiscontinuityDetails,
    SsrLifetime, SsrPhaseBiasQueryResult, SsrRawSignal, SsrSignalKey, SsrSolution, SsrSource,
};
use sidereon_core::{GnssSatelliteId, GnssSystem};

/// Holds a core phase continuity token, which has no public constructor.
pub struct PhaseContinuityTokenResource {
    pub token: PhaseContinuityToken,
}

#[rustler::resource_impl]
impl rustler::Resource for PhaseContinuityTokenResource {}

/// Holds the core error an ephemeris source returned for an SSR bias check.
pub struct SsrSourceErrorResource {
    pub error: sidereon_core::Error,
}

#[rustler::resource_impl]
impl rustler::Resource for SsrSourceErrorResource {}

fn refused(message: String) -> Error {
    Error::Term(Box::new(message))
}

fn unrecognized(what: &str) -> Error {
    refused(format!(
        "float solution ssr_bias_exclusions: {what} is :unrecognized, a core value this binding does not carry"
    ))
}

fn usize_from(value: u64, field: &str) -> NifResult<usize> {
    usize::try_from(value).map_err(|_| refused(format!("{field} {value} does not fit usize")))
}

fn satellite_term(sat: GnssSatelliteId) -> String {
    sat.to_string()
}

fn satellite_from(text: &str, field: &str) -> NifResult<GnssSatelliteId> {
    text.parse::<GnssSatelliteId>()
        .map_err(|_| refused(format!("{field} {text:?} is not a satellite token")))
}

fn system_term(system: GnssSystem) -> String {
    system.letter().to_string()
}

fn system_from(text: &str, field: &str) -> NifResult<GnssSystem> {
    let mut chars = text.chars();
    match (chars.next(), chars.next()) {
        (Some(letter), None) => GnssSystem::from_letter(letter),
        _ => None,
    }
    .ok_or_else(|| refused(format!("{field} {text:?} is not a GNSS system letter")))
}

fn signal_code_from(text: &str, field: &str) -> NifResult<SignalCode> {
    SignalCode::parse(text).ok_or_else(|| {
        refused(format!(
            "{field} {text:?} is not a band and tracking attribute"
        ))
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, NifUnitEnum)]
pub enum SsrSourceTerm {
    RtcmSsr,
    GalileoHas,
    IgsSsr,
}

impl From<SsrSource> for SsrSourceTerm {
    fn from(source: SsrSource) -> Self {
        match source {
            SsrSource::RtcmSsr => Self::RtcmSsr,
            SsrSource::GalileoHas => Self::GalileoHas,
            SsrSource::IgsSsr => Self::IgsSsr,
        }
    }
}

impl From<SsrSourceTerm> for SsrSource {
    fn from(source: SsrSourceTerm) -> Self {
        match source {
            SsrSourceTerm::RtcmSsr => Self::RtcmSsr,
            SsrSourceTerm::GalileoHas => Self::GalileoHas,
            SsrSourceTerm::IgsSsr => Self::IgsSsr,
        }
    }
}

#[derive(Debug, Clone, PartialEq, NifMap)]
pub struct SsrSolutionTerm {
    source: SsrSourceTerm,
    provider_id: u16,
    solution_id: u8,
}

impl From<SsrSolution> for SsrSolutionTerm {
    fn from(solution: SsrSolution) -> Self {
        Self {
            source: solution.source.into(),
            provider_id: solution.provider_id,
            solution_id: solution.solution_id,
        }
    }
}

impl From<SsrSolutionTerm> for SsrSolution {
    fn from(term: SsrSolutionTerm) -> Self {
        Self {
            source: term.source.into(),
            provider_id: term.provider_id,
            solution_id: term.solution_id,
        }
    }
}

/// A physical signal: the system letter and the RINEX 3 band and tracking
/// attribute (`"1C"`).
#[derive(Debug, Clone, PartialEq, NifMap)]
pub struct GnssSignalTerm {
    system: String,
    code: String,
}

impl From<GnssSignal> for GnssSignalTerm {
    fn from(signal: GnssSignal) -> Self {
        Self {
            system: system_term(signal.system()),
            code: signal.code().to_string(),
        }
    }
}

impl GnssSignalTerm {
    fn decode(self) -> NifResult<GnssSignal> {
        Ok(GnssSignal::new(
            system_from(&self.system, "signal system")?,
            signal_code_from(&self.code, "signal code")?,
        ))
    }
}

/// A signal index as its source transmitted it.
#[derive(Debug, Clone, PartialEq, NifMap)]
pub struct SsrRawSignalTerm {
    source: SsrSourceTerm,
    system: String,
    index: u8,
}

impl From<SsrRawSignal> for SsrRawSignalTerm {
    fn from(raw: SsrRawSignal) -> Self {
        Self {
            source: raw.source().into(),
            system: system_term(raw.system()),
            index: raw.index(),
        }
    }
}

impl SsrRawSignalTerm {
    fn decode(self) -> NifResult<SsrRawSignal> {
        Ok(SsrRawSignal::new(
            self.source.into(),
            system_from(&self.system, "raw signal system")?,
            self.index,
        ))
    }
}

#[derive(Debug, Clone, PartialEq, NifTaggedEnum)]
pub enum SsrSignalKeyTerm {
    Physical(GnssSignalTerm),
    Unknown(SsrRawSignalTerm),
}

impl From<SsrSignalKey> for SsrSignalKeyTerm {
    fn from(key: SsrSignalKey) -> Self {
        match key {
            SsrSignalKey::Physical(signal) => Self::Physical(signal.into()),
            SsrSignalKey::Unknown(raw) => Self::Unknown(raw.into()),
        }
    }
}

impl SsrSignalKeyTerm {
    fn decode(self) -> NifResult<SsrSignalKey> {
        Ok(match self {
            Self::Physical(signal) => SsrSignalKey::Physical(signal.decode()?),
            Self::Unknown(raw) => SsrSignalKey::Unknown(raw.decode()?),
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, NifUnitEnum)]
pub enum SsrBiasStatusTerm {
    Available,
    Missing,
    Unavailable,
    NotYetValid,
    Expired,
    Excluded,
    InvalidEpoch,
    PhaseDiscontinuityNeedsReset,
    UnknownSignal,
    Unrecognized,
}

impl From<SsrBiasStatus> for SsrBiasStatusTerm {
    fn from(status: SsrBiasStatus) -> Self {
        match status {
            SsrBiasStatus::Available => Self::Available,
            SsrBiasStatus::Missing => Self::Missing,
            SsrBiasStatus::Unavailable => Self::Unavailable,
            SsrBiasStatus::NotYetValid => Self::NotYetValid,
            SsrBiasStatus::Expired => Self::Expired,
            SsrBiasStatus::Excluded => Self::Excluded,
            SsrBiasStatus::InvalidEpoch => Self::InvalidEpoch,
            SsrBiasStatus::PhaseDiscontinuityNeedsReset => Self::PhaseDiscontinuityNeedsReset,
            SsrBiasStatus::UnknownSignal => Self::UnknownSignal,
            _ => Self::Unrecognized,
        }
    }
}

impl SsrBiasStatusTerm {
    fn decode(self) -> NifResult<SsrBiasStatus> {
        Ok(match self {
            Self::Available => SsrBiasStatus::Available,
            Self::Missing => SsrBiasStatus::Missing,
            Self::Unavailable => SsrBiasStatus::Unavailable,
            Self::NotYetValid => SsrBiasStatus::NotYetValid,
            Self::Expired => SsrBiasStatus::Expired,
            Self::Excluded => SsrBiasStatus::Excluded,
            Self::InvalidEpoch => SsrBiasStatus::InvalidEpoch,
            Self::PhaseDiscontinuityNeedsReset => SsrBiasStatus::PhaseDiscontinuityNeedsReset,
            Self::UnknownSignal => SsrBiasStatus::UnknownSignal,
            Self::Unrecognized => return Err(unrecognized("a bias status")),
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, NifUnitEnum)]
pub enum DegradeReasonTerm {
    BeforeCoverage,
    AfterCoverage,
}

impl From<DegradeReason> for DegradeReasonTerm {
    fn from(reason: DegradeReason) -> Self {
        match reason {
            DegradeReason::BeforeCoverage => Self::BeforeCoverage,
            DegradeReason::AfterCoverage => Self::AfterCoverage,
        }
    }
}

impl From<DegradeReasonTerm> for DegradeReason {
    fn from(reason: DegradeReasonTerm) -> Self {
        match reason {
            DegradeReasonTerm::BeforeCoverage => Self::BeforeCoverage,
            DegradeReasonTerm::AfterCoverage => Self::AfterCoverage,
        }
    }
}

#[derive(Debug, Clone, PartialEq, NifTaggedEnum)]
pub enum SsrIfCombinationStatusTerm {
    Applied,
    OptedOut,
    SignalUnavailable,
    InvalidFrequencies,
    ObservationSignalsUnknown,
    CarrierUnresolved,
    ObservationFrequencyMismatch,
    IncompatibleSourceOrSolution,
    IncompatibleIod,
    OrbitClockSolutionUnavailable,
    OrbitClockSolutionMismatch,
    SatelliteExcluded,
    TransmitTimeUnavailable,
    PhaseDiscontinuityNeedsReset,
    Ut1OutsideCoverage(DegradeReasonTerm),
    Unrecognized,
}

impl From<core::SsrIfCombinationStatus> for SsrIfCombinationStatusTerm {
    fn from(status: core::SsrIfCombinationStatus) -> Self {
        use core::SsrIfCombinationStatus as S;
        match status {
            S::Applied => Self::Applied,
            S::OptedOut => Self::OptedOut,
            S::SignalUnavailable => Self::SignalUnavailable,
            S::InvalidFrequencies => Self::InvalidFrequencies,
            S::ObservationSignalsUnknown => Self::ObservationSignalsUnknown,
            S::CarrierUnresolved => Self::CarrierUnresolved,
            S::ObservationFrequencyMismatch => Self::ObservationFrequencyMismatch,
            S::IncompatibleSourceOrSolution => Self::IncompatibleSourceOrSolution,
            S::IncompatibleIod => Self::IncompatibleIod,
            S::OrbitClockSolutionUnavailable => Self::OrbitClockSolutionUnavailable,
            S::OrbitClockSolutionMismatch => Self::OrbitClockSolutionMismatch,
            S::SatelliteExcluded => Self::SatelliteExcluded,
            S::TransmitTimeUnavailable => Self::TransmitTimeUnavailable,
            S::PhaseDiscontinuityNeedsReset => Self::PhaseDiscontinuityNeedsReset,
            S::Ut1OutsideCoverage(reason) => Self::Ut1OutsideCoverage(reason.into()),
            _ => Self::Unrecognized,
        }
    }
}

impl SsrIfCombinationStatusTerm {
    fn decode(self) -> NifResult<core::SsrIfCombinationStatus> {
        use core::SsrIfCombinationStatus as S;
        Ok(match self {
            Self::Applied => S::Applied,
            Self::OptedOut => S::OptedOut,
            Self::SignalUnavailable => S::SignalUnavailable,
            Self::InvalidFrequencies => S::InvalidFrequencies,
            Self::ObservationSignalsUnknown => S::ObservationSignalsUnknown,
            Self::CarrierUnresolved => S::CarrierUnresolved,
            Self::ObservationFrequencyMismatch => S::ObservationFrequencyMismatch,
            Self::IncompatibleSourceOrSolution => S::IncompatibleSourceOrSolution,
            Self::IncompatibleIod => S::IncompatibleIod,
            Self::OrbitClockSolutionUnavailable => S::OrbitClockSolutionUnavailable,
            Self::OrbitClockSolutionMismatch => S::OrbitClockSolutionMismatch,
            Self::SatelliteExcluded => S::SatelliteExcluded,
            Self::TransmitTimeUnavailable => S::TransmitTimeUnavailable,
            Self::PhaseDiscontinuityNeedsReset => S::PhaseDiscontinuityNeedsReset,
            Self::Ut1OutsideCoverage(reason) => S::Ut1OutsideCoverage(reason.into()),
            Self::Unrecognized => {
                return Err(unrecognized("an ionosphere-free combination status"))
            }
        })
    }
}

#[derive(Debug, Clone, PartialEq, NifTaggedEnum)]
pub enum SsrLifetimeTerm {
    GalileoHasValidityInterval(f64),
    RtcmUpdateInterval(f64),
    Unrecognized,
}

impl From<SsrLifetime> for SsrLifetimeTerm {
    fn from(lifetime: SsrLifetime) -> Self {
        match lifetime {
            SsrLifetime::GalileoHasValidityInterval(s) => Self::GalileoHasValidityInterval(s),
            SsrLifetime::RtcmUpdateInterval(s) => Self::RtcmUpdateInterval(s),
            _ => Self::Unrecognized,
        }
    }
}

impl SsrLifetimeTerm {
    fn decode(self) -> NifResult<SsrLifetime> {
        Ok(match self {
            Self::GalileoHasValidityInterval(s) => SsrLifetime::GalileoHasValidityInterval(s),
            Self::RtcmUpdateInterval(s) => SsrLifetime::RtcmUpdateInterval(s),
            Self::Unrecognized => return Err(unrecognized("a bias lifetime")),
        })
    }
}

#[derive(Debug, Clone, PartialEq, NifTaggedEnum)]
pub enum SsrDiscontinuityDetailsTerm {
    InitialTokenEstablished,
    Continuous,
    HasPdiChanged {
        previous: u8,
        current: u8,
    },
    RtcmDiscontinuityCounterChanged {
        previous: u8,
        current: u8,
    },
    SolutionChanged {
        previous: SsrSolutionTerm,
        current: SsrSolutionTerm,
    },
    StaleToken,
    FutureToken,
    MismatchedToken,
    Unrecognized,
}

impl From<SsrDiscontinuityDetails> for SsrDiscontinuityDetailsTerm {
    fn from(details: SsrDiscontinuityDetails) -> Self {
        use SsrDiscontinuityDetails as D;
        match details {
            D::InitialTokenEstablished => Self::InitialTokenEstablished,
            D::Continuous => Self::Continuous,
            D::HasPdiChanged { previous, current } => Self::HasPdiChanged { previous, current },
            D::RtcmDiscontinuityCounterChanged { previous, current } => {
                Self::RtcmDiscontinuityCounterChanged { previous, current }
            }
            D::SolutionChanged { previous, current } => Self::SolutionChanged {
                previous: previous.into(),
                current: current.into(),
            },
            D::StaleToken => Self::StaleToken,
            D::FutureToken => Self::FutureToken,
            D::MismatchedToken => Self::MismatchedToken,
            _ => Self::Unrecognized,
        }
    }
}

impl SsrDiscontinuityDetailsTerm {
    fn decode(self) -> NifResult<SsrDiscontinuityDetails> {
        use SsrDiscontinuityDetails as D;
        Ok(match self {
            Self::InitialTokenEstablished => D::InitialTokenEstablished,
            Self::Continuous => D::Continuous,
            Self::HasPdiChanged { previous, current } => D::HasPdiChanged { previous, current },
            Self::RtcmDiscontinuityCounterChanged { previous, current } => {
                D::RtcmDiscontinuityCounterChanged { previous, current }
            }
            Self::SolutionChanged { previous, current } => D::SolutionChanged {
                previous: previous.into(),
                current: current.into(),
            },
            Self::StaleToken => D::StaleToken,
            Self::FutureToken => D::FutureToken,
            Self::MismatchedToken => D::MismatchedToken,
            Self::Unrecognized => return Err(unrecognized("a phase discontinuity detail")),
        })
    }
}

#[derive(Debug, Clone, PartialEq, NifTaggedEnum)]
pub enum SsrBiasResolutionDetailsTerm {
    Available,
    NoRecord,
    TransmittedUnavailable,
    ConversionUnavailable,
    EpochBeforeReference {
        ref_epoch_j2000_s: f64,
        query_epoch_j2000_s: f64,
    },
    EpochExpired {
        expiry_epoch_j2000_s: f64,
        query_epoch_j2000_s: f64,
    },
    ExcludedByDoNotUse {
        ref_epoch_j2000_s: f64,
        validity_interval_s: f64,
    },
    InvalidEpoch,
    PhaseDiscontinuity(SsrDiscontinuityDetailsTerm),
    UnknownSignal(SsrRawSignalTerm),
    Unrecognized,
}

impl From<SsrBiasResolutionDetails> for SsrBiasResolutionDetailsTerm {
    fn from(details: SsrBiasResolutionDetails) -> Self {
        use SsrBiasResolutionDetails as D;
        match details {
            D::Available => Self::Available,
            D::NoRecord => Self::NoRecord,
            D::TransmittedUnavailable => Self::TransmittedUnavailable,
            D::ConversionUnavailable => Self::ConversionUnavailable,
            D::EpochBeforeReference {
                ref_epoch_j2000_s,
                query_epoch_j2000_s,
            } => Self::EpochBeforeReference {
                ref_epoch_j2000_s,
                query_epoch_j2000_s,
            },
            D::EpochExpired {
                expiry_epoch_j2000_s,
                query_epoch_j2000_s,
            } => Self::EpochExpired {
                expiry_epoch_j2000_s,
                query_epoch_j2000_s,
            },
            D::ExcludedByDoNotUse {
                ref_epoch_j2000_s,
                validity_interval_s,
            } => Self::ExcludedByDoNotUse {
                ref_epoch_j2000_s,
                validity_interval_s,
            },
            D::InvalidEpoch => Self::InvalidEpoch,
            D::PhaseDiscontinuity(details) => Self::PhaseDiscontinuity(details.into()),
            D::UnknownSignal(raw) => Self::UnknownSignal(raw.into()),
            _ => Self::Unrecognized,
        }
    }
}

impl SsrBiasResolutionDetailsTerm {
    fn decode(self) -> NifResult<SsrBiasResolutionDetails> {
        use SsrBiasResolutionDetails as D;
        Ok(match self {
            Self::Available => D::Available,
            Self::NoRecord => D::NoRecord,
            Self::TransmittedUnavailable => D::TransmittedUnavailable,
            Self::ConversionUnavailable => D::ConversionUnavailable,
            Self::EpochBeforeReference {
                ref_epoch_j2000_s,
                query_epoch_j2000_s,
            } => D::EpochBeforeReference {
                ref_epoch_j2000_s,
                query_epoch_j2000_s,
            },
            Self::EpochExpired {
                expiry_epoch_j2000_s,
                query_epoch_j2000_s,
            } => D::EpochExpired {
                expiry_epoch_j2000_s,
                query_epoch_j2000_s,
            },
            Self::ExcludedByDoNotUse {
                ref_epoch_j2000_s,
                validity_interval_s,
            } => D::ExcludedByDoNotUse {
                ref_epoch_j2000_s,
                validity_interval_s,
            },
            Self::InvalidEpoch => D::InvalidEpoch,
            Self::PhaseDiscontinuity(details) => D::PhaseDiscontinuity(details.decode()?),
            Self::UnknownSignal(raw) => D::UnknownSignal(raw.decode()?),
            Self::Unrecognized => return Err(unrecognized("a bias resolution detail")),
        })
    }
}

#[derive(Debug, Clone, PartialEq, NifTaggedEnum)]
pub enum PhaseDiscontinuityIndicatorTerm {
    GalileoHasPdi(u8),
    RtcmDiscontinuityCounter(u8),
}

impl From<PhaseDiscontinuityIndicator> for PhaseDiscontinuityIndicatorTerm {
    fn from(indicator: PhaseDiscontinuityIndicator) -> Self {
        match indicator {
            PhaseDiscontinuityIndicator::GalileoHasPdi(v) => Self::GalileoHasPdi(v),
            PhaseDiscontinuityIndicator::RtcmDiscontinuityCounter(v) => {
                Self::RtcmDiscontinuityCounter(v)
            }
        }
    }
}

impl From<PhaseDiscontinuityIndicatorTerm> for PhaseDiscontinuityIndicator {
    fn from(indicator: PhaseDiscontinuityIndicatorTerm) -> Self {
        match indicator {
            PhaseDiscontinuityIndicatorTerm::GalileoHasPdi(v) => Self::GalileoHasPdi(v),
            PhaseDiscontinuityIndicatorTerm::RtcmDiscontinuityCounter(v) => {
                Self::RtcmDiscontinuityCounter(v)
            }
        }
    }
}

/// A phase continuity token: its readable fields and the handle holding it.
#[derive(Clone, NifMap)]
pub struct PhaseContinuityTokenTerm {
    satellite: String,
    signal: SsrSignalKeyTerm,
    source: SsrSourceTerm,
    provider_id: u16,
    solution_id: u8,
    continuity_ref_epoch_j2000_s: f64,
    raw_indicator: u8,
    generation: u32,
    handle: ResourceArc<PhaseContinuityTokenResource>,
}

/// The readable fields of a phase continuity token, as its accessors state them.
#[derive(Debug, Clone, PartialEq)]
pub struct PhaseContinuityTokenView {
    satellite: String,
    signal: SsrSignalKeyTerm,
    source: SsrSourceTerm,
    provider_id: u16,
    solution_id: u8,
    continuity_ref_epoch_bits: u64,
    raw_indicator: u8,
    generation: u32,
}

impl PhaseContinuityTokenView {
    pub fn of(token: &PhaseContinuityToken) -> Self {
        Self {
            satellite: satellite_term(token.satellite()),
            signal: token.signal().into(),
            source: token.source().into(),
            provider_id: token.provider_id(),
            solution_id: token.solution_id(),
            continuity_ref_epoch_bits: token.continuity_ref_epoch_j2000_s().to_bits(),
            raw_indicator: token.raw_indicator(),
            generation: token.generation(),
        }
    }
}

impl From<PhaseContinuityToken> for PhaseContinuityTokenTerm {
    fn from(token: PhaseContinuityToken) -> Self {
        let view = PhaseContinuityTokenView::of(&token);
        Self {
            satellite: view.satellite,
            signal: view.signal,
            source: view.source,
            provider_id: view.provider_id,
            solution_id: view.solution_id,
            continuity_ref_epoch_j2000_s: f64::from_bits(view.continuity_ref_epoch_bits),
            raw_indicator: view.raw_indicator,
            generation: view.generation,
            handle: ResourceArc::new(PhaseContinuityTokenResource { token }),
        }
    }
}

impl PhaseContinuityTokenTerm {
    fn view(&self) -> PhaseContinuityTokenView {
        PhaseContinuityTokenView {
            satellite: self.satellite.clone(),
            signal: self.signal.clone(),
            source: self.source,
            provider_id: self.provider_id,
            solution_id: self.solution_id,
            continuity_ref_epoch_bits: self.continuity_ref_epoch_j2000_s.to_bits(),
            raw_indicator: self.raw_indicator,
            generation: self.generation,
        }
    }

    fn decode(self) -> NifResult<PhaseContinuityToken> {
        token_from_parts(&self.view(), self.handle.token)
    }
}

/// The token a handle holds, provided the readable fields beside it are the
/// token's own. The core offers no constructor, so the handle is the only
/// source of the token, and a view edited away from it is refused.
pub fn token_from_parts(
    view: &PhaseContinuityTokenView,
    token: PhaseContinuityToken,
) -> NifResult<PhaseContinuityToken> {
    if PhaseContinuityTokenView::of(&token) == *view {
        Ok(token)
    } else {
        Err(refused(
            "phase continuity token fields differ from the token its handle holds".to_string(),
        ))
    }
}

/// A core error an ephemeris source returned: its text and the handle holding it.
#[derive(Clone, NifMap)]
pub struct SourceErrorTerm {
    message: String,
    handle: ResourceArc<SsrSourceErrorResource>,
}

impl From<sidereon_core::Error> for SourceErrorTerm {
    fn from(error: sidereon_core::Error) -> Self {
        Self {
            message: error.to_string(),
            handle: ResourceArc::new(SsrSourceErrorResource { error }),
        }
    }
}

/// The error a handle holds, provided the text beside it is that error's own.
pub fn error_from_parts(
    message: &str,
    error: &sidereon_core::Error,
) -> NifResult<sidereon_core::Error> {
    if error.to_string() == message {
        Ok(error.clone())
    } else {
        Err(refused(
            "source error message differs from the error its handle holds".to_string(),
        ))
    }
}

impl SourceErrorTerm {
    fn decode(self) -> NifResult<sidereon_core::Error> {
        error_from_parts(&self.message, &self.handle.error)
    }
}

#[derive(Clone, NifMap)]
pub struct CodeBiasQueryTerm {
    sat: String,
    signal: SsrSignalKeyTerm,
    source_signal: Option<SsrRawSignalTerm>,
    status: SsrBiasStatusTerm,
    bias_m: Option<f64>,
    solution: Option<SsrSolutionTerm>,
    iod_ssr: Option<u8>,
    ref_epoch_j2000_s: Option<f64>,
    lifetime: Option<SsrLifetimeTerm>,
    details: SsrBiasResolutionDetailsTerm,
}

impl From<SsrCodeBiasQueryResult> for CodeBiasQueryTerm {
    fn from(q: SsrCodeBiasQueryResult) -> Self {
        Self {
            sat: satellite_term(q.sat),
            signal: q.signal.into(),
            source_signal: q.source_signal.map(Into::into),
            status: q.status.into(),
            bias_m: q.bias_m,
            solution: q.solution.map(Into::into),
            iod_ssr: q.iod_ssr,
            ref_epoch_j2000_s: q.ref_epoch_j2000_s,
            lifetime: q.lifetime.map(Into::into),
            details: q.details.into(),
        }
    }
}

impl CodeBiasQueryTerm {
    fn decode(self) -> NifResult<SsrCodeBiasQueryResult> {
        Ok(SsrCodeBiasQueryResult {
            sat: satellite_from(&self.sat, "code bias query sat")?,
            signal: self.signal.decode()?,
            source_signal: self
                .source_signal
                .map(SsrRawSignalTerm::decode)
                .transpose()?,
            status: self.status.decode()?,
            bias_m: self.bias_m,
            solution: self.solution.map(Into::into),
            iod_ssr: self.iod_ssr,
            ref_epoch_j2000_s: self.ref_epoch_j2000_s,
            lifetime: self.lifetime.map(SsrLifetimeTerm::decode).transpose()?,
            details: self.details.decode()?,
        })
    }
}

#[derive(Clone, NifMap)]
pub struct PhaseBiasQueryTerm {
    sat: String,
    signal: SsrSignalKeyTerm,
    source_signal: Option<SsrRawSignalTerm>,
    status: SsrBiasStatusTerm,
    bias_m: Option<f64>,
    bias_cycles: Option<f64>,
    solution: Option<SsrSolutionTerm>,
    iod_ssr: Option<u8>,
    ref_epoch_j2000_s: Option<f64>,
    lifetime: Option<SsrLifetimeTerm>,
    continuity_token: Option<PhaseContinuityTokenTerm>,
    discontinuity_indicator: Option<PhaseDiscontinuityIndicatorTerm>,
    discontinuity_details: Option<SsrDiscontinuityDetailsTerm>,
    details: SsrBiasResolutionDetailsTerm,
}

impl From<SsrPhaseBiasQueryResult> for PhaseBiasQueryTerm {
    fn from(q: SsrPhaseBiasQueryResult) -> Self {
        Self {
            sat: satellite_term(q.sat),
            signal: q.signal.into(),
            source_signal: q.source_signal.map(Into::into),
            status: q.status.into(),
            bias_m: q.bias_m,
            bias_cycles: q.bias_cycles,
            solution: q.solution.map(Into::into),
            iod_ssr: q.iod_ssr,
            ref_epoch_j2000_s: q.ref_epoch_j2000_s,
            lifetime: q.lifetime.map(Into::into),
            continuity_token: q.continuity_token.map(Into::into),
            discontinuity_indicator: q.discontinuity_indicator.map(Into::into),
            discontinuity_details: q.discontinuity_details.map(Into::into),
            details: q.details.into(),
        }
    }
}

impl PhaseBiasQueryTerm {
    fn decode(self) -> NifResult<SsrPhaseBiasQueryResult> {
        Ok(SsrPhaseBiasQueryResult {
            sat: satellite_from(&self.sat, "phase bias query sat")?,
            signal: self.signal.decode()?,
            source_signal: self
                .source_signal
                .map(SsrRawSignalTerm::decode)
                .transpose()?,
            status: self.status.decode()?,
            bias_m: self.bias_m,
            bias_cycles: self.bias_cycles,
            solution: self.solution.map(Into::into),
            iod_ssr: self.iod_ssr,
            ref_epoch_j2000_s: self.ref_epoch_j2000_s,
            lifetime: self.lifetime.map(SsrLifetimeTerm::decode).transpose()?,
            continuity_token: self
                .continuity_token
                .map(PhaseContinuityTokenTerm::decode)
                .transpose()?,
            discontinuity_indicator: self.discontinuity_indicator.map(Into::into),
            discontinuity_details: self
                .discontinuity_details
                .map(SsrDiscontinuityDetailsTerm::decode)
                .transpose()?,
            details: self.details.decode()?,
        })
    }
}

#[derive(Clone, NifMap)]
pub struct CodeSignalReportTerm {
    epoch_index: u64,
    sat: String,
    ambiguity_id: String,
    signal: GnssSignalTerm,
    query_result: CodeBiasQueryTerm,
}

impl From<core::SsrObsSignalReport<SsrCodeBiasQueryResult>> for CodeSignalReportTerm {
    fn from(r: core::SsrObsSignalReport<SsrCodeBiasQueryResult>) -> Self {
        Self {
            epoch_index: r.epoch_index as u64,
            sat: satellite_term(r.sat),
            ambiguity_id: r.ambiguity_id,
            signal: r.signal.into(),
            query_result: r.query_result.into(),
        }
    }
}

impl CodeSignalReportTerm {
    fn decode(self) -> NifResult<core::SsrObsSignalReport<SsrCodeBiasQueryResult>> {
        Ok(core::SsrObsSignalReport {
            epoch_index: usize_from(self.epoch_index, "signal report epoch_index")?,
            sat: satellite_from(&self.sat, "signal report sat")?,
            ambiguity_id: self.ambiguity_id,
            signal: self.signal.decode()?,
            query_result: self.query_result.decode()?,
        })
    }
}

#[derive(Clone, NifMap)]
pub struct PhaseSignalReportTerm {
    epoch_index: u64,
    sat: String,
    ambiguity_id: String,
    signal: GnssSignalTerm,
    query_result: PhaseBiasQueryTerm,
}

impl From<core::SsrObsSignalReport<SsrPhaseBiasQueryResult>> for PhaseSignalReportTerm {
    fn from(r: core::SsrObsSignalReport<SsrPhaseBiasQueryResult>) -> Self {
        Self {
            epoch_index: r.epoch_index as u64,
            sat: satellite_term(r.sat),
            ambiguity_id: r.ambiguity_id,
            signal: r.signal.into(),
            query_result: r.query_result.into(),
        }
    }
}

impl PhaseSignalReportTerm {
    fn decode(self) -> NifResult<core::SsrObsSignalReport<SsrPhaseBiasQueryResult>> {
        Ok(core::SsrObsSignalReport {
            epoch_index: usize_from(self.epoch_index, "signal report epoch_index")?,
            sat: satellite_from(&self.sat, "signal report sat")?,
            ambiguity_id: self.ambiguity_id,
            signal: self.signal.decode()?,
            query_result: self.query_result.decode()?,
        })
    }
}

/// The tracking codes of an observation's two pseudoranges and two carrier
/// phases, each a band and attribute (`"1C"`).
#[derive(Debug, Clone, PartialEq, NifMap)]
pub struct ObservationSignalsTerm {
    code1: String,
    code2: String,
    phase1: String,
    phase2: String,
}

impl From<core::FloatObservationSignals> for ObservationSignalsTerm {
    fn from(s: core::FloatObservationSignals) -> Self {
        Self {
            code1: s.code1.to_string(),
            code2: s.code2.to_string(),
            phase1: s.phase1.to_string(),
            phase2: s.phase2.to_string(),
        }
    }
}

impl ObservationSignalsTerm {
    fn decode(self) -> NifResult<core::FloatObservationSignals> {
        Ok(core::FloatObservationSignals {
            code1: signal_code_from(&self.code1, "observation signal code1")?,
            code2: signal_code_from(&self.code2, "observation signal code2")?,
            phase1: signal_code_from(&self.phase1, "observation signal phase1")?,
            phase2: signal_code_from(&self.phase2, "observation signal phase2")?,
        })
    }
}

#[derive(Clone, NifMap)]
pub struct ApplicationReportTerm {
    epoch_index: u64,
    sat: String,
    satellite_id: String,
    ambiguity_id: String,
    transmit_time_j2000_s: Option<f64>,
    applied_orbit_clock_solution: Option<SsrSolutionTerm>,
    observation_signals: Option<ObservationSignalsTerm>,
    code_status: SsrIfCombinationStatusTerm,
    applied_code_if_m: Option<f64>,
    code1_report: Option<CodeSignalReportTerm>,
    code2_report: Option<CodeSignalReportTerm>,
    phase_status: SsrIfCombinationStatusTerm,
    applied_phase_if_m: Option<f64>,
    phase1_report: Option<PhaseSignalReportTerm>,
    phase2_report: Option<PhaseSignalReportTerm>,
}

impl From<core::SsrObsApplicationReport> for ApplicationReportTerm {
    fn from(r: core::SsrObsApplicationReport) -> Self {
        Self {
            epoch_index: r.epoch_index as u64,
            sat: satellite_term(r.sat),
            satellite_id: r.satellite_id,
            ambiguity_id: r.ambiguity_id,
            transmit_time_j2000_s: r.transmit_time_j2000_s,
            applied_orbit_clock_solution: r.applied_orbit_clock_solution.map(Into::into),
            observation_signals: r.observation_signals.map(Into::into),
            code_status: r.code_status.into(),
            applied_code_if_m: r.applied_code_if_m,
            code1_report: r.code1_report.map(Into::into),
            code2_report: r.code2_report.map(Into::into),
            phase_status: r.phase_status.into(),
            applied_phase_if_m: r.applied_phase_if_m,
            phase1_report: r.phase1_report.map(Into::into),
            phase2_report: r.phase2_report.map(Into::into),
        }
    }
}

impl ApplicationReportTerm {
    fn decode(self) -> NifResult<core::SsrObsApplicationReport> {
        Ok(core::SsrObsApplicationReport {
            epoch_index: usize_from(self.epoch_index, "application epoch_index")?,
            sat: satellite_from(&self.sat, "application sat")?,
            satellite_id: self.satellite_id,
            ambiguity_id: self.ambiguity_id,
            transmit_time_j2000_s: self.transmit_time_j2000_s,
            applied_orbit_clock_solution: self.applied_orbit_clock_solution.map(Into::into),
            observation_signals: self
                .observation_signals
                .map(ObservationSignalsTerm::decode)
                .transpose()?,
            code_status: self.code_status.decode()?,
            applied_code_if_m: self.applied_code_if_m,
            code1_report: self
                .code1_report
                .map(CodeSignalReportTerm::decode)
                .transpose()?,
            code2_report: self
                .code2_report
                .map(CodeSignalReportTerm::decode)
                .transpose()?,
            phase_status: self.phase_status.decode()?,
            applied_phase_if_m: self.applied_phase_if_m,
            phase1_report: self
                .phase1_report
                .map(PhaseSignalReportTerm::decode)
                .transpose()?,
            phase2_report: self
                .phase2_report
                .map(PhaseSignalReportTerm::decode)
                .transpose()?,
        })
    }
}

#[derive(Clone, NifTaggedEnum)]
pub enum TransmitTimeFailureTerm {
    SourceWithoutSsrCorrections,
    TransmitTimeUnavailable,
    OrbitClockSolution {
        transmit_time_j2000_s: f64,
        applied: Option<SsrSolutionTerm>,
    },
    BiasRecord {
        transmit_time_j2000_s: f64,
        signal: SsrSignalKeyTerm,
        status: SsrBiasStatusTerm,
    },
    Source {
        transmit_time_j2000_s: f64,
        error: SourceErrorTerm,
    },
    Unrecognized,
}

impl From<core::SsrTransmitTimeFailure> for TransmitTimeFailureTerm {
    fn from(failure: core::SsrTransmitTimeFailure) -> Self {
        use core::SsrTransmitTimeFailure as F;
        match failure {
            F::SourceWithoutSsrCorrections => Self::SourceWithoutSsrCorrections,
            F::TransmitTimeUnavailable => Self::TransmitTimeUnavailable,
            F::OrbitClockSolution {
                transmit_time_j2000_s,
                applied,
            } => Self::OrbitClockSolution {
                transmit_time_j2000_s,
                applied: applied.map(Into::into),
            },
            F::BiasRecord {
                transmit_time_j2000_s,
                signal,
                status,
            } => Self::BiasRecord {
                transmit_time_j2000_s,
                signal: signal.into(),
                status: status.into(),
            },
            F::Source {
                transmit_time_j2000_s,
                error,
            } => Self::Source {
                transmit_time_j2000_s,
                error: error.into(),
            },
            _ => Self::Unrecognized,
        }
    }
}

impl TransmitTimeFailureTerm {
    fn decode(self) -> NifResult<core::SsrTransmitTimeFailure> {
        use core::SsrTransmitTimeFailure as F;
        Ok(match self {
            Self::SourceWithoutSsrCorrections => F::SourceWithoutSsrCorrections,
            Self::TransmitTimeUnavailable => F::TransmitTimeUnavailable,
            Self::OrbitClockSolution {
                transmit_time_j2000_s,
                applied,
            } => F::OrbitClockSolution {
                transmit_time_j2000_s,
                applied: applied.map(Into::into),
            },
            Self::BiasRecord {
                transmit_time_j2000_s,
                signal,
                status,
            } => F::BiasRecord {
                transmit_time_j2000_s,
                signal: signal.decode()?,
                status: status.decode()?,
            },
            Self::Source {
                transmit_time_j2000_s,
                error,
            } => F::Source {
                transmit_time_j2000_s,
                error: error.decode()?,
            },
            Self::Unrecognized => return Err(unrecognized("a transmit-time failure")),
        })
    }
}

/// One observation a float or fixed solve left out because an SSR/HAS bias it
/// requires was not resolved, with every field of the core record.
#[derive(Clone, NifMap)]
pub struct SsrBiasExclusionTerm {
    epoch_index: u64,
    satellite_id: String,
    ambiguity_id: String,
    code_bias_missing: bool,
    phase_bias_missing: bool,
    transmit_time_failure: Option<TransmitTimeFailureTerm>,
    application: Option<ApplicationReportTerm>,
}

impl From<core::SsrBiasExclusion> for SsrBiasExclusionTerm {
    fn from(e: core::SsrBiasExclusion) -> Self {
        Self {
            epoch_index: e.epoch_index as u64,
            satellite_id: e.satellite_id,
            ambiguity_id: e.ambiguity_id,
            code_bias_missing: e.code_bias_missing,
            phase_bias_missing: e.phase_bias_missing,
            transmit_time_failure: e.transmit_time_failure.map(Into::into),
            application: e.application.map(Into::into),
        }
    }
}

impl SsrBiasExclusionTerm {
    pub fn decode(self) -> NifResult<core::SsrBiasExclusion> {
        Ok(core::SsrBiasExclusion {
            epoch_index: usize_from(self.epoch_index, "ssr_bias_exclusions epoch_index")?,
            satellite_id: self.satellite_id,
            ambiguity_id: self.ambiguity_id,
            code_bias_missing: self.code_bias_missing,
            phase_bias_missing: self.phase_bias_missing,
            transmit_time_failure: self
                .transmit_time_failure
                .map(TransmitTimeFailureTerm::decode)
                .transpose()?,
            application: self
                .application
                .map(ApplicationReportTerm::decode)
                .transpose()?,
        })
    }
}

pub fn encode_ssr_bias_exclusions(
    exclusions: &[core::SsrBiasExclusion],
) -> Vec<SsrBiasExclusionTerm> {
    exclusions.iter().cloned().map(Into::into).collect()
}

pub fn decode_ssr_bias_exclusions(
    terms: Vec<SsrBiasExclusionTerm>,
) -> NifResult<Vec<core::SsrBiasExclusion>> {
    terms
        .into_iter()
        .map(SsrBiasExclusionTerm::decode)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn solution(provider_id: u16, solution_id: u8) -> SsrSolution {
        SsrSolution {
            source: SsrSource::RtcmSsr,
            provider_id,
            solution_id,
        }
    }

    fn l1c() -> GnssSignal {
        GnssSignal::new(GnssSystem::Gps, SignalCode::new('1', 'C').unwrap())
    }

    fn code_report() -> core::SsrObsSignalReport<SsrCodeBiasQueryResult> {
        core::SsrObsSignalReport {
            epoch_index: 3,
            sat: "G07".parse().unwrap(),
            ambiguity_id: "G07#1".to_string(),
            signal: l1c(),
            query_result: SsrCodeBiasQueryResult {
                sat: "G07".parse().unwrap(),
                signal: SsrSignalKey::Physical(l1c()),
                source_signal: Some(SsrRawSignal::rtcm_ssr(GnssSystem::Gps, 0)),
                status: SsrBiasStatus::Expired,
                bias_m: Some(-1.25),
                solution: Some(solution(7, 2)),
                iod_ssr: Some(4),
                ref_epoch_j2000_s: Some(646_229_000.5),
                lifetime: Some(SsrLifetime::RtcmUpdateInterval(5.0)),
                details: SsrBiasResolutionDetails::EpochExpired {
                    expiry_epoch_j2000_s: 646_229_090.5,
                    query_epoch_j2000_s: 646_229_100.25,
                },
            },
        }
    }

    fn phase_report() -> core::SsrObsSignalReport<SsrPhaseBiasQueryResult> {
        core::SsrObsSignalReport {
            epoch_index: 3,
            sat: "G07".parse().unwrap(),
            ambiguity_id: "G07#1".to_string(),
            signal: l1c(),
            query_result: SsrPhaseBiasQueryResult {
                sat: "G07".parse().unwrap(),
                signal: SsrSignalKey::Unknown(SsrRawSignal::galileo_has(GnssSystem::Gps, 13)),
                source_signal: Some(SsrRawSignal::galileo_has(GnssSystem::Gps, 13)),
                status: SsrBiasStatus::UnknownSignal,
                bias_m: Some(0.03),
                bias_cycles: Some(0.125),
                solution: Some(SsrSolution {
                    source: SsrSource::GalileoHas,
                    provider_id: 0,
                    solution_id: 0,
                }),
                iod_ssr: None,
                ref_epoch_j2000_s: Some(646_229_000.0),
                lifetime: Some(SsrLifetime::GalileoHasValidityInterval(300.0)),
                continuity_token: None,
                discontinuity_indicator: Some(PhaseDiscontinuityIndicator::GalileoHasPdi(2)),
                discontinuity_details: Some(SsrDiscontinuityDetails::SolutionChanged {
                    previous: solution(1, 1),
                    current: solution(1, 2),
                }),
                details: SsrBiasResolutionDetails::UnknownSignal(SsrRawSignal::galileo_has(
                    GnssSystem::Gps,
                    13,
                )),
            },
        }
    }

    fn exclusion(failure: Option<core::SsrTransmitTimeFailure>) -> core::SsrBiasExclusion {
        core::SsrBiasExclusion {
            epoch_index: 3,
            satellite_id: "G07".to_string(),
            ambiguity_id: "G07#1".to_string(),
            code_bias_missing: true,
            phase_bias_missing: false,
            transmit_time_failure: failure,
            application: Some(core::SsrObsApplicationReport {
                epoch_index: 3,
                sat: "G07".parse().unwrap(),
                satellite_id: "G07".to_string(),
                ambiguity_id: "G07#1".to_string(),
                transmit_time_j2000_s: Some(646_229_099.925),
                applied_orbit_clock_solution: Some(solution(7, 2)),
                observation_signals: Some(core::FloatObservationSignals {
                    code1: SignalCode::new('1', 'C').unwrap(),
                    code2: SignalCode::new('2', 'W').unwrap(),
                    phase1: SignalCode::new('1', 'C').unwrap(),
                    phase2: SignalCode::new('2', 'W').unwrap(),
                }),
                code_status: core::SsrIfCombinationStatus::Ut1OutsideCoverage(
                    DegradeReason::AfterCoverage,
                ),
                applied_code_if_m: None,
                code1_report: Some(code_report()),
                code2_report: None,
                phase_status: core::SsrIfCombinationStatus::OrbitClockSolutionMismatch,
                applied_phase_if_m: Some(0.5),
                phase1_report: Some(phase_report()),
                phase2_report: None,
            }),
        }
    }

    // Every nested type goes out and comes back unchanged. Tokens and source
    // errors travel through resource handles, which need a loaded NIF, so they
    // are checked by `token_from_parts` and `error_from_parts` below instead.
    #[test]
    fn exclusion_round_trips_every_field() {
        let failures = [
            None,
            Some(core::SsrTransmitTimeFailure::SourceWithoutSsrCorrections),
            Some(core::SsrTransmitTimeFailure::TransmitTimeUnavailable),
            Some(core::SsrTransmitTimeFailure::OrbitClockSolution {
                transmit_time_j2000_s: 646_229_099.925,
                applied: Some(solution(9, 1)),
            }),
            Some(core::SsrTransmitTimeFailure::BiasRecord {
                transmit_time_j2000_s: 646_229_099.925,
                signal: SsrSignalKey::Physical(l1c()),
                status: SsrBiasStatus::Available,
            }),
        ];
        for failure in failures {
            let original = exclusion(failure);
            let term: SsrBiasExclusionTerm = original.clone().into();
            assert_eq!(term.decode().unwrap(), original);
        }
    }

    #[test]
    fn unrecognized_values_are_refused_on_the_way_back() {
        assert!(SsrBiasStatusTerm::Unrecognized.decode().is_err());
        assert!(SsrIfCombinationStatusTerm::Unrecognized.decode().is_err());
        assert!(SsrLifetimeTerm::Unrecognized.decode().is_err());
        assert!(SsrDiscontinuityDetailsTerm::Unrecognized.decode().is_err());
        assert!(SsrBiasResolutionDetailsTerm::Unrecognized.decode().is_err());
        assert!(TransmitTimeFailureTerm::Unrecognized.decode().is_err());
    }

    #[test]
    fn a_source_error_comes_back_only_with_its_own_text() {
        let error = sidereon_core::Error::InvalidInput("no orbit".to_string());
        assert_eq!(error_from_parts(&error.to_string(), &error).unwrap(), error);
        assert!(error_from_parts("edited", &error).is_err());
    }
}
