#!/usr/bin/env python3
"""
ci-images-tool.py

Build, push, inspect, and query OCI registry status for
the batesste-ci-images Docker image collection.

Replaces build-and-push.sh with a richer CLI.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

import docker
import requests
from dotenv import load_dotenv
from rich.console import Console
from rich.table import Table

console = Console()

DEFAULT_QEMU_REPO = "https://gitlab.com/qemu-project/qemu.git"
DEFAULT_QEMU_COMMIT = "v11.1.1"
DEFAULT_LIBVFIO_USER_COMMIT = "323f4cb6cddc3713fb7aebe44436f28b28b5413a"
DEFAULT_QEMU_MINIMAL_REPO = "https://github.com/sbates130272/qemu-minimal.git"
DEFAULT_QEMU_MINIMAL_COMMIT = "225a81766b87ad2adb4e93d71bb8ed5e4e996466"
DEFAULT_KVM = True
DEFAULT_REGISTRY = "docker.io"
DEFAULT_IMAGE_TAG = "latest"
DEFAULT_USERNAME = "batesste"
DEFAULT_PASSWORD = "changeme"
DEFAULT_RELEASE = "noble"
DEFAULT_ARCH = "amd64"
DEFAULT_CUDA_VERSION = "13-3"
DEFAULT_ROCM_VERSION = "7.14"
DEFAULT_ROCM_STREAM = "therock"
DEFAULT_ROCM_ERNIC_COMMIT = "e3ef00c2a0c1ba1df95e6cbbe9362c2a1ad1d2fb"
DEFAULT_ROCM_ROCJITSU_REPO = "https://github.com/ROCm/rocm-systems.git"
DEFAULT_ROCM_ROCJITSU_BRANCH = "develop"
DEFAULT_ROCM_ROCJITSU_COMMIT = "5e9cc7c57d372c0198fd8decb1fe5ceb07038a2b"
DEFAULT_FIO_REPO = "https://github.com/axboe/fio.git"
DEFAULT_FIO_COMMIT = "975ea1856fee9f4c0f01f6f19ba3c61ce24f9bc8"
FIO_IMAGE_DIR = "ubuntu-cuda-rocm-fio"
FIO_BASE_IMAGE_DIR = "ubuntu-cuda-rocm"

BASE_IMAGE_DIR = "ubuntu-base"
VFU_IMAGE_DIR = "ubuntu-libvfio-user"

# Which image each image is layered on. Everything not listed here builds
# straight from a public upstream tag. Ordering used to fall out of the
# alphabetical sort in discover_images(); state it instead, so adding an
# image cannot silently reorder a base after its dependant.
IMAGE_BASES = {
    "ubuntu-cuda-rocm": BASE_IMAGE_DIR,
    "ubuntu-kernel-build": BASE_IMAGE_DIR,
    "ubuntu-rocm-rocjitsu": BASE_IMAGE_DIR,
    VFU_IMAGE_DIR: BASE_IMAGE_DIR,
    "ubuntu-qemu-libvfio-user": VFU_IMAGE_DIR,
    "ubuntu-rocm-ernic": VFU_IMAGE_DIR,
    FIO_IMAGE_DIR: FIO_BASE_IMAGE_DIR,
}

_SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
_VERSION_RE = re.compile(r"^\d+(\.\d+)*$")
_SHA_RE = re.compile(r"^[0-9a-f]{40}$")

BUILDER_NAME = "builder"
BUILDKITD_FLAGS = (
    "--allow-insecure-entitlement=security.insecure "
    "--allow-insecure-entitlement=network.host"
)

ENV_SEARCH_PATHS = [
    ".env",
    "/etc/batesste-ci-images/.env",
]


def resolve_image_tag(raw: str | None = None) -> str:
    """Return the effective OCI image tag.

    When unset, empty, or set to ``auto``/``date``, use today's UTC date in ISO
    basic form ``20260526`` -- it sorts lexically and is unambiguous next to a
    semver.  Otherwise return the provided tag (e.g. ``latest``, ``1.1.0``).
    """

    if raw is None:
        raw = os.environ.get("IMAGE_TAG", "")
    tag = (raw or "").strip()
    if not tag or tag.lower() in {"auto", "date"}:
        return datetime.now(tz=timezone.utc).strftime("%Y%m%d")
    return tag


# ── configuration ──────────────────────────────────────


@dataclass
class Config:
    """Centralised configuration built from env + CLI."""

    image_tag: str = DEFAULT_IMAGE_TAG
    registry: str = DEFAULT_REGISTRY
    registry_image: str = ""
    registry_username: str = ""
    registry_password: str = ""
    workdir: Path = field(default_factory=Path.cwd)

    qemu_repo: str = DEFAULT_QEMU_REPO
    qemu_commit: str = DEFAULT_QEMU_COMMIT
    libvfio_user_commit: str = DEFAULT_LIBVFIO_USER_COMMIT
    qemu_minimal_repo: str = DEFAULT_QEMU_MINIMAL_REPO
    qemu_minimal_commit: str = DEFAULT_QEMU_MINIMAL_COMMIT
    kvm: bool = DEFAULT_KVM

    username: str = DEFAULT_USERNAME
    vm_name: str = ""
    password: str = DEFAULT_PASSWORD
    release: str = DEFAULT_RELEASE
    arch: str = DEFAULT_ARCH
    cuda_version: str = DEFAULT_CUDA_VERSION
    rocm_version: str = DEFAULT_ROCM_VERSION
    rocm_stream: str = DEFAULT_ROCM_STREAM
    rocm_ernic_commit: str = DEFAULT_ROCM_ERNIC_COMMIT
    rocm_rocjitsu_repo: str = DEFAULT_ROCM_ROCJITSU_REPO
    rocm_rocjitsu_branch: str = DEFAULT_ROCM_ROCJITSU_BRANCH
    rocm_rocjitsu_commit: str = DEFAULT_ROCM_ROCJITSU_COMMIT
    fio_repo: str = DEFAULT_FIO_REPO
    fio_commit: str = DEFAULT_FIO_COMMIT
    fio_base_image: str = ""


def _resolve_password(
    password_file_cli: str | None,
    cfg: Config,
) -> str:
    """Resolve registry password: CLI file > env file >
    env literal.  Mirrors the shell script precedence."""

    pw_file: str | None = None

    if password_file_cli:
        pw_file = password_file_cli
    else:
        env_pw_file = os.environ.get("REGISTRY_PASSWORD_FILE", "")
        if env_pw_file:
            pw_file = env_pw_file
        elif cfg.registry_password and Path(cfg.registry_password).is_file():
            pw_file = cfg.registry_password

    if pw_file:
        p = Path(pw_file)
        if not p.is_file():
            console.print(f"[red]Error:[/] password file not found: {pw_file}")
            sys.exit(1)
        return p.read_text().strip()

    return cfg.registry_password


def _env_or_default(name: str, default: str) -> str:
    """Env value, falling back to ``default`` when unset or
    empty.  ``none`` explicitly disables the setting."""

    val = os.environ.get(name, "").strip()
    if not val:
        return default
    if val.lower() == "none":
        return ""
    return val


def _env_bool(name: str, default: bool) -> bool:
    val = os.environ.get(name, "").strip().lower()
    if not val:
        return default
    return val in {"1", "true", "yes", "on"}


def load_config(
    env_file: str | None = None,
    password_file: str | None = None,
) -> Config:
    """Load .env then populate a Config from the
    environment, applying defaults."""

    script_dir = Path(__file__).resolve().parent

    if env_file:
        load_dotenv(env_file, override=True)
    else:
        loaded = False
        env_in_script = script_dir / ".env"
        if env_in_script.is_file():
            load_dotenv(str(env_in_script), override=True)
            loaded = True
        if not loaded:
            for p in ENV_SEARCH_PATHS:
                if Path(p).is_file():
                    load_dotenv(p, override=True)
                    break

    workdir_env = os.environ.get("WORKDIR", "")
    if workdir_env and Path(workdir_env).is_dir():
        workdir = Path(workdir_env)
    else:
        if workdir_env:
            console.print(
                f"[yellow]Warning:[/] WORKDIR "
                f"{workdir_env} does not exist, using "
                f"script directory: {script_dir}"
            )
        workdir = script_dir

    cfg = Config(
        image_tag=resolve_image_tag(os.environ.get("IMAGE_TAG")),
        registry=os.environ.get("REGISTRY", DEFAULT_REGISTRY),
        registry_image=os.environ.get("REGISTRY_IMAGE", ""),
        registry_username=os.environ.get("REGISTRY_USERNAME", ""),
        registry_password=os.environ.get("REGISTRY_PASSWORD", ""),
        workdir=workdir,
        qemu_repo=os.environ.get("QEMU_REPO", DEFAULT_QEMU_REPO),
        qemu_commit=_env_or_default("QEMU_COMMIT", DEFAULT_QEMU_COMMIT),
        libvfio_user_commit=os.environ.get(
            "LIBVFIO_USER_COMMIT",
            DEFAULT_LIBVFIO_USER_COMMIT,
        ),
        qemu_minimal_repo=_env_or_default(
            "QEMU_MINIMAL_REPO",
            DEFAULT_QEMU_MINIMAL_REPO,
        ),
        qemu_minimal_commit=_env_or_default(
            "QEMU_MINIMAL_COMMIT",
            DEFAULT_QEMU_MINIMAL_COMMIT,
        ),
        kvm=_env_bool("KVM", DEFAULT_KVM),
        username=os.environ.get("USERNAME", DEFAULT_USERNAME),
        vm_name=os.environ.get("VM_NAME", ""),
        password=os.environ.get("PASSWORD", DEFAULT_PASSWORD),
        release=os.environ.get("RELEASE", DEFAULT_RELEASE),
        arch=os.environ.get("ARCH", DEFAULT_ARCH),
        cuda_version=_env_or_default("CUDA_VERSION", DEFAULT_CUDA_VERSION),
        rocm_version=_env_or_default("ROCM_VERSION", DEFAULT_ROCM_VERSION),
        rocm_stream=os.environ.get("ROCM_STREAM", DEFAULT_ROCM_STREAM),
        rocm_ernic_commit=_env_or_default(
            "ROCM_ERNIC_COMMIT",
            DEFAULT_ROCM_ERNIC_COMMIT,
        ),
        rocm_rocjitsu_repo=os.environ.get(
            "ROCM_ROCJITSU_REPO",
            DEFAULT_ROCM_ROCJITSU_REPO,
        ),
        rocm_rocjitsu_branch=os.environ.get(
            "ROCM_ROCJITSU_BRANCH",
            DEFAULT_ROCM_ROCJITSU_BRANCH,
        ),
        rocm_rocjitsu_commit=_env_or_default(
            "ROCM_ROCJITSU_COMMIT",
            DEFAULT_ROCM_ROCJITSU_COMMIT,
        ),
        fio_repo=os.environ.get("FIO_REPO", DEFAULT_FIO_REPO),
        fio_commit=_env_or_default("FIO_COMMIT", DEFAULT_FIO_COMMIT),
        fio_base_image=os.environ.get("FIO_BASE_IMAGE", ""),
    )

    cfg.registry_password = _resolve_password(password_file, cfg)
    return cfg


# ── image discovery ────────────────────────────────────


def discover_images(workdir: Path) -> list[str]:
    """Return sorted list of subdirectory names that
    contain a Dockerfile."""
    dirs: list[str] = []
    for child in sorted(workdir.iterdir()):
        if child.is_dir() and (child / "Dockerfile").is_file():
            dirs.append(child.name)
    return dirs


def order_images(image_dirs: list[str]) -> list[str]:
    """Sort so every image follows the image it is layered on.

    Stable within a dependency level: the input order (alphabetical, from
    discover_images) is preserved for images that do not depend on each other.
    """

    ordered: list[str] = []
    seen: set[str] = set()
    known = set(image_dirs)

    def visit(name: str, stack: tuple[str, ...] = ()) -> None:
        if name in seen:
            return
        if name in stack:
            cycle = " -> ".join((*stack, name))
            console.print(f"[red]Error:[/] circular image dependency: {cycle}")
            sys.exit(1)
        base = IMAGE_BASES.get(name)
        # A base outside the requested set is pulled from the registry
        # instead of being built, so it imposes no ordering.
        if base and base in known:
            visit(base, (*stack, name))
        seen.add(name)
        ordered.append(name)

    for name in image_dirs:
        visit(name)
    return ordered


def resolve_image_dirs(workdir: Path, image_arg: str | None) -> list[str]:
    """If the caller specified a single image name, return
    it; otherwise discover all, base images first."""
    if image_arg:
        dockerfile = workdir / image_arg / "Dockerfile"
        if not dockerfile.is_file():
            console.print(f"[red]Error:[/] Dockerfile not found in {image_arg}")
            sys.exit(1)
        return [image_arg]
    return order_images(discover_images(workdir))


# ── image naming ───────────────────────────────────────


def full_image_ref(cfg: Config, image_dir: str) -> str:
    """Compute the full registry/name portion (without
    tag) matching the shell script logic."""

    if cfg.registry_image:
        if "/" in cfg.registry_image:
            name = f"{cfg.registry_image}-{image_dir}"
        elif cfg.registry_username:
            name = f"{cfg.registry_username}/{cfg.registry_image}-{image_dir}"
        else:
            name = f"{cfg.registry_image}-{image_dir}"
    else:
        if cfg.registry_username:
            name = f"{cfg.registry_username}/batesste-ci-images-{image_dir}"
        else:
            name = f"batesste-ci-images-{image_dir}"
    return name


def tagged_ref(cfg: Config, image_dir: str, tag: str | None = None) -> str:
    """Full registry/name:tag string."""
    t = tag or cfg.image_tag
    name = full_image_ref(cfg, image_dir)
    return f"{cfg.registry}/{name}:{t}"


def _sanitise(value: str) -> str:
    """Reduce *value* to the OCI tag charset."""
    return re.sub(r"[^a-z0-9._]+", "-", value.strip().lower()).strip("-._")


def _ver(value: str) -> str:
    """Normalise an upstream version into a tag fragment.

    Strips the git-tag ``v`` prefix: ``v11.1.1`` -> ``11.1.1``.
    """
    return _sanitise(value.strip().lower().removeprefix("v"))


def _short(commit: str) -> str:
    """Abbreviate a pinned ref.

    Full SHAs shrink to 7 chars; a branch keeps only its last path segment, so
    ``dev/stephen/pci-mmio-bridge-submit`` becomes ``pci-mmio-bridge-submit``.
    """
    c = commit.strip().lower()
    if _SHA_RE.match(c):
        return c[:7]
    return _sanitise(c.rsplit("/", 1)[-1])


def image_variant(cfg: Config, image_dir: str) -> str:
    """Tag fragment naming the payload that differentiates this build.

    Derived from the same Config fields that feed the build args, so the tag
    cannot drift from what was actually built.  Empty for images whose only
    input is the Ubuntu base.
    """

    if image_dir in {"ubuntu-cuda-rocm", FIO_IMAGE_DIR}:
        # CUDA_VERSION carries the apt package form (13-3); publish it the way
        # NVIDIA versions it (13.3).
        cuda = _ver(cfg.cuda_version.replace("-", "."))
        variant = f"rocm{_ver(cfg.rocm_version)}-cuda{cuda}"
        if image_dir == FIO_IMAGE_DIR:
            variant += f"-fio.{_short(cfg.fio_commit)}"
        return variant
    # Both images below link against libvfio-user, so it belongs in the tag:
    # without it two builds differing only in that pin would collide.
    vfu = f"-vfu.{_short(cfg.libvfio_user_commit)}"
    if image_dir == VFU_IMAGE_DIR:
        return f"vfu.{_short(cfg.libvfio_user_commit)}"
    if image_dir == "ubuntu-rocm-ernic":
        return f"ernic.{_short(cfg.rocm_ernic_commit)}{vfu}"
    if image_dir == "ubuntu-rocm-rocjitsu":
        return f"rocjitsu.{_short(cfg.rocm_rocjitsu_commit)}"
    if image_dir == "ubuntu-qemu-libvfio-user":
        ref = cfg.qemu_commit.strip().lower()
        if _VERSION_RE.match(ref.removeprefix("v")):
            return f"qemu{_ver(ref)}{vfu}"
        # A fork branch or SHA: name it rather than dress it up as a version.
        return f"qemu.{_short(ref)}{vfu}"
    return ""


def tag_set(cfg: Config, image_dir: str, base_tag: str | None = None) -> list[str]:
    """Every tag this image should be published under, primary first.

    For ``1.1.0`` and variant ``rocm7.14-cuda13.3`` that is::

        1.1.0-rocm7.14-cuda13.3   immutable, fully specified
        1.1-rocm7.14-cuda13.3     rolling patch within the variant
        rocm7.14-cuda13.3         rolling latest of the variant
        1.1.0                     release alias
        1.1                       rolling minor alias
        latest
    """

    base = (base_tag or cfg.image_tag).strip()
    variant = image_variant(cfg, image_dir)
    semver = _SEMVER_RE.match(base)
    minor = f"{semver.group(1)}.{semver.group(2)}" if semver else ""

    tags: list[str] = []

    def add(tag: str) -> None:
        if tag and tag not in tags:
            tags.append(tag)

    if base != "latest":
        add(f"{base}-{variant}" if variant else base)
    if minor:
        add(f"{minor}-{variant}" if variant else minor)
    add(variant)
    add(base if semver else "")
    add(minor)
    add("latest")
    return tags


def primary_ref(cfg: Config, image_dir: str) -> str:
    """The most specific published ref -- what CI should pin."""
    return tagged_ref(cfg, image_dir, tag=tag_set(cfg, image_dir)[0])


def base_image_for(cfg: Config, image_dir: str) -> str:
    """The BASE_IMAGE build arg for a layered image, or "" if it has no base.

    Defaults to this run's own tag for the base: ``resolve_image_dirs``
    orders bases first, so a full build produces and ``--load``s the base
    before the dependant needs it.
    """
    base_dir = IMAGE_BASES.get(image_dir)
    if not base_dir:
        return ""
    # Two override forms: one keyed by the dependant, one keyed by the base.
    # CI uses the latter to point every dependant at a scratch registry copy
    # of a base built earlier in the same run, with a single env var.
    override = os.environ.get(f"BASE_IMAGE_{_env_key(image_dir)}", "")
    if not override:
        override = os.environ.get(f"BASE_IMAGE_FOR_{_env_key(base_dir)}", "")
    if not override and image_dir == FIO_IMAGE_DIR:
        # Retained for compatibility: FIO_BASE_IMAGE predates the generic form.
        override = cfg.fio_base_image
    if override:
        return override
    return primary_ref(cfg, base_dir)


def _env_key(image_dir: str) -> str:
    """ubuntu-rocm-ernic -> UBUNTU_ROCM_ERNIC"""
    return image_dir.replace("-", "_").upper()


def build_args_for(
    cfg: Config,
    image_dir: str,
    kvm_build: bool = False,
    include_secrets: bool = True,
) -> list[str]:
    """Every ``--build-arg`` this image needs, as ``KEY=value`` strings.

    Single source of truth for the pins: both the local build and the CI
    workflows read them from here, so a version cannot be bumped in one
    place and missed in the other.

    ``include_secrets`` is False for anything that gets printed: the VM
    PASSWORD would otherwise land in a CI log or a ``$GITHUB_OUTPUT`` file.
    """

    args: list[str] = []
    base = base_image_for(cfg, image_dir)
    if base:
        args.append(f"BASE_IMAGE={base}")

    if image_dir == BASE_IMAGE_DIR:
        return args
    if image_dir == VFU_IMAGE_DIR:
        args.append(f"LIBVFIO_USER_COMMIT={cfg.libvfio_user_commit}")
        return args
    if image_dir == "ubuntu-cuda-rocm":
        args += [
            f"CUDA_VERSION={cfg.cuda_version}",
            f"ROCM_VERSION={cfg.rocm_version}",
            f"ROCM_STREAM={cfg.rocm_stream}",
        ]
        return args
    if image_dir == "ubuntu-qemu-libvfio-user":
        args += [
            f"QEMU_REPO={cfg.qemu_repo}",
            f"QEMU_COMMIT={cfg.qemu_commit}",
            f"QEMU_MINIMAL_REPO={cfg.qemu_minimal_repo}",
            f"QEMU_MINIMAL_COMMIT={cfg.qemu_minimal_commit}",
            f"VM_STAGE={'vm-kvm' if kvm_build else 'vm-tcg'}",
            f"KVM={'true' if kvm_build else 'false'}",
            f"USERNAME={cfg.username}",
            f"VM_NAME={cfg.vm_name}",
            f"RELEASE={cfg.release}",
            f"ARCH={cfg.arch}",
        ]
        if include_secrets:
            args.append(f"PASSWORD={cfg.password}")
        return args
    if image_dir == "ubuntu-rocm-ernic":
        args.append(f"ROCM_ERNIC_COMMIT={cfg.rocm_ernic_commit}")
        return args
    if image_dir == "ubuntu-rocm-rocjitsu":
        args += [
            f"ROCJITSU_REPO={cfg.rocm_rocjitsu_repo}",
            f"ROCJITSU_BRANCH={cfg.rocm_rocjitsu_branch}",
            f"ROCJITSU_COMMIT={cfg.rocm_rocjitsu_commit}",
        ]
        return args
    if image_dir == FIO_IMAGE_DIR:
        args += [
            f"FIO_REPO={cfg.fio_repo}",
            f"FIO_COMMIT={cfg.fio_commit}",
        ]
        return args
    return args


# ── docker helpers ─────────────────────────────────────


def ensure_buildx() -> None:
    """Abort if docker buildx is unavailable."""
    try:
        subprocess.run(
            ["docker", "buildx", "version"],
            capture_output=True,
            check=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        console.print("[red]Error:[/] docker buildx is not available")
        sys.exit(1)


def _builder_daemon_flags(name: str) -> str | None:
    """Return the builder's buildkitd flags, or None if it does
    not exist."""

    proc = subprocess.run(
        ["docker", "buildx", "inspect", name],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        return None
    for line in proc.stdout.splitlines():
        if line.startswith("BuildKit daemon flags:"):
            return line.split(":", 1)[1].strip()
    return ""


def ensure_builder() -> bool:
    """Create or select the buildx builder.

    Returns True when the builder can grant the
    security.insecure entitlement (needed for a KVM-accelerated
    VM build)."""

    flags = _builder_daemon_flags(BUILDER_NAME)
    if flags is not None and "security.insecure" not in flags:
        # The VM build stage needs the insecure entitlement for
        # /dev/kvm; an old builder without it must be replaced.
        console.print(
            "[yellow]Warning:[/] recreating buildx builder "
            f"'{BUILDER_NAME}' to add the security.insecure "
            "entitlement (its build cache will be discarded)."
        )
        subprocess.run(
            ["docker", "buildx", "rm", BUILDER_NAME],
            capture_output=True,
            text=True,
            check=False,
        )

    # Allow create to fail (e.g., builder already exists), but
    # capture output so we can report it if selecting the builder fails.
    create_proc = subprocess.run(
        [
            "docker",
            "buildx",
            "create",
            "--name",
            BUILDER_NAME,
            "--buildkitd-flags",
            BUILDKITD_FLAGS,
            "--use",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    use_proc = subprocess.run(
        ["docker", "buildx", "use", BUILDER_NAME],
        capture_output=True,
        text=True,
        check=False,
    )
    if use_proc.returncode != 0:
        console.print(
            f"[red]Error:[/] failed to select docker buildx builder '{BUILDER_NAME}'."
        )
        if create_proc.returncode != 0 and create_proc.stderr:
            console.print("[red]docker buildx create stderr:[/]")
            console.print(create_proc.stderr.strip())
        if use_proc.stderr:
            console.print("[red]docker buildx use stderr:[/]")
            console.print(use_proc.stderr.strip())
        sys.exit(1)

    flags = _builder_daemon_flags(BUILDER_NAME) or ""
    return "security.insecure" in flags


def docker_login(cfg: Config) -> None:
    """Log in to the OCI registry when credentials are
    present."""
    if not (cfg.registry_username and cfg.registry_password):
        return
    subprocess.run(
        [
            "docker",
            "login",
            cfg.registry,
            "--username",
            cfg.registry_username,
            "--password-stdin",
        ],
        input=cfg.registry_password.encode(),
        check=True,
    )


def has_credentials(cfg: Config) -> bool:
    return bool(cfg.registry_username and cfg.registry_password)


# ── subcommands ────────────────────────────────────────


def cmd_build(args: argparse.Namespace) -> None:
    """Build one or all images with docker buildx."""

    cfg = load_config(
        env_file=args.env_file,
        password_file=args.password_file,
    )
    image_dirs = resolve_image_dirs(cfg.workdir, args.image)
    dry_run: bool = args.dry_run

    insecure_ok = True
    if not dry_run:
        ensure_buildx()
        insecure_ok = ensure_builder()
        docker_login(cfg)

    kvm_build = cfg.kvm and insecure_ok and Path("/dev/kvm").exists()
    if cfg.kvm and not kvm_build:
        reason = (
            "the buildx builder cannot grant the security.insecure entitlement"
            if not insecure_ok
            else "this host has no /dev/kvm"
        )
        console.print(
            f"[yellow]Warning:[/] KVM requested but {reason}; the VM "
            "build will fall back to TCG emulation (much slower)."
        )

    # A base built earlier in this same run only exists in the local daemon,
    # which the docker-container builder cannot see.
    local_bases = {
        d
        for d in image_dirs
        if IMAGE_BASES.get(d) in image_dirs and not args.base_from_registry
    }
    if "ubuntu-qemu-libvfio-user" in local_bases and kvm_build:
        console.print(
            "[yellow]Warning:[/] ubuntu-libvfio-user is being built in this "
            "run, so ubuntu-qemu-libvfio-user must build on the 'default' "
            "builder, which cannot grant security.insecure; its VM stage "
            "falls back to TCG emulation. Pass --base-from-registry to build "
            "against the published base and keep KVM."
        )

    for image_dir in image_dirs:
        refs = [tagged_ref(cfg, image_dir, tag=t) for t in tag_set(cfg, image_dir)]
        local_base = image_dir in local_bases
        image_kvm = kvm_build and not (
            image_dir == "ubuntu-qemu-libvfio-user" and local_base
        )

        build_args = build_args_for(cfg, image_dir, kvm_build=image_kvm)
        if args.cache_bust:
            build_args.append(f"CACHE_BUST={args.cache_bust}")

        cmd: list[str] = ["docker", "buildx", "build"]
        # The named builder uses the docker-container driver, which has its
        # own image store and cannot resolve a base image that only exists
        # in the local daemon.  Such images build on the 'default' (docker
        # driver) builder instead, which still has a full local layer cache.
        if local_base:
            cmd += ["--builder", "default"]
        # The vm-kvm stage runs QEMU against /dev/kvm, which only
        # an insecure-entitlement RUN can reach.  vm-tcg does not
        # need (and must not request) the entitlement.
        if image_dir == "ubuntu-qemu-libvfio-user" and image_kvm:
            cmd += ["--allow", "security.insecure"]
        for ba in build_args:
            cmd += ["--build-arg", ba]
        if args.no_cache:
            cmd.append("--no-cache")
        for ref in refs:
            cmd += ["--tag", ref]
        for key, value in image_labels(cfg, image_dir).items():
            cmd += ["--label", f"{key}={value}"]
        cmd += ["--load"]
        cmd += [
            "-f",
            str(cfg.workdir / image_dir / "Dockerfile"),
        ]
        cmd.append(str(cfg.workdir))

        console.rule(f"[bold]Building {image_dir}[/]")
        _print_build_summary(cfg, image_dir, args, kvm_build)

        # The Dockerfile bind-mounts this dir; buildx fails if it
        # is missing (it holds only gitignored *.img downloads).
        if image_dir == "ubuntu-qemu-libvfio-user":
            (cfg.workdir / "common" / "cloud-image-cache").mkdir(
                parents=True,
                exist_ok=True,
            )

        if dry_run:
            console.print("[yellow]dry-run:[/] " + " ".join(cmd))
            continue

        subprocess.run(cmd, check=True)

        if has_credentials(cfg):
            console.rule("[bold]Pushing to registry[/]")
            for ref in refs:
                subprocess.run(["docker", "push", ref], check=True)
                console.print(f"[green]Pushed[/] {ref}")
        else:
            console.print("[dim]Registry credentials not provided, skipping push[/]")

        console.rule(f"[bold green]Build complete: {image_dir}[/]")


def _print_build_summary(
    cfg: Config,
    image_dir: str,
    args: argparse.Namespace,
    kvm_build: bool = False,
) -> None:
    """Pretty-print the build configuration."""
    tags = tag_set(cfg, image_dir)
    table = Table(
        title="Build Configuration",
        show_header=False,
    )
    table.add_column("Key", style="bold")
    table.add_column("Value")
    table.add_row("Image", tagged_ref(cfg, image_dir, tag=tags[0]))
    table.add_row("Aliases", ", ".join(tags[1:]) or "-")
    table.add_row("Directory", image_dir)
    base = base_image_for(cfg, image_dir)
    if base:
        table.add_row("Base Image", base)

    if image_dir == "ubuntu-cuda-rocm":
        table.add_row("CUDA Version", cfg.cuda_version)
        table.add_row("ROCm Version", cfg.rocm_version)
        table.add_row("ROCm Stream", cfg.rocm_stream)
    elif image_dir == "ubuntu-rocm-ernic":
        table.add_row("libvfio-user Commit", cfg.libvfio_user_commit)
        table.add_row("ROCM_ERNIC Commit", cfg.rocm_ernic_commit)
    elif image_dir == "ubuntu-rocm-rocjitsu":
        table.add_row("ROCjitsu Branch", cfg.rocm_rocjitsu_branch)
        table.add_row("ROCjitsu Commit", cfg.rocm_rocjitsu_commit)
    elif image_dir == "ubuntu-cuda-rocm-fio":
        table.add_row("fio Commit", cfg.fio_commit)
    elif image_dir == VFU_IMAGE_DIR:
        table.add_row("libvfio-user Commit", cfg.libvfio_user_commit)
    elif image_dir == "ubuntu-qemu-libvfio-user":
        table.add_row("QEMU Commit", cfg.qemu_commit)
        table.add_row("libvfio-user Commit", cfg.libvfio_user_commit)
        table.add_row(
            "qemu-minimal Commit",
            cfg.qemu_minimal_commit if cfg.qemu_minimal_repo else "(VM build disabled)",
        )
        table.add_row(
            "KVM",
            "true" if kvm_build else "false (TCG emulation)",
        )
    elif image_dir == "ubuntu-kernel-build":
        pass

    if args.cache_bust:
        table.add_row("Cache Bust", args.cache_bust)
    if args.no_cache:
        table.add_row("No Cache", "true")
    console.print(table)


def cmd_push(args: argparse.Namespace) -> None:
    """Push already-built images to the OCI registry."""

    cfg = load_config(
        env_file=args.env_file,
        password_file=args.password_file,
    )
    if not has_credentials(cfg):
        console.print("[red]Error:[/] registry credentials are required for push")
        sys.exit(1)

    docker_login(cfg)
    image_dirs = resolve_image_dirs(cfg.workdir, args.image)

    for image_dir in image_dirs:
        console.rule(f"[bold]Pushing {image_dir}[/]")
        for tag in tag_set(cfg, image_dir):
            ref = tagged_ref(cfg, image_dir, tag=tag)
            subprocess.run(["docker", "push", ref], check=True)
            console.print(f"[green]Pushed[/] {ref}")


def cmd_list(args: argparse.Namespace) -> None:
    """List all discoverable image directories."""

    cfg = load_config(env_file=args.env_file)
    dirs = discover_images(cfg.workdir)

    table = Table(title="Discoverable Images")
    table.add_column("#", style="dim")
    table.add_column("Directory")
    table.add_column("Variant")
    table.add_column("Full Reference")

    for idx, d in enumerate(dirs, 1):
        table.add_row(str(idx), d, image_variant(cfg, d) or "-", primary_ref(cfg, d))

    console.print(table)


def cmd_tags(args: argparse.Namespace) -> None:
    """Print an image's tag set, one per line, on plain stdout.

    Release CI consumes this so the workflow and a local build derive the tags
    from one implementation; the pinned versions reach it through the same env
    vars that drive the build args.
    """

    cfg = load_config(env_file=args.env_file)
    if args.tag:
        cfg.image_tag = resolve_image_tag(args.tag)

    tags = tag_set(cfg, args.image) + list(args.extra_tag)
    if args.names_only:
        print("\n".join(dict.fromkeys(tags)))
        return

    name = full_image_ref(cfg, args.image) + args.suffix
    seen = dict.fromkeys(f"{cfg.registry}/{name}:{t}" for t in tags)
    print("\n".join(seen))


def cmd_build_args(args: argparse.Namespace) -> None:
    """Print an image's build args, one ``KEY=value`` per line, on plain stdout.

    CI feeds this straight into ``docker/build-push-action``'s ``build-args``
    so the pins live in exactly one place.
    """

    cfg = load_config(env_file=args.env_file)
    if args.tag:
        cfg.image_tag = resolve_image_tag(args.tag)

    print(
        "\n".join(
            build_args_for(
                cfg,
                args.image,
                kvm_build=args.kvm,
                include_secrets=False,
            )
        )
    )


def image_labels(cfg: Config, image_dir: str) -> dict[str, str]:
    """OCI labels describing what went into *image_dir*.

    The variant tag is a summary for humans; these are the same facts in a
    form a scanner can read without parsing a tag.
    """

    ns = "io.batesste.ci-images"
    labels = {
        "org.opencontainers.image.title": f"batesste-ci-images-{image_dir}",
        f"{ns}.variant": image_variant(cfg, image_dir),
    }
    if image_dir in {"ubuntu-cuda-rocm", FIO_IMAGE_DIR}:
        labels[f"{ns}.rocm.version"] = cfg.rocm_version
        # Publish CUDA the way NVIDIA versions it, not in its apt form (13-3).
        labels[f"{ns}.cuda.version"] = cfg.cuda_version.replace("-", ".")
        labels[f"{ns}.rocm.stream"] = cfg.rocm_stream
    if image_dir == FIO_IMAGE_DIR:
        labels[f"{ns}.fio.commit"] = cfg.fio_commit
    # The canonical published base, not whatever scratch ref this particular
    # build layered on: CI points BASE_IMAGE at a per-run GHCR tag that will
    # not exist by the time anyone reads the label.
    base_dir = IMAGE_BASES.get(image_dir)
    if base_dir:
        labels["org.opencontainers.image.base.name"] = primary_ref(cfg, base_dir)
    if image_dir == VFU_IMAGE_DIR:
        labels[f"{ns}.libvfio-user.commit"] = cfg.libvfio_user_commit
    if image_dir == "ubuntu-rocm-ernic":
        labels[f"{ns}.ernic.commit"] = cfg.rocm_ernic_commit
        labels[f"{ns}.libvfio-user.commit"] = cfg.libvfio_user_commit
    if image_dir == "ubuntu-rocm-rocjitsu":
        labels[f"{ns}.rocjitsu.branch"] = cfg.rocm_rocjitsu_branch
        labels[f"{ns}.rocjitsu.commit"] = cfg.rocm_rocjitsu_commit
    if image_dir == "ubuntu-qemu-libvfio-user":
        labels[f"{ns}.qemu.repo"] = cfg.qemu_repo
        labels[f"{ns}.qemu.commit"] = cfg.qemu_commit
        labels[f"{ns}.libvfio-user.commit"] = cfg.libvfio_user_commit
    return {k: v for k, v in labels.items() if v}


def cmd_labels(args: argparse.Namespace) -> None:
    """Print an image's OCI labels as ``key=value`` lines on plain stdout."""

    cfg = load_config(env_file=args.env_file)
    if args.tag:
        cfg.image_tag = resolve_image_tag(args.tag)

    labels = image_labels(cfg, args.image)
    print("\n".join(f"{k}={v}" for k, v in labels.items()))


