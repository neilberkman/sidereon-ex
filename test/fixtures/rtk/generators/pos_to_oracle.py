#!/usr/bin/env python3
"""Convert an RTKLIB rnx2rtkp .pos solution into a vendored RTK oracle JSON.

Usage:
    pos_to_oracle.py POS CONF LABEL DESCRIPTION OUT.json
    pos_to_oracle.py POS CONF LABEL DESCRIPTION OUT.json --moving-truth-csv CSV ...

Truth is the WTZR/WTZZ static antenna baseline (receivers do not move), copied
verbatim from the existing Wettzell oracle, so kinematic-mode and multi-GNSS
oracles share the same physical truth; only the RTKLIB processing changes.
"""
import argparse
import csv
import json
import math
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

# Physical truth for the co-located WTZR(base)/WTZZ(rover) pair, identical to
# test/fixtures/rtk/wtzr_wtzz_rtklib_oracle.json ("truth").
TRUTH = {
    "frame": "ENU at WTZR ARP, metres",
    "base_marker_ecef_m": {"x": 4075580.3111, "y": 931854.0543, "z": 4801568.2808},
    "rover_marker_ecef_m": {"x": 4075579.1913, "y": 931853.3696, "z": 4801569.1897},
    "base_antenna_height_m": 0.071,
    "rover_antenna_height_m": 0.284,
    "antenna_baseline_enu_m": {
        "east": -0.41788146461250397,
        "north": 1.5352286147033802,
        "up": 0.08141828505054118,
    },
}
TE = TRUTH["antenna_baseline_enu_m"]["east"]
TN = TRUTH["antenna_baseline_enu_m"]["north"]
TU = TRUTH["antenna_baseline_enu_m"]["up"]

Q_STATUS = {1: "fixed", 2: "float", 3: "sbas", 4: "dgps", 5: "single", 6: "ppp"}

RTKLIB = {"program": "rnx2rtkp", "version": "v2.4.2-p13", "commit": "71db0ff"}
WGS84_A_M = 6378137.0
WGS84_F = 1.0 / 298.257223563
WGS84_E2 = WGS84_F * (2.0 - WGS84_F)
UNIX_EPOCH = datetime(1970, 1, 1)


def parse_pos(path):
    epochs = []
    with open(path) as fh:
        for line in fh:
            if not line or line.startswith("%") or "/" not in line[:12]:
                continue
            f = line.split()
            if len(f) < 15:
                continue
            # date time e n u Q ns sde sdn sdu sden sdnu sdue age ratio
            d, t = f[0], f[1]
            iso = datetime.strptime(d + " " + t, "%Y/%m/%d %H:%M:%S.%f").isoformat()
            e, n, u = float(f[2]), float(f[3]), float(f[4])
            q, ns, ratio = int(f[5]), int(f[6]), float(f[14])
            epochs.append(
                {
                    "time": iso,
                    "fix_status": Q_STATUS.get(q, str(q)),
                    "q": q,
                    "satellites": ns,
                    "baseline_enu_m": {"east": e, "north": n, "up": u},
                    "ratio": ratio,
                }
            )
    return epochs


def static_truth_enu(truth):
    return truth["antenna_baseline_enu_m"]


def truth_err(ep, truth=TRUTH):
    expected = static_truth_enu(truth)
    b = ep["baseline_enu_m"]
    return (
        (b["east"] - expected["east"]) ** 2
        + (b["north"] - expected["north"]) ** 2
        + (b["up"] - expected["up"]) ** 2
    ) ** 0.5


def lla_to_ecef(lat_deg, lon_deg, height_m):
    lat = math.radians(lat_deg)
    lon = math.radians(lon_deg)
    sin_lat = math.sin(lat)
    cos_lat = math.cos(lat)
    n = WGS84_A_M / math.sqrt(1.0 - WGS84_E2 * sin_lat * sin_lat)

    return (
        (n + height_m) * cos_lat * math.cos(lon),
        (n + height_m) * cos_lat * math.sin(lon),
        (n * (1.0 - WGS84_E2) + height_m) * sin_lat,
    )


def ecef_delta_to_enu(dx, dy, dz, lat_deg, lon_deg):
    lat = math.radians(lat_deg)
    lon = math.radians(lon_deg)
    sin_lat = math.sin(lat)
    cos_lat = math.cos(lat)
    sin_lon = math.sin(lon)
    cos_lon = math.cos(lon)

    east = -sin_lon * dx + cos_lon * dy
    north = -sin_lat * cos_lon * dx - sin_lat * sin_lon * dy + cos_lat * dz
    up = cos_lat * cos_lon * dx + cos_lat * sin_lon * dy + sin_lat * dz
    return east, north, up


