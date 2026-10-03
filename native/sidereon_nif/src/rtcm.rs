//! Rustler boundary for the `sidereon-core` RTCM 3.x stream decoder.
//!
//! Pure glue over `sidereon_core::rtcm`: it forwards a byte buffer to the crate's
//! forgiving frame scanner / message decoder and re-shapes the canonical message
//! IR into Elixir-friendly maps. No bit-field layout, CRC, or framing math lives
//! here. Each decoded message crosses as a `{type_atom, fields_map}` pair; the raw
//! transmitted integer fields are widened to signed 64-bit for a uniform numeric
//! boundary (decode is one-way, so no precision is lost relative to the
//! scaling-helper conversions the crate exposes). An unrecognized message number
//! is preserved as `{:unsupported, %{message_number, body}}`.

use rustler::{Encoder, Env, Error, NifResult, OwnedBinary, Term};
use sidereon_core::rtcm::{
    self, derive_lli, minimum_lock_time_ms, msm_epoch_dt_ms, msm_signal_mask,
    msm_signal_rinex_code, AntennaDescriptor, BeidouEphemeris, CellLli, FkpGradient, FkpGradients,
    FrameSkip, FrameSkipReason, GalileoFnavEphemeris, GalileoInavEphemeris, GlonassCodePhaseBiases,
    GlonassEphemeris, GpsEphemeris, GridResidual, HelmertTransformation, LegacyL1, LegacyL2,
    LegacyObservations, LegacySatellite, LockTimeTracker, Message, MessageAnnouncement, MsmHeader,
    MsmKind, MsmMessage, MsmSatellite, MsmSignal, NavicEphemeris, NetworkAuxiliaryStation,
    NetworkCorrectionDifference, NetworkCorrectionDifferences, NetworkResidual, NetworkResiduals,
    PhysicalReferenceStation, PreviousLock, Projection, ProjectionParameters, QzssEphemeris,
    ResidualGrid, RotationPoint, RtcmConversionError, RtcmDeparture, RtcmPolicy, SsrVtecLayer,
    SsrVtecMessage, StationCoordinates, StreamDiagnostics, SystemParameters, TextMessage,
    UnsupportedMessage, VtecEvaluationProblem, LLI_HALF_CYCLE, LLI_LOSS_OF_LOCK,
};
use sidereon_core::GnssSystem;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        rtcm_encode_error,
        rtcm_conversion_error,
        station_coordinates,
        antenna_descriptor,
        legacy_observations,
        system_parameters,
        text,
        network_auxiliary_station,
        network_correction_differences,
        helmert_transformation,
        residual_grid,
        projection,
        network_residuals,
        physical_reference_station,
        fkp_gradients,
        glonass_code_phase_biases,
        gps_ephemeris,
        glonass_ephemeris,
        beidou_ephemeris,
        qzss_ephemeris,
        galileo_fnav_ephemeris,
        galileo_inav_ephemeris,
        navic_ephemeris,
        msm,
        ssr,
        ssr_vtec,
        unsupported,
        truncated,
        malformed,
        departure,
        invalid_input,
        frame_reserved_bits,
        trailing_bits,
        msm_cell_mask_over_64,
        ssr_records_short,
        order_exceeds_degree,
        records_short,
        other,
        offset,
        message_number,
        reason,
        detail,
        resync_bytes,
        crc_failures,
        skipped_frames,
        departures,
        vtec_evaluation
    }
}

fn field_encoding_label(encoding: sidereon_core::rtcm::RtcmFieldEncoding) -> &'static str {
    match encoding {
        sidereon_core::rtcm::RtcmFieldEncoding::Unsigned => "unsigned",
        sidereon_core::rtcm::RtcmFieldEncoding::TwosComplement => "twos_complement",
        sidereon_core::rtcm::RtcmFieldEncoding::SignMagnitude => "sign_magnitude",
        _ => "unrecognized_encoding",
    }
}

fn record_kind_label(record: sidereon_core::rtcm::RtcmRecordKind) -> String {
    use sidereon_core::rtcm::RtcmRecordKind as Record;
    match record {
        Record::StationCoordinates => "station_coordinates".into(),
        Record::AntennaDescriptor => "antenna_descriptor".into(),
        Record::Msm { system, kind } => format!("msm:{}:{}", system.letter(), kind.number()),
        Record::Ssr { system, kind } => format!("ssr:{}:{}", system.letter(), ssr_kind_label(kind)),
        Record::LegacyObservations => "legacy_observations".into(),
        Record::SystemParameters => "system_parameters".into(),
        Record::Text => "text".into(),
        Record::Network { family } => format!("network:{family}"),
        Record::Transformation { family } => format!("transformation:{family}"),
        Record::GlonassCodePhaseBiases => "glonass_code_phase_biases".into(),
        Record::SsrVtec { message_number } => format!("ssr_vtec:{message_number}"),
        _ => "unrecognized_record".into(),
    }
}

fn ssr_kind_label(kind: sidereon_core::rtcm::SsrKind) -> String {
    use sidereon_core::rtcm::SsrKind;
    match kind {
        SsrKind::Orbit => "orbit".into(),
        SsrKind::Clock => "clock".into(),
        SsrKind::CombinedOrbitClock => "combined_orbit_clock".into(),
        SsrKind::CodeBias => "code_bias".into(),
        SsrKind::PhaseBias => "phase_bias".into(),
        SsrKind::Ura => "ura".into(),
        SsrKind::HighRateClock => "high_rate_clock".into(),
    }
}

fn msm_kind_label(kind: sidereon_core::rtcm::MsmKind) -> String {
    format!("msm{}", kind.number())
}

fn msm_optional_field_label(field: sidereon_core::rtcm::MsmOptionalField) -> &'static str {
    match field {
        sidereon_core::rtcm::MsmOptionalField::ExtendedInfo => "extended_info",
        sidereon_core::rtcm::MsmOptionalField::RoughPhaseRangeRate => "rough_phase_range_rate",
        sidereon_core::rtcm::MsmOptionalField::FinePhaseRangeRate => "fine_phase_range_rate",
        _ => "unrecognized_optional_field",
    }
}

fn departure_label(departure: &RtcmDeparture) -> &'static str {
    match departure {
        RtcmDeparture::FrameReservedBits { .. } => "frame_reserved_bits",
        RtcmDeparture::TrailingBits { .. } => "trailing_bits",
        RtcmDeparture::MsmCellMaskOver64 { .. } => "msm_cell_mask_over_64",
        RtcmDeparture::OrderExceedsDegree { .. } => "order_exceeds_degree",
        RtcmDeparture::SsrRecordsShort { .. } => "ssr_records_short",
        RtcmDeparture::RecordsShort { .. } => "records_short",
        _ => "unrecognized_departure",
    }
}

fn rtcm_encode_error_fields(error: &sidereon_core::rtcm::RtcmEncodeError) -> RtcmEncodeErrorFields {
    let mut fields = RtcmEncodeErrorFields {
        variant: String::new(),
        message_number: None,
        field: None,
        value: None,
        minimum: None,
        maximum: None,
        width: None,
        encoding: None,
        record: None,
        carried: None,
        satellite: None,
        expected: None,
        actual: None,
        index: None,
        orbit: None,
        clock: None,
        orbit_satellite: None,
        clock_satellite: None,
        c1: None,
        c2: None,
        signal: None,
        mask: None,
        problem: None,
        count: None,
        detail: None,
        trailing_bits: None,
    };
    use sidereon_core::rtcm::RtcmEncodeError as EncodeError;
    match error {
        EncodeError::FieldOutOfRange {
            message_number,
            field,
            value,
            width,
            encoding,
        } => {
            fields.variant = "field_out_of_range".into();
            fields.message_number = Some(i64::from(*message_number));
            fields.field = Some(field.clone());
            fields.value = Some(value.to_string());
            fields.width = Some(i64::from(*width));
            fields.encoding = Some(field_encoding_label(*encoding).into());
        }
        EncodeError::NegativeZeroWithValue {
            message_number,
            field,
            value,
        } => {
            fields.variant = "negative_zero_with_value".into();
            fields.message_number = Some(i64::from(*message_number));
            fields.field = Some(field.clone());
            fields.value = Some(value.to_string());
        }
        EncodeError::NegativeZeroMask {
            message_number,
            mask,
        } => {
            fields.variant = "negative_zero_mask".into();
            fields.message_number = Some(i64::from(*message_number));
            fields.value = Some(mask.to_string());
        }
        EncodeError::MessageNumber {
            message_number,
            record,
        } => {
            fields.variant = "message_number".into();
            fields.message_number = Some(i64::from(*message_number));
            fields.record = Some(record_kind_label(*record));
        }
        EncodeError::FieldPresence {
            message_number,
            record,
            field,
            carried,
        } => {
            fields.variant = "field_presence".into();
            fields.message_number = Some(i64::from(*message_number));
            fields.record = Some(record_kind_label(*record));
            fields.field = Some((*field).into());
            fields.carried = Some(*carried);
        }
        EncodeError::SatelliteFieldPresence {
            message_number,
            record,
            satellite,
            field,
            carried,
        } => {
            fields.variant = "satellite_field_presence".into();
            fields.message_number = Some(i64::from(*message_number));
            fields.record = Some(record_kind_label(*record));
            fields.satellite = Some(i64::from(*satellite));
            fields.field = Some((*field).into());
            fields.carried = Some(*carried);
        }
        EncodeError::CountMismatch {
            message_number,
            field,
            expected,
            actual,
        } => {
            fields.variant = "count_mismatch".into();
            fields.message_number = Some(i64::from(*message_number));
            fields.field = Some((*field).into());
            fields.expected = i64::try_from(*expected).ok();
            fields.actual = i64::try_from(*actual).ok();
        }
        EncodeError::ValueOutOfRange {
            message_number,
            field,
            value,
            minimum,
            maximum,
        } => {
            fields.variant = "value_out_of_range".into();
            fields.message_number = Some(i64::from(*message_number));
            fields.field = Some(field.clone());
            fields.value = Some(value.to_string());
            fields.minimum = Some(minimum.to_string());
            fields.maximum = Some(maximum.to_string());
        }
        EncodeError::NonLatin1Character { field, character } => {
            fields.variant = "non_latin1_character".into();
            fields.field = Some(field.clone());
            fields.value = Some(u32::from(*character).to_string());
        }
        EncodeError::SatelliteIdOutOfRange {
            message_number,
            field,
            value,
            width,
        } => {
            fields.variant = "satellite_id_out_of_range".into();
            fields.message_number = Some(i64::from(*message_number));
            fields.field = Some((*field).into());
            fields.value = Some(i64::from(*value).to_string());
            fields.width = Some(i64::from(*width));
        }
        EncodeError::SsrSatelliteIdOutOfRange {
            message_number,
            value,
            width,
        } => {
            fields.variant = "ssr_satellite_id_out_of_range".into();
            fields.message_number = Some(i64::from(*message_number));
            fields.satellite = Some(i64::from(*value));
            fields.width = Some(i64::from(*width));
        }
        EncodeError::SsrRecordsNotCarried {
            message_number,
            kind,
            records,
            count,
        } => {
            fields.variant = "ssr_records_not_carried".into();
            fields.message_number = Some(i64::from(*message_number));
            fields.record = Some(ssr_kind_label(*kind));
            fields.field = Some((*records).into());
            fields.count = i64::try_from(*count).ok();
        }
        EncodeError::SsrCombinedRecordCounts {
            message_number,
            orbit,
            clock,
        } => {
            fields.variant = "ssr_combined_record_counts".into();
            fields.message_number = Some(i64::from(*message_number));
            fields.orbit = i64::try_from(*orbit).ok();
            fields.clock = i64::try_from(*clock).ok();
        }
        EncodeError::SsrCombinedSatelliteMismatch {
            message_number,
            index,
            orbit_satellite,
            clock_satellite,
        } => {
            fields.variant = "ssr_combined_satellite_mismatch".into();
            fields.message_number = Some(i64::from(*message_number));
            fields.index = i64::try_from(*index).ok();
            fields.orbit_satellite = Some(i64::from(*orbit_satellite));
            fields.clock_satellite = Some(i64::from(*clock_satellite));
        }
        EncodeError::SsrHighRateClockTerms {
            message_number,
            satellite,
            c1,
            c2,
        } => {
            fields.variant = "ssr_high_rate_clock_terms".into();
            fields.message_number = Some(i64::from(*message_number));
            fields.satellite = Some(i64::from(*satellite));
            fields.c1 = Some(i64::from(*c1));
            fields.c2 = Some(i64::from(*c2));
        }
        EncodeError::SsrSatelliteCount {
            message_number,
            declared,
            records,
        } => {
            fields.variant = "ssr_satellite_count".into();
            fields.message_number = Some(i64::from(*message_number));
            fields.expected = i64::try_from(*declared).ok();
            fields.actual = i64::try_from(*records).ok();
        }
        EncodeError::MsmMask {
            message_number,
            problem,
        } => {
            fields.variant = "msm_mask".into();
            fields.message_number = Some(i64::from(*message_number));
            match problem {
                sidereon_core::rtcm::MsmMaskProblem::SatelliteOutsideMask { satellite } => {
                    fields.problem = Some("satellite_outside_mask".into());
                    fields.satellite = Some(i64::from(*satellite));
                }
                sidereon_core::rtcm::MsmMaskProblem::SatelliteListedTwice { satellite } => {
                    fields.problem = Some("satellite_listed_twice".into());
                    fields.satellite = Some(i64::from(*satellite));
                }
                sidereon_core::rtcm::MsmMaskProblem::SignalOutsideMask { signal } => {
                    fields.problem = Some("signal_outside_mask".into());
                    fields.signal = Some(i64::from(*signal));
                }
                sidereon_core::rtcm::MsmMaskProblem::SignalNotInMask { signal, mask } => {
                    fields.problem = Some("signal_not_in_mask".into());
                    fields.signal = Some(i64::from(*signal));
                    fields.mask = Some(i64::from(*mask));
                }
                sidereon_core::rtcm::MsmMaskProblem::SignalSatelliteNotListed {
                    signal,
                    satellite,
                } => {
                    fields.problem = Some("signal_satellite_not_listed".into());
                    fields.signal = Some(i64::from(*signal));
                    fields.satellite = Some(i64::from(*satellite));
                }
                sidereon_core::rtcm::MsmMaskProblem::CellListedTwice { signal, satellite } => {
                    fields.problem = Some("cell_listed_twice".into());
                    fields.signal = Some(i64::from(*signal));
                    fields.satellite = Some(i64::from(*satellite));
                }
                _ => fields.problem = Some("unrecognized_mask_problem".into()),
            }
        }
        EncodeError::MsmOptional {
            message_number,
            kind,
            satellite,
            signal,
            field,
            problem,
        } => {
            fields.variant = "msm_optional".into();
            fields.message_number = Some(i64::from(*message_number));
            fields.satellite = Some(i64::from(*satellite));
            fields.record = Some(msm_kind_label(*kind));
            fields.field = Some(msm_optional_field_label(*field).into());
            fields.signal = signal.map(i64::from);
            match problem {
                sidereon_core::rtcm::MsmOptionalProblem::Missing => {
                    fields.problem = Some("missing".into());
                }
                sidereon_core::rtcm::MsmOptionalProblem::NotCarried => {
                    fields.problem = Some("not_carried".into());
                }
                sidereon_core::rtcm::MsmOptionalProblem::InvalidValue(value) => {
                    fields.problem = Some("invalid_value".into());
                    fields.value = Some(value.to_string());
                }
                _ => fields.problem = Some("unrecognized_optional_problem".into()),
            }
        }
        EncodeError::TrailingZeroBits {
            message_number,
            bits,
        } => {
            fields.variant = "trailing_zero_bits".into();
            fields.message_number = Some(i64::from(*message_number));
            fields.count = i64::try_from(*bits).ok();
        }
        EncodeError::StrictDeparture(departure) => {
            fields.variant = "strict_departure".into();
            fields.detail = Some(departure_label(departure).into());
            match departure {
                RtcmDeparture::FrameReservedBits { reserved } => {
                    fields.value = Some(i64::from(*reserved).to_string());
                }
                RtcmDeparture::TrailingBits {
                    message_number,
                    bits,
                } => {
                    fields.message_number = Some(i64::from(*message_number));
                    fields.count = i64::try_from(bits.len()).ok();
                    fields.trailing_bits = Some(bits.clone());
                }
                RtcmDeparture::MsmCellMaskOver64 {
                    message_number,
                    cells,
                } => {
                    fields.message_number = Some(i64::from(*message_number));
                    fields.count = i64::try_from(*cells).ok();
                }
                RtcmDeparture::OrderExceedsDegree {
                    message_number,
                    layer_index,
                    degree,
                    order,
                } => {
                    fields.message_number = Some(i64::from(*message_number));
                    fields.index = i64::try_from(*layer_index).ok();
                    fields.expected = Some(i64::from(*degree));
                    fields.actual = Some(i64::from(*order));
                }
                RtcmDeparture::SsrRecordsShort {
                    message_number,
                    declared,
                    read,
                }
                | RtcmDeparture::RecordsShort {
                    message_number,
                    declared,
                    read,
                } => {
                    fields.message_number = Some(i64::from(*message_number));
                    fields.expected = i64::try_from(*declared).ok();
                    fields.actual = i64::try_from(*read).ok();
                }
                _ => {}
            }
        }
        EncodeError::UnsupportedBodyTooShort { message_number } => {
            fields.variant = "unsupported_body_too_short".into();
            fields.message_number = Some(i64::from(*message_number));
        }
        EncodeError::UnsupportedBodyNumber {
            message_number,
            carried,
        } => {
            fields.variant = "unsupported_body_number".into();
            fields.message_number = Some(i64::from(*message_number));
            fields.actual = Some(i64::from(*carried));
        }
        EncodeError::UnsupportedDecodedNumber { message_number } => {
            fields.variant = "unsupported_decoded_number".into();
            fields.message_number = Some(i64::from(*message_number));
        }
        EncodeError::FrameBodyTooLong { len } => {
            fields.variant = "frame_body_too_long".into();
            fields.count = i64::try_from(*len).ok();
        }
        EncodeError::FrameReservedOutOfRange { value } => {
            fields.variant = "frame_reserved_out_of_range".into();
            fields.value = Some(i64::from(*value).to_string());
        }
        _ => fields.variant = "unrecognized_encode_error".into(),
    }
    fields
}

#[cfg(test)]
mod rtcm_encode_error_contract_tests {
    use super::rtcm_encode_error_fields;
    use sidereon_core::rtcm::{
        MsmKind, MsmMaskProblem, MsmOptionalField, MsmOptionalProblem, RtcmDeparture,
        RtcmEncodeError as Encode, RtcmFieldEncoding, RtcmRecordKind, SsrKind,
    };