def cmd_inspect(args: argparse.Namespace) -> None:
    """Inspect locally-available Docker images."""

    cfg = load_config(
        env_file=args.env_file,
        password_file=getattr(args, "password_file", None),
    )
    image_dirs = resolve_image_dirs(cfg.workdir, args.image)

    try:
        client = docker.from_env()
    except docker.errors.DockerException as exc:
        console.print(f"[red]Error:[/] cannot connect to Docker daemon: {exc}")
        sys.exit(1)

    for image_dir in image_dirs:
        ref = primary_ref(cfg, image_dir)
        console.rule(f"[bold]{image_dir}[/]")

        try:
            img = client.images.get(ref)
        except docker.errors.ImageNotFound:
            console.print(f"  [yellow]Not found locally:[/] {ref}")
            continue

        attrs = img.attrs
        size_mb = attrs.get("Size", 0) / 1_000_000
        created = attrs.get("Created", "unknown")
        img_id = attrs.get("Id", "unknown")[:19]
        arch_label = attrs.get("Architecture", "unknown")
        os_label = attrs.get("Os", "unknown")

        table = Table(title=ref, show_header=False)
        table.add_column("Key", style="bold")
        table.add_column("Value")
        table.add_row("ID", img_id)
        table.add_row("Size", f"{size_mb:.1f} MB")
        table.add_row("Created", created)
        table.add_row("Arch", arch_label)
        table.add_row("OS", os_label)

        tags = attrs.get("RepoTags", [])
        table.add_row("Tags", ", ".join(tags))

        layers = attrs.get("RootFS", {}).get("Layers", [])
        table.add_row("Layers", str(len(layers)))

        console.print(table)