def round_xyz(xyz, ndigits=6):
    return {"x": round(xyz[0], ndigits), "y": round(xyz[1], ndigits), "z": round(xyz[2], ndigits)}


def parse_ecef_pos(path, gps_utc_offset_s):
    epochs = []
    with open(path) as fh:
        for line in fh:
            if not line or line.startswith("%"):
                continue

            f = line.split()
            if len(f) < 15 or "/" not in f[0]:
                continue

            gpst = datetime.strptime(f[0] + " " + f[1], "%Y/%m/%d %H:%M:%S.%f")
            utc = gpst - timedelta(seconds=gps_utc_offset_s)
            x, y, z = float(f[2]), float(f[3]), float(f[4])
            q, ns, ratio = int(f[5]), int(f[6]), float(f[14])
            epochs.append(
                {
                    "gpst": gpst,
                    "utc": utc,
                    "position": (x, y, z),
                    "q": q,
                    "satellites": ns,
                    "ratio": ratio,
                }
            )
    return epochs


def parse_gsdc_truth_csv(path):
    truth = {}
    with open(path, newline="") as fh:
        for row in csv.DictReader(fh):
            utc = datetime.fromtimestamp(int(row["UnixTimeMillis"]) / 1000.0, timezone.utc)
            utc = utc.replace(tzinfo=None)
            lat = float(row["LatitudeDegrees"])
            lon = float(row["LongitudeDegrees"])
            height = float(row["AltitudeMeters"])
            truth[utc] = {
                "latitude_deg": lat,
                "longitude_deg": lon,
                "height_m": height,
                "speed_mps": float(row["SpeedMps"]),
                "accuracy_m": float(row["AccuracyMeters"]),
                "bearing_deg": float(row["BearingDegrees"]),
                "ecef": lla_to_ecef(lat, lon, height),
            }
    return truth


def naive_unix_ms(dt):
    return int(round((dt - UNIX_EPOCH).total_seconds() * 1000.0))


def indexed_truth(truth):
    return {naive_unix_ms(utc): (utc, row) for utc, row in truth.items()}


def match_truth_epoch(truth, truth_by_ms, utc, tolerance_ms):
    t = truth.get(utc)
    if t is not None:
        return utc, t

    if tolerance_ms <= 0:
        return None, None

    utc_ms = naive_unix_ms(utc)
    candidates = []

    for delta_ms in range(-tolerance_ms, tolerance_ms + 1):
        match = truth_by_ms.get(utc_ms + delta_ms)
        if match is not None:
            candidates.append((abs(delta_ms), match))

    if not candidates:
        return None, None

    _, (matched_utc, row) = min(candidates, key=lambda item: item[0])
    return matched_utc, row


def percentile(values, pct):
    if not values:
        return None
    return sorted(values)[int(pct * (len(values) - 1))]


def mean(values):
    return sum(values) / len(values) if values else None


def rms(values):
    return math.sqrt(mean([v * v for v in values])) if values else None


def median(values):
    if not values:
        return None
    ordered = sorted(values)
    n = len(ordered)
    mid = n // 2
    if n % 2:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2.0


def metric_summary(values):
    return {
        "mean_m": round(mean(values), 12),
        "rms_m": round(rms(values), 12),
        "median_m": round(median(values), 12),
        "p95_m": round(percentile(values, 0.95), 12),
        "max_m": round(max(values), 12),
    }


def parse_xyz_arg(value):
    parts = [float(part) for part in value.split(",")]
    if len(parts) != 3:
        raise argparse.ArgumentTypeError("expected x,y,z")
    return tuple(parts)


def static_inputs(args):
    inputs = {}

    for key, value in [
        ("rover_obs", args.rover_source),
        ("base_obs", args.base_source),
        ("nav", args.nav_source),
        ("sp3", args.sp3_source),
        ("clk", args.clk_source),
        ("antex", args.antex_source),
    ]:
        if value:
            inputs[key] = value

    return inputs or None