    #[test]
    fn every_rtcm_encode_variant_and_field_has_the_documented_elixir_term() {
        let mut count = 0;
        macro_rules! check {
            ($error:expr, $variant:literal $(, $field:ident => $expected:expr)* $(,)?) => {{
                let actual = rtcm_encode_error_fields(&$error);
                assert_eq!(actual.variant, $variant);
                $(assert_eq!(actual.$field, $expected, "{}", stringify!($field));)*
                count += 1;
            }};
        }

        check!(
            Encode::FieldOutOfRange {
                message_number: 1005,
                field: "ecef_x".into(),
                value: -2,
                width: 38,
                encoding: RtcmFieldEncoding::TwosComplement,
            },
            "field_out_of_range",
            message_number => Some(1005),
            field => Some("ecef_x".into()),
            value => Some("-2".into()),
            width => Some(38),
            encoding => Some("twos_complement".into()),
        );
        check!(
            Encode::NegativeZeroWithValue {
                message_number: 1020,
                field: "tau_n".into(),
                value: 7,
            },
            "negative_zero_with_value",
            message_number => Some(1020),
            field => Some("tau_n".into()),
            value => Some("7".into()),
        );
        check!(
            Encode::NegativeZeroMask { message_number: 1020, mask: 9 },
            "negative_zero_mask",
            message_number => Some(1020),
            value => Some("9".into()),
        );
        check!(
            Encode::MessageNumber {
                message_number: 999,
                record: RtcmRecordKind::StationCoordinates,
            },
            "message_number",
            message_number => Some(999),
            record => Some("station_coordinates".into()),
        );
        check!(
            Encode::FieldPresence {
                message_number: 1005,
                record: RtcmRecordKind::StationCoordinates,
                field: "antenna_height",
                carried: false,
            },
            "field_presence",
            message_number => Some(1005),
            record => Some("station_coordinates".into()),
            field => Some("antenna_height".into()),
            carried => Some(false),
        );
        check!(
            Encode::SatelliteFieldPresence {
                message_number: 1074,
                record: RtcmRecordKind::Msm {
                    system: sidereon_core::GnssSystem::Gps,
                    kind: MsmKind::Msm4,
                },
                satellite: 7,
                field: "extended_info",
                carried: false,
            },
            "satellite_field_presence",
            message_number => Some(1074),
            record => Some("msm:G:4".into()),
            satellite => Some(7),
            field => Some("extended_info".into()),
            carried => Some(false),
        );
        check!(
            Encode::CountMismatch {
                message_number: 1015,
                field: "satellites",
                expected: 2,
                actual: 1,
            },
            "count_mismatch",
            message_number => Some(1015),
            field => Some("satellites".into()),
            expected => Some(2),
            actual => Some(1),
        );
        check!(
            Encode::ValueOutOfRange {
                message_number: 1005,
                field: "itrf".into(),
                value: 64,
                minimum: 0,
                maximum: 63,
            },
            "value_out_of_range",
            message_number => Some(1005),
            field => Some("itrf".into()),
            value => Some("64".into()),
            minimum => Some("0".into()),
            maximum => Some("63".into()),
        );
        check!(
            Encode::NonLatin1Character { field: "descriptor".into(), character: 'λ' },
            "non_latin1_character",
            field => Some("descriptor".into()),
            value => Some("955".into()),
        );
        check!(
            Encode::SatelliteIdOutOfRange {
                message_number: 1019,
                field: "GPS PRN",
                value: 64,
                width: 6,
            },
            "satellite_id_out_of_range",
            message_number => Some(1019),
            field => Some("GPS PRN".into()),
            value => Some("64".into()),
            width => Some(6),
        );
        check!(
            Encode::SsrSatelliteIdOutOfRange { message_number: 1057, value: 64, width: 6 },
            "ssr_satellite_id_out_of_range",
            message_number => Some(1057),
            satellite => Some(64),
            width => Some(6),
        );
        check!(
            Encode::SsrRecordsNotCarried {
                message_number: 1058,
                kind: SsrKind::Clock,
                records: "orbit",
                count: 2,
            },
            "ssr_records_not_carried",
            message_number => Some(1058),
            record => Some("clock".into()),
            field => Some("orbit".into()),
            count => Some(2),
        );
        check!(
            Encode::SsrCombinedRecordCounts { message_number: 1060, orbit: 2, clock: 1 },
            "ssr_combined_record_counts",
            message_number => Some(1060),
            orbit => Some(2),
            clock => Some(1),
        );
        check!(
            Encode::SsrCombinedSatelliteMismatch {
                message_number: 1060,
                index: 1,
                orbit_satellite: 4,
                clock_satellite: 5,
            },
            "ssr_combined_satellite_mismatch",
            message_number => Some(1060),
            index => Some(1),
            orbit_satellite => Some(4),
            clock_satellite => Some(5),
        );
        check!(
            Encode::SsrHighRateClockTerms {
                message_number: 1062,
                satellite: 3,
                c1: -4,
                c2: 5,
            },
            "ssr_high_rate_clock_terms",
            message_number => Some(1062),
            satellite => Some(3),
            c1 => Some(-4),
            c2 => Some(5),
        );
        check!(
            Encode::SsrSatelliteCount { message_number: 1057, declared: 2, records: 1 },
            "ssr_satellite_count",
            message_number => Some(1057),
            expected => Some(2),
            actual => Some(1),
        );
        check!(
            Encode::MsmMask {
                message_number: 1074,
                problem: MsmMaskProblem::SignalNotInMask { signal: 3, mask: 5 },
            },
            "msm_mask",
            message_number => Some(1074),
            problem => Some("signal_not_in_mask".into()),
            signal => Some(3),
            mask => Some(5),
        );
        check!(
            Encode::MsmOptional {
                message_number: 1077,
                kind: MsmKind::Msm7,
                satellite: 4,
                signal: Some(6),
                field: MsmOptionalField::FinePhaseRangeRate,
                problem: MsmOptionalProblem::InvalidValue(-16384),
            },
            "msm_optional",
            message_number => Some(1077),
            record => Some("msm7".into()),
            satellite => Some(4),
            signal => Some(6),
            field => Some("fine_phase_range_rate".into()),
            problem => Some("invalid_value".into()),
            value => Some("-16384".into()),
        );
        check!(
            Encode::TrailingZeroBits { message_number: 1006, bits: 3 },
            "trailing_zero_bits",
            message_number => Some(1006),
            count => Some(3),
        );
        check!(
            Encode::StrictDeparture(RtcmDeparture::FrameReservedBits { reserved: 5 }),
            "strict_departure",
            detail => Some("frame_reserved_bits".into()),
            value => Some("5".into()),
        );
        check!(
            Encode::UnsupportedBodyTooShort { message_number: 4090 },
            "unsupported_body_too_short",
            message_number => Some(4090),
        );
        check!(
            Encode::UnsupportedBodyNumber { message_number: 4090, carried: 4089 },
            "unsupported_body_number",
            message_number => Some(4090),
            actual => Some(4089),
        );
        check!(
            Encode::UnsupportedDecodedNumber { message_number: 4090 },
            "unsupported_decoded_number",
            message_number => Some(4090),
        );
        check!(
            Encode::FrameBodyTooLong { len: 1024 },
            "frame_body_too_long",
            count => Some(1024),
        );
        check!(
            Encode::FrameReservedOutOfRange { value: 64 },
            "frame_reserved_out_of_range",
            value => Some("64".into()),
        );
        assert_eq!(count, 25);
    }
}

fn rtcm_conversion_error_fields(error: &RtcmConversionError) -> RtcmConversionErrorFields {
    let mut fields = RtcmConversionErrorFields {
        variant: String::new(),
        nested_variant: None,
        message_number: None,
        field: None,
        value: None,
        width: None,
        index: None,
        system: None,
        full_week: None,
        week: None,
        broadcast_prn: None,
        satellite: None,
        reason: None,
        decoded_week: None,
        fit_interval_flag: None,
        iode: None,
        iodc: None,
        vtec: None,
        detail: None,
    };
    use sidereon_core::rtcm::RtcmConversionError as ConversionError;
    match error {
        ConversionError::SatelliteIdOutOfRange {
            message_number,
            field,
            value,
            width,
        } => {
            fields.variant = "satellite_id_out_of_range".into();
            fields.message_number = Some(i64::from(*message_number));
            fields.field = Some((*field).into());
            fields.value = Some(i64::from(*value));
            fields.width = Some(i64::from(*width));
        }
        ConversionError::InvalidSatellite {
            message_number,
            field,
            value,
            error,
        } => {
            fields.variant = "invalid_satellite".into();
            fields.message_number = Some(i64::from(*message_number));
            fields.field = Some((*field).into());
            fields.value = Some(i64::from(*value));
            match error {
                sidereon_core::SatelliteIdError::InvalidInput { field, reason } => {
                    fields.nested_variant = Some("invalid_input".into());
                    fields.detail = Some((*field).into());
                    fields.reason = Some((*reason).into());
                }
            }
        }
        ConversionError::SbasPrnOutsideWindow {
            value,
            broadcast_prn,
        } => {
            fields.variant = "sbas_prn_outside_window".into();
            fields.value = Some(i64::from(*value));
            fields.broadcast_prn = Some(i64::from(*broadcast_prn));
        }
        ConversionError::NoLnavRecord { value, satellite } => {
            fields.variant = "no_lnav_record".into();
            fields.value = Some(i64::from(*value));
            fields.satellite = Some(satellite.to_string());
        }
        ConversionError::WeekMismatch {
            message_number,
            full_week,
            week,
        } => {
            fields.variant = "week_mismatch".into();
            fields.message_number = Some(i64::from(*message_number));
            fields.full_week = Some(i64::from(*full_week));
            fields.week = Some(i64::from(*week));
        }
        ConversionError::NavicWeekMismatch { full_week, week } => {
            fields.variant = "navic_week_mismatch".into();
            fields.full_week = Some(i64::from(*full_week));
            fields.week = Some(i64::from(*week));
        }
        ConversionError::TimeNotRepresentable { field } => {
            fields.variant = "time_not_representable".into();
            fields.field = Some((*field).into());
        }
        ConversionError::GalileoWeekOverflow => fields.variant = "galileo_week_overflow".into(),
        ConversionError::SisaSpare { index } => {
            fields.variant = "sisa_spare".into();
            fields.index = Some(i64::from(*index));
        }
        ConversionError::SisaNoPrediction => fields.variant = "sisa_no_prediction".into(),
        ConversionError::UraOutOfRange { system, index } => {
            fields.variant = "ura_out_of_range".into();
            fields.system = Some(system.letter().to_string());
            fields.index = Some(i64::from(*index));
        }
        ConversionError::UraNoPrediction { system, index } => {
            fields.variant = "ura_no_prediction".into();
            fields.system = Some(system.letter().to_string());
            fields.index = Some(i64::from(*index));
        }
        ConversionError::FitInterval(error) => {
            fields.variant = "fit_interval".into();
            match error {
                sidereon_core::ephemeris::LnavRecordError::NotGps(satellite) => {
                    fields.nested_variant = Some("not_gps".into());
                    fields.satellite = Some(satellite.to_string());
                }
                sidereon_core::ephemeris::LnavRecordError::InvalidEpoch(field) => {
                    fields.nested_variant = Some("invalid_epoch".into());
                    fields.field = Some((*field).into());
                }
                sidereon_core::ephemeris::LnavRecordError::WeekMismatch {
                    full_week,
                    decoded_week,
                } => {
                    fields.nested_variant = Some("week_mismatch".into());
                    fields.full_week = Some(i64::from(*full_week));
                    fields.decoded_week = Some(*decoded_week);
                }
                sidereon_core::ephemeris::LnavRecordError::NoUraPrediction(index) => {
                    fields.nested_variant = Some("no_ura_prediction".into());
                    fields.index = Some(*index);
                }
                sidereon_core::ephemeris::LnavRecordError::FitIntervalUnsupported {
                    fit_interval_flag,
                    iode,
                    iodc,
                } => {
                    fields.nested_variant = Some("fit_interval_unsupported".into());
                    fields.fit_interval_flag = Some(*fit_interval_flag);
                    fields.iode = Some(*iode);
                    fields.iodc = Some(*iodc);
                }
            }
        }
        ConversionError::VtecEvaluation(problem) => {
            fields.variant = "vtec_evaluation".into();
            fields.vtec = Some(VtecEvaluationErrorFields::from(problem.clone()));
        }
        _ => fields.variant = "unrecognized_conversion_error".into(),
    }
    fields
}

/// The reason for an RTCM message the encoder refuses: `{:invalid_input,
/// message}` for fields the wire format cannot state (an MSM satellite or
/// signal outside its mask, a satellite field wider than the message's, or a
/// body over the frame length limit), the error text for any other failure.
pub(crate) fn encode_error_reason<'a>(env: Env<'a>, error: &sidereon_core::Error) -> Term<'a> {
    match error {
        sidereon_core::Error::InvalidInput(message) => {
            (atoms::invalid_input(), message.as_str()).encode(env)
        }
        sidereon_core::Error::RtcmEncode(error) => match error.as_ref() {
            sidereon_core::rtcm::RtcmEncodeError::StrictDeparture(departure) => {
                (atoms::departure(), departure_term(env, departure)).encode(env)
            }
            other => (atoms::rtcm_encode_error(), rtcm_encode_error_fields(other)).encode(env),
        },
        sidereon_core::Error::RtcmConversion(error) => (
            atoms::rtcm_conversion_error(),
            rtcm_conversion_error_fields(error),
        )
            .encode(env),
        other => other.to_string().encode(env),
    }
}