def cmd_status(args: argparse.Namespace) -> None:
    """Query the remote OCI registry for tag and digest
    information via the Registry HTTP API v2."""

    cfg = load_config(
        env_file=args.env_file,
        password_file=getattr(args, "password_file", None),
    )
    image_dirs = resolve_image_dirs(cfg.workdir, args.image)

    for image_dir in image_dirs:
        name = full_image_ref(cfg, image_dir)
        console.rule(f"[bold]{image_dir}[/]")
        _query_registry(cfg, name)


def _registry_base_url(registry: str) -> str:
    """Return the v2 API base URL for a registry."""
    if registry in ("docker.io", "registry-1.docker.io"):
        return "https://registry-1.docker.io"
    if "://" not in registry:
        return f"https://{registry}"
    return registry


def _docker_hub_token(repo: str) -> str | None:
    """Obtain a Docker Hub bearer token for public
    read access."""
    url = (
        "https://auth.docker.io/token"
        "?service=registry.docker.io"
        f"&scope=repository:{repo}:pull"
    )
    try:
        resp = requests.get(url, timeout=15)
    except requests.RequestException as exc:
        console.print(
            f"[yellow]Warning:[/] Failed to obtain Docker Hub token for "
            f"[bold]{repo}[/]: {exc}"
        )
        return None
    if resp.ok:
        return resp.json().get("token")
    return None


