#!/usr/bin/env python3
"""Rebuild the C+D Phase 1 PASA/SCOA data fixtures.

This recipe downloads the raw public inputs, decodes the two Hatanaka
observation files with the Python `hatanaka` package, and trims the committed
2 h arc plus product margins used by the RTKLIB oracles.

Example:

    PYTHONPATH=/tmp/cd-phase1-tools/py python3 cd_phase1_pasa_scoa_2026_120.py \
      --work /tmp/cd-phase1-data/rebuild
"""

import argparse
import gzip
import hashlib
import json
import math
import shutil
from datetime import datetime
from pathlib import Path
from urllib.request import urlretrieve

try:
    import hatanaka
except ImportError as exc:
    raise SystemExit("install hatanaka or set PYTHONPATH to a directory containing it") from exc


RAW_URLS = {
    "PASA00ESP_R_20261200000_01D_30S_MO.crx.gz": "https://igs.bkg.bund.de/root_ftp/EUREF/obs/2026/120/PASA00ESP_R_20261200000_01D_30S_MO.crx.gz",
    "SCOA00FRA_R_20261200000_01D_30S_MO.crx.gz": "https://igs.bkg.bund.de/root_ftp/EUREF/obs/2026/120/SCOA00FRA_R_20261200000_01D_30S_MO.crx.gz",
    "BRDC00WRD_R_20261200000_01D_MN.rnx.gz": "https://igs.bkg.bund.de/root_ftp/IGS/BRDC/2026/120/BRDC00WRD_R_20261200000_01D_MN.rnx.gz",
    "IGS0OPSFIN_20261200000_01D_15M_ORB.SP3.gz": "https://igs.bkg.bund.de/root_ftp/IGS/products/2416/IGS0OPSFIN_20261200000_01D_15M_ORB.SP3.gz",
    "IGS0OPSFIN_20261200000_01D_30S_CLK.CLK.gz": "https://igs.bkg.bund.de/root_ftp/IGS/products/2416/IGS0OPSFIN_20261200000_01D_30S_CLK.CLK.gz",
    "igs20.atx": "https://files.igs.org/pub/station/general/igs20.atx",
    "EUR0OPSSNX_1996001_2025270_00U_SOL.SSC": "https://epncb.oma.be/pub/product/referenceframe/C2385/EUR0OPSSNX_1996001_2025270_00U_SOL.SSC",
    "pasa00esp_20251003.log": "https://epncb.oma.be/pub/station/log/pasa00esp_20251003.log",
    "scoa00fra_20251209.log": "https://epncb.oma.be/pub/station/log/scoa00fra_20251209.log",
}

START = datetime(2026, 4, 30, 10, 0, 0)
END = datetime(2026, 4, 30, 11, 59, 30)
MID = datetime(2026, 4, 30, 11, 0, 0)
COORD_EPOCH = datetime(2020, 1, 1, 0, 0, 0)
NAV_START = datetime(2026, 4, 30, 8, 0, 0)
NAV_END = datetime(2026, 4, 30, 14, 0, 0)
SP3_START = datetime(2026, 4, 30, 9, 45, 0)
SP3_END = datetime(2026, 4, 30, 12, 15, 0)
CLK_START = datetime(2026, 4, 30, 9, 59, 30)
CLK_END = datetime(2026, 4, 30, 12, 0, 30)

STATIONS = {
    "PASA00ESP": {
        "name": "Pasaia, Spain",
        "domes": "19351S001",
        "antenna": "LEIAR20         LEIM",
        "receiver": "LEICA GR30",
        "log": "pasa00esp_20251003.log",
        "xyz": (4644909.0560, -156645.0592, 4353623.0839),
        "vel": (-0.0109, 0.0193, 0.0118),
    },
    "SCOA00FRA": {
        "name": "Ciboure, France",
        "domes": "10088M002",
        "antenna": "TRM55971.00     NONE",
        "receiver": "LEICA GR50",
        "log": "scoa00fra_20251209.log",
        "xyz": (4639940.5055, -136224.9318, 4359552.4338),
        "vel": (-0.0120, 0.0190, 0.0109),
    },
}

