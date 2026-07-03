//! Rustler boundary for RINEX observation QC, lint, and repair.
//!
//! The binding only marshals parsed observation handles or text buffers into
//! core QC and repair entry points, then encodes the resulting reports.

use rustler::{Encoder, Env, ResourceArc, Term};
use sidereon_core::observation_qc::{
    observation_qc_with_options, IntervalSource, ObservationDataGap, ObservationQcNote,
    ObservationQcOptions, ObservationQcReport, SatelliteObservationQc, SatelliteSignalQc, SnrStats,
    SsiHistogram, SystemSignalQc,
};
use sidereon_core::rinex::nav::encode_nav;
use sidereon_core::rinex::observations::{ObsEpochTime, PgmRunByDate};
use sidereon_core::rinex::qc::{
    lint_nav_text, lint_obs, lint_obs_text, repair_nav_text, repair_obs_text,
    repair_obs_to_crinex_string, FindingRef, LintReport, RepairAction, RepairOptions, Severity,
};
use sidereon_core::GnssSystem;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_interval,
        invalid_gap_factor
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SsiHistogramTerm {
    counts: Vec<i64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SnrStatsTerm {
    n: i64,
    mean: f64,
    min: f64,
    max: f64,
    std: Option<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct DataGapTerm {
    start_epoch: ((i32, i64, i64), (i64, i64, f64)),
    end_epoch: ((i32, i64, i64), (i64, i64, f64)),
    nominal_interval_s: f64,
    observed_delta_s: f64,
    missing_epochs: i64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SatelliteQcTerm {
    satellite: String,
    epochs_with_observations: i64,
    value_observations: i64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SatelliteSignalQcTerm {
    satellite: String,
    code: String,
    value_observations: i64,
    ssi: Option<SsiHistogramTerm>,
    snr: Option<SnrStatsTerm>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SystemSignalQcTerm {
    system: String,
    code: String,
    value_observations: i64,
    ssi: Option<SsiHistogramTerm>,
    snr: Option<SnrStatsTerm>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ObservationNoteTerm {
    kind: String,
    epoch_index: Option<i64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ObservationReportTerm {
    total_epoch_records: i64,
    observation_epochs: i64,
    event_records: i64,
    power_failure_epochs: i64,
    skipped_records: i64,
    interval_s: Option<f64>,
    interval_source: String,
    missing_epochs: i64,
    data_gaps: Vec<DataGapTerm>,
    satellites: Vec<SatelliteQcTerm>,
    satellite_signals: Vec<SatelliteSignalQcTerm>,
    system_signals: Vec<SystemSignalQcTerm>,
    notes: Vec<ObservationNoteTerm>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct FindingRefTerm {
    epoch_index: Option<i64>,
    satellite: Option<String>,
    field: Option<String>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct FindingTerm {
    code: String,
    severity: String,
    spec_ref: String,
    repairable: bool,
    at: FindingRefTerm,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SeverityCountsTerm {
    fatal: i64,
    error: i64,
    warning: i64,
    info: i64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct LintReportTerm {
    clean: bool,
    decoded_from_crinex: bool,
    counts: SeverityCountsTerm,
    findings: Vec<FindingTerm>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct PgmRunByDateTerm {
    program: String,
    run_by: String,
    date: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct RepairOptionsTerm {
    file_stamp: Option<PgmRunByDateTerm>,
    set_interval: bool,
    set_time_of_last_obs: bool,
    set_obs_counts: bool,
    drop_empty_records: bool,
    sort_records: bool,
    drop_unsupported: bool,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct RepairActionTerm {
    id: String,
    message: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct IonoTupleTerm {
    gps: Option<(Vec<f64>, Vec<f64>)>,
    beidou: Option<(Vec<f64>, Vec<f64>)>,
    galileo: Option<Vec<f64>>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ObsRepairTerm {
    rinex: String,
    crinex: String,
    actions: Vec<RepairActionTerm>,
    remaining: LintReportTerm,
    decoded_from_crinex: bool,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct NavRepairTerm {
    rinex: String,
    actions: Vec<RepairActionTerm>,
    remaining: LintReportTerm,
    iono: IonoTupleTerm,
    leap_seconds: Option<f64>,
}

fn epoch_term(epoch: ObsEpochTime) -> ((i32, i64, i64), (i64, i64, f64)) {
    (
        (epoch.year, i64::from(epoch.month), i64::from(epoch.day)),
        (i64::from(epoch.hour), i64::from(epoch.minute), epoch.second),
    )
}

fn interval_source_label(source: IntervalSource) -> String {
    match source {
        IntervalSource::Override => "override",
        IntervalSource::Header => "header",
        IntervalSource::Inferred => "inferred",
        IntervalSource::Unresolved => "unresolved",
    }
    .to_string()
}

fn note_term(note: ObservationQcNote) -> ObservationNoteTerm {
    match note {
        ObservationQcNote::NonMonotonicEpoch { epoch_index } => ObservationNoteTerm {
            kind: "non_monotonic_epoch".to_string(),
            epoch_index: Some(epoch_index as i64),
        },
        ObservationQcNote::IntervalUnresolved => ObservationNoteTerm {
            kind: "interval_unresolved".to_string(),
            epoch_index: None,
        },
    }
}

fn ssi_term(ssi: SsiHistogram) -> SsiHistogramTerm {
    SsiHistogramTerm {
        counts: ssi.counts.iter().map(|&value| value as i64).collect(),
    }
}

fn snr_term(snr: SnrStats) -> SnrStatsTerm {
    SnrStatsTerm {
        n: snr.n as i64,
        mean: snr.mean,
        min: snr.min,
        max: snr.max,
        std: snr.std,
    }
}

fn data_gap_term(gap: ObservationDataGap) -> DataGapTerm {
    DataGapTerm {
        start_epoch: epoch_term(gap.start_epoch),
        end_epoch: epoch_term(gap.end_epoch),
        nominal_interval_s: gap.nominal_interval_s,
        observed_delta_s: gap.observed_delta_s,
        missing_epochs: gap.missing_epochs as i64,
    }
}

fn satellite_qc_term(row: SatelliteObservationQc) -> SatelliteQcTerm {
    SatelliteQcTerm {
        satellite: row.satellite.to_string(),
        epochs_with_observations: row.epochs_with_observations as i64,
        value_observations: row.value_observations as i64,
    }
}

fn satellite_signal_qc_term(row: SatelliteSignalQc) -> SatelliteSignalQcTerm {
    SatelliteSignalQcTerm {
        satellite: row.satellite.to_string(),
        code: row.code,
        value_observations: row.value_observations as i64,
        ssi: row.ssi.map(ssi_term),
        snr: row.snr.map(snr_term),
    }
}

fn system_letter(system: GnssSystem) -> String {
    system.letter().to_string()
}

fn system_signal_qc_term(row: SystemSignalQc) -> SystemSignalQcTerm {
    SystemSignalQcTerm {
        system: system_letter(row.system),
        code: row.code,
        value_observations: row.value_observations as i64,
        ssi: row.ssi.map(ssi_term),
        snr: row.snr.map(snr_term),
    }
}

fn observation_report_term(report: ObservationQcReport) -> ObservationReportTerm {
    ObservationReportTerm {
        total_epoch_records: report.total_epoch_records as i64,
        observation_epochs: report.observation_epochs as i64,
        event_records: report.event_records as i64,
        power_failure_epochs: report.power_failure_epochs as i64,
        skipped_records: report.skipped_records as i64,
        interval_s: report.interval_s,
        interval_source: interval_source_label(report.interval_source),
        missing_epochs: report.missing_epochs as i64,
        data_gaps: report.data_gaps.into_iter().map(data_gap_term).collect(),
        satellites: report
            .satellites
            .into_iter()
            .map(satellite_qc_term)
            .collect(),
        satellite_signals: report
            .satellite_signals
            .into_iter()
            .map(satellite_signal_qc_term)
            .collect(),
        system_signals: report
            .system_signals
            .into_iter()
            .map(system_signal_qc_term)
            .collect(),
        notes: report.notes.into_iter().map(note_term).collect(),
    }
}

fn severity_label(severity: Severity) -> String {
    match severity {
        Severity::Fatal => "fatal",
        Severity::Error => "error",
        Severity::Warning => "warning",
        Severity::Info => "info",
    }
    .to_string()
}

fn finding_ref_term(at: &FindingRef) -> FindingRefTerm {
    FindingRefTerm {
        epoch_index: at.epoch_index.map(|value| value as i64),
        satellite: at.satellite.clone(),
        field: at.field.map(str::to_string),
    }
}

fn lint_report_term(report: LintReport) -> LintReportTerm {
    LintReportTerm {
        clean: report.is_clean(),
        decoded_from_crinex: report.decoded_from_crinex,
        counts: SeverityCountsTerm {
            fatal: report.count(Severity::Fatal) as i64,
            error: report.count(Severity::Error) as i64,
            warning: report.count(Severity::Warning) as i64,
            info: report.count(Severity::Info) as i64,
        },
        findings: report
            .findings
            .iter()
            .map(|finding| FindingTerm {
                code: finding.code().to_string(),
                severity: severity_label(finding.severity()),
                spec_ref: finding.spec_ref().to_string(),
                repairable: finding.is_repairable(),
                at: finding_ref_term(finding.at()),
            })
            .collect(),
    }
}

fn repair_options(term: RepairOptionsTerm) -> RepairOptions {
    RepairOptions {
        file_stamp: term.file_stamp.map(|stamp| PgmRunByDate {
            program: stamp.program,
            run_by: stamp.run_by,
            date: stamp.date,
        }),
        set_interval: term.set_interval,
        set_time_of_last_obs: term.set_time_of_last_obs,
        set_obs_counts: term.set_obs_counts,
        drop_empty_records: term.drop_empty_records,
        sort_records: term.sort_records,
        drop_unsupported: term.drop_unsupported,
    }
}

fn action_terms(actions: Vec<RepairAction>) -> Vec<RepairActionTerm> {
    actions
        .into_iter()
        .map(|action| RepairActionTerm {
            id: action.id.to_string(),
            message: action.message,
        })
        .collect()
}

fn iono_term(iono: Option<sidereon_core::rinex::nav::IonoCorrections>) -> IonoTupleTerm {
    let Some(iono) = iono else {
        return IonoTupleTerm {
            gps: None,
            beidou: None,
            galileo: None,
        };
    };
    let coeffs = |value: sidereon_core::rinex::nav::KlobucharAlphaBeta| {
        (value.alpha.to_vec(), value.beta.to_vec())
    };
    IonoTupleTerm {
        gps: iono.gps.map(coeffs),
        beidou: iono.beidou.map(coeffs),
        galileo: iono
            .galileo
            .map(|values| vec![values.ai0, values.ai1, values.ai2]),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_obs_observation_qc<'a>(
    env: Env<'a>,
    handle: ResourceArc<crate::rinex_obs::RinexObsResource>,
    interval_override_s: Option<f64>,
    gap_factor: f64,
) -> Term<'a> {
    let options = ObservationQcOptions {
        interval_override_s,
        gap_factor,
    };
    match observation_qc_with_options(&handle.obs, options) {
        Ok(report) => (atoms::ok(), observation_report_term(report)).encode(env),
        Err(sidereon_core::observation_qc::ObservationQcError::InvalidInterval) => {
            (atoms::error(), atoms::invalid_interval()).encode(env)
        }
        Err(sidereon_core::observation_qc::ObservationQcError::InvalidGapFactor) => {
            (atoms::error(), atoms::invalid_gap_factor()).encode(env)
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_qc_lint_obs<'a>(
    env: Env<'a>,
    handle: ResourceArc<crate::rinex_obs::RinexObsResource>,
) -> Term<'a> {
    (atoms::ok(), lint_report_term(lint_obs(&handle.obs))).encode(env)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_qc_lint_obs_text<'a>(env: Env<'a>, text: String) -> Term<'a> {
    (atoms::ok(), lint_report_term(lint_obs_text(&text))).encode(env)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_qc_lint_nav_text<'a>(env: Env<'a>, text: String) -> Term<'a> {
    (atoms::ok(), lint_report_term(lint_nav_text(&text))).encode(env)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_qc_repair_obs_text<'a>(
    env: Env<'a>,
    text: String,
    options: RepairOptionsTerm,
) -> Term<'a> {
    match repair_obs_text(&text, &repair_options(options)) {
        Ok(repair) => match repair_obs_to_crinex_string(&repair) {
            Ok(crinex) => (
                atoms::ok(),
                ObsRepairTerm {
                    rinex: repair.repaired.to_rinex_string(),
                    crinex,
                    actions: action_terms(repair.actions),
                    remaining: lint_report_term(repair.remaining),
                    decoded_from_crinex: repair.decoded_from_crinex,
                },
            )
                .encode(env),
            Err(error) => (atoms::error(), error.to_string()).encode(env),
        },
        Err(error) => (atoms::error(), error.to_string()).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_qc_repair_nav_text<'a>(
    env: Env<'a>,
    text: String,
    options: RepairOptionsTerm,
) -> Term<'a> {
    match repair_nav_text(&text, &repair_options(options)) {
        Ok(repair) => (
            atoms::ok(),
            NavRepairTerm {
                rinex: encode_nav(&repair.records),
                actions: action_terms(repair.actions),
                remaining: lint_report_term(repair.remaining),
                iono: iono_term(repair.iono),
                leap_seconds: repair.leap_seconds,
            },
        )
            .encode(env),
        Err(error) => (atoms::error(), error.to_string()).encode(env),
    }
}