def _query_registry(cfg: Config, repo_name: str) -> None:
    """Fetch tags and manifests for *repo_name* from the
    remote registry and print a Rich table."""

    base = _registry_base_url(cfg.registry)
    headers: dict[str, str] = {}

    if cfg.registry in ("docker.io", "registry-1.docker.io"):
        token = _docker_hub_token(repo_name)
        if token:
            headers["Authorization"] = f"Bearer {token}"
    elif cfg.registry_username and cfg.registry_password:
        headers["Authorization"] = requests.auth._basic_auth_str(
            cfg.registry_username,
            cfg.registry_password,
        )

    tags_url = f"{base}/v2/{repo_name}/tags/list"
    try:
        resp = requests.get(tags_url, headers=headers, timeout=15)
    except requests.RequestException:
        console.print(f"  [red]Cannot reach registry:[/] {base}")
        return

    if resp.status_code == 401:
        console.print("  [red]Unauthorized:[/] check credentials")
        return
    if resp.status_code == 404:
        console.print(f"  [yellow]Repository not found:[/] {repo_name}")
        return
    if not resp.ok:
        console.print(f"  [red]HTTP {resp.status_code}[/]: {resp.text[:200]}")
        return

    tags = resp.json().get("tags") or []
    if not tags:
        console.print("  [dim]No tags found[/]")
        return

    table = Table(title=f"{cfg.registry}/{repo_name}")
    table.add_column("Tag")
    table.add_column("Digest")
    table.add_column("Content-Type")

    accept = (
        "application/vnd.docker.distribution"
        ".manifest.v2+json, "
        "application/vnd.oci.image.index.v1+json"
    )

    for tag in sorted(tags):
        manifest_url = f"{base}/v2/{repo_name}/manifests/{tag}"
        try:
            mresp = requests.head(
                manifest_url,
                headers={**headers, "Accept": accept},
                timeout=15,
            )
        except requests.RequestException as exc:
            console.print(
                f"  [yellow]Failed to fetch manifest for tag '{tag}':[/] {exc}"
            )
            digest = "n/a"
            ctype = "n/a"
        else:
            if not mresp.ok:
                console.print(
                    f"  [yellow]Manifest request for tag '{tag}' failed with "
                    f"HTTP {mresp.status_code}[/]"
                )
                digest = "n/a"
                ctype = "n/a"
            else:
                digest = mresp.headers.get("Docker-Content-Digest", "n/a")
                ctype = mresp.headers.get("Content-Type", "n/a")
        short_digest = digest[:25] + "..." if len(digest) > 28 else digest
        table.add_row(tag, short_digest, ctype)

    console.print(table)