WGS84_A_M = 6378137.0
WGS84_F = 1.0 / 298.257223563
WGS84_E2 = WGS84_F * (2.0 - WGS84_F)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def download_raw(raw_dir):
    raw_dir.mkdir(parents=True, exist_ok=True)
    for name, url in RAW_URLS.items():
        path = raw_dir / name
        if not path.exists():
            print(f"download {name}")
            urlretrieve(url, path)
        print(f"{sha256(path)}  {name}")


def time_line(dt):
    return (
        f"  {dt.year:4d}    {dt.month:02d}    {dt.day:02d}    "
        f"{dt.hour:02d}    {dt.minute:02d}   {dt.second:2d}.0000000     GPS         "
    )


def is_obs_epoch(line):
    return line.startswith("> ") and len(line.split()) >= 8 and line.split()[1].isdigit()


def trim_obs(src, dst):
    lines = src.read_text().splitlines(True)
    header = []
    i = 0

    while i < len(lines):
        line = lines[i]
        if "TIME OF FIRST OBS" in line:
            line = time_line(START).ljust(60) + "TIME OF FIRST OBS\n"
        elif "TIME OF LAST OBS" in line:
            line = time_line(END).ljust(60) + "TIME OF LAST OBS\n"

        header.append(line)
        i += 1

        if "END OF HEADER" in line:
            break

    out = header[:]
    kept = 0

    while i < len(lines):
        if not is_obs_epoch(lines[i]):
            i += 1
            continue

        j = i + 1
        while j < len(lines) and not is_obs_epoch(lines[j]):
            j += 1

        parts = lines[i][1:].split()
        dt = datetime(
            int(parts[0]),
            int(parts[1]),
            int(parts[2]),
            int(parts[3]),
            int(parts[4]),
            int(float(parts[5])),
        )

        if START <= dt <= END:
            out.extend(lines[i:j])
            kept += 1

        i = j

    dst.write_text("".join(out))
    print(f"{dst.name}: {kept} epochs")


def nav_block_len(system):
    return 4 if system in "RS" else 8


def trim_nav(src, dst):
    lines = src.read_text(errors="ignore").splitlines(True)
    header = []
    i = 0

    while i < len(lines):
        header.append(lines[i])
        i += 1
        if "END OF HEADER" in lines[i - 1]:
            break

    out = header[:]
    kept = 0

    while i < len(lines):
        system = lines[i][0]
        n = nav_block_len(system)

        if system not in "GRECJIS":
            i += 1
            continue

        fields = lines[i][1:].split()
        try:
            dt = datetime(
                int(fields[1]),
                int(fields[2]),
                int(fields[3]),
                int(fields[4]),
                int(fields[5]),
                int(float(fields[6])),
            )
        except (IndexError, ValueError):
            i += 1
            continue

        if NAV_START <= dt <= NAV_END:
            out.extend(lines[i : i + n])
            kept += 1

        i += n

    dst.write_text("".join(out))
    print(f"{dst.name}: {kept} nav blocks")


def trim_sp3(src, dst):
    lines = src.read_text(errors="ignore").splitlines(True)
    out = []
    i = 0

    while i < len(lines) and not lines[i].startswith("*"):
        out.append(lines[i])
        i += 1

    kept = 0

    while i < len(lines):
        if lines[i].startswith("EOF"):
            break
        if not lines[i].startswith("*"):
            i += 1
            continue

        fields = lines[i].split()
        dt = datetime(
            int(fields[1]),
            int(fields[2]),
            int(fields[3]),
            int(fields[4]),
            int(fields[5]),
            int(float(fields[6])),
        )
        j = i + 1
        while j < len(lines) and not lines[j].startswith("*") and not lines[j].startswith("EOF"):
            j += 1

        if SP3_START <= dt <= SP3_END:
            out.extend(lines[i:j])
            kept += 1

        i = j

    out.append("EOF\n")
    dst.write_text("".join(out))
    print(f"{dst.name}: {kept} SP3 epochs")


