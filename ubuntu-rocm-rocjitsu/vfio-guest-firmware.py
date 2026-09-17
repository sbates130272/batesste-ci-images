#!/usr/bin/env python3

"""Emit a complete, self-describing guest firmware set for a rocjitsu config.

Upstream's generator emits five header fixtures under hardwired gfx12.1 names
and nothing that says what they are, so every consumer has had to carry its own
gfx1250 knowledge to close the gap: fabricate the two MES names the driver
actually opens, hardcode a filename to prove the set arrived, and name a
generation on the `rj-ip-discovery` call. This wraps it and emits the whole set
plus a manifest naming every file, so copying firmware into a guest needs no
knowledge of this device model at all.

The fixture bytes are still upstream's -- this calls its builders rather than
reimplementing them.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path
from types import ModuleType

UPSTREAM = Path(
    os.environ.get(
        "ROCJITSU_FIRMWARE_UPSTREAM",
        "/usr/local/lib/rocjitsu/vfio_guest_firmware_upstream.py",
    )
)

# The fixture filenames carry IP versions -- gc_12_1_0, sdma_7_1_0 -- so
# upstream's table is gfx1250's and nobody else's, and rj-ip-discovery agrees:
# it knows one generation. The image ships thirteen other configs, and a stack
# that selects one of them should be told it has no firmware rather than handed
# gfx1250 stubs and left to fail in the guest's early init.
SUPPORTED_GENERATIONS = ("gfx1250",)

# Real mes.bin (pipe 0 scheduler) and mes1.bin (KIQ) are distinct blobs, but
# these are headers over a sentinel payload, not microcode: amdgpu parses the
# header and the version word in amdgpu_mes_init_microcode() and never executes
# what follows. One fixture is therefore correct under all three names. Writing
# the same bytes rather than rebuilding makes that identity rather than a
# property of the builder being deterministic.
MES_SOURCE = "gc_12_1_0_uni_mes.bin"
MES_ALIASES = ("gc_12_1_0_mes.bin", "gc_12_1_0_mes1.bin")

IP_DISCOVERY = "ip_discovery.bin"
MANIFEST = "manifest.json"

DEFAULT_CONFIG_DIR = "/usr/local/share/rocjitsu/configs"


class FirmwareError(Exception):
    """A requested firmware set cannot be produced."""


def load_upstream(path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location("vfio_guest_firmware_upstream", path)
    if spec is None or spec.loader is None:
        raise FirmwareError(f"cannot load the upstream generator: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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


def generate(*, output: Path, config: Path, ip_discovery: bool) -> None:
    generation, version = generation_for_config(config)
    if generation not in SUPPORTED_GENERATIONS:
        raise FirmwareError(
            f"{config.name} models {generation} (gfx_target_version {version}); "
            f"stub generation covers {', '.join(SUPPORTED_GENERATIONS)} only"
        )

    upstream = load_upstream(UPSTREAM)
    # Upstream rejects a symlinked output and refuses to overwrite, which is
    # the behaviour the aliases below hold to as well.
    try:
        upstream.generate(output)
    except upstream.FixtureError as error:
        raise FirmwareError(str(error)) from error

    mes = (output / MES_SOURCE).read_bytes()
    for alias in MES_ALIASES:
        path = output / alias
        if path.exists():
            raise FirmwareError(f"refusing to replace existing fixture: {path}")
        path.write_bytes(mes)

    files = [*upstream.FIXTURES, *MES_ALIASES]
    if ip_discovery:
        write_ip_discovery(generation, output / IP_DISCOVERY)
        files.append(IP_DISCOVERY)

    manifest = {
        "generation": generation,
        "gfx_target_version": version,
        "config": config.name,
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
        )
    except (FirmwareError, OSError) as error:
        print(f"vfio guest firmware generation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