/// The raised form of [`encode_error_reason`], for a native call whose success
/// value is not an `{:ok, _}` tuple.
fn raise_encode_error(error: &sidereon_core::Error) -> Error {
    match error {
        sidereon_core::Error::InvalidInput(message) => {
            Error::RaiseTerm(Box::new((atoms::invalid_input(), message.clone())))
        }
        sidereon_core::Error::RtcmEncode(error) => match error.as_ref() {
            sidereon_core::rtcm::RtcmEncodeError::StrictDeparture(departure) => match departure {
                RtcmDeparture::FrameReservedBits { reserved } => Error::RaiseTerm(Box::new((
                    atoms::frame_reserved_bits(),
                    i64::from(*reserved),
                ))),
                RtcmDeparture::TrailingBits {
                    message_number,
                    bits,
                } => Error::RaiseTerm(Box::new((
                    atoms::trailing_bits(),
                    i64::from(*message_number),
                    bits.clone(),
                ))),
                RtcmDeparture::MsmCellMaskOver64 {
                    message_number,
                    cells,
                } => Error::RaiseTerm(Box::new((
                    atoms::msm_cell_mask_over_64(),
                    i64::from(*message_number),
                    *cells as u64,
                ))),
                RtcmDeparture::SsrRecordsShort {
                    message_number,
                    declared,
                    read,
                } => Error::RaiseTerm(Box::new((
                    atoms::ssr_records_short(),
                    i64::from(*message_number),
                    *declared as u64,
                    *read as u64,
                ))),
                RtcmDeparture::OrderExceedsDegree {
                    message_number,
                    layer_index,
                    degree,
                    order,
                } => Error::RaiseTerm(Box::new((
                    atoms::order_exceeds_degree(),
                    i64::from(*message_number),
                    *layer_index as u64,
                    i64::from(*degree),
                    i64::from(*order),
                ))),
                RtcmDeparture::RecordsShort {
                    message_number,
                    declared,
                    read,
                } => Error::RaiseTerm(Box::new((
                    atoms::records_short(),
                    i64::from(*message_number),
                    *declared as u64,
                    *read as u64,
                ))),
                other => Error::RaiseTerm(Box::new((atoms::departure(), other.to_string()))),
            },
            other => Error::RaiseTerm(Box::new((
                atoms::rtcm_encode_error(),
                rtcm_encode_error_fields(other),
            ))),
        },
        sidereon_core::Error::RtcmConversion(error) => Error::RaiseTerm(Box::new((
            atoms::rtcm_conversion_error(),
            rtcm_conversion_error_fields(error),
        ))),
        other => Error::RaiseTerm(Box::new(other.to_string())),
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct StationCoordinatesFields {
    message_number: i64,
    reference_station_id: i64,
    itrf_realization_year: i64,
    gps_indicator: bool,
    glonass_indicator: bool,
    galileo_indicator: bool,
    reference_station_indicator: bool,
    ecef_x: i64,
    single_receiver_oscillator: bool,
    reserved: bool,
    ecef_y: i64,
    quarter_cycle_indicator: i64,
    ecef_z: i64,
    antenna_height: Option<i64>,
    x_m: f64,
    y_m: f64,
    z_m: f64,
    antenna_height_m: Option<f64>,
    trailing_bits: Vec<bool>,
}

impl From<StationCoordinates> for StationCoordinatesFields {
    fn from(s: StationCoordinates) -> Self {
        Self {
            message_number: s.message_number as i64,
            reference_station_id: s.reference_station_id as i64,
            itrf_realization_year: s.itrf_realization_year as i64,
            gps_indicator: s.gps_indicator,
            glonass_indicator: s.glonass_indicator,
            galileo_indicator: s.galileo_indicator,
            reference_station_indicator: s.reference_station_indicator,
            ecef_x: s.ecef_x,
            single_receiver_oscillator: s.single_receiver_oscillator,
            reserved: s.reserved,
            ecef_y: s.ecef_y,
            quarter_cycle_indicator: s.quarter_cycle_indicator as i64,
            ecef_z: s.ecef_z,
            antenna_height: s.antenna_height.map(|h| h as i64),
            x_m: s.x_m(),
            y_m: s.y_m(),
            z_m: s.z_m(),
            antenna_height_m: s.antenna_height_m(),
            trailing_bits: s.trailing_bits,
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct AntennaDescriptorFields {
    message_number: i64,
    reference_station_id: i64,
    antenna_descriptor: String,
    antenna_setup_id: i64,
    antenna_serial_number: Option<String>,
    receiver_type: Option<String>,
    receiver_firmware_version: Option<String>,
    receiver_serial_number: Option<String>,
    trailing_bits: Vec<bool>,
}

impl From<AntennaDescriptor> for AntennaDescriptorFields {
    fn from(a: AntennaDescriptor) -> Self {
        Self {
            message_number: a.message_number as i64,
            reference_station_id: a.reference_station_id as i64,
            antenna_descriptor: a.antenna_descriptor,
            antenna_setup_id: a.antenna_setup_id as i64,
            antenna_serial_number: a.antenna_serial_number,
            receiver_type: a.receiver_type,
            receiver_firmware_version: a.receiver_firmware_version,
            receiver_serial_number: a.receiver_serial_number,
            trailing_bits: a.trailing_bits,
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct GpsEphemerisFields {
    satellite_id: i64,
    week_number: i64,
    sv_accuracy: i64,
    code_on_l2: i64,
    idot: i64,
    iode: i64,
    t_oc: i64,
    a_f2: i64,
    a_f1: i64,
    a_f0: i64,
    iodc: i64,
    c_rs: i64,
    delta_n: i64,
    m0: i64,
    c_uc: i64,
    eccentricity: i64,
    c_us: i64,
    sqrt_a: i64,
    t_oe: i64,
    c_ic: i64,
    omega0: i64,
    c_is: i64,
    i0: i64,
    c_rc: i64,
    omega: i64,
    omega_dot: i64,
    t_gd: i64,
    sv_health: i64,
    l2_p_data_flag: bool,
    fit_interval: bool,
    trailing_bits: Vec<bool>,
}

impl From<GpsEphemeris> for GpsEphemerisFields {
    fn from(e: GpsEphemeris) -> Self {
        Self {
            satellite_id: e.satellite_id as i64,
            week_number: e.week_number as i64,
            sv_accuracy: e.sv_accuracy as i64,
            code_on_l2: e.code_on_l2 as i64,
            idot: e.idot as i64,
            iode: e.iode as i64,
            t_oc: e.t_oc as i64,
            a_f2: e.a_f2 as i64,
            a_f1: e.a_f1 as i64,
            a_f0: e.a_f0 as i64,
            iodc: e.iodc as i64,
            c_rs: e.c_rs as i64,
            delta_n: e.delta_n as i64,
            m0: e.m0,
            c_uc: e.c_uc as i64,
            eccentricity: e.eccentricity as i64,
            c_us: e.c_us as i64,
            sqrt_a: e.sqrt_a as i64,
            t_oe: e.t_oe as i64,
            c_ic: e.c_ic as i64,
            omega0: e.omega0,
            c_is: e.c_is as i64,
            i0: e.i0,
            c_rc: e.c_rc as i64,
            omega: e.omega,
            omega_dot: e.omega_dot as i64,
            t_gd: e.t_gd as i64,
            sv_health: e.sv_health as i64,
            l2_p_data_flag: e.l2_p_data_flag,
            fit_interval: e.fit_interval,
            trailing_bits: e.trailing_bits,
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct GalileoFnavEphemerisFields {
    satellite_id: i64,
    week_number: i64,
    iod_nav: i64,
    sisa: i64,
    idot: i64,
    t_oc: i64,
    a_f2: i64,
    a_f1: i64,
    a_f0: i64,
    c_rs: i64,
    delta_n: i64,
    m0: i64,
    c_uc: i64,
    eccentricity: i64,
    c_us: i64,
    sqrt_a: i64,
    t_oe: i64,
    c_ic: i64,
    omega0: i64,
    c_is: i64,
    i0: i64,
    c_rc: i64,
    omega: i64,
    omega_dot: i64,
    bgd_e5a_e1: i64,
    e5a_signal_health: i64,
    e5a_data_validity: bool,
    reserved: i64,
    trailing_bits: Vec<bool>,
}

impl From<GalileoFnavEphemeris> for GalileoFnavEphemerisFields {
    fn from(e: GalileoFnavEphemeris) -> Self {
        Self {
            satellite_id: e.satellite_id as i64,
            week_number: e.week_number as i64,
            iod_nav: e.iod_nav as i64,
            sisa: e.sisa as i64,
            idot: e.idot as i64,
            t_oc: e.t_oc as i64,
            a_f2: e.a_f2 as i64,
            a_f1: e.a_f1 as i64,
            a_f0: e.a_f0,
            c_rs: e.c_rs as i64,
            delta_n: e.delta_n as i64,
            m0: e.m0,
            c_uc: e.c_uc as i64,
            eccentricity: e.eccentricity as i64,
            c_us: e.c_us as i64,
            sqrt_a: e.sqrt_a as i64,
            t_oe: e.t_oe as i64,
            c_ic: e.c_ic as i64,
            omega0: e.omega0,
            c_is: e.c_is as i64,
            i0: e.i0,
            c_rc: e.c_rc as i64,
            omega: e.omega,
            omega_dot: e.omega_dot as i64,
            bgd_e5a_e1: e.bgd_e5a_e1 as i64,
            e5a_signal_health: e.e5a_signal_health as i64,
            e5a_data_validity: e.e5a_data_validity,
            reserved: e.reserved as i64,
            trailing_bits: e.trailing_bits,
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct GalileoInavEphemerisFields {
    satellite_id: i64,
    week_number: i64,
    iod_nav: i64,
    sisa_index: i64,
    idot: i64,
    t_oc: i64,
    a_f2: i64,
    a_f1: i64,
    a_f0: i64,
    c_rs: i64,
    delta_n: i64,
    m0: i64,
    c_uc: i64,
    eccentricity: i64,
    c_us: i64,
    sqrt_a: i64,
    t_oe: i64,
    c_ic: i64,
    omega0: i64,
    c_is: i64,
    i0: i64,
    c_rc: i64,
    omega: i64,
    omega_dot: i64,
    bgd_e5a_e1: i64,
    bgd_e5b_e1: i64,
    e5b_signal_health: i64,
    e5b_data_validity: bool,
    e1b_signal_health: i64,
    e1b_data_validity: bool,
    reserved: i64,
    trailing_bits: Vec<bool>,
}

impl From<GalileoInavEphemeris> for GalileoInavEphemerisFields {
    fn from(e: GalileoInavEphemeris) -> Self {
        Self {
            satellite_id: e.satellite_id as i64,
            week_number: e.week_number as i64,
            iod_nav: e.iod_nav as i64,
            sisa_index: e.sisa_index as i64,
            idot: e.idot as i64,
            t_oc: e.t_oc as i64,
            a_f2: e.a_f2 as i64,
            a_f1: e.a_f1 as i64,
            a_f0: e.a_f0,
            c_rs: e.c_rs as i64,
            delta_n: e.delta_n as i64,
            m0: e.m0,
            c_uc: e.c_uc as i64,
            eccentricity: e.eccentricity as i64,
            c_us: e.c_us as i64,
            sqrt_a: e.sqrt_a as i64,
            t_oe: e.t_oe as i64,
            c_ic: e.c_ic as i64,
            omega0: e.omega0,
            c_is: e.c_is as i64,
            i0: e.i0,
            c_rc: e.c_rc as i64,
            omega: e.omega,
            omega_dot: e.omega_dot as i64,
            bgd_e5a_e1: e.bgd_e5a_e1 as i64,
            bgd_e5b_e1: e.bgd_e5b_e1 as i64,
            e5b_signal_health: e.e5b_signal_health as i64,
            e5b_data_validity: e.e5b_data_validity,
            e1b_signal_health: e.e1b_signal_health as i64,
            e1b_data_validity: e.e1b_data_validity,
            reserved: e.reserved as i64,
            trailing_bits: e.trailing_bits,
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct BeidouEphemerisFields {
    satellite_id: i64,
    week_number: i64,
    sv_urai: i64,
    idot: i64,
    aode: i64,
    t_oc: i64,
    a_f2: i64,
    a_f1: i64,
    a_f0: i64,
    aodc: i64,
    c_rs: i64,
    delta_n: i64,
    m0: i64,
    c_uc: i64,
    eccentricity: i64,
    c_us: i64,
    sqrt_a: i64,
    t_oe: i64,
    c_ic: i64,
    omega0: i64,
    c_is: i64,
    i0: i64,
    c_rc: i64,
    omega: i64,
    omega_dot: i64,
    t_gd1: i64,
    t_gd2: i64,
    sv_health: bool,
    trailing_bits: Vec<bool>,
}

impl From<BeidouEphemeris> for BeidouEphemerisFields {
    fn from(e: BeidouEphemeris) -> Self {
        Self {
            satellite_id: e.satellite_id as i64,
            week_number: e.week_number as i64,
            sv_urai: e.sv_urai as i64,
            idot: e.idot as i64,
            aode: e.aode as i64,
            t_oc: e.t_oc as i64,
            a_f2: e.a_f2 as i64,
            a_f1: e.a_f1 as i64,
            a_f0: e.a_f0 as i64,
            aodc: e.aodc as i64,
            c_rs: e.c_rs as i64,
            delta_n: e.delta_n as i64,
            m0: e.m0,
            c_uc: e.c_uc as i64,
            eccentricity: e.eccentricity as i64,
            c_us: e.c_us as i64,
            sqrt_a: e.sqrt_a as i64,
            t_oe: e.t_oe as i64,
            c_ic: e.c_ic as i64,
            omega0: e.omega0,
            c_is: e.c_is as i64,
            i0: e.i0,
            c_rc: e.c_rc as i64,
            omega: e.omega,
            omega_dot: e.omega_dot as i64,
            t_gd1: e.t_gd1 as i64,
            t_gd2: e.t_gd2 as i64,
            sv_health: e.sv_health,
            trailing_bits: e.trailing_bits,
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct QzssEphemerisFields {
    satellite_id: i64,
    t_oc: i64,
    a_f2: i64,
    a_f1: i64,
    a_f0: i64,
    iode: i64,
    c_rs: i64,
    delta_n: i64,
    m0: i64,
    c_uc: i64,
    eccentricity: i64,
    c_us: i64,
    sqrt_a: i64,
    t_oe: i64,
    c_ic: i64,
    omega0: i64,
    c_is: i64,
    i0: i64,
    c_rc: i64,
    omega: i64,
    omega_dot: i64,
    idot: i64,
    codes_on_l2: i64,
    week_number: i64,
    ura: i64,
    sv_health: i64,
    t_gd: i64,
    iodc: i64,
    fit_interval: bool,
    trailing_bits: Vec<bool>,
}

impl From<QzssEphemeris> for QzssEphemerisFields {
    fn from(e: QzssEphemeris) -> Self {
        Self {
            satellite_id: e.satellite_id as i64,
            t_oc: e.t_oc as i64,
            a_f2: e.a_f2 as i64,
            a_f1: e.a_f1 as i64,
            a_f0: e.a_f0 as i64,
            iode: e.iode as i64,
            c_rs: e.c_rs as i64,
            delta_n: e.delta_n as i64,
            m0: e.m0,
            c_uc: e.c_uc as i64,
            eccentricity: e.eccentricity as i64,
            c_us: e.c_us as i64,
            sqrt_a: e.sqrt_a as i64,
            t_oe: e.t_oe as i64,
            c_ic: e.c_ic as i64,
            omega0: e.omega0,
            c_is: e.c_is as i64,
            i0: e.i0,
            c_rc: e.c_rc as i64,
            omega: e.omega,
            omega_dot: e.omega_dot as i64,
            idot: e.idot as i64,
            codes_on_l2: e.codes_on_l2 as i64,
            week_number: e.week_number as i64,
            ura: e.ura as i64,
            sv_health: e.sv_health as i64,
            t_gd: e.t_gd as i64,
            iodc: e.iodc as i64,
            fit_interval: e.fit_interval,
            trailing_bits: e.trailing_bits,
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct GlonassEphemerisFields {
    satellite_id: i64,
    frequency_channel: i64,
    almanac_health: bool,
    almanac_health_availability: bool,
    p1: i64,
    t_k: i64,
    b_n_msb: bool,
    p2: bool,
    t_b: i64,
    xn_dot: i64,
    xn: i64,
    xn_dot_dot: i64,
    yn_dot: i64,
    yn: i64,
    yn_dot_dot: i64,
    zn_dot: i64,
    zn: i64,
    zn_dot_dot: i64,
    p3: bool,
    gamma_n: i64,
    m_p: i64,
    m_l_n_third: bool,
    tau_n: i64,
    delta_tau_n: i64,
    e_n: i64,
    m_p4: bool,
    m_f_t: i64,
    m_n_t: i64,
    m_m: i64,
    additional_data_available: bool,
    n_a: i64,
    tau_c: i64,
    m_n4: i64,
    m_tau_gps: i64,
    m_l_n_fifth: bool,
    reserved: i64,
    trailing_bits: Vec<bool>,
    negative_zero: i64,
}

impl From<GlonassEphemeris> for GlonassEphemerisFields {
    fn from(e: GlonassEphemeris) -> Self {
        Self {
            satellite_id: e.satellite_id as i64,
            frequency_channel: e.frequency_channel as i64,
            almanac_health: e.almanac_health,
            almanac_health_availability: e.almanac_health_availability,
            p1: e.p1 as i64,
            t_k: e.t_k as i64,
            b_n_msb: e.b_n_msb,
            p2: e.p2,
            t_b: e.t_b as i64,
            xn_dot: e.xn_dot as i64,
            xn: e.xn as i64,
            xn_dot_dot: e.xn_dot_dot as i64,
            yn_dot: e.yn_dot as i64,
            yn: e.yn as i64,
            yn_dot_dot: e.yn_dot_dot as i64,
            zn_dot: e.zn_dot as i64,
            zn: e.zn as i64,
            zn_dot_dot: e.zn_dot_dot as i64,
            p3: e.p3,
            gamma_n: e.gamma_n as i64,
            m_p: e.m_p as i64,
            m_l_n_third: e.m_l_n_third,
            tau_n: e.tau_n as i64,
            delta_tau_n: e.delta_tau_n as i64,
            e_n: e.e_n as i64,
            m_p4: e.m_p4,
            m_f_t: e.m_f_t as i64,
            m_n_t: e.m_n_t as i64,
            m_m: e.m_m as i64,
            additional_data_available: e.additional_data_available,
            n_a: e.n_a as i64,
            tau_c: e.tau_c,
            m_n4: e.m_n4 as i64,
            m_tau_gps: e.m_tau_gps as i64,
            m_l_n_fifth: e.m_l_n_fifth,
            reserved: e.reserved as i64,
            trailing_bits: e.trailing_bits,
            negative_zero: i64::from(e.negative_zero),
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct MsmHeaderFields {
    reference_station_id: i64,
    epoch_time: i64,
    multiple_message: bool,
    iods: i64,
    reserved: i64,
    clock_steering: i64,
    external_clock: i64,
    divergence_free_smoothing: bool,
    smoothing_interval: i64,
}

impl From<MsmHeader> for MsmHeaderFields {
    fn from(h: MsmHeader) -> Self {
        Self {
            reference_station_id: h.reference_station_id as i64,
            epoch_time: h.epoch_time as i64,
            multiple_message: h.multiple_message,
            iods: h.iods as i64,
            reserved: h.reserved as i64,
            clock_steering: h.clock_steering as i64,
            external_clock: h.external_clock as i64,
            divergence_free_smoothing: h.divergence_free_smoothing,
            smoothing_interval: h.smoothing_interval as i64,
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct MsmSatelliteFields {
    id: i64,
    rough_range_ms: Option<i64>,
    rough_range_mod1: i64,
    extended_info: Option<i64>,
    rough_phase_range_rate_m_s: Option<i64>,
}

impl From<MsmSatellite> for MsmSatelliteFields {
    fn from(s: MsmSatellite) -> Self {
        Self {
            id: s.id as i64,
            rough_range_ms: s.rough_range_ms.map(i64::from),
            rough_range_mod1: s.rough_range_mod1 as i64,
            extended_info: s.extended_info.map(|v| v as i64),
            rough_phase_range_rate_m_s: s.rough_phase_range_rate_m_s.map(|v| v as i64),
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct MsmSignalFields {
    satellite_id: i64,
    signal_id: i64,
    fine_pseudorange: Option<i64>,
    fine_phase_range: Option<i64>,
    lock_time_indicator: Option<i64>,
    half_cycle_ambiguity: Option<bool>,
    cnr: Option<i64>,
    fine_phase_range_rate: Option<i64>,
}

impl From<MsmSignal> for MsmSignalFields {
    fn from(s: MsmSignal) -> Self {
        Self {
            satellite_id: s.satellite_id as i64,
            signal_id: s.signal_id as i64,
            fine_pseudorange: s.fine_pseudorange.map(i64::from),
            fine_phase_range: s.fine_phase_range.map(i64::from),
            lock_time_indicator: s.lock_time_indicator.map(i64::from),
            half_cycle_ambiguity: s.half_cycle_ambiguity,
            cnr: s.cnr.map(i64::from),
            fine_phase_range_rate: s.fine_phase_range_rate.map(|v| v as i64),
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct MsmMessageFields {
    message_number: i64,
    system: String,
    kind: String,
    header: MsmHeaderFields,
    signal_mask: Option<i64>,
    satellites: Vec<MsmSatelliteFields>,
    signals: Vec<MsmSignalFields>,
    trailing_bits: Vec<bool>,
}

impl From<MsmMessage> for MsmMessageFields {
    fn from(m: MsmMessage) -> Self {
        let kind = match m.kind {
            MsmKind::Msm1 => "msm1",
            MsmKind::Msm2 => "msm2",
            MsmKind::Msm3 => "msm3",
            MsmKind::Msm4 => "msm4",
            MsmKind::Msm5 => "msm5",
            MsmKind::Msm6 => "msm6",
            MsmKind::Msm7 => "msm7",
        };
        Self {
            message_number: m.message_number as i64,
            system: m.system.letter().to_string(),
            kind: kind.to_string(),
            header: m.header.into(),
            signal_mask: Some(i64::from(m.signal_mask)),
            satellites: m.satellites.into_iter().map(Into::into).collect(),
            signals: m.signals.into_iter().map(Into::into).collect(),
            trailing_bits: m.trailing_bits,
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct UnsupportedFields {
    message_number: i64,
    body: Vec<u8>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SsrFields {
    message_number: i64,
    body: Vec<u8>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct NetworkDifferenceRecordFields {
    satellite_id: i64,
    ambiguity_status: i64,
    non_sync_count: i64,
    geometric: Option<i64>,
    iod: Option<i64>,
    ionospheric: Option<i64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct NetworkCorrectionDifferencesFields {
    message_number: i64,
    network_id: i64,
    subnetwork_id: i64,
    epoch_time: i64,
    multiple_message: bool,
    master_station_id: i64,
    auxiliary_station_id: i64,
    satellite_count: i64,
    satellites: Vec<NetworkDifferenceRecordFields>,
    trailing_bits: Vec<bool>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct RotationPointFields {
    x: i64,
    y: i64,
    z: i64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct HelmertTransformationFields {
    message_number: i64,
    source_name: String,
    target_name: String,
    system_id: i64,
    utilized_messages: i64,
    plate_number: i64,
    computation_indicator: i64,
    height_indicator: i64,
    validity_latitude: i64,
    validity_longitude: i64,
    validity_extension_latitude: i64,
    validity_extension_longitude: i64,
    dx: i64,
    dy: i64,
    dz: i64,
    r1: i64,
    r2: i64,
    r3: i64,
    ds: i64,
    rotation_point: Option<RotationPointFields>,
    add_as: i64,
    add_bs: i64,
    add_at: i64,
    add_bt: i64,
    horizontal_quality: i64,
    vertical_quality: i64,
    trailing_bits: Vec<bool>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct GridResidualFields {
    horizontal_1: i64,
    horizontal_2: i64,
    height: i64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ResidualGridFields {
    message_number: i64,
    system_id: i64,
    horizontal_shift: bool,
    vertical_shift: bool,
    origin_1: i64,
    origin_2: i64,
    extension_1: i64,
    extension_2: i64,
    mean_offset_1: i64,
    mean_offset_2: i64,
    mean_height_offset: i64,
    residuals: Vec<GridResidualFields>,
    horizontal_interpolation: i64,
    vertical_interpolation: i64,
    horizontal_quality: i64,
    vertical_quality: i64,
    mjd: i64,
    trailing_bits: Vec<bool>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ProjectionFields {
    message_number: i64,
    system_id: i64,
    projection_type: i64,
    parameter_kind: String,
    latitude: Option<i64>,
    longitude: Option<i64>,
    add_scale: Option<i64>,
    false_easting: Option<i64>,
    false_northing: Option<i64>,
    standard_parallel_1: Option<i64>,
    standard_parallel_2: Option<i64>,
    rectification: Option<bool>,
    azimuth: Option<i64>,
    rectified_to_skew: Option<i64>,
    easting: Option<i64>,
    northing: Option<i64>,
    trailing_bits: Vec<bool>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct NetworkResidualRecordFields {
    satellite_id: i64,
    s_oc: i64,
    s_od: i64,
    s_oh: i64,
    s_lc: i64,
    s_ld: i64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct NetworkResidualsFields {
    message_number: i64,
    epoch_time: i64,
    reference_station_id: i64,
    reference_station_count: i64,
    satellite_count: i64,
    satellites: Vec<NetworkResidualRecordFields>,
    trailing_bits: Vec<bool>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct PhysicalReferenceStationFields {
    message_number: i64,
    non_physical_station_id: i64,
    physical_station_id: i64,
    itrf_realization_year: i64,
    ecef_x: i64,
    ecef_y: i64,
    ecef_z: i64,
    trailing_bits: Vec<bool>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct FkpGradientRecordFields {
    satellite_id: i64,
    iod: i64,
    geometric_north: i64,
    geometric_east: i64,
    ionospheric_north: i64,
    ionospheric_east: i64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct FkpGradientsFields {
    message_number: i64,
    reference_station_id: i64,
    epoch_time: i64,
    satellite_count: i64,
    satellites: Vec<FkpGradientRecordFields>,
    trailing_bits: Vec<bool>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct RtcmEncodeErrorFields {
    variant: String,
    message_number: Option<i64>,
    field: Option<String>,
    value: Option<String>,
    minimum: Option<String>,
    maximum: Option<String>,
    width: Option<i64>,
    encoding: Option<String>,
    record: Option<String>,
    carried: Option<bool>,
    satellite: Option<i64>,
    expected: Option<i64>,
    actual: Option<i64>,
    index: Option<i64>,
    orbit: Option<i64>,
    clock: Option<i64>,
    orbit_satellite: Option<i64>,
    clock_satellite: Option<i64>,
    c1: Option<i64>,
    c2: Option<i64>,
    signal: Option<i64>,
    mask: Option<i64>,
    problem: Option<String>,
    count: Option<i64>,
    detail: Option<String>,
    trailing_bits: Option<Vec<bool>>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct RtcmConversionErrorFields {
    variant: String,
    nested_variant: Option<String>,
    message_number: Option<i64>,
    field: Option<String>,
    value: Option<i64>,
    width: Option<i64>,
    index: Option<i64>,
    system: Option<String>,
    full_week: Option<i64>,
    week: Option<i64>,
    broadcast_prn: Option<i64>,
    satellite: Option<String>,
    reason: Option<String>,
    decoded_week: Option<i64>,
    fit_interval_flag: Option<i64>,
    iode: Option<i64>,
    iodc: Option<i64>,
    vtec: Option<VtecEvaluationErrorFields>,
    detail: Option<String>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct MessageAnnouncementFields {
    message_number: i64,
    synchronous: bool,
    interval: i64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SystemParametersFields {
    message_number: i64,
    reference_station_id: i64,
    mjd: i64,
    seconds_of_day: i64,
    announcement_count: i64,
    leap_seconds: i64,
    announcements: Vec<MessageAnnouncementFields>,
    trailing_bits: Vec<bool>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TextMessageFields {
    message_number: i64,
    reference_station_id: i64,
    mjd: i64,
    seconds_of_day: i64,
    character_count: i64,
    code_units: Vec<u8>,
    trailing_bits: Vec<bool>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct NetworkAuxiliaryStationFields {
    message_number: i64,
    network_id: i64,
    subnetwork_id: i64,
    auxiliary_station_count: i64,
    master_station_id: i64,
    auxiliary_station_id: i64,
    delta_latitude: i64,
    delta_longitude: i64,
    delta_height: i64,
    trailing_bits: Vec<bool>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct GlonassCodePhaseBiasesFields {
    message_number: i64,
    reference_station_id: i64,
    aligned: bool,
    reserved: i64,
    l1_ca: Option<i64>,
    l1_p: Option<i64>,
    l2_ca: Option<i64>,
    l2_p: Option<i64>,
    trailing_bits: Vec<bool>,
}

impl From<SystemParameters> for SystemParametersFields {
    fn from(message: SystemParameters) -> Self {
        Self {
            message_number: 1013,
            reference_station_id: i64::from(message.reference_station_id),
            mjd: i64::from(message.mjd),
            seconds_of_day: i64::from(message.seconds_of_day),
            announcement_count: i64::from(message.announcement_count),
            leap_seconds: i64::from(message.leap_seconds),
            announcements: message
                .announcements
                .into_iter()
                .map(|announcement| MessageAnnouncementFields {
                    message_number: i64::from(announcement.message_number),
                    synchronous: announcement.synchronous,
                    interval: i64::from(announcement.interval),
                })
                .collect(),
            trailing_bits: message.trailing_bits,
        }
    }
}

impl From<TextMessage> for TextMessageFields {
    fn from(message: TextMessage) -> Self {
        Self {
            message_number: 1029,
            reference_station_id: i64::from(message.reference_station_id),
            mjd: i64::from(message.mjd),
            seconds_of_day: i64::from(message.seconds_of_day),
            character_count: i64::from(message.character_count),
            code_units: message.code_units,
            trailing_bits: message.trailing_bits,
        }
    }
}

impl From<NetworkAuxiliaryStation> for NetworkAuxiliaryStationFields {
    fn from(message: NetworkAuxiliaryStation) -> Self {
        Self {
            message_number: 1014,
            network_id: i64::from(message.network_id),
            subnetwork_id: i64::from(message.subnetwork_id),
            auxiliary_station_count: i64::from(message.auxiliary_station_count),
            master_station_id: i64::from(message.master_station_id),
            auxiliary_station_id: i64::from(message.auxiliary_station_id),
            delta_latitude: i64::from(message.delta_latitude),
            delta_longitude: i64::from(message.delta_longitude),
            delta_height: i64::from(message.delta_height),
            trailing_bits: message.trailing_bits,
        }
    }
}

impl From<NetworkCorrectionDifferences> for NetworkCorrectionDifferencesFields {
    fn from(message: NetworkCorrectionDifferences) -> Self {
        Self {
            message_number: i64::from(message.message_number),
            network_id: i64::from(message.network_id),
            subnetwork_id: i64::from(message.subnetwork_id),
            epoch_time: i64::from(message.epoch_time),
            multiple_message: message.multiple_message,
            master_station_id: i64::from(message.master_station_id),
            auxiliary_station_id: i64::from(message.auxiliary_station_id),
            satellite_count: i64::from(message.satellite_count),
            satellites: message
                .satellites
                .into_iter()
                .map(|record| NetworkDifferenceRecordFields {
                    satellite_id: i64::from(record.satellite_id),
                    ambiguity_status: i64::from(record.ambiguity_status),
                    non_sync_count: i64::from(record.non_sync_count),
                    geometric: record.geometric.map(i64::from),
                    iod: record.iod.map(i64::from),
                    ionospheric: record.ionospheric.map(i64::from),
                })
                .collect(),
            trailing_bits: message.trailing_bits,
        }
    }
}

impl From<HelmertTransformation> for HelmertTransformationFields {
    fn from(message: HelmertTransformation) -> Self {
        Self {
            message_number: i64::from(message.message_number),
            source_name: message.source_name,
            target_name: message.target_name,
            system_id: i64::from(message.system_id),
            utilized_messages: i64::from(message.utilized_messages),
            plate_number: i64::from(message.plate_number),
            computation_indicator: i64::from(message.computation_indicator),
            height_indicator: i64::from(message.height_indicator),
            validity_latitude: i64::from(message.validity_latitude),
            validity_longitude: i64::from(message.validity_longitude),
            validity_extension_latitude: i64::from(message.validity_extension_latitude),
            validity_extension_longitude: i64::from(message.validity_extension_longitude),
            dx: i64::from(message.dx),
            dy: i64::from(message.dy),
            dz: i64::from(message.dz),
            r1: i64::from(message.r1),
            r2: i64::from(message.r2),
            r3: i64::from(message.r3),
            ds: i64::from(message.ds),
            rotation_point: message.rotation_point.map(|point| RotationPointFields {
                x: point.x,
                y: point.y,
                z: point.z,
            }),
            add_as: i64::from(message.add_as),
            add_bs: i64::from(message.add_bs),
            add_at: i64::from(message.add_at),
            add_bt: i64::from(message.add_bt),
            horizontal_quality: i64::from(message.horizontal_quality),
            vertical_quality: i64::from(message.vertical_quality),
            trailing_bits: message.trailing_bits,
        }
    }
}

impl From<ResidualGrid> for ResidualGridFields {
    fn from(message: ResidualGrid) -> Self {
        Self {
            message_number: i64::from(message.message_number),
            system_id: i64::from(message.system_id),
            horizontal_shift: message.horizontal_shift,
            vertical_shift: message.vertical_shift,
            origin_1: i64::from(message.origin_1),
            origin_2: i64::from(message.origin_2),
            extension_1: i64::from(message.extension_1),
            extension_2: i64::from(message.extension_2),
            mean_offset_1: i64::from(message.mean_offset_1),
            mean_offset_2: i64::from(message.mean_offset_2),
            mean_height_offset: i64::from(message.mean_height_offset),
            residuals: message
                .residuals
                .into_iter()
                .map(|record| GridResidualFields {
                    horizontal_1: i64::from(record.horizontal_1),
                    horizontal_2: i64::from(record.horizontal_2),
                    height: i64::from(record.height),
                })
                .collect(),
            horizontal_interpolation: i64::from(message.horizontal_interpolation),
            vertical_interpolation: i64::from(message.vertical_interpolation),
            horizontal_quality: i64::from(message.horizontal_quality),
            vertical_quality: i64::from(message.vertical_quality),
            mjd: i64::from(message.mjd),
            trailing_bits: message.trailing_bits,
        }
    }
}

impl From<Projection> for ProjectionFields {
    fn from(message: Projection) -> Self {
        let mut fields = Self {
            message_number: i64::from(message.message_number()),
            system_id: i64::from(message.system_id),
            projection_type: i64::from(message.projection_type),
            parameter_kind: String::new(),
            latitude: None,
            longitude: None,
            add_scale: None,
            false_easting: None,
            false_northing: None,
            standard_parallel_1: None,
            standard_parallel_2: None,
            rectification: None,
            azimuth: None,
            rectified_to_skew: None,
            easting: None,
            northing: None,
            trailing_bits: message.trailing_bits,
        };
        match message.parameters {
            ProjectionParameters::NaturalOrigin {
                latitude,
                longitude,
                add_scale,
                false_easting,
                false_northing,
            } => {
                fields.parameter_kind = "natural_origin".into();
                fields.latitude = Some(latitude);
                fields.longitude = Some(longitude);
                fields.add_scale = Some(i64::from(add_scale));
                fields.false_easting = Some(false_easting as i64);
                fields.false_northing = Some(false_northing);
            }
            ProjectionParameters::LambertConicConformal {
                latitude,
                longitude,
                standard_parallel_1,
                standard_parallel_2,
                false_easting,
                false_northing,
            } => {
                fields.parameter_kind = "lambert_conic_conformal".into();
                fields.latitude = Some(latitude);
                fields.longitude = Some(longitude);
                fields.standard_parallel_1 = Some(standard_parallel_1);
                fields.standard_parallel_2 = Some(standard_parallel_2);
                fields.false_easting = Some(false_easting as i64);
                fields.false_northing = Some(false_northing);
            }
            ProjectionParameters::ObliqueMercator {
                rectification,
                latitude,
                longitude,
                azimuth,
                rectified_to_skew,
                add_scale,
                easting,
                northing,
            } => {
                fields.parameter_kind = "oblique_mercator".into();
                fields.rectification = Some(rectification);
                fields.latitude = Some(latitude);
                fields.longitude = Some(longitude);
                fields.azimuth = Some(azimuth as i64);
                fields.rectified_to_skew = Some(i64::from(rectified_to_skew));
                fields.add_scale = Some(i64::from(add_scale));
                fields.easting = Some(easting as i64);
                fields.northing = Some(northing);
            }
        }
        fields
    }
}

impl From<NetworkResiduals> for NetworkResidualsFields {
    fn from(message: NetworkResiduals) -> Self {
        Self {
            message_number: i64::from(message.message_number),
            epoch_time: i64::from(message.epoch_time),
            reference_station_id: i64::from(message.reference_station_id),
            reference_station_count: i64::from(message.reference_station_count),
            satellite_count: i64::from(message.satellite_count),
            satellites: message
                .satellites
                .into_iter()
                .map(|record| NetworkResidualRecordFields {
                    satellite_id: i64::from(record.satellite_id),
                    s_oc: i64::from(record.s_oc),
                    s_od: i64::from(record.s_od),
                    s_oh: i64::from(record.s_oh),
                    s_lc: i64::from(record.s_lc),
                    s_ld: i64::from(record.s_ld),
                })
                .collect(),
            trailing_bits: message.trailing_bits,
        }
    }
}

impl From<PhysicalReferenceStation> for PhysicalReferenceStationFields {
    fn from(message: PhysicalReferenceStation) -> Self {
        Self {
            message_number: 1032,
            non_physical_station_id: i64::from(message.non_physical_station_id),
            physical_station_id: i64::from(message.physical_station_id),
            itrf_realization_year: i64::from(message.itrf_realization_year),
            ecef_x: message.ecef_x,
            ecef_y: message.ecef_y,
            ecef_z: message.ecef_z,
            trailing_bits: message.trailing_bits,
        }
    }
}

impl From<FkpGradients> for FkpGradientsFields {
    fn from(message: FkpGradients) -> Self {
        Self {
            message_number: i64::from(message.message_number),
            reference_station_id: i64::from(message.reference_station_id),
            epoch_time: i64::from(message.epoch_time),
            satellite_count: i64::from(message.satellite_count),
            satellites: message
                .satellites
                .into_iter()
                .map(|record| FkpGradientRecordFields {
                    satellite_id: i64::from(record.satellite_id),
                    iod: i64::from(record.iod),
                    geometric_north: i64::from(record.geometric_north),
                    geometric_east: i64::from(record.geometric_east),
                    ionospheric_north: i64::from(record.ionospheric_north),
                    ionospheric_east: i64::from(record.ionospheric_east),
                })
                .collect(),
            trailing_bits: message.trailing_bits,
        }
    }
}

impl From<GlonassCodePhaseBiases> for GlonassCodePhaseBiasesFields {
    fn from(message: GlonassCodePhaseBiases) -> Self {
        Self {
            message_number: 1230,
            reference_station_id: i64::from(message.reference_station_id),
            aligned: message.aligned,
            reserved: i64::from(message.reserved),
            l1_ca: message.l1_ca.map(i64::from),
            l1_p: message.l1_p.map(i64::from),
            l2_ca: message.l2_ca.map(i64::from),
            l2_p: message.l2_p.map(i64::from),
            trailing_bits: message.trailing_bits,
        }
    }
}

fn checked_rtcm_integer<T>(value: i64, field: &str) -> NifResult<T>
where
    T: TryFrom<i64>,
{
    T::try_from(value).map_err(|_| Error::Term(Box::new(format!("invalid RTCM {field}"))))
}

fn required_projection_value(value: Option<i64>, field: &str) -> NifResult<i64> {
    value.ok_or_else(|| Error::Term(Box::new(format!("projection field {field} is required"))))
}

fn build_network_correction_differences(
    fields: NetworkCorrectionDifferencesFields,
) -> NifResult<NetworkCorrectionDifferences> {
    let satellites = fields
        .satellites
        .into_iter()
        .map(|record| {
            Ok(NetworkCorrectionDifference {
                satellite_id: checked_rtcm_integer(record.satellite_id, "satellite id")?,
                ambiguity_status: checked_rtcm_integer(
                    record.ambiguity_status,
                    "ambiguity status",
                )?,
                non_sync_count: checked_rtcm_integer(record.non_sync_count, "non-sync count")?,
                geometric: record
                    .geometric
                    .map(|value| checked_rtcm_integer(value, "geometric correction"))
                    .transpose()?,
                iod: record
                    .iod
                    .map(|value| checked_rtcm_integer(value, "issue of data"))
                    .transpose()?,
                ionospheric: record
                    .ionospheric
                    .map(|value| checked_rtcm_integer(value, "ionospheric correction"))
                    .transpose()?,
            })
        })
        .collect::<NifResult<Vec<_>>>()?;
    Ok(NetworkCorrectionDifferences {
        message_number: checked_rtcm_integer(fields.message_number, "message number")?,
        network_id: checked_rtcm_integer(fields.network_id, "network id")?,
        subnetwork_id: checked_rtcm_integer(fields.subnetwork_id, "subnetwork id")?,
        epoch_time: checked_rtcm_integer(fields.epoch_time, "epoch time")?,
        multiple_message: fields.multiple_message,
        master_station_id: checked_rtcm_integer(fields.master_station_id, "master station id")?,
        auxiliary_station_id: checked_rtcm_integer(
            fields.auxiliary_station_id,
            "auxiliary station id",
        )?,
        satellite_count: checked_rtcm_integer(fields.satellite_count, "satellite count")?,
        satellites,
        trailing_bits: fields.trailing_bits,
    })
}

fn build_helmert_transformation(
    fields: HelmertTransformationFields,
) -> NifResult<HelmertTransformation> {
    Ok(HelmertTransformation {
        message_number: checked_rtcm_integer(fields.message_number, "message number")?,
        source_name: fields.source_name,
        target_name: fields.target_name,
        system_id: checked_rtcm_integer(fields.system_id, "system id")?,
        utilized_messages: checked_rtcm_integer(fields.utilized_messages, "utilized messages")?,
        plate_number: checked_rtcm_integer(fields.plate_number, "plate number")?,
        computation_indicator: checked_rtcm_integer(
            fields.computation_indicator,
            "computation indicator",
        )?,
        height_indicator: checked_rtcm_integer(fields.height_indicator, "height indicator")?,
        validity_latitude: checked_rtcm_integer(fields.validity_latitude, "validity latitude")?,
        validity_longitude: checked_rtcm_integer(fields.validity_longitude, "validity longitude")?,
        validity_extension_latitude: checked_rtcm_integer(
            fields.validity_extension_latitude,
            "latitude extension",
        )?,
        validity_extension_longitude: checked_rtcm_integer(
            fields.validity_extension_longitude,
            "longitude extension",
        )?,
        dx: checked_rtcm_integer(fields.dx, "dx")?,
        dy: checked_rtcm_integer(fields.dy, "dy")?,
        dz: checked_rtcm_integer(fields.dz, "dz")?,
        r1: checked_rtcm_integer(fields.r1, "r1")?,
        r2: checked_rtcm_integer(fields.r2, "r2")?,
        r3: checked_rtcm_integer(fields.r3, "r3")?,
        ds: checked_rtcm_integer(fields.ds, "scale correction")?,
        rotation_point: fields.rotation_point.map(|point| RotationPoint {
            x: point.x,
            y: point.y,
            z: point.z,
        }),
        add_as: checked_rtcm_integer(fields.add_as, "source semi-major axis")?,
        add_bs: checked_rtcm_integer(fields.add_bs, "source semi-minor axis")?,
        add_at: checked_rtcm_integer(fields.add_at, "target semi-major axis")?,
        add_bt: checked_rtcm_integer(fields.add_bt, "target semi-minor axis")?,
        horizontal_quality: checked_rtcm_integer(fields.horizontal_quality, "horizontal quality")?,
        vertical_quality: checked_rtcm_integer(fields.vertical_quality, "vertical quality")?,
        trailing_bits: fields.trailing_bits,
    })
}

fn build_residual_grid(fields: ResidualGridFields) -> NifResult<ResidualGrid> {
    let residuals = fields
        .residuals
        .into_iter()
        .map(|record| {
            Ok(GridResidual {
                horizontal_1: checked_rtcm_integer(record.horizontal_1, "grid horizontal 1")?,
                horizontal_2: checked_rtcm_integer(record.horizontal_2, "grid horizontal 2")?,
                height: checked_rtcm_integer(record.height, "grid height")?,
            })
        })
        .collect::<NifResult<Vec<_>>>()?;
    let residuals = residuals
        .try_into()
        .map_err(|_| Error::Term(Box::new("RTCM residual grid requires exactly 16 points")))?;
    Ok(ResidualGrid {
        message_number: checked_rtcm_integer(fields.message_number, "message number")?,
        system_id: checked_rtcm_integer(fields.system_id, "system id")?,
        horizontal_shift: fields.horizontal_shift,
        vertical_shift: fields.vertical_shift,
        origin_1: checked_rtcm_integer(fields.origin_1, "origin 1")?,
        origin_2: checked_rtcm_integer(fields.origin_2, "origin 2")?,
        extension_1: checked_rtcm_integer(fields.extension_1, "extension 1")?,
        extension_2: checked_rtcm_integer(fields.extension_2, "extension 2")?,
        mean_offset_1: checked_rtcm_integer(fields.mean_offset_1, "mean offset 1")?,
        mean_offset_2: checked_rtcm_integer(fields.mean_offset_2, "mean offset 2")?,
        mean_height_offset: checked_rtcm_integer(fields.mean_height_offset, "mean height offset")?,
        residuals,
        horizontal_interpolation: checked_rtcm_integer(
            fields.horizontal_interpolation,
            "horizontal interpolation",
        )?,
        vertical_interpolation: checked_rtcm_integer(
            fields.vertical_interpolation,
            "vertical interpolation",
        )?,
        horizontal_quality: checked_rtcm_integer(fields.horizontal_quality, "horizontal quality")?,
        vertical_quality: checked_rtcm_integer(fields.vertical_quality, "vertical quality")?,
        mjd: checked_rtcm_integer(fields.mjd, "MJD")?,
        trailing_bits: fields.trailing_bits,
    })
}

fn build_projection(fields: ProjectionFields) -> NifResult<Projection> {
    let parameters = match fields.parameter_kind.as_str() {
        "natural_origin" => ProjectionParameters::NaturalOrigin {
            latitude: required_projection_value(fields.latitude, "latitude")?,
            longitude: required_projection_value(fields.longitude, "longitude")?,
            add_scale: checked_rtcm_integer(
                required_projection_value(fields.add_scale, "add_scale")?,
                "add_scale",
            )?,
            false_easting: checked_rtcm_integer(
                required_projection_value(fields.false_easting, "false_easting")?,
                "false_easting",
            )?,
            false_northing: required_projection_value(fields.false_northing, "false_northing")?,
        },
        "lambert_conic_conformal" => ProjectionParameters::LambertConicConformal {
            latitude: required_projection_value(fields.latitude, "latitude")?,
            longitude: required_projection_value(fields.longitude, "longitude")?,
            standard_parallel_1: required_projection_value(
                fields.standard_parallel_1,
                "standard_parallel_1",
            )?,
            standard_parallel_2: required_projection_value(
                fields.standard_parallel_2,
                "standard_parallel_2",
            )?,
            false_easting: checked_rtcm_integer(
                required_projection_value(fields.false_easting, "false_easting")?,
                "false_easting",
            )?,
            false_northing: required_projection_value(fields.false_northing, "false_northing")?,
        },
        "oblique_mercator" => ProjectionParameters::ObliqueMercator {
            rectification: fields.rectification.ok_or_else(|| {
                Error::Term(Box::new("projection field rectification is required"))
            })?,
            latitude: required_projection_value(fields.latitude, "latitude")?,
            longitude: required_projection_value(fields.longitude, "longitude")?,
            azimuth: checked_rtcm_integer(
                required_projection_value(fields.azimuth, "azimuth")?,
                "azimuth",
            )?,
            rectified_to_skew: checked_rtcm_integer(
                required_projection_value(fields.rectified_to_skew, "rectified_to_skew")?,
                "rectified_to_skew",
            )?,
            add_scale: checked_rtcm_integer(
                required_projection_value(fields.add_scale, "add_scale")?,
                "add_scale",
            )?,
            easting: checked_rtcm_integer(
                required_projection_value(fields.easting, "easting")?,
                "easting",
            )?,
            northing: required_projection_value(fields.northing, "northing")?,
        },
        _ => return Err(Error::Term(Box::new("invalid projection parameter_kind"))),
    };
    let message = Projection {
        system_id: checked_rtcm_integer(fields.system_id, "system id")?,
        projection_type: checked_rtcm_integer(fields.projection_type, "projection type")?,
        parameters,
        trailing_bits: fields.trailing_bits,
    };
    if i64::from(message.message_number()) != fields.message_number {
        return Err(Error::Term(Box::new(
            "projection message number does not match parameter_kind",
        )));
    }
    Ok(message)
}

fn build_network_residuals(fields: NetworkResidualsFields) -> NifResult<NetworkResiduals> {
    Ok(NetworkResiduals {
        message_number: checked_rtcm_integer(fields.message_number, "message number")?,
        epoch_time: checked_rtcm_integer(fields.epoch_time, "epoch time")?,
        reference_station_id: checked_rtcm_integer(
            fields.reference_station_id,
            "reference station id",
        )?,
        reference_station_count: checked_rtcm_integer(
            fields.reference_station_count,
            "reference station count",
        )?,
        satellite_count: checked_rtcm_integer(fields.satellite_count, "satellite count")?,
        satellites: fields
            .satellites
            .into_iter()
            .map(|record| {
                Ok(NetworkResidual {
                    satellite_id: checked_rtcm_integer(record.satellite_id, "satellite id")?,
                    s_oc: checked_rtcm_integer(record.s_oc, "s_oc")?,
                    s_od: checked_rtcm_integer(record.s_od, "s_od")?,
                    s_oh: checked_rtcm_integer(record.s_oh, "s_oh")?,
                    s_lc: checked_rtcm_integer(record.s_lc, "s_lc")?,
                    s_ld: checked_rtcm_integer(record.s_ld, "s_ld")?,
                })
            })
            .collect::<NifResult<_>>()?,
        trailing_bits: fields.trailing_bits,
    })
}

fn build_physical_reference_station(
    fields: PhysicalReferenceStationFields,
) -> NifResult<PhysicalReferenceStation> {
    if fields.message_number != 1032 {
        return Err(Error::Term(Box::new(
            "physical-reference-station message number must be 1032",
        )));
    }
    Ok(PhysicalReferenceStation {
        non_physical_station_id: checked_rtcm_integer(
            fields.non_physical_station_id,
            "non-physical station id",
        )?,
        physical_station_id: checked_rtcm_integer(
            fields.physical_station_id,
            "physical station id",
        )?,
        itrf_realization_year: checked_rtcm_integer(
            fields.itrf_realization_year,
            "ITRF realization year",
        )?,
        ecef_x: fields.ecef_x,
        ecef_y: fields.ecef_y,
        ecef_z: fields.ecef_z,
        trailing_bits: fields.trailing_bits,
    })
}

fn build_fkp_gradients(fields: FkpGradientsFields) -> NifResult<FkpGradients> {
    Ok(FkpGradients {
        message_number: checked_rtcm_integer(fields.message_number, "message number")?,
        reference_station_id: checked_rtcm_integer(
            fields.reference_station_id,
            "reference station id",
        )?,
        epoch_time: checked_rtcm_integer(fields.epoch_time, "epoch time")?,
        satellite_count: checked_rtcm_integer(fields.satellite_count, "satellite count")?,
        satellites: fields
            .satellites
            .into_iter()
            .map(|record| {
                Ok(FkpGradient {
                    satellite_id: checked_rtcm_integer(record.satellite_id, "satellite id")?,
                    iod: checked_rtcm_integer(record.iod, "issue of data")?,
                    geometric_north: checked_rtcm_integer(
                        record.geometric_north,
                        "geometric north",
                    )?,
                    geometric_east: checked_rtcm_integer(record.geometric_east, "geometric east")?,
                    ionospheric_north: checked_rtcm_integer(
                        record.ionospheric_north,
                        "ionospheric north",
                    )?,
                    ionospheric_east: checked_rtcm_integer(
                        record.ionospheric_east,
                        "ionospheric east",
                    )?,
                })
            })
            .collect::<NifResult<_>>()?,
        trailing_bits: fields.trailing_bits,
    })
}

fn checked_system_parameters(fields: SystemParametersFields) -> NifResult<SystemParameters> {
    fn checked<T>(value: i64) -> NifResult<T>
    where
        T: TryFrom<i64>,
    {
        T::try_from(value).map_err(|_| Error::Term(Box::new("invalid system-parameters field")))
    }
    if fields.message_number != 1013 {
        return Err(Error::Term(Box::new(
            "system-parameters message number must be 1013",
        )));
    }
    Ok(SystemParameters {
        reference_station_id: checked(fields.reference_station_id)?,
        mjd: checked(fields.mjd)?,
        seconds_of_day: checked(fields.seconds_of_day)?,
        announcement_count: checked(fields.announcement_count)?,
        leap_seconds: checked(fields.leap_seconds)?,
        announcements: fields
            .announcements
            .into_iter()
            .map(|announcement| {
                Ok(MessageAnnouncement {
                    message_number: checked(announcement.message_number)?,
                    synchronous: announcement.synchronous,
                    interval: checked(announcement.interval)?,
                })
            })
            .collect::<NifResult<_>>()?,
        trailing_bits: fields.trailing_bits,
    })
}

fn checked_text_message(fields: TextMessageFields) -> NifResult<TextMessage> {
    fn checked<T>(value: i64) -> NifResult<T>
    where
        T: TryFrom<i64>,
    {
        T::try_from(value).map_err(|_| Error::Term(Box::new("invalid text-message field")))
    }
    if fields.message_number != 1029 {
        return Err(Error::Term(Box::new("text message number must be 1029")));
    }
    Ok(TextMessage {
        reference_station_id: checked(fields.reference_station_id)?,
        mjd: checked(fields.mjd)?,
        seconds_of_day: checked(fields.seconds_of_day)?,
        character_count: checked(fields.character_count)?,
        code_units: fields.code_units,
        trailing_bits: fields.trailing_bits,
    })
}

fn checked_network_auxiliary_station(
    fields: NetworkAuxiliaryStationFields,
) -> NifResult<NetworkAuxiliaryStation> {
    fn checked<T>(value: i64) -> NifResult<T>
    where
        T: TryFrom<i64>,
    {
        T::try_from(value).map_err(|_| Error::Term(Box::new("invalid network-auxiliary field")))
    }
    if fields.message_number != 1014 {
        return Err(Error::Term(Box::new(
            "network-auxiliary message number must be 1014",
        )));
    }
    Ok(NetworkAuxiliaryStation {
        network_id: checked(fields.network_id)?,
        subnetwork_id: checked(fields.subnetwork_id)?,
        auxiliary_station_count: checked(fields.auxiliary_station_count)?,
        master_station_id: checked(fields.master_station_id)?,
        auxiliary_station_id: checked(fields.auxiliary_station_id)?,
        delta_latitude: checked(fields.delta_latitude)?,
        delta_longitude: checked(fields.delta_longitude)?,
        delta_height: checked(fields.delta_height)?,
        trailing_bits: fields.trailing_bits,
    })
}

fn checked_glonass_code_phase_biases(
    fields: GlonassCodePhaseBiasesFields,
) -> NifResult<GlonassCodePhaseBiases> {
    fn checked<T>(value: i64) -> NifResult<T>
    where
        T: TryFrom<i64>,
    {
        T::try_from(value).map_err(|_| Error::Term(Box::new("invalid GLONASS bias field")))
    }
    if fields.message_number != 1230 {
        return Err(Error::Term(Box::new(
            "GLONASS bias message number must be 1230",
        )));
    }
    Ok(GlonassCodePhaseBiases {
        reference_station_id: checked(fields.reference_station_id)?,
        aligned: fields.aligned,
        reserved: checked(fields.reserved)?,
        l1_ca: fields.l1_ca.map(checked).transpose()?,
        l1_p: fields.l1_p.map(checked).transpose()?,
        l2_ca: fields.l2_ca.map(checked).transpose()?,
        l2_p: fields.l2_p.map(checked).transpose()?,
        trailing_bits: fields.trailing_bits,
    })
}

#[derive(Debug, Clone, rustler::NifMap)]
struct LegacyL1Fields {
    code_indicator: bool,
    pseudorange: i64,
    phase_range_minus_pseudorange: i64,
    lock_time_indicator: i64,
    pseudorange_modulus_ambiguity: Option<i64>,
    cnr: Option<i64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct LegacyL2Fields {
    code_indicator: i64,
    pseudorange_difference: i64,
    phase_range_minus_l1_pseudorange: i64,
    lock_time_indicator: i64,
    cnr: Option<i64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct LegacySatelliteFields {
    satellite_id: i64,
    frequency_channel: Option<i64>,
    l1: LegacyL1Fields,
    l2: Option<LegacyL2Fields>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct LegacyObservationsFields {
    message_number: i64,
    reference_station_id: i64,
    epoch_time: i64,
    synchronous_gnss: bool,
    satellite_count: i64,
    divergence_free_smoothing: bool,
    smoothing_interval: i64,
    satellites: Vec<LegacySatelliteFields>,
    trailing_bits: Vec<bool>,
}

impl From<LegacyObservations> for LegacyObservationsFields {
    fn from(message: LegacyObservations) -> Self {
        Self {
            message_number: i64::from(message.message_number),
            reference_station_id: i64::from(message.reference_station_id),
            epoch_time: i64::from(message.epoch_time),
            synchronous_gnss: message.synchronous_gnss,
            satellite_count: i64::from(message.satellite_count),
            divergence_free_smoothing: message.divergence_free_smoothing,
            smoothing_interval: i64::from(message.smoothing_interval),
            satellites: message
                .satellites
                .into_iter()
                .map(|satellite| LegacySatelliteFields {
                    satellite_id: i64::from(satellite.satellite_id),
                    frequency_channel: satellite.frequency_channel.map(i64::from),
                    l1: LegacyL1Fields {
                        code_indicator: satellite.l1.code_indicator,
                        pseudorange: i64::from(satellite.l1.pseudorange),
                        phase_range_minus_pseudorange: i64::from(
                            satellite.l1.phase_range_minus_pseudorange,
                        ),
                        lock_time_indicator: i64::from(satellite.l1.lock_time_indicator),
                        pseudorange_modulus_ambiguity: satellite
                            .l1
                            .pseudorange_modulus_ambiguity
                            .map(i64::from),
                        cnr: satellite.l1.cnr.map(i64::from),
                    },
                    l2: satellite.l2.map(|l2| LegacyL2Fields {
                        code_indicator: i64::from(l2.code_indicator),
                        pseudorange_difference: i64::from(l2.pseudorange_difference),
                        phase_range_minus_l1_pseudorange: i64::from(
                            l2.phase_range_minus_l1_pseudorange,
                        ),
                        lock_time_indicator: i64::from(l2.lock_time_indicator),
                        cnr: l2.cnr.map(i64::from),
                    }),
                })
                .collect(),
            trailing_bits: message.trailing_bits,
        }
    }
}

fn checked_legacy_fields(fields: LegacyObservationsFields) -> NifResult<LegacyObservations> {
    macro_rules! checked {
        ($value:expr, $type:ty) => {
            <$type>::try_from($value)
                .map_err(|_| Error::Term(Box::new("invalid legacy observation field")))
        };
    }
    Ok(LegacyObservations {
        message_number: checked!(fields.message_number, u16)?,
        reference_station_id: checked!(fields.reference_station_id, u16)?,
        epoch_time: checked!(fields.epoch_time, u32)?,
        synchronous_gnss: fields.synchronous_gnss,
        satellite_count: checked!(fields.satellite_count, u8)?,
        divergence_free_smoothing: fields.divergence_free_smoothing,
        smoothing_interval: checked!(fields.smoothing_interval, u8)?,
        satellites: fields
            .satellites
            .into_iter()
            .map(|satellite| -> NifResult<LegacySatellite> {
                Ok(LegacySatellite {
                    satellite_id: checked!(satellite.satellite_id, u8)?,
                    frequency_channel: satellite
                        .frequency_channel
                        .map(|value| checked!(value, u8))
                        .transpose()?,
                    l1: LegacyL1 {
                        code_indicator: satellite.l1.code_indicator,
                        pseudorange: checked!(satellite.l1.pseudorange, u32)?,
                        phase_range_minus_pseudorange: checked!(
                            satellite.l1.phase_range_minus_pseudorange,
                            i32
                        )?,
                        lock_time_indicator: checked!(satellite.l1.lock_time_indicator, u8)?,
                        pseudorange_modulus_ambiguity: satellite
                            .l1
                            .pseudorange_modulus_ambiguity
                            .map(|value| checked!(value, u8))
                            .transpose()?,
                        cnr: satellite
                            .l1
                            .cnr
                            .map(|value| checked!(value, u8))
                            .transpose()?,
                    },
                    l2: satellite
                        .l2
                        .map(|l2| -> NifResult<LegacyL2> {
                            Ok(LegacyL2 {
                                code_indicator: checked!(l2.code_indicator, u8)?,
                                pseudorange_difference: checked!(l2.pseudorange_difference, i16)?,
                                phase_range_minus_l1_pseudorange: checked!(
                                    l2.phase_range_minus_l1_pseudorange,
                                    i32
                                )?,
                                lock_time_indicator: checked!(l2.lock_time_indicator, u8)?,
                                cnr: l2.cnr.map(|value| checked!(value, u8)).transpose()?,
                            })
                        })
                        .transpose()?,
                })
            })
            .collect::<NifResult<_>>()?,
        trailing_bits: fields.trailing_bits,
    })
}

#[derive(Debug, Clone, rustler::NifMap)]
struct NavicEphemerisFields {
    satellite_id: i64,
    week_number: i64,
    a_f0: i64,
    a_f1: i64,
    a_f2: i64,
    ura: i64,
    t_oc: i64,
    t_gd: i64,
    delta_n: i64,
    iodec: i64,
    reserved: i64,
    l5_flag: bool,
    s_flag: bool,
    c_uc: i64,
    c_us: i64,
    c_ic: i64,
    c_is: i64,
    c_rc: i64,
    c_rs: i64,
    idot: i64,
    m0: i64,
    t_oe: i64,
    eccentricity: i64,
    sqrt_a: i64,
    omega0: i64,
    omega: i64,
    omega_dot: i64,
    i0: i64,
    spare_df544: i64,
    spare_df545: i64,
    trailing_bits: Vec<bool>,
}

impl From<NavicEphemeris> for NavicEphemerisFields {
    fn from(ephemeris: NavicEphemeris) -> Self {
        Self {
            satellite_id: i64::from(ephemeris.satellite_id),
            week_number: i64::from(ephemeris.week_number),
            a_f0: i64::from(ephemeris.a_f0),
            a_f1: i64::from(ephemeris.a_f1),
            a_f2: i64::from(ephemeris.a_f2),
            ura: i64::from(ephemeris.ura),
            t_oc: i64::from(ephemeris.t_oc),
            t_gd: i64::from(ephemeris.t_gd),
            delta_n: i64::from(ephemeris.delta_n),
            iodec: i64::from(ephemeris.iodec),
            reserved: i64::from(ephemeris.reserved),
            l5_flag: ephemeris.l5_flag,
            s_flag: ephemeris.s_flag,
            c_uc: i64::from(ephemeris.c_uc),
            c_us: i64::from(ephemeris.c_us),
            c_ic: i64::from(ephemeris.c_ic),
            c_is: i64::from(ephemeris.c_is),
            c_rc: i64::from(ephemeris.c_rc),
            c_rs: i64::from(ephemeris.c_rs),
            idot: i64::from(ephemeris.idot),
            m0: ephemeris.m0,
            t_oe: i64::from(ephemeris.t_oe),
            eccentricity: ephemeris.eccentricity as i64,
            sqrt_a: ephemeris.sqrt_a as i64,
            omega0: ephemeris.omega0,
            omega: ephemeris.omega,
            omega_dot: i64::from(ephemeris.omega_dot),
            i0: ephemeris.i0,
            spare_df544: i64::from(ephemeris.spare_df544),
            spare_df545: i64::from(ephemeris.spare_df545),
            trailing_bits: ephemeris.trailing_bits,
        }
    }
}

fn build_navic_ephemeris(fields: NavicEphemerisFields) -> NifResult<NavicEphemeris> {
    macro_rules! checked {
        ($field:ident, $ty:ty) => {
            <$ty>::try_from(fields.$field)
                .map_err(|_| Error::Term(Box::new("invalid NavIC ephemeris field")))?
        };
    }
    Ok(NavicEphemeris {
        satellite_id: checked!(satellite_id, u8),
        week_number: checked!(week_number, u16),
        a_f0: checked!(a_f0, i32),
        a_f1: checked!(a_f1, i32),
        a_f2: checked!(a_f2, i16),
        ura: checked!(ura, u8),
        t_oc: checked!(t_oc, u16),
        t_gd: checked!(t_gd, i16),
        delta_n: checked!(delta_n, i32),
        iodec: checked!(iodec, u8),
        reserved: checked!(reserved, u16),
        l5_flag: fields.l5_flag,
        s_flag: fields.s_flag,
        c_uc: checked!(c_uc, i32),
        c_us: checked!(c_us, i32),
        c_ic: checked!(c_ic, i32),
        c_is: checked!(c_is, i32),
        c_rc: checked!(c_rc, i32),
        c_rs: checked!(c_rs, i32),
        idot: checked!(idot, i32),
        m0: fields.m0,
        t_oe: checked!(t_oe, u16),
        eccentricity: checked!(eccentricity, u64),
        sqrt_a: checked!(sqrt_a, u64),
        omega0: fields.omega0,
        omega: fields.omega,
        omega_dot: checked!(omega_dot, i32),
        i0: fields.i0,
        spare_df544: checked!(spare_df544, u8),
        spare_df545: checked!(spare_df545, u8),
        trailing_bits: fields.trailing_bits,
    })
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SsrVtecLayerFields {
    height: i64,
    degree: i64,
    order: i64,
    cosine: Vec<i64>,
    sine: Vec<i64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SsrVtecFields {
    message_number: i64,
    igs_ssr_version: Option<i64>,
    epoch_time_s: i64,
    update_interval: i64,
    multiple_message: bool,
    iod_ssr: i64,
    provider_id: i64,
    solution_id: i64,
    quality_indicator: i64,
    layers: Vec<SsrVtecLayerFields>,
    trailing_bits: Vec<bool>,
}

impl From<SsrVtecMessage> for SsrVtecFields {
    fn from(message: SsrVtecMessage) -> Self {
        Self {
            message_number: i64::from(message.message_number),
            igs_ssr_version: message.igs_ssr_version.map(i64::from),
            epoch_time_s: i64::from(message.epoch_time_s),
            update_interval: i64::from(message.update_interval),
            multiple_message: message.multiple_message,
            iod_ssr: i64::from(message.iod_ssr),
            provider_id: i64::from(message.provider_id),
            solution_id: i64::from(message.solution_id),
            quality_indicator: i64::from(message.quality_indicator),
            layers: message
                .layers
                .into_iter()
                .map(|layer| SsrVtecLayerFields {
                    height: i64::from(layer.height),
                    degree: i64::from(layer.degree),
                    order: i64::from(layer.order),
                    cosine: layer.cosine.into_iter().map(i64::from).collect(),
                    sine: layer.sine.into_iter().map(i64::from).collect(),
                })
                .collect(),
            trailing_bits: message.trailing_bits,
        }
    }
}

fn build_ssr_vtec(fields: SsrVtecFields) -> NifResult<SsrVtecMessage> {
    // Each raw field is refused by name, with the value it could not hold.
    fn field<T: TryFrom<i64>>(name: &str, value: i64) -> NifResult<T> {
        T::try_from(value).map_err(|_| {
            Error::Term(Box::new(format!(
                "invalid VTEC field {name}: {value} does not fit its raw width"
            )))
        })
    }
    let layers = fields
        .layers
        .into_iter()
        .map(|layer| {
            Ok(SsrVtecLayer {
                height: field("height", layer.height)?,
                degree: field("degree", layer.degree)?,
                order: field("order", layer.order)?,
                cosine: layer
                    .cosine
                    .into_iter()
                    .map(|value| field("cosine", value))
                    .collect::<NifResult<_>>()?,
                sine: layer
                    .sine
                    .into_iter()
                    .map(|value| field("sine", value))
                    .collect::<NifResult<_>>()?,
            })
        })
        .collect::<NifResult<_>>()?;
    Ok(SsrVtecMessage {
        message_number: field("message_number", fields.message_number)?,
        igs_ssr_version: fields
            .igs_ssr_version
            .map(|value| field("igs_ssr_version", value))
            .transpose()?,
        epoch_time_s: field("epoch_time_s", fields.epoch_time_s)?,
        update_interval: field("update_interval", fields.update_interval)?,
        multiple_message: fields.multiple_message,
        iod_ssr: field("iod_ssr", fields.iod_ssr)?,
        provider_id: field("provider_id", fields.provider_id)?,
        solution_id: field("solution_id", fields.solution_id)?,
        quality_indicator: field("quality_indicator", fields.quality_indicator)?,
        layers,
        trailing_bits: fields.trailing_bits,
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn rtcm_ssr_vtec_evaluate<'a>(
    env: Env<'a>,
    fields: SsrVtecFields,
    receiver_ecef_m: Vec<f64>,
    satellite_transmit_ecef_m: Vec<f64>,
    gps_seconds_of_day: f64,
    frequency_hz: f64,
) -> NifResult<Term<'a>> {
    let receiver_ecef_m: [f64; 3] = receiver_ecef_m
        .try_into()
        .map_err(|_| Error::Term(Box::new("receiver ECEF must contain three coordinates")))?;
    let satellite_transmit_ecef_m: [f64; 3] = satellite_transmit_ecef_m
        .try_into()
        .map_err(|_| Error::Term(Box::new("satellite ECEF must contain three coordinates")))?;
    let message = build_ssr_vtec(fields)?;
    match message.evaluate(
        receiver_ecef_m,
        satellite_transmit_ecef_m,
        gps_seconds_of_day,
        frequency_hz,
    ) {
        Ok(evaluation) => Ok((atoms::ok(), SsrVtecEvaluationFields::from(evaluation)).encode(env)),
        Err(sidereon_core::Error::RtcmConversion(error)) => match error.as_ref() {
            RtcmConversionError::VtecEvaluation(problem) => Ok((
                atoms::error(),
                (
                    atoms::vtec_evaluation(),
                    VtecEvaluationErrorFields::from(problem.clone()),
                ),
            )
                .encode(env)),
            other => Ok((
                atoms::error(),
                (
                    atoms::rtcm_conversion_error(),
                    rtcm_conversion_error_fields(other),
                ),
            )
                .encode(env)),
        },
        Err(sidereon_core::Error::RtcmEncode(error)) => Ok((
            atoms::error(),
            (atoms::rtcm_encode_error(), rtcm_encode_error_fields(&error)),
        )
            .encode(env)),
        Err(error) => Ok((
            atoms::error(),
            (atoms::rtcm_conversion_error(), error.to_string()),
        )
            .encode(env)),
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SsrVtecLayerEvaluationFields {
    pierce_latitude_rad: f64,
    pierce_longitude_rad: f64,
    sun_fixed_longitude_rad: f64,
    vtec_tecu: f64,
    mapping_factor: f64,
    stec_tecu: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SsrVtecEvaluationFields {
    layers: Vec<SsrVtecLayerEvaluationFields>,
    stec_tecu: f64,
    pseudorange_delay_m: f64,
    phase_range_advance_m: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct VtecEvaluationErrorFields {
    kind: String,
    message_number: Option<i64>,
    layers: Option<i64>,
    layer_index: Option<i64>,
    degree: Option<i64>,
    order: Option<i64>,
    cosine_expected: Option<i64>,
    cosine_actual: Option<i64>,
    sine_expected: Option<i64>,
    sine_actual: Option<i64>,
    field: Option<String>,
    index: Option<i64>,
}

impl From<VtecEvaluationProblem> for VtecEvaluationErrorFields {
    fn from(problem: VtecEvaluationProblem) -> Self {
        let mut fields = Self {
            kind: String::new(),
            message_number: None,
            layers: None,
            layer_index: None,
            degree: None,
            order: None,
            cosine_expected: None,
            cosine_actual: None,
            sine_expected: None,
            sine_actual: None,
            field: None,
            index: None,
        };
        match problem {
            VtecEvaluationProblem::ComputationTime => fields.kind = "computation_time".into(),
            VtecEvaluationProblem::Frequency => fields.kind = "frequency".into(),
            VtecEvaluationProblem::NonFiniteCoordinates => {
                fields.kind = "non_finite_coordinates".into()
            }
            VtecEvaluationProblem::MessageIdentity { message_number } => {
                fields.kind = "message_identity".into();
                fields.message_number = Some(i64::from(message_number));
            }
            VtecEvaluationProblem::LayerCount { layers } => {
                fields.kind = "layer_count".into();
                fields.layers = i64::try_from(layers).ok();
            }
            VtecEvaluationProblem::InvalidGeometry => fields.kind = "invalid_geometry".into(),
            VtecEvaluationProblem::BelowHorizon => fields.kind = "below_horizon".into(),
            VtecEvaluationProblem::LayerDegreeOrder {
                layer_index,
                degree,
                order,
            } => {
                fields.kind = "layer_degree_order".into();
                fields.layer_index = i64::try_from(layer_index).ok();
                fields.degree = Some(i64::from(degree));
                fields.order = Some(i64::from(order));
            }
            VtecEvaluationProblem::CoefficientCounts {
                layer_index,
                cosine_expected,
                cosine_actual,
                sine_expected,
                sine_actual,
            } => {
                fields.kind = "coefficient_counts".into();
                fields.layer_index = i64::try_from(layer_index).ok();
                fields.cosine_expected = i64::try_from(cosine_expected).ok();
                fields.cosine_actual = i64::try_from(cosine_actual).ok();
                fields.sine_expected = i64::try_from(sine_expected).ok();
                fields.sine_actual = i64::try_from(sine_actual).ok();
            }
            VtecEvaluationProblem::UnavailableCoefficient { layer_index } => {
                fields.kind = "unavailable_coefficient".into();
                fields.layer_index = i64::try_from(layer_index).ok();
            }
            VtecEvaluationProblem::ShellNotAboveReceiver { layer_index } => {
                fields.kind = "shell_not_above_receiver".into();
                fields.layer_index = i64::try_from(layer_index).ok();
            }
            VtecEvaluationProblem::MissingCoefficient {
                layer_index,
                field,
                index,
            } => {
                fields.kind = "missing_coefficient".into();
                fields.layer_index = i64::try_from(layer_index).ok();
                fields.field = Some(field.into());
                fields.index = i64::try_from(index).ok();
            }
            VtecEvaluationProblem::InvalidMappingFactor { layer_index } => {
                fields.kind = "invalid_mapping_factor".into();
                fields.layer_index = i64::try_from(layer_index).ok();
            }
            VtecEvaluationProblem::PhysicalResultOutOfRange { field } => {
                fields.kind = "physical_result_out_of_range".into();
                fields.field = Some(field.into());
            }
            _ => fields.kind = "unrecognized_problem".into(),
        }
        fields
    }
}

impl From<sidereon_core::rtcm::SsrVtecEvaluation> for SsrVtecEvaluationFields {
    fn from(evaluation: sidereon_core::rtcm::SsrVtecEvaluation) -> Self {
        Self {
            layers: evaluation
                .layers
                .into_iter()
                .map(|layer| SsrVtecLayerEvaluationFields {
                    pierce_latitude_rad: layer.pierce_latitude_rad,
                    pierce_longitude_rad: layer.pierce_longitude_rad,
                    sun_fixed_longitude_rad: layer.sun_fixed_longitude_rad,
                    vtec_tecu: layer.vtec_tecu,
                    mapping_factor: layer.mapping_factor,
                    stec_tecu: layer.stec_tecu,
                })
                .collect(),
            stec_tecu: evaluation.stec_tecu,
            pseudorange_delay_m: evaluation.pseudorange_delay_m,
            phase_range_advance_m: evaluation.phase_range_advance_m,
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct CellLliFields {
    satellite_id: i64,
    signal_id: i64,
    lli: i64,
    min_lock_time_ms: Option<i64>,
}

impl From<CellLli> for CellLliFields {
    fn from(cell: CellLli) -> Self {
        Self {
            satellite_id: cell.satellite_id as i64,
            signal_id: cell.signal_id as i64,
            lli: cell.lli as i64,
            min_lock_time_ms: cell.min_lock_time_ms.map(|v| v as i64),
        }
    }
}

/// An RTCM departure as a tagged tuple: `{:frame_reserved_bits, reserved}`,
/// `{:trailing_bits, message_number, bits}`,
/// `{:msm_cell_mask_over_64, message_number, cells}` or
/// `{:ssr_records_short, message_number, declared, read}`.
pub(crate) fn departure_term<'a>(env: Env<'a>, departure: &RtcmDeparture) -> Term<'a> {
    match departure {
        RtcmDeparture::FrameReservedBits { reserved } => {
            (atoms::frame_reserved_bits(), i64::from(*reserved)).encode(env)
        }
        RtcmDeparture::TrailingBits {
            message_number,
            bits,
        } => (
            atoms::trailing_bits(),
            i64::from(*message_number),
            bits.clone(),
        )
            .encode(env),
        RtcmDeparture::MsmCellMaskOver64 {
            message_number,
            cells,
        } => (
            atoms::msm_cell_mask_over_64(),
            i64::from(*message_number),
            *cells as u64,
        )
            .encode(env),
        RtcmDeparture::SsrRecordsShort {
            message_number,
            declared,
            read,
        } => (
            atoms::ssr_records_short(),
            i64::from(*message_number),
            *declared as u64,
            *read as u64,
        )
            .encode(env),
        RtcmDeparture::OrderExceedsDegree {
            message_number,
            layer_index,
            degree,
            order,
        } => (
            atoms::order_exceeds_degree(),
            i64::from(*message_number),
            *layer_index as u64,
            i64::from(*degree),
            i64::from(*order),
        )
            .encode(env),
        RtcmDeparture::RecordsShort {
            message_number,
            declared,
            read,
        } => (
            atoms::records_short(),
            i64::from(*message_number),
            *declared as u64,
            *read as u64,
        )
            .encode(env),
        other => (atoms::other(), other.to_string()).encode(env),
    }
}

fn departures_term<'a>(env: Env<'a>, departures: &[RtcmDeparture]) -> Term<'a> {
    departures
        .iter()
        .map(|departure| departure_term(env, departure))
        .collect::<Vec<_>>()
        .encode(env)
}

/// `%{offset, message_number, reason, detail}` for a skipped frame: `reason` is
/// `:truncated`, `:malformed` (with the decoder's text in `detail`) or
/// `:departure` (with the departure, as `departure_term` writes it, in
/// `detail`).
fn frame_skip_term<'a>(env: Env<'a>, skip: &FrameSkip) -> Term<'a> {
    let (reason, detail) = match &skip.reason {
        FrameSkipReason::Truncated => (atoms::truncated(), rustler::types::atom::nil().encode(env)),
        FrameSkipReason::Malformed(detail) => (atoms::malformed(), detail.as_str().encode(env)),
        FrameSkipReason::Departure(departure) => {
            (atoms::departure(), departure_term(env, departure))
        }
    };
    Term::map_from_pairs(
        env,
        &[
            (
                atoms::offset().encode(env),
                (skip.offset as u64).encode(env),
            ),
            (
                atoms::message_number().encode(env),
                skip.message_number.map(i64::from).encode(env),
            ),
            (atoms::reason().encode(env), reason.encode(env)),
            (atoms::detail().encode(env), detail),
        ],
    )
    .expect("distinct atom keys")
}

/// `%{resync_bytes, crc_failures, skipped_frames, departures}`, each departure
/// `{offset, departure}`.
pub(crate) fn diagnostics_term<'a>(env: Env<'a>, diagnostics: &StreamDiagnostics) -> Term<'a> {
    let skipped: Vec<Term<'a>> = diagnostics
        .skipped_frames
        .iter()
        .map(|skip| frame_skip_term(env, skip))
        .collect();
    let departures: Vec<Term<'a>> = diagnostics
        .departures
        .iter()
        .map(|entry| (entry.offset as u64, departure_term(env, &entry.departure)).encode(env))
        .collect();
    Term::map_from_pairs(
        env,
        &[
            (
                atoms::resync_bytes().encode(env),
                (diagnostics.resync_bytes as u64).encode(env),
            ),
            (
                atoms::crc_failures().encode(env),
                (diagnostics.crc_failures as u64).encode(env),
            ),
            (atoms::skipped_frames().encode(env), skipped.encode(env)),
            (atoms::departures().encode(env), departures.encode(env)),
        ],
    )
    .expect("distinct atom keys")
}

pub(crate) fn parse_policy(label: &str) -> NifResult<RtcmPolicy> {
    match label {
        "strict" => Ok(RtcmPolicy::Strict),
        "lenient" => Ok(RtcmPolicy::Lenient),
        _ => Err(Error::Term(Box::new("unknown RTCM policy"))),
    }
}

fn parse_system(system: &str) -> NifResult<GnssSystem> {
    let mut chars = system.chars();
    match (chars.next(), chars.next()) {
        (Some(letter), None) => GnssSystem::from_letter(letter)
            .ok_or_else(|| Error::Term(Box::new("unknown RTCM MSM constellation letter"))),
        _ => Err(Error::Term(Box::new(
            "invalid RTCM MSM constellation letter",
        ))),
    }
}

fn parse_msm_kind(kind: &str) -> NifResult<MsmKind> {
    match kind {
        "msm1" => Ok(MsmKind::Msm1),
        "msm2" => Ok(MsmKind::Msm2),
        "msm3" => Ok(MsmKind::Msm3),
        "msm4" => Ok(MsmKind::Msm4),
        "msm5" => Ok(MsmKind::Msm5),
        "msm6" => Ok(MsmKind::Msm6),
        "msm7" => Ok(MsmKind::Msm7),
        _ => Err(Error::Term(Box::new("unknown RTCM MSM kind"))),
    }
}

/// Construction input for a 1005 / 1006 station antenna reference point.
///
/// Carries only the raw transmitted fields, so a caller builds a message from
/// scratch without supplying the scaled `x_m`/`y_m`/`z_m` outputs the decoder
/// derives. A round-trip caller can also pass the full decoded map directly: the
/// extra derived keys are ignored at decode.
#[derive(Debug, Clone, rustler::NifMap)]
struct StationCoordinatesInput {
    message_number: i64,
    reference_station_id: i64,
    itrf_realization_year: i64,
    gps_indicator: bool,
    glonass_indicator: bool,
    galileo_indicator: bool,
    reference_station_indicator: bool,
    ecef_x: i64,
    single_receiver_oscillator: bool,
    reserved: bool,
    ecef_y: i64,
    quarter_cycle_indicator: i64,
    ecef_z: i64,
    antenna_height: Option<i64>,
    trailing_bits: Vec<bool>,
}

impl From<StationCoordinatesInput> for StationCoordinates {
    fn from(s: StationCoordinatesInput) -> Self {
        Self {
            message_number: s.message_number as u16,
            reference_station_id: s.reference_station_id as u16,
            itrf_realization_year: s.itrf_realization_year as u8,
            gps_indicator: s.gps_indicator,
            glonass_indicator: s.glonass_indicator,
            galileo_indicator: s.galileo_indicator,
            reference_station_indicator: s.reference_station_indicator,
            ecef_x: s.ecef_x,
            single_receiver_oscillator: s.single_receiver_oscillator,
            reserved: s.reserved,
            ecef_y: s.ecef_y,
            quarter_cycle_indicator: s.quarter_cycle_indicator as u8,
            ecef_z: s.ecef_z,
            antenna_height: s.antenna_height.map(|h| h as u16),
            trailing_bits: s.trailing_bits,
        }
    }
}

impl From<AntennaDescriptorFields> for AntennaDescriptor {
    fn from(a: AntennaDescriptorFields) -> Self {
        Self {
            message_number: a.message_number as u16,
            reference_station_id: a.reference_station_id as u16,
            antenna_descriptor: a.antenna_descriptor,
            antenna_setup_id: a.antenna_setup_id as u8,
            antenna_serial_number: a.antenna_serial_number,
            receiver_type: a.receiver_type,
            receiver_firmware_version: a.receiver_firmware_version,
            receiver_serial_number: a.receiver_serial_number,
            trailing_bits: a.trailing_bits,
        }
    }
}

impl From<GpsEphemerisFields> for GpsEphemeris {
    fn from(e: GpsEphemerisFields) -> Self {
        Self {
            satellite_id: e.satellite_id as u8,
            week_number: e.week_number as u16,
            sv_accuracy: e.sv_accuracy as u8,
            code_on_l2: e.code_on_l2 as u8,
            idot: e.idot as i32,
            iode: e.iode as u8,
            t_oc: e.t_oc as u16,
            a_f2: e.a_f2 as i16,
            a_f1: e.a_f1 as i32,
            a_f0: e.a_f0 as i32,
            iodc: e.iodc as u16,
            c_rs: e.c_rs as i32,
            delta_n: e.delta_n as i32,
            m0: e.m0,
            c_uc: e.c_uc as i32,
            eccentricity: e.eccentricity as u64,
            c_us: e.c_us as i32,
            sqrt_a: e.sqrt_a as u64,
            t_oe: e.t_oe as u16,
            c_ic: e.c_ic as i32,
            omega0: e.omega0,
            c_is: e.c_is as i32,
            i0: e.i0,
            c_rc: e.c_rc as i32,
            omega: e.omega,
            omega_dot: e.omega_dot as i32,
            t_gd: e.t_gd as i16,
            sv_health: e.sv_health as u8,
            l2_p_data_flag: e.l2_p_data_flag,
            fit_interval: e.fit_interval,
            trailing_bits: e.trailing_bits,
        }
    }
}

impl From<GalileoFnavEphemerisFields> for GalileoFnavEphemeris {
    fn from(e: GalileoFnavEphemerisFields) -> Self {
        Self {
            satellite_id: e.satellite_id as u8,
            week_number: e.week_number as u16,
            iod_nav: e.iod_nav as u16,
            sisa: e.sisa as u8,
            idot: e.idot as i32,
            t_oc: e.t_oc as u16,
            a_f2: e.a_f2 as i16,
            a_f1: e.a_f1 as i32,
            a_f0: e.a_f0,
            c_rs: e.c_rs as i32,
            delta_n: e.delta_n as i32,
            m0: e.m0,
            c_uc: e.c_uc as i32,
            eccentricity: e.eccentricity as u64,
            c_us: e.c_us as i32,
            sqrt_a: e.sqrt_a as u64,
            t_oe: e.t_oe as u16,
            c_ic: e.c_ic as i32,
            omega0: e.omega0,
            c_is: e.c_is as i32,
            i0: e.i0,
            c_rc: e.c_rc as i32,
            omega: e.omega,
            omega_dot: e.omega_dot as i32,
            bgd_e5a_e1: e.bgd_e5a_e1 as i16,
            e5a_signal_health: e.e5a_signal_health as u8,
            e5a_data_validity: e.e5a_data_validity,
            reserved: e.reserved as u8,
            trailing_bits: e.trailing_bits,
        }
    }
}

impl From<GalileoInavEphemerisFields> for GalileoInavEphemeris {
    fn from(e: GalileoInavEphemerisFields) -> Self {
        Self {
            satellite_id: e.satellite_id as u8,
            week_number: e.week_number as u16,
            iod_nav: e.iod_nav as u16,
            sisa_index: e.sisa_index as u8,
            idot: e.idot as i32,
            t_oc: e.t_oc as u16,
            a_f2: e.a_f2 as i16,
            a_f1: e.a_f1 as i32,
            a_f0: e.a_f0,
            c_rs: e.c_rs as i32,
            delta_n: e.delta_n as i32,
            m0: e.m0,
            c_uc: e.c_uc as i32,
            eccentricity: e.eccentricity as u64,
            c_us: e.c_us as i32,
            sqrt_a: e.sqrt_a as u64,
            t_oe: e.t_oe as u16,
            c_ic: e.c_ic as i32,
            omega0: e.omega0,
            c_is: e.c_is as i32,
            i0: e.i0,
            c_rc: e.c_rc as i32,
            omega: e.omega,
            omega_dot: e.omega_dot as i32,
            bgd_e5a_e1: e.bgd_e5a_e1 as i16,
            bgd_e5b_e1: e.bgd_e5b_e1 as i16,
            e5b_signal_health: e.e5b_signal_health as u8,
            e5b_data_validity: e.e5b_data_validity,
            e1b_signal_health: e.e1b_signal_health as u8,
            e1b_data_validity: e.e1b_data_validity,
            reserved: e.reserved as u8,
            trailing_bits: e.trailing_bits,
        }
    }
}

impl From<BeidouEphemerisFields> for BeidouEphemeris {
    fn from(e: BeidouEphemerisFields) -> Self {
        Self {
            satellite_id: e.satellite_id as u8,
            week_number: e.week_number as u16,
            sv_urai: e.sv_urai as u8,
            idot: e.idot as i32,
            aode: e.aode as u8,
            t_oc: e.t_oc as u32,
            a_f2: e.a_f2 as i16,
            a_f1: e.a_f1 as i32,
            a_f0: e.a_f0 as i32,
            aodc: e.aodc as u8,
            c_rs: e.c_rs as i32,
            delta_n: e.delta_n as i32,
            m0: e.m0,
            c_uc: e.c_uc as i32,
            eccentricity: e.eccentricity as u64,
            c_us: e.c_us as i32,
            sqrt_a: e.sqrt_a as u64,
            t_oe: e.t_oe as u32,
            c_ic: e.c_ic as i32,
            omega0: e.omega0,
            c_is: e.c_is as i32,
            i0: e.i0,
            c_rc: e.c_rc as i32,
            omega: e.omega,
            omega_dot: e.omega_dot as i32,
            t_gd1: e.t_gd1 as i16,
            t_gd2: e.t_gd2 as i16,
            sv_health: e.sv_health,
            trailing_bits: e.trailing_bits,
        }
    }
}

impl From<QzssEphemerisFields> for QzssEphemeris {
    fn from(e: QzssEphemerisFields) -> Self {
        Self {
            satellite_id: e.satellite_id as u8,
            t_oc: e.t_oc as u16,
            a_f2: e.a_f2 as i16,
            a_f1: e.a_f1 as i32,
            a_f0: e.a_f0 as i32,
            iode: e.iode as u8,
            c_rs: e.c_rs as i32,
            delta_n: e.delta_n as i32,
            m0: e.m0,
            c_uc: e.c_uc as i32,
            eccentricity: e.eccentricity as u64,
            c_us: e.c_us as i32,
            sqrt_a: e.sqrt_a as u64,
            t_oe: e.t_oe as u16,
            c_ic: e.c_ic as i32,
            omega0: e.omega0,
            c_is: e.c_is as i32,
            i0: e.i0,
            c_rc: e.c_rc as i32,
            omega: e.omega,
            omega_dot: e.omega_dot as i32,
            idot: e.idot as i32,
            codes_on_l2: e.codes_on_l2 as u8,
            week_number: e.week_number as u16,
            ura: e.ura as u8,
            sv_health: e.sv_health as u8,
            t_gd: e.t_gd as i16,
            iodc: e.iodc as u16,
            fit_interval: e.fit_interval,
            trailing_bits: e.trailing_bits,
        }
    }
}

impl From<GlonassEphemerisFields> for GlonassEphemeris {
    fn from(e: GlonassEphemerisFields) -> Self {
        Self {
            satellite_id: e.satellite_id as u8,
            frequency_channel: e.frequency_channel as u8,
            almanac_health: e.almanac_health,
            almanac_health_availability: e.almanac_health_availability,
            p1: e.p1 as u8,
            t_k: e.t_k as u16,
            b_n_msb: e.b_n_msb,
            p2: e.p2,
            t_b: e.t_b as u8,
            xn_dot: e.xn_dot as i32,
            xn: e.xn as i32,
            xn_dot_dot: e.xn_dot_dot as i8,
            yn_dot: e.yn_dot as i32,
            yn: e.yn as i32,
            yn_dot_dot: e.yn_dot_dot as i8,
            zn_dot: e.zn_dot as i32,
            zn: e.zn as i32,
            zn_dot_dot: e.zn_dot_dot as i8,
            p3: e.p3,
            gamma_n: e.gamma_n as i16,
            m_p: e.m_p as u8,
            m_l_n_third: e.m_l_n_third,
            tau_n: e.tau_n as i32,
            delta_tau_n: e.delta_tau_n as i8,
            e_n: e.e_n as u8,
            m_p4: e.m_p4,
            m_f_t: e.m_f_t as u8,
            m_n_t: e.m_n_t as u16,
            m_m: e.m_m as u8,
            additional_data_available: e.additional_data_available,
            n_a: e.n_a as u16,
            tau_c: e.tau_c,
            m_n4: e.m_n4 as u8,
            m_tau_gps: e.m_tau_gps as i32,
            m_l_n_fifth: e.m_l_n_fifth,
            reserved: e.reserved as u8,
            trailing_bits: e.trailing_bits,
            negative_zero: e.negative_zero as u16,
        }
    }
}

impl From<MsmHeaderFields> for MsmHeader {
    fn from(h: MsmHeaderFields) -> Self {
        Self {
            reference_station_id: h.reference_station_id as u16,
            epoch_time: h.epoch_time as u32,
            multiple_message: h.multiple_message,
            iods: h.iods as u8,
            reserved: h.reserved as u8,
            clock_steering: h.clock_steering as u8,
            external_clock: h.external_clock as u8,
            divergence_free_smoothing: h.divergence_free_smoothing,
            smoothing_interval: h.smoothing_interval as u8,
        }
    }
}

impl From<MsmSatelliteFields> for MsmSatellite {
    fn from(s: MsmSatelliteFields) -> Self {
        Self {
            id: s.id as u8,
            rough_range_ms: s.rough_range_ms.map(|value| value as u8),
            rough_range_mod1: s.rough_range_mod1 as u16,
            extended_info: s.extended_info.map(|v| v as u8),
            rough_phase_range_rate_m_s: s.rough_phase_range_rate_m_s.map(|v| v as i16),
        }
    }
}

fn build_msm_signal(fields: MsmSignalFields) -> NifResult<MsmSignal> {
    check_wire_u8(fields.satellite_id, "signal satellite id")?;
    check_wire_u8(fields.signal_id, "signal id")?;
    let convert_i32 = |value: Option<i64>| {
        value
            .map(i32::try_from)
            .transpose()
            .map_err(|_| Error::Term(Box::new("invalid MSM signal field")))
    };
    let convert_u16 = |value: Option<i64>| {
        value
            .map(u16::try_from)
            .transpose()
            .map_err(|_| Error::Term(Box::new("invalid MSM signal field")))
    };
    Ok(MsmSignal {
        satellite_id: fields.satellite_id as u8,
        signal_id: fields.signal_id as u8,
        fine_pseudorange: convert_i32(fields.fine_pseudorange)?,
        fine_phase_range: convert_i32(fields.fine_phase_range)?,
        lock_time_indicator: convert_u16(fields.lock_time_indicator)?,
        half_cycle_ambiguity: fields.half_cycle_ambiguity,
        cnr: convert_u16(fields.cnr)?,
        fine_phase_range_rate: fields
            .fine_phase_range_rate
            .map(i16::try_from)
            .transpose()
            .map_err(|_| Error::Term(Box::new("invalid MSM signal field")))?,
    })
}

/// Build an [`MsmMessage`] from its decoded field map. The constellation letter
/// and MSM kind are validated here (the only fallible parts of construction).
fn build_msm(fields: MsmMessageFields) -> NifResult<MsmMessage> {
    let system = parse_system(&fields.system)?;
    let kind = parse_msm_kind(&fields.kind)?;
    for satellite in &fields.satellites {
        check_wire_u8(satellite.id, "satellite id")?;
    }
    for signal in &fields.signals {
        check_wire_u8(signal.satellite_id, "signal satellite id")?;
        check_wire_u8(signal.signal_id, "signal id")?;
    }
    let signals: Vec<MsmSignal> = fields
        .signals
        .into_iter()
        .map(build_msm_signal)
        .collect::<NifResult<_>>()?;
    // A `nil` mask is the mask of the listed cells' signals, for a message
    // built by hand whose every listed signal has a cell.
    let signal_mask = match fields.signal_mask {
        Some(mask) => u32::try_from(mask).map_err(|_| {
            Error::Term(Box::new((
                atoms::invalid_input(),
                format!("RTCM MSM signal mask {mask} is outside 0..=4294967295"),
            )))
        })?,
        None => msm_signal_mask(&signals),
    };
    Ok(MsmMessage {
        message_number: u16::try_from(fields.message_number)
            .map_err(|_| Error::Term(Box::new("invalid MSM message number")))?,
        system,
        kind,
        header: fields.header.into(),
        signal_mask,
        satellites: fields.satellites.into_iter().map(Into::into).collect(),
        signals,
        trailing_bits: fields.trailing_bits,
    })
}

fn build_ssr(fields: SsrFields, policy: RtcmPolicy) -> NifResult<Message> {
    let (message, _) = Message::decode_with_policy(&fields.body, policy)
        .map_err(|error| Error::Term(Box::new(error.to_string())))?;
    match message {
        Message::Ssr(ssr) if i64::from(ssr.message_number) == fields.message_number => {
            Ok(Message::Ssr(ssr))
        }
        Message::Ssr(_) => Err(Error::Term(Box::new("RTCM SSR message number mismatch"))),
        _ => Err(Error::Term(Box::new("RTCM body is not an SSR message"))),
    }
}

/// Refuse a satellite or signal number that does not fit the byte the message
/// IR holds it in, before the conversion would keep only its low bits and name
/// another satellite or signal; the encoder then checks the message's own field
/// width.
fn check_wire_u8(value: i64, field: &str) -> NifResult<()> {
    if u8::try_from(value).is_ok() {
        Ok(())
    } else {
        Err(Error::Term(Box::new((
            atoms::invalid_input(),
            format!("RTCM {field} {value} is outside 0..=255"),
        ))))
    }
}

/// Build the canonical [`Message`] IR for a `{type, fields}` construction pair.
pub(crate) fn build_message(kind: &str, fields: Term<'_>) -> NifResult<Message> {
    build_message_with_policy(kind, fields, RtcmPolicy::Strict)
}

/// As [`build_message`], reading an SSR message's body under `policy`.
fn build_message_with_policy(
    kind: &str,
    fields: Term<'_>,
    policy: RtcmPolicy,
) -> NifResult<Message> {
    let message = match kind {
        "station_coordinates" => {
            Message::StationCoordinates(fields.decode::<StationCoordinatesInput>()?.into())
        }
        "legacy_observations" => Message::LegacyObservations(checked_legacy_fields(
            fields.decode::<LegacyObservationsFields>()?,
        )?),
        "antenna_descriptor" => {
            Message::AntennaDescriptor(fields.decode::<AntennaDescriptorFields>()?.into())
        }
        "system_parameters" => Message::SystemParameters(checked_system_parameters(
            fields.decode::<SystemParametersFields>()?,
        )?),
        "text" => Message::Text(checked_text_message(fields.decode::<TextMessageFields>()?)?),
        "network_auxiliary_station" => Message::NetworkAuxiliaryStation(
            checked_network_auxiliary_station(fields.decode::<NetworkAuxiliaryStationFields>()?)?,
        ),
        "network_correction_differences" => Message::NetworkCorrectionDifferences(
            build_network_correction_differences(fields.decode()?)?,
        ),
        "helmert_transformation" => {
            Message::HelmertTransformation(build_helmert_transformation(fields.decode()?)?)
        }
        "residual_grid" => Message::ResidualGrid(build_residual_grid(fields.decode()?)?),
        "projection" => Message::Projection(build_projection(fields.decode()?)?),
        "network_residuals" => {
            Message::NetworkResiduals(build_network_residuals(fields.decode()?)?)
        }
        "physical_reference_station" => {
            Message::PhysicalReferenceStation(build_physical_reference_station(fields.decode()?)?)
        }
        "fkp_gradients" => Message::FkpGradients(build_fkp_gradients(fields.decode()?)?),
        "gps_ephemeris" => {
            let fields = fields.decode::<GpsEphemerisFields>()?;
            check_wire_u8(fields.satellite_id, "satellite id")?;
            Message::GpsEphemeris(fields.into())
        }
        "glonass_ephemeris" => {
            let fields = fields.decode::<GlonassEphemerisFields>()?;
            check_wire_u8(fields.satellite_id, "satellite id")?;
            Message::GlonassEphemeris(fields.into())
        }
        "beidou_ephemeris" => {
            let fields = fields.decode::<BeidouEphemerisFields>()?;
            check_wire_u8(fields.satellite_id, "satellite id")?;
            Message::BeidouEphemeris(fields.into())
        }
        "qzss_ephemeris" => {
            let fields = fields.decode::<QzssEphemerisFields>()?;
            check_wire_u8(fields.satellite_id, "satellite id")?;
            Message::QzssEphemeris(fields.into())
        }
        "galileo_fnav_ephemeris" => {
            let fields = fields.decode::<GalileoFnavEphemerisFields>()?;
            check_wire_u8(fields.satellite_id, "satellite id")?;
            Message::GalileoFnavEphemeris(fields.into())
        }
        "galileo_inav_ephemeris" => {
            let fields = fields.decode::<GalileoInavEphemerisFields>()?;
            check_wire_u8(fields.satellite_id, "satellite id")?;
            Message::GalileoInavEphemeris(fields.into())
        }
        "navic_ephemeris" => {
            let ephemeris = build_navic_ephemeris(fields.decode::<NavicEphemerisFields>()?)?;
            ephemeris
                .satellite()
                .map_err(|error| Error::Term(Box::new(error.to_string())))?;
            Message::NavicEphemeris(ephemeris)
        }
        "glonass_code_phase_biases" => Message::GlonassCodePhaseBiases(
            checked_glonass_code_phase_biases(fields.decode::<GlonassCodePhaseBiasesFields>()?)?,
        ),
        "msm" => Message::Msm(build_msm(fields.decode::<MsmMessageFields>()?)?),
        "ssr" => build_ssr(fields.decode::<SsrFields>()?, policy)?,
        "ssr_vtec" => Message::SsrVtec(build_ssr_vtec(fields.decode::<SsrVtecFields>()?)?),
        "unsupported" => {
            let unsupported = fields.decode::<UnsupportedFields>()?;
            Message::Unsupported(UnsupportedMessage {
                message_number: unsupported.message_number as u16,
                body: unsupported.body,
            })
        }
        _ => return Err(Error::Term(Box::new("unsupported RTCM message type"))),
    };
    Ok(message)
}

/// The `{type_atom, fields_map}` term for a message. An SSR message crosses as
/// its encoded body, which the encoder can refuse; a message decoded from a
/// body always re-encodes, since the decoder reads each field at the width the
/// encoder checks.
pub(crate) fn encode_message<'a>(
    env: Env<'a>,
    message: Message,
) -> Result<Term<'a>, sidereon_core::Error> {
    encode_message_with_policy(env, message, RtcmPolicy::Strict)
}

/// As [`encode_message`], writing an SSR message's body under `policy`, so an
/// SSR message read under the lenient policy crosses as the body it was read
/// from.
pub(crate) fn encode_message_with_policy<'a>(
    env: Env<'a>,
    message: Message,
    policy: RtcmPolicy,
) -> Result<Term<'a>, sidereon_core::Error> {
    Ok(match message {
        Message::Msm(m) => (atoms::msm(), MsmMessageFields::from(m)).encode(env),
        Message::LegacyObservations(message) => {
            message.encode_with_policy(policy)?;
            (
                atoms::legacy_observations(),
                LegacyObservationsFields::from(message),
            )
                .encode(env)
        }
        Message::StationCoordinates(s) => (
            atoms::station_coordinates(),
            StationCoordinatesFields::from(s),
        )
            .encode(env),
        Message::AntennaDescriptor(a) => (
            atoms::antenna_descriptor(),
            AntennaDescriptorFields::from(a),
        )
            .encode(env),
        Message::SystemParameters(message) => {
            message.encode_with_policy(policy)?;
            (
                atoms::system_parameters(),
                SystemParametersFields::from(message),
            )
                .encode(env)
        }
        Message::Text(message) => {
            message.encode_with_policy(policy)?;
            (atoms::text(), TextMessageFields::from(message)).encode(env)
        }
        Message::NetworkAuxiliaryStation(message) => {
            message.encode_with_policy(policy)?;
            (
                atoms::network_auxiliary_station(),
                NetworkAuxiliaryStationFields::from(message),
            )
                .encode(env)
        }
        Message::NetworkCorrectionDifferences(message) => {
            message.encode_with_policy(policy)?;
            (
                atoms::network_correction_differences(),
                NetworkCorrectionDifferencesFields::from(message),
            )
                .encode(env)
        }
        Message::HelmertTransformation(message) => {
            message.encode_with_policy(policy)?;
            (
                atoms::helmert_transformation(),
                HelmertTransformationFields::from(message),
            )
                .encode(env)
        }
        Message::ResidualGrid(message) => {
            message.encode_with_policy(policy)?;
            (atoms::residual_grid(), ResidualGridFields::from(message)).encode(env)
        }
        Message::Projection(message) => {
            message.encode_with_policy(policy)?;
            (atoms::projection(), ProjectionFields::from(message)).encode(env)
        }
        Message::NetworkResiduals(message) => {
            message.encode_with_policy(policy)?;
            (
                atoms::network_residuals(),
                NetworkResidualsFields::from(message),
            )
                .encode(env)
        }
        Message::PhysicalReferenceStation(message) => {
            message.encode_with_policy(policy)?;
            (
                atoms::physical_reference_station(),
                PhysicalReferenceStationFields::from(message),
            )
                .encode(env)
        }
        Message::FkpGradients(message) => {
            message.encode_with_policy(policy)?;
            (atoms::fkp_gradients(), FkpGradientsFields::from(message)).encode(env)
        }
        Message::GpsEphemeris(e) => {
            (atoms::gps_ephemeris(), GpsEphemerisFields::from(e)).encode(env)
        }
        Message::GlonassEphemeris(e) => {
            (atoms::glonass_ephemeris(), GlonassEphemerisFields::from(e)).encode(env)
        }
        Message::BeidouEphemeris(e) => {
            (atoms::beidou_ephemeris(), BeidouEphemerisFields::from(e)).encode(env)
        }
        Message::QzssEphemeris(e) => {
            (atoms::qzss_ephemeris(), QzssEphemerisFields::from(e)).encode(env)
        }
        Message::GalileoFnavEphemeris(e) => (
            atoms::galileo_fnav_ephemeris(),
            GalileoFnavEphemerisFields::from(e),
        )
            .encode(env),
        Message::GalileoInavEphemeris(e) => (
            atoms::galileo_inav_ephemeris(),
            GalileoInavEphemerisFields::from(e),
        )
            .encode(env),
        Message::NavicEphemeris(e) => {
            e.encode_with_policy(policy)?;
            (atoms::navic_ephemeris(), NavicEphemerisFields::from(e)).encode(env)
        }
        Message::GlonassCodePhaseBiases(message) => {
            message.encode_with_policy(policy)?;
            (
                atoms::glonass_code_phase_biases(),
                GlonassCodePhaseBiasesFields::from(message),
            )
                .encode(env)
        }
        Message::Ssr(s) => (
            atoms::ssr(),
            SsrFields {
                message_number: i64::from(s.message_number),
                body: s.encode_with_policy(policy)?.0,
            },
        )
            .encode(env),
        Message::SsrVtec(vtec) => {
            vtec.encode_with_policy(policy)?;
            (atoms::ssr_vtec(), SsrVtecFields::from(vtec)).encode(env)
        }
        Message::Unsupported(u) => (
            atoms::unsupported(),
            UnsupportedFields {
                message_number: u.message_number as i64,
                body: u.body,
            },
        )
            .encode(env),
    })
}

/// Decode a complete RTCM 3 byte stream into the message IR.
///
/// Mirrors `rtcm::decode_messages`: every byte has to belong to a CRC-valid
/// frame whose body decodes under the strict policy. Returns `{:ok, messages}`,
/// or `{:error, text}` naming what was not read (a skipped frame, or bytes
/// outside CRC-valid frames with the CRC-24Q failure count).
#[rustler::nif(schedule = "DirtyCpu")]
fn rtcm_decode_messages<'a>(env: Env<'a>, bytes: rustler::Binary) -> NifResult<Term<'a>> {
    let messages = match rtcm::decode_messages(bytes.as_slice()) {
        Ok(messages) => messages,
        Err(error) => return Ok((atoms::error(), error.to_string()).encode(env)),
    };
    let terms = messages
        .into_iter()
        .map(|message| encode_message(env, message).map_err(|error| raise_encode_error(&error)))
        .collect::<NifResult<Vec<Term<'a>>>>()?;
    Ok((atoms::ok(), terms).encode(env))
}

/// Decode every RTCM frame under `policy` and return messages plus stream
/// diagnostics.
#[rustler::nif(schedule = "DirtyCpu")]
fn rtcm_decode_stream<'a>(
    env: Env<'a>,
    bytes: rustler::Binary,
    policy: String,
) -> NifResult<Term<'a>> {
    let policy = parse_policy(&policy)?;
    let stream = rtcm::decode_stream_with_policy(bytes.as_slice(), policy);
    let messages = match stream
        .messages
        .into_iter()
        .map(|message| encode_message_with_policy(env, message, policy))
        .collect::<Result<Vec<Term<'a>>, _>>()
    {
        Ok(messages) => messages,
        Err(error) => return Ok((atoms::error(), encode_error_reason(env, &error)).encode(env)),
    };
    let diagnostics = diagnostics_term(env, &stream.diagnostics);
    Ok((atoms::ok(), (messages, diagnostics)).encode(env))
}

/// Decode a single RTCM message body under `policy` into the message IR:
/// `{:ok, {message, departures}}`, the departures read under the lenient
/// policy (always empty under the strict one, which refuses them).
#[rustler::nif]
fn rtcm_decode_message<'a>(
    env: Env<'a>,
    body: rustler::Binary,
    policy: String,
) -> NifResult<Term<'a>> {
    let policy = parse_policy(&policy)?;
    match Message::decode_with_policy(body.as_slice(), policy) {
        Ok((message, departures)) => Ok(match encode_message_with_policy(env, message, policy) {
            Ok(term) => (atoms::ok(), (term, departures_term(env, &departures))).encode(env),
            Err(error) => (atoms::error(), encode_error_reason(env, &error)).encode(env),
        }),
        Err(error) => Ok((atoms::error(), error.to_string()).encode(env)),
    }
}

/// Read the RTCM message number from a message body.
#[rustler::nif]
fn rtcm_message_number<'a>(env: Env<'a>, body: rustler::Binary) -> NifResult<Term<'a>> {
    match rtcm::message_number(body.as_slice()) {
        Ok(number) => Ok((atoms::ok(), number as i64).encode(env)),
        Err(error) => Ok((atoms::error(), error.to_string()).encode(env)),
    }
}

/// Core RINEX LLI bit constants used by the RTCM derivation helpers.
#[rustler::nif]
fn rtcm_lli_bits<'a>(env: Env<'a>) -> Term<'a> {
    ((LLI_LOSS_OF_LOCK as i64), (LLI_HALF_CYCLE as i64)).encode(env)
}

/// Minimum continuous-lock time for an MSM lock indicator.
#[rustler::nif]
fn rtcm_minimum_lock_time_ms<'a>(
    env: Env<'a>,
    kind: String,
    indicator: i64,
) -> NifResult<Term<'a>> {
    let kind = parse_msm_kind(&kind)?;
    let value = minimum_lock_time_ms(kind, indicator as u16).map(|v| v as i64);
    Ok((atoms::ok(), value).encode(env))
}

/// Derive the RINEX LLI digit for one signal cell.
#[rustler::nif]
fn rtcm_derive_lli(
    previous_min_lock_time_ms: Option<i64>,
    elapsed_ms: Option<i64>,
    current_min_lock_time_ms: Option<i64>,
    half_cycle_ambiguity: bool,
) -> i64 {
    let previous = elapsed_ms.map(|elapsed_ms| PreviousLock {
        min_lock_time_ms: previous_min_lock_time_ms.map(|v| v as u32),
        elapsed_ms: elapsed_ms as u64,
    });
    derive_lli(
        previous,
        current_min_lock_time_ms.map(|v| v as u32),
        half_cycle_ambiguity,
    ) as i64
}

/// Elapsed milliseconds between two raw MSM epoch fields for one system.
#[rustler::nif]
fn rtcm_msm_epoch_dt_ms<'a>(
    env: Env<'a>,
    system: String,
    previous: i64,
    current: i64,
) -> NifResult<Term<'a>> {
    let system = parse_system(&system)?;
    let dt = msm_epoch_dt_ms(system, previous as u32, current as u32) as i64;
    Ok((atoms::ok(), dt).encode(env))
}

/// RINEX observation-code suffix for an MSM signal id.
#[rustler::nif]
fn rtcm_msm_signal_rinex_code<'a>(
    env: Env<'a>,
    system: String,
    signal_id: i64,
) -> NifResult<Term<'a>> {
    let system = parse_system(&system)?;
    let code = msm_signal_rinex_code(system, signal_id as u8);
    Ok((atoms::ok(), code).encode(env))
}

/// Derive LLI rows by running one tracker over a sequence of MSM field maps.
#[rustler::nif(schedule = "DirtyCpu")]
fn rtcm_msm_lli(messages: Vec<MsmMessageFields>) -> NifResult<Vec<Vec<CellLliFields>>> {
    let mut tracker = LockTimeTracker::new();
    let mut output = Vec::with_capacity(messages.len());
    for fields in messages {
        let message = build_msm(fields)?;
        output.push(
            tracker
                .observe(&message)
                .into_iter()
                .map(Into::into)
                .collect(),
        );
    }
    Ok(output)
}

/// Decode the single RTCM 3 frame that begins at the start of `bytes`.
///
/// Verifies the preamble and the CRC-24Q. Returns
/// `{:ok, %{message_number, frame_len, body}}` (body as a binary) or
/// `{:error, reason}` for a missing preamble, a truncated buffer, or a CRC
/// mismatch.
#[rustler::nif]
fn rtcm_decode_frame<'a>(env: Env<'a>, bytes: rustler::Binary) -> NifResult<Term<'a>> {
    match rtcm::decode_frame(bytes.as_slice()) {
        Ok(frame) => {
            let message_number = rtcm::message_number(frame.body)
                .map(|n| n as i64)
                .unwrap_or(-1);
            let body = frame.body.to_vec();
            Ok((
                atoms::ok(),
                FrameFields {
                    message_number,
                    frame_len: frame.frame_len as i64,
                    reserved: i64::from(frame.reserved),
                    body,
                },
            )
                .encode(env))
        }
        Err(e) => Ok((atoms::error(), e.to_string()).encode(env)),
    }
}

/// Wrap an RTCM message body in a fresh RTCM frame whose six reserved header
/// bits hold `reserved`.
#[rustler::nif]
fn rtcm_encode_frame_body<'a>(
    env: Env<'a>,
    body: rustler::Binary,
    reserved: i64,
) -> NifResult<Term<'a>> {
    let reserved = match u8::try_from(reserved) {
        Ok(reserved) => reserved,
        Err(_) => {
            return Ok((
                atoms::error(),
                (
                    atoms::invalid_input(),
                    format!("RTCM frame reserved bits {reserved} do not fit six bits"),
                ),
            )
                .encode(env))
        }
    };
    match rtcm::encode_frame_with_reserved(body.as_slice(), reserved) {
        Ok(frame) => Ok((atoms::ok(), bytes_to_binary(env, &frame)).encode(env)),
        Err(error) => Ok((atoms::error(), encode_error_reason(env, &error)).encode(env)),
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct FrameFields {
    message_number: i64,
    frame_len: i64,
    reserved: i64,
    body: Vec<u8>,
}

/// Construct a supported RTCM 3 message from a `{type, fields}` pair and encode
/// it into a complete transport frame (preamble, length, body, CRC-24Q).
///
/// Pure glue over the per-type constructors and `Message::to_frame`: it builds
/// the canonical message IR from the field map and emits the framed bytes a
/// stream consumer (or `decode_messages/1`) reads back. Returns
/// `{:ok, binary}` or `{:error, reason}` for an unsupported type, a malformed
/// field map, or a body that overflows the frame length limit.
#[rustler::nif(schedule = "DirtyCpu")]
fn rtcm_encode_message<'a>(env: Env<'a>, kind: String, fields: Term<'a>) -> NifResult<Term<'a>> {
    let message = build_message(&kind, fields)?;
    match message.to_frame() {
        Ok(frame) => Ok((atoms::ok(), bytes_to_binary(env, &frame)).encode(env)),
        Err(error) => Ok((atoms::error(), encode_error_reason(env, &error)).encode(env)),
    }
}

/// Construct a supported RTCM 3 message and return its message body.
#[rustler::nif(schedule = "DirtyCpu")]
fn rtcm_encode<'a>(env: Env<'a>, kind: String, fields: Term<'a>) -> NifResult<Term<'a>> {
    let message = build_message(&kind, fields)?;
    Ok(match message.encode() {
        Ok(body) => (atoms::ok(), bytes_to_binary(env, &body)).encode(env),
        Err(error) => (atoms::error(), encode_error_reason(env, &error)).encode(env),
    })
}

/// Construct a supported RTCM 3 message and return its body written under
/// `policy`, with the departures written under the lenient policy:
/// `{:ok, {body, departures}}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn rtcm_encode_with_policy<'a>(
    env: Env<'a>,
    kind: String,
    fields: Term<'a>,
    policy: String,
) -> NifResult<Term<'a>> {
    let policy = parse_policy(&policy)?;
    let message = build_message_with_policy(&kind, fields, policy)?;
    Ok(match message.encode_with_policy(policy) {
        Ok((body, departures)) => (
            atoms::ok(),
            (
                bytes_to_binary(env, &body),
                departures_term(env, &departures),
            ),
        )
            .encode(env),
        Err(error) => (atoms::error(), encode_error_reason(env, &error)).encode(env),
    })
}

/// Construct a supported RTCM 3 message and return its complete frame.
#[rustler::nif(schedule = "DirtyCpu")]
fn rtcm_encode_frame<'a>(env: Env<'a>, kind: String, fields: Term<'a>) -> NifResult<Term<'a>> {
    let message = build_message(&kind, fields)?;
    match message.to_frame() {
        Ok(frame) => Ok((atoms::ok(), bytes_to_binary(env, &frame)).encode(env)),
        Err(error) => Ok((atoms::error(), encode_error_reason(env, &error)).encode(env)),
    }
}

/// Copy a byte slice into an Elixir binary term.
fn bytes_to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut binary = OwnedBinary::new(bytes.len()).expect("allocate RTCM frame binary");
    binary.as_mut_slice().copy_from_slice(bytes);
    binary.release(env).encode(env)
}