def trim_clk(src, dst):
    lines = src.read_text(errors="ignore").splitlines(True)
    out = []
    i = 0

    while i < len(lines):
        out.append(lines[i])
        i += 1
        if "END OF HEADER" in lines[i - 1]:
            break

    kept = 0

    for line in lines[i:]:
        if not (line.startswith("AS ") or line.startswith("AR ")):
            continue

        fields = line.split()
        if len(fields) < 9:
            continue

        dt = datetime(
            int(fields[2]),
            int(fields[3]),
            int(fields[4]),
            int(fields[5]),
            int(fields[6]),
            int(float(fields[7])),
        )

        if CLK_START <= dt <= CLK_END:
            out.append(line)
            kept += 1

    dst.write_text("".join(out))
    print(f"{dst.name}: {kept} CLK records")


def trim_antex(src, dst):
    lines = src.read_text(errors="ignore").splitlines(True)
    header = []
    i = 0

    while i < len(lines) and "START OF ANTENNA" not in lines[i]:
        header.append(lines[i])
        i += 1

    out = header[:]

    while i < len(lines):
        if "START OF ANTENNA" not in lines[i]:
            i += 1
            continue

        j = i + 1
        while j < len(lines) and "END OF ANTENNA" not in lines[j]:
            j += 1
        j += 1

        block = lines[i:j]
        type_line = next((line for line in block if "TYPE / SERIAL NO" in line), "")
        antenna = type_line[:20].strip()
        serial = type_line[20:40].strip()

        if serial.startswith("G") or antenna in {"LEIAR20         LEIM", "TRM55971.00     NONE"}:
            out.extend(block)

        i = j

    dst.write_text("".join(out))
    print(f"{dst.name}: {dst.stat().st_size} bytes")


def gunzip(src, dst):
    with gzip.open(src, "rb") as inp, open(dst, "wb") as out:
        shutil.copyfileobj(inp, out)


def ecef_to_geodetic(x, y, z):
    lon = math.atan2(y, x)
    p = math.hypot(x, y)
    lat = math.atan2(z, p * (1.0 - WGS84_E2))

    for _ in range(10):
        sin_lat = math.sin(lat)
        n = WGS84_A_M / math.sqrt(1.0 - WGS84_E2 * sin_lat * sin_lat)
        h = p / math.cos(lat) - n
        lat = math.atan2(z, p * (1.0 - WGS84_E2 * n / (n + h)))

    sin_lat = math.sin(lat)
    n = WGS84_A_M / math.sqrt(1.0 - WGS84_E2 * sin_lat * sin_lat)
    h = p / math.cos(lat) - n
    return math.degrees(lat), math.degrees(lon), h


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


def round_xyz(xyz):
    return {"x": round(xyz[0], 6), "y": round(xyz[1], 6), "z": round(xyz[2], 6)}


def station_log_sha(raw_dir, station):
    return sha256(raw_dir / STATIONS[station]["log"])


def write_truth(raw_dir, dst):
    years = (MID - COORD_EPOCH).total_seconds() / (86400.0 * 365.25)
    propagated = {}

    for station, row in STATIONS.items():
        propagated[station] = tuple(row["xyz"][i] + years * row["vel"][i] for i in range(3))

    base = propagated["SCOA00FRA"]
    rover = propagated["PASA00ESP"]
    lat, lon, height = ecef_to_geodetic(*base)
    delta = tuple(rover[i] - base[i] for i in range(3))
    baseline_enu = ecef_delta_to_enu(*delta, lat, lon)

    truth = {
        "frame": "ITRF2020 ECEF metres propagated to 2026-04-30T11:00:00 GPST; ENU baseline at SCOA00FRA ARP, metres",
        "source": {
            "product": "EPN C2385 multi-year position and velocity solution",
            "url": RAW_URLS["EUR0OPSSNX_1996001_2025270_00U_SOL.SSC"],
            "sha256": sha256(raw_dir / "EUR0OPSSNX_1996001_2025270_00U_SOL.SSC"),
            "coordinate_epoch": "2020-01-01T00:00:00",
            "observation_midpoint_gpst": "2026-04-30T11:00:00",
            "years_since_coordinate_epoch": round(years, 11),
        },
        "frame_handling": "Station coordinates are the latest C2385 ITRF2020 rows valid on 2026-04-30. X/Y/Z were propagated from epoch 2020-01-01 to the arc midpoint using the published C2385 velocities and a 365.25-day Julian year. Both station logs and RINEX headers report zero marker-to-ARP eccentricities for the active antennas, so marker and ARP coordinates are identical here. No extra plate model was applied beyond the published ITRF2020 velocities; over the 2 h arc, intraday linear motion is negligible for this oracle.",
        "base_station": station_doc(raw_dir, "SCOA00FRA", base, (lat, lon, height)),
        "rover_station": station_doc(raw_dir, "PASA00ESP", rover, None),
        "baseline_ecef_m": round_xyz(delta),
        "baseline_length_km": round(math.sqrt(sum(v * v for v in delta)) / 1000.0, 9),
        "antenna_baseline_enu_m": {
            "east": baseline_enu[0],
            "north": baseline_enu[1],
            "up": round(baseline_enu[2], 12),
        },
    }

    dst.write_text(json.dumps(truth, indent=2) + "\n")


