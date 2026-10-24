#!/usr/bin/env python3
"""Set the VRAM BAR window in a rocjitsu config.

``vm.gpu.pci.vram_aperture_bytes`` is the size of BAR0 the vfio-user front end
advertises.  Upstream ships ``gfx1250_mi455x.json`` at 268435456 -- 256 MiB,
the small-BAR ceiling -- so a guest can only ever see a 256 MiB window onto a
432 GiB device and has to page the rest through the GART.  Large BAR is this
field and nothing else: there is no CLI flag for it, and no environment
variable rocjitsu reads instead.

rocjitsu validates the value at startup and refuses to grow it for you:

  * larger than ``vm.gpu.device.local_mem_size`` warns "the video memory
    aperture is larger than the memory itself"
  * not a power of two warns "... is not a power of two"

so ``max`` here means the largest power of two that is not larger than the
device's own memory -- 256 GiB for the 432 GiB gfx1250 profile.  Both of those
are warnings upstream, not errors; the device still serves, which is why this
resolves and asserts the value rather than letting a typo reach a guest as a
BAR that silently does not map.
"""

import argparse
import json
import sys
from pathlib import Path


def largest_power_of_two_within(limit: int) -> int:
    """The largest power of two <= limit."""
    if limit < 1:
        raise ValueError(f"no power of two fits in {limit} bytes")
    return 1 << (limit.bit_length() - 1)


def resolve(config: dict, spec: str) -> int | None:
    """Resolve a --bytes spec against a loaded config.

    Returns None for "keep", meaning leave whatever upstream shipped.
    """
    if spec == "keep":
        return None

    try:
        gpu = config["vm"]["gpu"]
    except KeyError as exc:
        raise SystemExit(f"config has no vm.gpu section: missing {exc}")

    local_mem = gpu.get("device", {}).get("local_mem_size")
    if not isinstance(local_mem, int):
        raise SystemExit(
            "config has no integer vm.gpu.device.local_mem_size, so there is "
            "nothing to size the aperture against"
        )

    if spec == "max":
        return largest_power_of_two_within(local_mem)

    try:
        want = int(spec, 0)
    except ValueError:
        raise SystemExit(f"--bytes must be max, keep or a byte count, not {spec!r}")

    if want <= 0:
        raise SystemExit(f"--bytes must be positive, not {want}")
    if want & (want - 1):
        raise SystemExit(f"--bytes must be a power of two, not {want}")
    if want > local_mem:
        raise SystemExit(
            f"--bytes {want} is larger than the device's own "
            f"vm.gpu.device.local_mem_size ({local_mem})"
        )
    return want


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument(
        "--bytes",
        default="max",
        help="max (largest power of two within local_mem_size), keep, "
        "or an explicit power-of-two byte count",
    )
    parser.add_argument(
        "--print-only",
        action="store_true",
        help="resolve and report without writing the config",
    )
    args = parser.parse_args()

    config = json.loads(args.config.read_text())
    gpu = config.get("vm", {}).get("gpu")
    if not isinstance(gpu, dict):
        raise SystemExit(f"{args.config} has no vm.gpu section")

    # Created when absent rather than demanded. gfx1250_mi455x.json is the only
    # profile upstream gives a pci block to at all, so requiring one would mean
    # that repointing ROCJITSU_CONFIG at any other profile -- the entire reason
    # that var exists -- failed the build here. rocjitsu reads a pci block it
    # was not shipped with and serves normally.
    pci = gpu.setdefault("pci", {})
    if not isinstance(pci, dict):
        raise SystemExit(f"{args.config} has a vm.gpu.pci that is not an object")

    before = pci.get("vram_aperture_bytes")
    want = resolve(config, args.bytes)

    if want is None or args.print_only:
        print(f"vram_aperture_bytes: {before} (unchanged)")
        return 0

    pci["vram_aperture_bytes"] = want
    args.config.write_text(json.dumps(config, indent=2) + "\n")
    print(f"vram_aperture_bytes: {before} -> {want}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
