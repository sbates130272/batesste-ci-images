#!/usr/bin/env python3

"""Emit a complete, self-describing guest firmware set for a rocjitsu config.

Upstream deleted its stub generator when docs/qemu-vfio.md moved to "use the
firmware files from the same public driver release as the guest's amdgpu.ko",
and as of amdgpu 31.60 that release exists: amdgpu-dkms-firmware ships real
gc_12_1_0 mec/mec_1/rlc/rlc_1/uni_mes and sdma_7_1_0 blobs, and amdgpu-dkms
depends on it, so any guest with the driver already has them.

Two things it does not ship, which the driver still opens:

  gc_12_1_0_imu.bin -- AMDGPU_UCODE_REQUIRED whenever fw_load_type is not
    AMDGPU_FW_LOAD_PSP, which is exactly the amdgpu.fw_load_type=0 the vfio
    guest boots with. Its error propagates fatally out of
    gfx_v12_1_init_microcode and no amdgpu_emu_mode guard bypasses it.

  ip_discovery.bin -- amdgpu.discovery=2 reads it instead of polling BAR
    registers, and it comes from rj-ip-discovery, not from any package.

So the default output is that gap and nothing else: a set that lands beside the
packaged blobs rather than over them. `--set full` still emits the whole stub
set for a guest whose driver release predates the packaged firmware.

The fixture bytes are upstream's builders, vendored here at 730bc62 rather than
fetched: the file was deleted, so the only way to fetch it is from a commit on
a branch that has already been deleted once and can be pruned at any time.
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import subprocess
import sys
import zlib
from pathlib import Path

# The fixture filenames carry IP versions -- gc_12_1_0, sdma_7_1_0 -- so the
# table below is gfx1250's and nobody else's, and rj-ip-discovery agrees: it
# knows one generation. The image ships thirteen other configs, and a stack that
# selects one of them should be told it has no firmware rather than handed
# gfx1250 stubs and left to fail in the guest's early init.
SUPPORTED_GENERATIONS = ("gfx1250",)

IP_DISCOVERY = "ip_discovery.bin"
MANIFEST = "manifest.json"

DEFAULT_CONFIG_DIR = "/usr/local/share/rocjitsu/configs"

FIXED_HEADER_BYTES = 0x100
SENTINEL = 0x524A4657  # ASCII "RJFW" in big-endian display order.


class FirmwareError(Exception):
    """A requested firmware set cannot be produced."""


def common_header(
    *,
    total_size: int,
    header_size: int,
    header_major: int,
    header_minor: int,
    ip_major: int,
    ip_minor: int,
    ucode_size: int,
    ucode_offset: int,
    payload: bytes,
) -> bytes:
    return struct.pack(
        "<IIHHHHIIII",
        total_size,
        header_size,
        header_major,
        header_minor,
        ip_major,
        ip_minor,
        1,  # Synthetic fixture revision.
        ucode_size,
        ucode_offset,
        zlib.crc32(payload) & 0xFFFFFFFF,
    )


def padded_header(common: bytes, extension: bytes) -> bytearray:
    header = bytearray(FIXED_HEADER_BYTES)
    header[: len(common)] = common
    header[len(common) : len(common) + len(extension)] = extension
    return header


def rlc_fixture() -> bytes:
    payload = struct.pack("<I", SENTINEL)
    total_size = FIXED_HEADER_BYTES + len(payload)
    common = common_header(
        total_size=total_size,
        header_size=104,
        header_major=2,
        header_minor=0,
        ip_major=12,
        ip_minor=1,
        ucode_size=len(payload),
        ucode_offset=FIXED_HEADER_BYTES,
        payload=payload,
    )
    fields = [0] * 18
    fields[11] = FIXED_HEADER_BYTES
    fields[13] = FIXED_HEADER_BYTES
    fields[15] = FIXED_HEADER_BYTES
    fields[17] = FIXED_HEADER_BYTES
    return bytes(padded_header(common, struct.pack("<18I", *fields))) + payload


def mec_fixture() -> bytes:
    ucode = struct.pack("<I", SENTINEL)
    data = struct.pack("<I", SENTINEL)
    ucode_offset = FIXED_HEADER_BYTES
    data_offset = ucode_offset + len(ucode)
    total_size = data_offset + len(data)
    common = common_header(
        total_size=total_size,
        header_size=60,
        header_major=2,
        header_minor=0,
        ip_major=12,
        ip_minor=1,
        ucode_size=len(ucode),
        ucode_offset=ucode_offset,
        payload=ucode,
    )
    extension = struct.pack(
        "<7I",
        0,  # Feature version.
        len(ucode),
        ucode_offset,
        len(data),
        data_offset,
        0x3000,
        0,
    )
    return bytes(padded_header(common, extension)) + ucode + data


def sdma_fixture() -> bytes:
    payload = struct.pack("<I", SENTINEL)
    total_size = FIXED_HEADER_BYTES + len(payload)
    common = common_header(
        total_size=total_size,
        header_size=44,
        header_major=3,
        header_minor=0,
        ip_major=7,
        ip_minor=1,
        ucode_size=len(payload),
        ucode_offset=FIXED_HEADER_BYTES,
        payload=payload,
    )
    extension = struct.pack("<3I", 0, FIXED_HEADER_BYTES, len(payload))
    return bytes(padded_header(common, extension)) + payload


def mes_fixture() -> bytes:
    ucode_words = [SENTINEL] * 32
    ucode_words[24] = 1  # Version field read by amdgpu_mes_init_microcode().
    ucode = struct.pack("<32I", *ucode_words)
    data = struct.pack("<I", SENTINEL)
    ucode_offset = FIXED_HEADER_BYTES
    data_offset = ucode_offset + len(ucode)
    total_size = data_offset + len(data)
    common = common_header(
        total_size=total_size,
        header_size=72,
        header_major=1,
        header_minor=0,
        ip_major=12,
        ip_minor=1,
        ucode_size=len(ucode),
        ucode_offset=ucode_offset,
        payload=ucode,
    )
    extension = struct.pack(
        "<10I",
        1,
        len(ucode),
        ucode_offset,
        1,
        len(data),
        data_offset,
        0x3000,
        0,
        0,
        0,
    )
    return bytes(padded_header(common, extension)) + ucode + data


def imu_fixture() -> bytes:
    iram = struct.pack("<I", SENTINEL)
    dram = struct.pack("<I", SENTINEL)
    iram_offset = FIXED_HEADER_BYTES
    dram_offset = iram_offset + len(iram)
    total_size = dram_offset + len(dram)
    common = common_header(
        total_size=total_size,
        header_size=48,
        header_major=1,
        header_minor=0,
        ip_major=12,
        ip_minor=1,
        ucode_size=len(iram) + len(dram),
        ucode_offset=iram_offset,
        payload=iram + dram,
    )
    extension = struct.pack("<4I", len(iram), iram_offset, len(dram), dram_offset)
    return bytes(padded_header(common, extension)) + iram + dram


FIXTURES = {
    "gc_12_1_0_imu.bin": imu_fixture,
    "gc_12_1_0_mec.bin": mec_fixture,
    "gc_12_1_0_rlc_1.bin": rlc_fixture,
    "gc_12_1_0_uni_mes.bin": mes_fixture,
    "sdma_7_1_0.bin": sdma_fixture,
}

# Names amdgpu opens that are the same header format as a fixture above, so one
# builder's bytes are correct under both. These are headers over a sentinel
# payload, not microcode: amdgpu parses the header and a version word and never
# executes what follows.
#
#   mes/mes1 -- real pipe-0 scheduler and KIQ blobs are distinct, but amdgpu
#     only opens them when amdgpu_uni_mes=0, which is not the default.
#   mec_1, rlc -- which of the bare and _1 spellings the driver requests turns
#     on adev->rev_id, which soc_v1_0_set_rev_id derives from an NBIO register
#     and the IP-discovery die rev rather than from PCI config space. The
#     packaged firmware ships both spellings; emitting both here means a
#     stub-only guest does not have to predict which one it will be asked for.
ALIASES = {
    "gc_12_1_0_uni_mes.bin": ("gc_12_1_0_mes.bin", "gc_12_1_0_mes1.bin"),
    "gc_12_1_0_mec.bin": ("gc_12_1_0_mec_1.bin",),
    "gc_12_1_0_rlc_1.bin": ("gc_12_1_0_rlc.bin",),
}

# Shipped by amdgpu-dkms-firmware from 31.60 on, which amdgpu-dkms depends on:
# a guest with the driver has these already, under /lib/firmware/updates/amdgpu.
# Overwriting real microcode with a sentinel stub is strictly worse, so the
# default set omits them.
PACKAGED = frozenset(
    (
        "gc_12_1_0_mec.bin",
        "gc_12_1_0_mec_1.bin",
        "gc_12_1_0_rlc.bin",
        "gc_12_1_0_rlc_1.bin",
        "gc_12_1_0_uni_mes.bin",
        "sdma_7_1_0.bin",
    )
)

SETS = ("gap", "full")


def resolve_config(name: str) -> Path:
    path = Path(name)
    if path.parent == Path("."):
        path = Path(os.environ.get("ROCJITSU_CONFIG_DIR", DEFAULT_CONFIG_DIR)) / name
    if not path.is_file():
        raise FirmwareError(f"no such config: {path}")
    return path


def find_target_version(node: object) -> int | None:
    """The first gfx_target_version anywhere in a config.

    It sits under vm.gpu.device in a served config and under
    dbt_guest.guest_device in a guest-on-host one, so it is searched for rather
    than addressed.
    """
    if isinstance(node, dict):
        if "gfx_target_version" in node:
            return node["gfx_target_version"]
        for value in node.values():
            found = find_target_version(value)
            if found is not None:
                return found
    elif isinstance(node, list):
        for value in node:
            found = find_target_version(value)
            if found is not None:
                return found
    return None


def generation_of(version: int) -> str:
    """gfx_target_version to the generation name the tooling uses.

    AMD packs the version as decimal major * 10000 + minor * 100 + step and
    renders minor and step as hex digits: 120500 is gfx1250, 90010 is gfx90a.
    """
    return f"gfx{version // 10000}{version // 100 % 100:x}{version % 100:x}"


def generation_for_config(config: Path) -> tuple[str, int]:
    try:
        parsed = json.loads(config.read_text())
    except json.JSONDecodeError as error:
        raise FirmwareError(f"{config} is not valid JSON: {error}") from error
    version = find_target_version(parsed)
    if not isinstance(version, int):
        raise FirmwareError(f"{config} names no gfx_target_version")
    return generation_of(version), version


def write_ip_discovery(generation: str, path: Path) -> None:
    try:
        subprocess.run(
            ["rj-ip-discovery", generation, str(path)],
            check=True,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as error:
        raise FirmwareError(
            "rj-ip-discovery is not on PATH; pass --no-ip-discovery to emit "
            "the header fixtures alone"
        ) from error
    except subprocess.CalledProcessError as error:
        raise FirmwareError(
            f"rj-ip-discovery {generation} failed: {error.stderr.strip()}"
        ) from error
    # A guest handed an empty ip_discovery.bin hangs in hw_init rather than
    # failing, so an exit status alone is not enough to report success on.
    if not path.is_file() or path.stat().st_size == 0:
        raise FirmwareError(f"rj-ip-discovery produced nothing at {path}")


def planned_files(firmware_set: str) -> dict[str, str]:
    """Every fixture name to emit, mapped to the builder key that produces it."""
    planned: dict[str, str] = {}
    for source in FIXTURES:
        for name in (source, *ALIASES.get(source, ())):
            if firmware_set == "gap" and name in PACKAGED:
                continue
            planned[name] = source
    return planned


def generate(
    *, output: Path, config: Path, ip_discovery: bool, firmware_set: str
) -> None:
    generation, version = generation_for_config(config)
    if generation not in SUPPORTED_GENERATIONS:
        raise FirmwareError(
            f"{config.name} models {generation} (gfx_target_version {version}); "
            f"stub generation covers {', '.join(SUPPORTED_GENERATIONS)} only"
        )

    if output.is_symlink():
        raise FirmwareError(f"output is a symlink: {output}")
    output.mkdir(parents=True, exist_ok=True)

    planned = planned_files(firmware_set)
    for name in planned:
        if (output / name).exists():
            raise FirmwareError(
                f"refusing to replace existing fixture: {output / name}"
            )

    built: dict[str, bytes] = {}
    for name, source in planned.items():
        if source not in built:
            built[source] = FIXTURES[source]()
        (output / name).write_bytes(built[source])

    files = list(planned)
    if ip_discovery:
        write_ip_discovery(generation, output / IP_DISCOVERY)
        files.append(IP_DISCOVERY)

    manifest = {
        "generation": generation,
        "gfx_target_version": version,
        "config": config.name,
        "set": firmware_set,
        # What the set deliberately leaves to the guest's own driver release.
        # A consumer that finds one of these missing in the guest is looking at
        # a firmware package older than 31.60, not at a bug here.
        "packaged_by_driver_release": sorted(PACKAGED - set(files)),
        "files": sorted(files),
    }
    (output / MANIFEST).write_text(json.dumps(manifest, indent=2) + "\n")


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--config",
        default=os.environ.get("ROCJITSU_CONFIG_PATH", "gfx1250_mi455x.json"),
        help="a config name under ROCJITSU_CONFIG_DIR, or a path. Defaults to "
        "ROCJITSU_CONFIG_PATH, the config this image serves.",
    )
    parser.add_argument(
        "--set",
        dest="firmware_set",
        choices=SETS,
        default="gap",
        help="gap (default) emits only what no amdgpu-dkms-firmware release "
        "ships -- gc_12_1_0_imu.bin -- for a guest that has the packaged "
        "blobs. full emits the whole stub set, for a guest whose driver "
        "release predates them.",
    )
    parser.add_argument(
        "--no-ip-discovery",
        dest="ip_discovery",
        action="store_false",
        help="emit the header fixtures alone, leaving ip_discovery.bin to a "
        "separate rj-ip-discovery call",
    )
    args = parser.parse_args(arguments)
    try:
        generate(
            output=args.output,
            config=resolve_config(args.config),
            ip_discovery=args.ip_discovery,
            firmware_set=args.firmware_set,
        )
    except (FirmwareError, OSError) as error:
        print(f"vfio guest firmware generation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