# ── argparse ───────────────────────────────────────────


def _add_common_args(
    parser: argparse.ArgumentParser,
) -> None:
    """Add flags shared across subcommands."""
    parser.add_argument(
        "--env-file",
        metavar="PATH",
        help=("Path to .env file (overrides default search)"),
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="ci-images-tool.py",
        description=(
            "Build, push, inspect, and query OCI "
            "registry status for batesste-ci-images."
        ),
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # ── build ──
    p_build = sub.add_parser(
        "build",
        help="Build Docker images via buildx",
    )
    p_build.add_argument(
        "image",
        nargs="?",
        default=None,
        help=("Image directory name (builds all if omitted)"),
    )
    p_build.add_argument(
        "--no-cache",
        action="store_true",
        help="Disable Docker build cache",
    )
    p_build.add_argument(
        "--cache-bust",
        metavar="VALUE",
        help="Cache-busting build arg value",
    )
    p_build.add_argument(
        "--password-file",
        metavar="FILE",
        help="File containing registry password",
    )
    p_build.add_argument(
        "--base-from-registry",
        action="store_true",
        help=(
            "Layer on the published base images rather than ones built in "
            "this run; keeps every image on the buildx builder, so the VM "
            "stage can still use KVM"
        ),
    )
    p_build.add_argument(
        "--dry-run",
        action="store_true",
        help="Print commands without executing",
    )
    _add_common_args(p_build)

    # ── push ──
    p_push = sub.add_parser(
        "push",
        help="Push images to OCI registry",
    )
    p_push.add_argument(
        "image",
        nargs="?",
        default=None,
        help=("Image directory name (pushes all if omitted)"),
    )
    p_push.add_argument(
        "--password-file",
        metavar="FILE",
        help="File containing registry password",
    )
    _add_common_args(p_push)

    # ── list ──
    p_list = sub.add_parser(
        "list",
        help="List discoverable image directories",
    )
    _add_common_args(p_list)

    # ── tags ──
    p_tags = sub.add_parser(
        "tags",
        help="Print the tags an image should be published under",
    )
    p_tags.add_argument(
        "image",
        help="Image directory name",
    )
    p_tags.add_argument(
        "--tag",
        metavar="TAG",
        help=(
            "Base tag to expand (defaults to IMAGE_TAG); a semver such as "
            "1.1.0 also yields the rolling minor and bare aliases"
        ),
    )
    p_tags.add_argument(
        "--suffix",
        default="",
        metavar="TEXT",
        help=("Appended to the repository name, not the tag (e.g. -sbates-fork)"),
    )
    p_tags.add_argument(
        "--extra-tag",
        action="append",
        default=[],
        metavar="TAG",
        help="Additional tag to emit verbatim (repeatable)",
    )
    p_tags.add_argument(
        "--names-only",
        action="store_true",
        help="Print bare tags instead of full registry refs",
    )
    _add_common_args(p_tags)

    # ── build-args ──
    p_build_args = sub.add_parser(
        "build-args",
        help="Print an image's docker build args as KEY=value lines",
    )
    p_build_args.add_argument(
        "image",
        help="Image directory name",
    )
    p_build_args.add_argument(
        "--tag",
        metavar="TAG",
        help=("Base tag being published; sets the BASE_IMAGE reference emitted"),
    )
    p_build_args.add_argument(
        "--kvm",
        action="store_true",
        help="Select the vm-kvm stage for ubuntu-qemu-libvfio-user",
    )
    _add_common_args(p_build_args)

    # ── labels ──
    p_labels = sub.add_parser(
        "labels",
        help="Print an image's OCI labels as key=value lines",
    )
    p_labels.add_argument(
        "image",
        help="Image directory name",
    )
    p_labels.add_argument(
        "--tag",
        metavar="TAG",
        help=(
            "Base tag being published; sets the base image reference "
            "recorded for derived images"
        ),
    )
    _add_common_args(p_labels)

    # ── inspect ──
    p_inspect = sub.add_parser(
        "inspect",
        help="Inspect local Docker images",
    )
    p_inspect.add_argument(
        "image",
        nargs="?",
        default=None,
        help=("Image directory name (inspects all if omitted)"),
    )
    p_inspect.add_argument(
        "--password-file",
        metavar="FILE",
        help="File containing registry password",
    )
    _add_common_args(p_inspect)

    # ── status ──
    p_status = sub.add_parser(
        "status",
        help=("Query remote registry for tags and digests"),
    )
    p_status.add_argument(
        "image",
        nargs="?",
        default=None,
        help=("Image directory name (queries all if omitted)"),
    )
    p_status.add_argument(
        "--password-file",
        metavar="FILE",
        help="File containing registry password",
    )
    _add_common_args(p_status)

    return parser


# ── main ───────────────────────────────────────────────


DISPATCH = {
    "build": cmd_build,
    "push": cmd_push,
    "list": cmd_list,
    "tags": cmd_tags,
    "build-args": cmd_build_args,
    "labels": cmd_labels,
    "inspect": cmd_inspect,
    "status": cmd_status,
}


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    handler = DISPATCH.get(args.command)
    if handler is None:
        parser.print_help()
        sys.exit(1)
    handler(args)


if __name__ == "__main__":
    main()