def station_doc(raw_dir, station, xyz, geodetic):
    row = STATIONS[station]
    doc = {
        "id": station,
        "name": row["name"],
        "domes": row["domes"],
        "antenna": row["antenna"],
        "receiver": row["receiver"],
        "station_log": RAW_URLS[row["log"]],
        "station_log_sha256": station_log_sha(raw_dir, station),
        "marker_to_arp_enu_m": {"east": 0.0, "north": 0.0, "up": 0.0},
        "c2385_itrf2020_at_epoch_m": round_xyz(row["xyz"]),
        "c2385_itrf2020_velocity_m_per_y": round_xyz(row["vel"]),
        "marker_ecef_m": round_xyz(xyz),
    }

    if geodetic:
        doc["geodetic_deg_m"] = {
            "latitude": round(geodetic[0], 12),
            "longitude": round(geodetic[1], 12),
            "height": round(geodetic[2], 6),
        }

    return doc


def build(work):
    raw = work / "raw"
    decoded = work / "decoded"
    trim = work / "trim"
    decoded.mkdir(parents=True, exist_ok=True)
    trim.mkdir(parents=True, exist_ok=True)

    download_raw(raw)

    for name in [
        "PASA00ESP_R_20261200000_01D_30S_MO.crx.gz",
        "SCOA00FRA_R_20261200000_01D_30S_MO.crx.gz",
    ]:
        out = decoded / name.replace(".crx.gz", ".rnx")
        out.write_bytes(hatanaka.decompress(raw / name))

    gunzip(raw / "BRDC00WRD_R_20261200000_01D_MN.rnx.gz", decoded / "BRDC00WRD_R_20261200000_01D_MN.rnx")
    gunzip(raw / "IGS0OPSFIN_20261200000_01D_15M_ORB.SP3.gz", decoded / "IGS0OPSFIN_20261200000_01D_15M_ORB.SP3")
    gunzip(raw / "IGS0OPSFIN_20261200000_01D_30S_CLK.CLK.gz", decoded / "IGS0OPSFIN_20261200000_01D_30S_CLK.CLK")

    trim_obs(decoded / "PASA00ESP_R_20261200000_01D_30S_MO.rnx", trim / "PASA00ESP_R_20261201000_02H_30S_MO.rnx")
    trim_obs(decoded / "SCOA00FRA_R_20261200000_01D_30S_MO.rnx", trim / "SCOA00FRA_R_20261201000_02H_30S_MO.rnx")
    trim_nav(decoded / "BRDC00WRD_R_20261200000_01D_MN.rnx", trim / "BRDC00WRD_R_20261200800_06H_MN.rnx")
    trim_sp3(decoded / "IGS0OPSFIN_20261200000_01D_15M_ORB.SP3", trim / "IGS0OPSFIN_20261200945_02H30M_15M_ORB.SP3")
    trim_clk(decoded / "IGS0OPSFIN_20261200000_01D_30S_CLK.CLK", trim / "IGS0OPSFIN_2026120095930_02H01M_30S_CLK.CLK")
    trim_antex(raw / "igs20.atx", trim / "igs20_pasa_scoa_gps.atx")
    write_truth(raw, trim / "cd_pasa_scoa_2026_120_truth.json")

    print("\ntrimmed checksums:")
    for path in sorted(trim.iterdir()):
        print(f"{sha256(path)}  {path.name}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--work", default="/tmp/cd-phase1-data/rebuild")
    args = parser.parse_args()
    build(Path(args.work))


if __name__ == "__main__":
    main()