def moving_oracle(args):
    truth = parse_gsdc_truth_csv(args.moving_truth_csv)
    truth_by_ms = indexed_truth(truth)
    epochs = []
    missing_truth = []

    for ep in parse_ecef_pos(args.pos, args.gps_utc_offset_s):
        truth_utc, t = match_truth_epoch(
            truth, truth_by_ms, ep["utc"], args.truth_time_tolerance_ms
        )

        if t is None:
            missing_truth.append(ep["utc"].isoformat(timespec="milliseconds"))
            continue

        sol = ep["position"]
        ref = t["ecef"]
        dx, dy, dz = sol[0] - ref[0], sol[1] - ref[1], sol[2] - ref[2]
        east, north, up = ecef_delta_to_enu(dx, dy, dz, t["latitude_deg"], t["longitude_deg"])
        horizontal_error = math.hypot(east, north)
        error_3d = math.sqrt(dx * dx + dy * dy + dz * dz)

        epochs.append(
            {
                "time": ep["gpst"].isoformat(timespec="milliseconds"),
                "time_scale": "GPST",
                "truth_time_utc": truth_utc.isoformat(timespec="milliseconds"),
                "fix_status": Q_STATUS.get(ep["q"], str(ep["q"])),
                "q": ep["q"],
                "satellites": ep["satellites"],
                "position_ecef_m": round_xyz(sol, 4),
                "truth_ecef_m": round_xyz(ref, 6),
                "truth_geodetic_deg_m": {
                    "latitude": round(t["latitude_deg"], 10),
                    "longitude": round(t["longitude_deg"], 10),
                    "height": round(t["height_m"], 6),
                },
                "error_enu_m": {
                    "east": round(east, 6),
                    "north": round(north, 6),
                    "up": round(up, 6),
                },
                "horizontal_error_m": round(horizontal_error, 6),
                "vertical_error_m": round(up, 6),
                "error_3d_m": round(error_3d, 6),
                "ratio": ep["ratio"],
            }
        )

    if not epochs:
        raise SystemExit("no RTKLIB epochs matched moving truth")

    if missing_truth:
        print(f"warning: skipped {len(missing_truth)} epochs with no matching truth", file=sys.stderr)

    fixed = [i for i, e in enumerate(epochs) if e["q"] == 1]
    q_counts = Counter(e["q"] for e in epochs)
    first_fix = fixed[0] if fixed else None
    last = epochs[-1]
    errors_3d = [e["error_3d_m"] for e in epochs]
    horizontal = [e["horizontal_error_m"] for e in epochs]
    vertical_abs = [abs(e["vertical_error_m"]) for e in epochs]

    ref = {
        "label": args.label,
        "config": args.conf,
        "source_pos": args.pos.split("/")[-1],
        "epochs": len(epochs),
        "fixed_epochs": len(fixed),
        "fix_rate": round(len(fixed) / len(epochs), 12),
        "first_fixed_index": first_fix,
        "first_fixed_time": epochs[first_fix]["time"] if first_fix is not None else None,
        "first_fixed_truth_time_utc": epochs[first_fix]["truth_time_utc"] if first_fix is not None else None,
        "final_status": last["fix_status"],
        "final_ratio": last["ratio"],
        "final_position_ecef_m": last["position_ecef_m"],
        "final_truth_ecef_m": last["truth_ecef_m"],
        "final_error_3d_m": last["error_3d_m"],
        "error_3d": metric_summary(errors_3d),
        "horizontal_error": metric_summary(horizontal),
        "vertical_abs_error": metric_summary(vertical_abs),
        "q_counts": {str(q): q_counts[q] for q in sorted(q_counts)},
        "satellites_min": min(e["satellites"] for e in epochs),
        "satellites_max": max(e["satellites"] for e in epochs),
    }

    truth_doc = {
        "frame": "WGS84 ECEF metres per epoch, derived from GSDC ground_truth.csv",
        "source_csv": args.truth_source or args.moving_truth_csv,
        "gps_utc_offset_s": args.gps_utc_offset_s,
        "epochs": len(truth),
    }

    if args.truth_time_tolerance_ms > 0:
        truth_doc["time_match_tolerance_ms"] = args.truth_time_tolerance_ms

    if args.base_station:
        truth_doc["base_station"] = {"id": args.base_station}
        if args.base_ecef_m:
            truth_doc["base_station"]["marker_ecef_m"] = round_xyz(args.base_ecef_m, 4)
        if args.base_distance_km is not None:
            truth_doc["base_station"]["distance_from_drive_start_km"] = round(args.base_distance_km, 3)

    inputs = {
        "drive": args.drive,
        "rover_obs": args.rover_source,
        "base_obs": args.base_source,
        "nav": args.nav_source,
    }

    doc = {
        "version": 1,
        "description": args.description,
        "generator": {
            "rtklib": {
                "program": "rnx2rtkp",
                "version": args.rtklib_version,
                "commit": args.rtklib_commit,
            },
            "config": args.conf,
            "script": "pos_to_oracle.py",
        },
        "inputs": inputs,
        "truth": truth_doc,
        "reference": ref,
        "per_epoch": epochs,
    }

    with open(args.out, "w") as fh:
        json.dump(doc, fh, indent=1)
        fh.write("\n")

    print(
        f"{args.out}: {ref['fixed_epochs']}/{ref['epochs']} fixed, "
        f"median_3d={ref['error_3d']['median_m']:.3f}m, p95_3d={ref['error_3d']['p95_m']:.3f}m"
    )


