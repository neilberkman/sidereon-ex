//! Rustler boundary for RINEX observation QC, lint, and repair.
//!
//! The binding only marshals parsed observation handles or text buffers into
//! core QC and repair entry points, then encodes the resulting reports.

use rustler::{Encoder, Env, ResourceArc, Term};
use sidereon_core::observation_qc::{
    observation_qc_with_options, render_html as render_observation_qc_html,
    render_text as render_observation_qc_text, ClockJump, CycleSlipQc, IntervalSource, MpStats,
    MultipathReport, ObservationDataGap, ObservationQcAntenna, ObservationQcFinding,
    ObservationQcHeader, ObservationQcNote, ObservationQcOptions, ObservationQcReceiver,
    ObservationQcReport, ObservationQcTime, SatelliteMultipathQc, SatelliteObservationQc,
    SatelliteSignalQc, SnrStats, SsiHistogram, SystemCycleSlipQc, SystemMultipathQc,
    SystemObservationQc, SystemSignalQc,
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
        invalid_gap_factor,
        invalid_clock_jump_threshold
    }
}

pub struct ObservationQcReportResource {
    pub report: ObservationQcReport,
}

#[rustler::resource_impl]
impl rustler::Resource for ObservationQcReportResource {}

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

type Vec3Term = (f64, f64, f64);