def static_oracle(args):
    pos, conf, label, desc, out = args.pos, args.conf, args.label, args.description, args.out
    truth = json.loads(Path(args.static_truth_json).read_text()) if args.static_truth_json else TRUTH
    epochs = parse_pos(pos)
    if not epochs:
        raise SystemExit("no RTKLIB epochs parsed from static .pos")

    fixed = [i for i, e in enumerate(epochs) if e["q"] == 1]
    q_counts = Counter(e["q"] for e in epochs)
    first_fix = fixed[0] if fixed else None
    last = epochs[-1]
    errors = [truth_err(e, truth) for e in epochs]
    ref = {
        "label": label,
        "config": conf,
        "source_pos": pos.split("/")[-1],
        "epochs": len(epochs),
        "fixed_epochs": len(fixed),
        "fix_rate": round(len(fixed) / len(epochs), 12),
        "first_fixed_index": first_fix,
        "first_fixed_time": epochs[first_fix]["time"] if first_fix is not None else None,
        "final_status": last["fix_status"],
        "final_ratio": last["ratio"],
        "final_baseline_enu_m": last["baseline_enu_m"],
        "final_truth_error_m": round(truth_err(last, truth), 12),
        "mean_truth_error_m": round(sum(errors) / len(errors), 12),
        "max_truth_error_m": round(max(errors), 12),
        "q_counts": {str(q): q_counts[q] for q in sorted(q_counts)},
        "satellites_min": min(e["satellites"] for e in epochs),
        "satellites_max": max(e["satellites"] for e in epochs),
    }
    doc = {
        "version": "1",
        "description": desc,
        "generator": {
            "rtklib": {
                "program": "rnx2rtkp",
                "version": args.rtklib_version,
                "commit": args.rtklib_commit,
            },
            "config": conf,
            "script": "pos_to_oracle.py",
        },
        "truth": truth,
        "reference": ref,
        "per_epoch": epochs,
    }
    inputs = static_inputs(args)
    if inputs:
        doc["inputs"] = inputs

    with open(out, "w") as fh:
        json.dump(doc, fh, indent=1)
        fh.write("\n")
    print(
        f"{out}: {ref['fixed_epochs']}/{ref['epochs']} fixed, "
        f"first_fix@{first_fix}, final_err={ref['final_truth_error_m']*1000:.1f}mm"
    )


def parse_args(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("pos")
    parser.add_argument("conf")
    parser.add_argument("label")
    parser.add_argument("description")
    parser.add_argument("out")
    parser.add_argument("--moving-truth-csv")
    parser.add_argument("--truth-source")
    parser.add_argument("--drive")
    parser.add_argument("--rover-source")
    parser.add_argument("--base-source")
    parser.add_argument("--nav-source")
    parser.add_argument("--sp3-source")
    parser.add_argument("--clk-source")
    parser.add_argument("--antex-source")
    parser.add_argument("--base-station")
    parser.add_argument("--base-ecef-m", type=parse_xyz_arg)
    parser.add_argument("--base-distance-km", type=float)
    parser.add_argument("--static-truth-json")
    parser.add_argument("--gps-utc-offset-s", type=int, default=18)
    parser.add_argument("--truth-time-tolerance-ms", type=int, default=0)
    parser.add_argument("--rtklib-version", default=RTKLIB["version"])
    parser.add_argument("--rtklib-commit", default=RTKLIB["commit"])
    return parser.parse_args(argv)


def main():
    args = parse_args(sys.argv[1:])
    if args.moving_truth_csv:
        moving_oracle(args)
    else:
        static_oracle(args)


if __name__ == "__main__":
    main()