#[derive(Debug, Clone, rustler::NifMap)]
struct ObservationReceiverTerm {
    number: String,
    receiver_type: String,
    version: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ObservationAntennaTerm {
    number: String,
    antenna_type: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ObservationTimeTerm {
    epoch: ((i32, i64, i64), (i64, i64, f64)),
    time_scale: Option<String>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ObservationHeaderTerm {
    marker_name: Option<String>,
    marker_number: Option<String>,
    marker_type: Option<String>,
    receiver: Option<ObservationReceiverTerm>,
    antenna: Option<ObservationAntennaTerm>,
    approx_position_m: Option<Vec3Term>,
    antenna_delta_hen_m: Option<Vec3Term>,
    time_of_first_obs: Option<ObservationTimeTerm>,
    time_of_last_obs: Option<ObservationTimeTerm>,
    duration_s: Option<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SystemObservationTerm {
    system: String,
    satellites_seen: i64,
    epochs_with_observations: i64,
    value_observations: i64,
    expected_observations: i64,
    completeness_ratio: Option<f64>,
    gap_count: i64,
    total_gap_s: f64,
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
struct ObservationFindingTerm {
    code: String,
    severity: String,
    spec_ref: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ClockJumpTerm {
    epoch_index: i64,
    epoch: ((i32, i64, i64), (i64, i64, f64)),
    delta_s: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SystemCycleSlipTerm {
    system: String,
    observations: i64,
    slips: i64,
    observations_per_slip: Option<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct CycleSlipTerm {
    observations: i64,
    total_slips: i64,
    observations_per_slip: Option<f64>,
    by_system: Vec<SystemCycleSlipTerm>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct MultipathStatsTerm {
    n: i64,
    rms_m: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SatelliteMultipathTerm {
    satellite: String,
    mp1: Option<MultipathStatsTerm>,
    mp2: Option<MultipathStatsTerm>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SystemMultipathTerm {
    system: String,
    mp1: Option<MultipathStatsTerm>,
    mp2: Option<MultipathStatsTerm>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct MultipathReportTerm {
    satellites: Vec<SatelliteMultipathTerm>,
    systems: Vec<SystemMultipathTerm>,
}

#[derive(Clone, rustler::NifMap)]
struct ObservationReportTerm {
    handle: ResourceArc<ObservationQcReportResource>,
    header: ObservationHeaderTerm,
    total_epoch_records: i64,
    observation_epochs: i64,
    event_records: i64,
    power_failure_epochs: i64,
    skipped_records: i64,
    interval_s: Option<f64>,
    interval_source: String,
    missing_epochs: i64,
    data_gaps: Vec<DataGapTerm>,
    clock_jumps: Vec<ClockJumpTerm>,
    cycle_slips: CycleSlipTerm,
    multipath: MultipathReportTerm,
    systems: Vec<SystemObservationTerm>,
    satellites: Vec<SatelliteQcTerm>,
    satellite_signals: Vec<SatelliteSignalQcTerm>,
    system_signals: Vec<SystemSignalQcTerm>,
    lint_findings: Vec<ObservationFindingTerm>,
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

fn vec3_term(values: [f64; 3]) -> Vec3Term {
    (values[0], values[1], values[2])
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

fn observation_receiver_term(receiver: ObservationQcReceiver) -> ObservationReceiverTerm {
    ObservationReceiverTerm {
        number: receiver.number,
        receiver_type: receiver.receiver_type,
        version: receiver.version,
    }
}

fn observation_antenna_term(antenna: ObservationQcAntenna) -> ObservationAntennaTerm {
    ObservationAntennaTerm {
        number: antenna.number,
        antenna_type: antenna.antenna_type,
    }
}

fn observation_time_term(time: ObservationQcTime) -> ObservationTimeTerm {
    ObservationTimeTerm {
        epoch: epoch_term(time.epoch),
        time_scale: time.time_scale,
    }
}

fn observation_header_term(header: ObservationQcHeader) -> ObservationHeaderTerm {
    ObservationHeaderTerm {
        marker_name: header.marker_name,
        marker_number: header.marker_number,
        marker_type: header.marker_type,
        receiver: header.receiver.map(observation_receiver_term),
        antenna: header.antenna.map(observation_antenna_term),
        approx_position_m: header.approx_position_m.map(vec3_term),
        antenna_delta_hen_m: header.antenna_delta_hen_m.map(vec3_term),
        time_of_first_obs: header.time_of_first_obs.map(observation_time_term),
        time_of_last_obs: header.time_of_last_obs.map(observation_time_term),
        duration_s: header.duration_s,
    }
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

fn system_observation_term(row: SystemObservationQc) -> SystemObservationTerm {
    SystemObservationTerm {
        system: system_letter(row.system),
        satellites_seen: row.satellites_seen as i64,
        epochs_with_observations: row.epochs_with_observations as i64,
        value_observations: row.value_observations as i64,
        expected_observations: row.expected_observations as i64,
        completeness_ratio: row.completeness_ratio,
        gap_count: row.gap_count as i64,
        total_gap_s: row.total_gap_s,
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

fn observation_finding_term(finding: ObservationQcFinding) -> ObservationFindingTerm {
    ObservationFindingTerm {
        code: finding.code,
        severity: severity_label(finding.severity),
        spec_ref: finding.spec_ref,
    }
}

fn clock_jump_term(row: ClockJump) -> ClockJumpTerm {
    ClockJumpTerm {
        epoch_index: row.epoch_index as i64,
        epoch: epoch_term(row.epoch),
        delta_s: row.delta_s,
    }
}

fn system_cycle_slip_term(row: SystemCycleSlipQc) -> SystemCycleSlipTerm {
    SystemCycleSlipTerm {
        system: system_letter(row.system),
        observations: row.observations as i64,
        slips: row.slips as i64,
        observations_per_slip: row.observations_per_slip,
    }
}

fn cycle_slip_term(row: CycleSlipQc) -> CycleSlipTerm {
    CycleSlipTerm {
        observations: row.observations as i64,
        total_slips: row.total_slips as i64,
        observations_per_slip: row.observations_per_slip,
        by_system: row
            .by_system
            .into_iter()
            .map(system_cycle_slip_term)
            .collect(),
    }
}

fn multipath_stats_term(stats: MpStats) -> MultipathStatsTerm {
    MultipathStatsTerm {
        n: stats.n as i64,
        rms_m: stats.rms_m,
    }
}

fn satellite_multipath_term(row: SatelliteMultipathQc) -> SatelliteMultipathTerm {
    SatelliteMultipathTerm {
        satellite: row.satellite.to_string(),
        mp1: row.mp1.map(multipath_stats_term),
        mp2: row.mp2.map(multipath_stats_term),
    }
}

fn system_multipath_term(row: SystemMultipathQc) -> SystemMultipathTerm {
    SystemMultipathTerm {
        system: system_letter(row.system),
        mp1: row.mp1.map(multipath_stats_term),
        mp2: row.mp2.map(multipath_stats_term),
    }
}

fn multipath_report_term(report: MultipathReport) -> MultipathReportTerm {
    MultipathReportTerm {
        satellites: report
            .satellites
            .into_iter()
            .map(satellite_multipath_term)
            .collect(),
        systems: report
            .systems
            .into_iter()
            .map(system_multipath_term)
            .collect(),
    }
}

fn observation_report_term(report: ObservationQcReport) -> ObservationReportTerm {
    let handle = ResourceArc::new(ObservationQcReportResource {
        report: report.clone(),
    });

    ObservationReportTerm {
        handle,
        header: observation_header_term(report.header),
        total_epoch_records: report.total_epoch_records as i64,
        observation_epochs: report.observation_epochs as i64,
        event_records: report.event_records as i64,
        power_failure_epochs: report.power_failure_epochs as i64,
        skipped_records: report.skipped_records as i64,
        interval_s: report.interval_s,
        interval_source: interval_source_label(report.interval_source),
        missing_epochs: report.missing_epochs as i64,
        data_gaps: report.data_gaps.into_iter().map(data_gap_term).collect(),
        clock_jumps: report
            .clock_jumps
            .into_iter()
            .map(clock_jump_term)
            .collect(),
        cycle_slips: cycle_slip_term(report.cycle_slips),
        multipath: multipath_report_term(report.multipath),
        systems: report
            .systems
            .into_iter()
            .map(system_observation_term)
            .collect(),
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
        lint_findings: report
            .lint_findings
            .into_iter()
            .map(observation_finding_term)
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
    clock_jump_threshold_s: Option<f64>,
) -> Term<'a> {
    let options = ObservationQcOptions {
        interval_override_s,
        gap_factor,
        clock_jump_threshold_s: clock_jump_threshold_s
            .unwrap_or(sidereon_core::observation_qc::DEFAULT_CLOCK_JUMP_THRESHOLD_S),
    };
    match observation_qc_with_options(&handle.obs, options) {
        Ok(report) => (atoms::ok(), observation_report_term(report)).encode(env),
        Err(sidereon_core::observation_qc::ObservationQcError::InvalidInterval) => {
            (atoms::error(), atoms::invalid_interval()).encode(env)
        }
        Err(sidereon_core::observation_qc::ObservationQcError::InvalidGapFactor) => {
            (atoms::error(), atoms::invalid_gap_factor()).encode(env)
        }
        Err(sidereon_core::observation_qc::ObservationQcError::InvalidClockJumpThreshold) => {
            (atoms::error(), atoms::invalid_clock_jump_threshold()).encode(env)
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_qc_report_render_text(handle: ResourceArc<ObservationQcReportResource>) -> String {
    render_observation_qc_text(&handle.report)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_qc_report_render_html(handle: ResourceArc<ObservationQcReportResource>) -> String {
    render_observation_qc_html(&handle.report)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_qc_report_to_json<'a>(
    env: Env<'a>,
    handle: ResourceArc<ObservationQcReportResource>,
) -> Term<'a> {
    match serde_json::to_string(&handle.report) {
        Ok(json) => (atoms::ok(), json).encode(env),
        Err(error) => (atoms::error(), error.to_string()).encode(env),
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
