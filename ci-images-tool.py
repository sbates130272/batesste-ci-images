#!/usr/bin/env python3
"""
ci-images-tool.py

Build, push, inspect, and query OCI registry status for
the batesste-ci-images Docker image collection.

Everything about what gets built -- the pins, the build args, the tag variant,
the OCI labels, the base each image layers on, and the variants published from
the same Dockerfile -- is declared in images.yml. This file is the engine that
reads it; adding an image needs a Dockerfile and a YAML entry, not a code change.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

import docker
import requests
import yaml
from dotenv import load_dotenv
from rich.console import Console
from rich.table import Table

console = Console()
# Notices that must not land in the plain stdout that `tags`, `labels`,
# `build-args`, `config --get` and `targets --json` are consumed from.
err_console = Console(stderr=True)

SPEC_FILE = "images.yml"
OVERLAY_FILE = "images.local.yml"
BASE_IMAGE_DIR = "ubuntu-base"

DEFAULT_UBUNTU_VERSION = "24.04"
DEFAULT_REGISTRY = "docker.io"
DEFAULT_REGISTRY_IMAGE = "batesste-ci-images"
DEFAULT_IMAGE_TAG = "latest"
DEFAULT_LABEL_NS = "io.batesste.ci-images"
DEFAULT_KVM = True

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


# ── template rendering ─────────────────────────────────


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


def _dots(value: str) -> str:
    """CUDA's apt package form to the way NVIDIA versions it: 13-3 -> 13.3."""
    return value.replace("-", ".")


FILTERS = {
    "short": _short,
    "ver": _ver,
    "dots": _dots,
    "sanitise": _sanitise,
}

_TEMPLATE_RE = re.compile(r"\{([a-z_][a-z0-9_]*)((?:\|[a-z]+)*)\}")


def template_vars(template: str) -> set[str]:
    """Every var name a template references."""
    return {m.group(1) for m in _TEMPLATE_RE.finditer(template)}


def render(template: str, values: dict[str, str], where: str) -> str:
    """Interpolate ``{var}`` and ``{var|filter|filter}`` against *values*.

    *where* names the YAML site, so an unresolvable var reports where it came
    from rather than just what it was.
    """

    def sub(match: re.Match[str]) -> str:
        name, filters = match.group(1), match.group(2)
        if name not in values:
            console.print(f"[red]Error:[/] {where}: unknown var '{name}'")
            sys.exit(1)
        out = values[name]
        for f in filter(None, filters.split("|")):
            fn = FILTERS.get(f)
            if fn is None:
                console.print(f"[red]Error:[/] {where}: unknown filter '{f}'")
                sys.exit(1)
            out = fn(out)
        return out

    return _TEMPLATE_RE.sub(sub, template)


# ── spec ───────────────────────────────────────────────


@dataclass(frozen=True)
class Target:
    """An image directory plus an optional variant of it.

    The variant is what lets one Dockerfile publish more than one image: the
    same build context with overlaid vars, pushed to its own suffixed
    repository so each keeps its own ``latest``.
    """

    image: str
    variant: str = ""

    @property
    def key(self) -> str:
        """Canonical CLI name: ``ubuntu-cuda-rocm-fio@async-hipfile``."""
        return f"{self.image}@{self.variant}" if self.variant else self.image

    def __str__(self) -> str:
        return self.key


@dataclass
class Spec:
    """Parsed images.yml."""

    defaults: dict
    images: dict
    workdir: Path
    overlay: Path | None = None

    @property
    def label_ns(self) -> str:
        return self.defaults.get("label_namespace", DEFAULT_LABEL_NS)

    def image_spec(self, image: str) -> dict:
        spec = self.images.get(image)
        if spec is None:
            console.print(f"[red]Error:[/] {SPEC_FILE} has no entry for '{image}'")
            sys.exit(1)
        return spec

    def variant_spec(self, target: Target) -> dict:
        if not target.variant:
            return {}
        variants = self.image_spec(target.image).get("variants") or {}
        spec = variants.get(target.variant)
        if spec is None:
            console.print(
                f"[red]Error:[/] {target.image} has no variant '{target.variant}'"
            )
            sys.exit(1)
        return spec

    def base_chain(self, image: str) -> list[str]:
        """*image* and every image it layers on, base first."""
        chain: list[str] = []
        seen: set[str] = set()
        cur = image
        while cur and cur not in seen:
            seen.add(cur)
            chain.append(cur)
            cur = self.images.get(cur, {}).get("base", "")
        chain.reverse()
        return chain


def _read_yaml(path: Path) -> dict:
    try:
        return yaml.safe_load(path.read_text()) or {}
    except OSError as exc:
        console.print(f"[red]Error:[/] cannot read {path}: {exc}")
        sys.exit(1)
    except yaml.YAMLError as exc:
        console.print(f"[red]Error:[/] {path} is not valid YAML: {exc}")
        sys.exit(1)


def deep_merge(base: dict, over: dict) -> dict:
    """*over* laid on *base*: dicts merge key by key, anything else replaces.

    Replacing rather than merging lists is what makes an overlay predictable --
    a list in the overlay is the whole new value, not an unordered addition to
    whatever was there.
    """

    merged = dict(base)
    for key, value in over.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def load_spec(workdir: Path) -> Spec:
    data = _read_yaml(workdir / SPEC_FILE)

    # An optional, gitignored scratch file. It can reach anything the spec can,
    # including a variant's pins -- unlike an environment override, writing it
    # is deliberate. It is never read in CI, so a published image always
    # matches what is checked in.
    overlay = workdir / OVERLAY_FILE
    applied = None
    if overlay.is_file():
        data = deep_merge(data, _read_yaml(overlay))
        applied = overlay
        # Loud, because it silently changes what every tag and build arg
        # resolves to; on stderr, because callers parse stdout.
        err_console.print(f"[yellow]note:[/] {OVERLAY_FILE} applied over {SPEC_FILE}")

    return Spec(
        defaults=data.get("defaults") or {},
        images=data.get("images") or {},
        workdir=workdir,
        overlay=applied,
    )


# ── configuration ──────────────────────────────────────


@dataclass
class Config:
    """Global settings: everything not owned by images.yml.

    The pins live in the spec; what is left here is machine-local -- where to
    push, who to push as, and what this host can accelerate.
    """

    spec: Spec
    image_tag: str = DEFAULT_IMAGE_TAG
    registry: str = DEFAULT_REGISTRY
    registry_image: str = DEFAULT_REGISTRY_IMAGE
    registry_username: str = ""
    registry_password: str = ""
    workdir: Path = field(default_factory=Path.cwd)

    # The Ubuntu release ubuntu-base is built FROM, read off its Dockerfile.
    # Distinct from the ``release`` var, which names the cloud image the QEMU
    # VM guest is built from.
    ubuntu_version: str = DEFAULT_UBUNTU_VERSION

    kvm: bool = DEFAULT_KVM
    # Retained for compatibility: FIO_BASE_IMAGE predates BASE_IMAGE_FOR_*.
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


_FROM_UBUNTU_RE = re.compile(r"^FROM\s+ubuntu:(\S+)", re.IGNORECASE | re.MULTILINE)


def _ubuntu_version_from_base(workdir: Path) -> str:
    """The Ubuntu release ``ubuntu-base`` is built FROM.

    Parsed out of the Dockerfile rather than declared in images.yml. The
    FROM line is what actually decides it, so reading it keeps one source of
    truth without making the first instruction of the base image depend on a
    variable -- which would invalidate every layer below it, in every image,
    on every build.
    """

    try:
        text = (workdir / BASE_IMAGE_DIR / "Dockerfile").read_text()
    except OSError:
        return DEFAULT_UBUNTU_VERSION
    match = _FROM_UBUNTU_RE.search(text)
    return match.group(1) if match else DEFAULT_UBUNTU_VERSION


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
    environment, applying the spec's defaults."""

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

    spec = load_spec(workdir)
    d = spec.defaults

    cfg = Config(
        spec=spec,
        image_tag=resolve_image_tag(
            os.environ.get("IMAGE_TAG", d.get("image_tag", DEFAULT_IMAGE_TAG))
        ),
        registry=_env_or_default("REGISTRY", d.get("registry", DEFAULT_REGISTRY)),
        registry_image=_env_or_default(
            "REGISTRY_IMAGE",
            d.get("registry_image", DEFAULT_REGISTRY_IMAGE),
        ),
        registry_username=os.environ.get("REGISTRY_USERNAME", ""),
        registry_password=os.environ.get("REGISTRY_PASSWORD", ""),
        workdir=workdir,
        ubuntu_version=_ubuntu_version_from_base(workdir),
        kvm=_env_bool("KVM", DEFAULT_KVM),
        fio_base_image=os.environ.get("FIO_BASE_IMAGE", ""),
    )

    cfg.registry_password = _resolve_password(password_file, cfg)
    return cfg


# ── var resolution ─────────────────────────────────────


def _declaration(name: str, raw: object) -> dict:
    """Normalise a ``vars:`` entry to ``{value, env, secret}``.

    Scalar form ``name: value`` derives the env override name by upper-casing.
    """
    if isinstance(raw, dict):
        decl = dict(raw)
    else:
        decl = {"value": raw}
    decl.setdefault("value", "")
    decl.setdefault("env", name.upper())
    decl.setdefault("secret", False)
    decl["value"] = "" if decl["value"] is None else str(decl["value"])
    return decl


def declarations(spec: Spec, image: str) -> dict[str, dict]:
    """Var declarations in scope for *image*: defaults, then the base chain.

    An image inherits its base's vars, which is how ubuntu-cuda-rocm-fio names
    the ROCm and CUDA versions in its own tag variant without repeating the
    pins that ubuntu-cuda-rocm owns.
    """

    out: dict[str, dict] = {}
    for name, raw in (spec.defaults.get("vars") or {}).items():
        out[name] = _declaration(name, raw)
    for img in spec.base_chain(image):
        for name, raw in (spec.images.get(img, {}).get("vars") or {}).items():
            out[name] = _declaration(name, raw)
    return out


def resolve_vars(
    cfg: Config,
    target: Target,
    extra: dict[str, str] | None = None,
) -> dict[str, str]:
    """Every var visible to *target*'s templates and build args.

    Precedence: declared default, then the variant's overlay, then the
    environment -- but the environment may only override a var the variant does
    *not* pin.  A stray ``QEMU_COMMIT`` in a local .env must not silently
    rewrite what the -sbates-fork image is built against.
    """

    spec = cfg.spec
    decls = declarations(spec, target.image)
    pinned = spec.variant_spec(target).get("vars") or {}

    values: dict[str, str] = {}
    for name, decl in decls.items():
        if name in pinned:
            values[name] = str(pinned[name])
        else:
            values[name] = _env_or_default(decl["env"], decl["value"])

    for name in pinned:
        if name not in decls:
            console.print(
                f"[red]Error:[/] {target.key}: variant pins undeclared var '{name}'"
            )
            sys.exit(1)

    values.update(
        {
            "ns": spec.label_ns,
            "ubuntu_version": cfg.ubuntu_version,
            "image_dir": target.image,
            "image_tag": cfg.image_tag,
            "scope": target_scope(cfg, target),
        }
    )
    if extra:
        values.update(extra)
    return values


def secret_vars(cfg: Config, target: Target) -> set[str]:
    return {
        n for n, d in declarations(cfg.spec, target.image).items() if d.get("secret")
    }


# ── targets ────────────────────────────────────────────


def target_suffix(cfg: Config, target: Target) -> str:
    """Appended to the repository name, so a variant gets its own repo."""
    return str(cfg.spec.variant_spec(target).get("suffix", ""))


def target_scope(cfg: Config, target: Target) -> str:
    """Directory name plus suffix.

    Used for the BuildKit cache ref, CI artifact names and the local ``:test``
    tag -- anywhere a target needs a flat, filesystem- and tag-safe name.
    """
    return f"{target.image}{target_suffix(cfg, target)}"


def target_attr(cfg: Config, target: Target, key: str, default: object = "") -> object:
    """A spec field, with the variant overriding the image."""
    variant = cfg.spec.variant_spec(target)
    if key in variant:
        return variant[key]
    return cfg.spec.image_spec(target.image).get(key, default)


def needs_entitlement(cfg: Config, target: Target) -> str:
    return str(target_attr(cfg, target, "entitlement", "") or "")


def base_target(cfg: Config, target: Target) -> Target | None:
    """The target this one layers on, or None if it builds from upstream.

    Variants do not stack: a variant layers on its base's *default* target
    unless it names a ``base_variant``.
    """
    base = str(target_attr(cfg, target, "base", "") or "")
    if not base:
        return None
    return Target(base, str(target_attr(cfg, target, "base_variant", "") or ""))


def discover_targets(cfg: Config) -> list[Target]:
    """Every target declared in the spec, in dependency order.

    Stable within a dependency level: the spec's own order is preserved for
    images that do not depend on each other.
    """

    flat: list[Target] = []
    for image in cfg.spec.images:
        flat.append(Target(image))
        for variant in cfg.spec.image_spec(image).get("variants") or {}:
            flat.append(Target(image, variant))
    return order_targets(cfg, flat)


def order_targets(cfg: Config, targets: list[Target]) -> list[Target]:
    """Sort so every target follows the target it is layered on."""

    ordered: list[Target] = []
    seen: set[Target] = set()
    known = set(targets)

    def visit(t: Target, stack: tuple[Target, ...] = ()) -> None:
        if t in seen:
            return
        if t in stack:
            cycle = " -> ".join(x.key for x in (*stack, t))
            console.print(f"[red]Error:[/] circular image dependency: {cycle}")
            sys.exit(1)
        base = base_target(cfg, t)
        # A base outside the requested set is pulled from the registry
        # instead of being built, so it imposes no ordering.
        if base and base in known:
            visit(base, (*stack, t))
        seen.add(t)
        ordered.append(t)

    for t in targets:
        visit(t)
    return ordered


def parse_target(cfg: Config, name: str) -> Target:
    """``ubuntu-cuda-rocm-fio`` or ``ubuntu-cuda-rocm-fio@async-hipfile``."""
    image, _, variant = name.partition("@")
    target = Target(image, variant)
    cfg.spec.variant_spec(target)  # validates the variant exists
    if not (cfg.workdir / image / "Dockerfile").is_file():
        console.print(f"[red]Error:[/] Dockerfile not found in {image}")
        sys.exit(1)
    return target


def resolve_targets(cfg: Config, arg: str | None) -> list[Target]:
    """The named target, or every target in dependency order."""
    if arg:
        return [parse_target(cfg, arg)]
    return discover_targets(cfg)


# ── image naming ───────────────────────────────────────


def repo_name(cfg: Config, target: Target) -> str:
    """The bare repository name, no user prefix and no registry."""
    return f"{cfg.registry_image.rsplit('/', 1)[-1]}-{target_scope(cfg, target)}"


def full_image_ref(cfg: Config, target: Target) -> str:
    """The full registry-relative name (without tag)."""
    name = cfg.registry_image
    if "/" not in name and cfg.registry_username:
        name = f"{cfg.registry_username}/{name}"
    return f"{name}-{target_scope(cfg, target)}"


def tagged_ref(cfg: Config, target: Target, tag: str | None = None) -> str:
    """Full registry/name:tag string."""
    t = tag or cfg.image_tag
    return f"{cfg.registry}/{full_image_ref(cfg, target)}:{t}"


def _qemu_variant(cfg: Config, target: Target, values: dict[str, str]) -> str:
    """QEMU's tag fragment.

    A release tag becomes ``qemu11.1.1``; a fork branch or SHA is named rather
    than dressed up as a version.  libvfio-user is in the tag too: this image
    links against it, so without it two builds differing only in that pin would
    collide.
    """
    ref = values["qemu_commit"].strip().lower()
    vfu = f"-vfu.{_short(values['libvfio_user_commit'])}"
    if _VERSION_RE.match(ref.removeprefix("v")):
        return f"qemu{_ver(ref)}{vfu}"
    return f"qemu.{_short(ref)}{vfu}"


VARIANT_HELPERS = {"qemu_variant": _qemu_variant}


def image_variant(cfg: Config, target: Target) -> str:
    """Tag fragment naming the payload that differentiates this build.

    Derived from the same vars that feed the build args, so the tag cannot
    drift from what was actually built.
    """

    template = str(target_attr(cfg, target, "variant", "") or "")
    if not template:
        return ""
    values = resolve_vars(cfg, target)
    if template.startswith("!"):
        helper = VARIANT_HELPERS.get(template[1:])
        if helper is None:
            console.print(
                f"[red]Error:[/] {target.key}: unknown variant helper '{template[1:]}'"
            )
            sys.exit(1)
        return helper(cfg, target, values)
    return render(template, values, f"{target.key} variant")


def tag_set(cfg: Config, target: Target, base_tag: str | None = None) -> list[str]:
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
    variant = image_variant(cfg, target)
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


def primary_ref(cfg: Config, target: Target) -> str:
    """The most specific published ref -- what CI should pin."""
    return tagged_ref(cfg, target, tag=tag_set(cfg, target)[0])


def _env_key(name: str) -> str:
    """ubuntu-rocm-ernic -> UBUNTU_ROCM_ERNIC"""
    return name.replace("-", "_").upper()


def base_image_for(cfg: Config, target: Target) -> str:
    """The BASE_IMAGE build arg for a layered target, or "" if it has no base.

    Defaults to this run's own tag for the base: ``discover_targets`` orders
    bases first, so a full build produces and ``--load``s the base before the
    dependant needs it.
    """
    base = base_target(cfg, target)
    if not base:
        return ""
    # Two override forms: one keyed by the dependant, one keyed by the base.
    # CI uses the latter to point every dependant at a scratch registry copy
    # of a base built earlier in the same run, with a single env var.
    override = os.environ.get(f"BASE_IMAGE_{_env_key(target_scope(cfg, target))}", "")
    if not override:
        override = os.environ.get(f"BASE_IMAGE_{_env_key(target.image)}", "")
    if not override:
        override = os.environ.get(f"BASE_IMAGE_FOR_{_env_key(base.image)}", "")
    if not override and target.image == "ubuntu-cuda-rocm-fio":
        override = cfg.fio_base_image
    if override:
        return override
    return primary_ref(cfg, base)


def build_args_for(
    cfg: Config,
    target: Target,
    kvm_build: bool = False,
    include_secrets: bool = True,
) -> list[str]:
    """Every ``--build-arg`` this target needs, as ``KEY=value`` strings.

    Single source of truth for the pins: both the local build and the CI
    workflows read them from here, so a version cannot be bumped in one
    place and missed in the other.

    ``include_secrets`` is False for anything that gets printed: the VM
    PASSWORD would otherwise land in a CI log or a ``$GITHUB_OUTPUT`` file.
    """

    args: list[str] = []
    base = base_image_for(cfg, target)
    if base:
        args.append(f"BASE_IMAGE={base}")

    values = resolve_vars(
        cfg,
        target,
        extra={
            "vm_stage": "vm-kvm" if kvm_build else "vm-tcg",
            "kvm": "true" if kvm_build else "false",
        },
    )
    secrets = secret_vars(cfg, target)

    for key, template in (
        cfg.spec.image_spec(target.image).get("build_args") or {}
    ).items():
        template = str(template)
        if not include_secrets and template_vars(template) & secrets:
            continue
        args.append(f"{key}={render(template, values, f'{target.key} {key}')}")
    return args


def image_labels(cfg: Config, target: Target) -> dict[str, str]:
    """OCI labels describing what went into *target*.

    The variant tag is a summary for humans; these are the same facts in a
    form a scanner can read without parsing a tag.
    """

    values = resolve_vars(cfg, target)
    labels = {
        "org.opencontainers.image.title": repo_name(cfg, target),
        f"{cfg.spec.label_ns}.variant": image_variant(cfg, target),
    }
    # The canonical published base, not whatever scratch ref this particular
    # build layered on: CI points BASE_IMAGE at a per-run GHCR tag that will
    # not exist by the time anyone reads the label.
    base = base_target(cfg, target)
    if base:
        labels["org.opencontainers.image.base.name"] = primary_ref(cfg, base)

    for key, template in (
        cfg.spec.image_spec(target.image).get("labels") or {}
    ).items():
        where = f"{target.key} label"
        labels[render(str(key), values, where)] = render(str(template), values, where)
    return {k: v for k, v in labels.items() if v}


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
    """Build one or all targets with docker buildx."""

    cfg = load_config(
        env_file=args.env_file,
        password_file=args.password_file,
    )
    targets = resolve_targets(cfg, args.image)
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
    selected = set(targets)
    local_bases = {
        t
        for t in targets
        if base_target(cfg, t) in selected and not args.base_from_registry
    }

    # The VM image is the only one needing an entitlement the 'default' builder
    # cannot grant, so it is the only one for which being pushed off the buildx
    # builder actually costs anything. Targets are built in dependency order and
    # each is pushed as soon as it is built, so when we have credentials its base
    # is already published by the time we get here: point at that and keep the
    # builder, rather than trading KVM for a local image reference. Only worth it
    # for entitlement-needing images -- routing ubuntu-cuda-rocm-fio the same way
    # would re-pull a 28 GB base for no gain.
    if has_credentials(cfg) and kvm_build:
        local_bases -= {t for t in local_bases if needs_entitlement(cfg, t)}

    for t in local_bases:
        if needs_entitlement(cfg, t) and kvm_build:
            console.print(
                f"[yellow]Warning:[/] {base_target(cfg, t)} is being built in "
                f"this run and no registry credentials are set, so {t.key} must "
                "build on the 'default' builder, which cannot grant "
                "security.insecure; its VM stage falls back to TCG emulation. "
                "Pass --base-from-registry to build against the published base "
                "and keep KVM."
            )

    for target in targets:
        refs = [tagged_ref(cfg, target, tag=x) for x in tag_set(cfg, target)]
        local_base = target in local_bases
        entitlement = needs_entitlement(cfg, target)
        target_kvm = kvm_build and not (entitlement and local_base)

        build_args = build_args_for(cfg, target, kvm_build=target_kvm)
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
        if entitlement and target_kvm:
            cmd += ["--allow", entitlement]
        for ba in build_args:
            cmd += ["--build-arg", ba]
        if args.no_cache:
            cmd.append("--no-cache")
        for ref in refs:
            cmd += ["--tag", ref]
        for key, value in image_labels(cfg, target).items():
            cmd += ["--label", f"{key}={value}"]
        cmd += ["--load"]
        cmd += [
            "-f",
            str(cfg.workdir / target.image / "Dockerfile"),
        ]
        cmd.append(str(cfg.workdir))

        console.rule(f"[bold]Building {target.key}[/]")
        _print_build_summary(cfg, target, args, target_kvm)

        # Declared in images.yml: the Dockerfile bind-mounts these, and
        # buildx fails if one is missing (they hold gitignored downloads).
        for rel in target_attr(cfg, target, "context_dirs", []) or []:
            (cfg.workdir / str(rel)).mkdir(parents=True, exist_ok=True)

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

        console.rule(f"[bold green]Build complete: {target.key}[/]")


def _print_build_summary(
    cfg: Config,
    target: Target,
    args: argparse.Namespace,
    kvm_build: bool = False,
) -> None:
    """Pretty-print the build configuration."""
    tags = tag_set(cfg, target)
    table = Table(
        title="Build Configuration",
        show_header=False,
    )
    table.add_column("Key", style="bold")
    table.add_column("Value")
    table.add_row("Image", tagged_ref(cfg, target, tag=tags[0]))
    table.add_row("Aliases", ", ".join(tags[1:]) or "-")
    table.add_row("Directory", target.image)
    if target.variant:
        table.add_row("Variant", target.variant)
    base = base_image_for(cfg, target)
    if base:
        table.add_row("Base Image", base)

    # The pins themselves, straight off the resolved vars: no per-image chain
    # to keep in step with images.yml.
    secrets = secret_vars(cfg, target)
    values = resolve_vars(cfg, target)
    own = declarations(cfg.spec, target.image)
    for name in own:
        if name in secrets:
            continue
        table.add_row(name, values[name] or "-")
    if needs_entitlement(cfg, target):
        table.add_row("KVM", "true" if kvm_build else "false (TCG emulation)")

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

    for target in resolve_targets(cfg, args.image):
        console.rule(f"[bold]Pushing {target.key}[/]")
        for tag in tag_set(cfg, target):
            ref = tagged_ref(cfg, target, tag=tag)
            subprocess.run(["docker", "push", ref], check=True)
            console.print(f"[green]Pushed[/] {ref}")


def cmd_list(args: argparse.Namespace) -> None:
    """List every target declared in the spec."""

    cfg = load_config(env_file=args.env_file)
    targets = discover_targets(cfg)

    if args.names_only:
        print("\n".join(t.key for t in targets))
        return

    table = Table(title="Targets")
    table.add_column("#", style="dim")
    table.add_column("Target")
    table.add_column("Job")
    table.add_column("Variant")
    table.add_column("Full Reference")

    for idx, t in enumerate(targets, 1):
        table.add_row(
            str(idx),
            t.key,
            str(target_attr(cfg, t, "job", "-")),
            image_variant(cfg, t) or "-",
            primary_ref(cfg, t),
        )

    console.print(table)


def cmd_targets(args: argparse.Namespace) -> None:
    """Emit the CI build matrix.

    Both workflows call this instead of globbing for Dockerfiles and carrying
    their own exclusion lists, so which job builds what is decided in one place.
    """

    cfg = load_config(env_file=args.env_file)
    rows = []
    for t in discover_targets(cfg):
        job = str(target_attr(cfg, t, "job", "matrix"))
        if args.job and job != args.job:
            continue
        base = base_target(cfg, t)
        rows.append(
            {
                "key": t.key,
                "image": t.image,
                "variant": t.variant,
                "suffix": target_suffix(cfg, t),
                "scope": target_scope(cfg, t),
                "job": job,
                "artifact": bool(target_attr(cfg, t, "artifact", False)),
                "entitlement": needs_entitlement(cfg, t),
                # Lets the derived CI job point BASE_IMAGE at the copy of its
                # base built earlier in the same run without naming any image.
                "base": base.key if base else "",
                "base_scope": target_scope(cfg, base) if base else "",
            }
        )

    if args.json:
        print(json.dumps(rows, separators=(",", ":")))
        return
    print("\n".join(r["key"] for r in rows))


def cmd_validate(args: argparse.Namespace) -> None:
    """Check images.yml against the tree, and that everything renders."""

    cfg = load_config(env_file=args.env_file)
    errors: list[str] = []

    on_disk = {
        c.name
        for c in cfg.workdir.iterdir()
        if c.is_dir() and (c / "Dockerfile").is_file()
    }
    declared = set(cfg.spec.images)
    for missing in sorted(on_disk - declared):
        errors.append(f"{missing}/Dockerfile exists but {SPEC_FILE} has no entry")
    for missing in sorted(declared - on_disk):
        errors.append(
            f"{SPEC_FILE} declares {missing} but {missing}/Dockerfile is absent"
        )

    targets = discover_targets(cfg)  # also detects dependency cycles

    scopes: dict[str, str] = {}
    for t in targets:
        scope = target_scope(cfg, t)
        if scope in scopes:
            errors.append(f"{t.key} and {scopes[scope]} share the repository {scope}")
        scopes[scope] = t.key
        # Renders every template; render() exits on an unknown var or filter.
        image_variant(cfg, t)
        image_labels(cfg, t)
        build_args_for(cfg, t)
        build_args_for(cfg, t, kvm_build=True)

    if errors:
        for e in errors:
            console.print(f"[red]Error:[/] {e}")
        sys.exit(1)
    source = SPEC_FILE
    if cfg.spec.overlay:
        source = f"{SPEC_FILE} + {OVERLAY_FILE}"
    console.print(f"[green]OK[/] {len(targets)} targets in {source}")


def cmd_tags(args: argparse.Namespace) -> None:
    """Print a target's tag set, one per line, on plain stdout.

    Release CI consumes this so the workflow and a local build derive the tags
    from one implementation.
    """

    cfg = load_config(env_file=args.env_file)
    if args.tag:
        cfg.image_tag = resolve_image_tag(args.tag)

    target = parse_target(cfg, args.image)
    tags = tag_set(cfg, target) + list(args.extra_tag)
    if args.names_only:
        print("\n".join(dict.fromkeys(tags)))
        return

    name = full_image_ref(cfg, target) + args.suffix
    seen = dict.fromkeys(f"{cfg.registry}/{name}:{t}" for t in tags)
    print("\n".join(seen))


def cmd_build_args(args: argparse.Namespace) -> None:
    """Print a target's build args, one ``KEY=value`` per line, on plain stdout.

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
                parse_target(cfg, args.image),
                kvm_build=args.kvm,
                include_secrets=False,
            )
        )
    )


def cmd_labels(args: argparse.Namespace) -> None:
    """Print a target's OCI labels as ``key=value`` lines on plain stdout."""

    cfg = load_config(env_file=args.env_file)
    if args.tag:
        cfg.image_tag = resolve_image_tag(args.tag)

    labels = image_labels(cfg, parse_target(cfg, args.image))
    print("\n".join(f"{k}={v}" for k, v in labels.items()))


def cmd_config(args: argparse.Namespace) -> None:
    """Print a resolved var, or every var, for a target.

    ``--get`` is what scripts/version-scrub.sh uses to read the current pin
    without grepping the YAML itself.
    """

    cfg = load_config(env_file=args.env_file)
    target = parse_target(cfg, args.image)
    values = resolve_vars(cfg, target)
    secrets = secret_vars(cfg, target)

    if args.get:
        if args.get not in values:
            console.print(f"[red]Error:[/] {target.key} has no var '{args.get}'")
            sys.exit(1)
        print(values[args.get])
        return

    for name in declarations(cfg.spec, target.image):
        if name in secrets:
            continue
        print(f"{name}={values[name]}")


def cmd_inspect(args: argparse.Namespace) -> None:
    """Inspect locally-available Docker images."""

    cfg = load_config(
        env_file=args.env_file,
        password_file=getattr(args, "password_file", None),
    )

    try:
        client = docker.from_env()
    except docker.errors.DockerException as exc:
        console.print(f"[red]Error:[/] cannot connect to Docker daemon: {exc}")
        sys.exit(1)

    for target in resolve_targets(cfg, args.image):
        ref = primary_ref(cfg, target)
        console.rule(f"[bold]{target.key}[/]")

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

    for target in resolve_targets(cfg, args.image):
        console.rule(f"[bold]{target.key}[/]")
        _query_registry(cfg, full_image_ref(cfg, target))


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

TARGET_HELP = "Target name: <image> or <image>@<variant>"


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
        metavar="TARGET",
        help=f"{TARGET_HELP} (builds all if omitted)",
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
        metavar="TARGET",
        help=f"{TARGET_HELP} (pushes all if omitted)",
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
        help="List every target declared in images.yml",
    )
    p_list.add_argument(
        "--names-only",
        action="store_true",
        help="Print bare target keys, one per line",
    )
    _add_common_args(p_list)

    # ── targets ──
    p_targets = sub.add_parser(
        "targets",
        help="Emit the CI build matrix",
    )
    p_targets.add_argument(
        "--job",
        metavar="NAME",
        help="Only targets whose job is NAME (bases, matrix, derived)",
    )
    p_targets.add_argument(
        "--json",
        action="store_true",
        help="Emit a JSON array for a GitHub Actions matrix",
    )
    _add_common_args(p_targets)

    # ── validate ──
    p_validate = sub.add_parser(
        "validate",
        help="Check images.yml against the tree and render every template",
    )
    _add_common_args(p_validate)

    # ── tags ──
    p_tags = sub.add_parser(
        "tags",
        help="Print the tags a target should be published under",
    )
    p_tags.add_argument("image", metavar="TARGET", help=TARGET_HELP)
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
        help=(
            "Extra text appended to the repository name, on top of the "
            "target's own variant suffix"
        ),
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
        help="Print a target's docker build args as KEY=value lines",
    )
    p_build_args.add_argument("image", metavar="TARGET", help=TARGET_HELP)
    p_build_args.add_argument(
        "--tag",
        metavar="TAG",
        help=("Base tag being published; sets the BASE_IMAGE reference emitted"),
    )
    p_build_args.add_argument(
        "--kvm",
        action="store_true",
        help="Select the vm-kvm stage for the VM image",
    )
    _add_common_args(p_build_args)

    # ── labels ──
    p_labels = sub.add_parser(
        "labels",
        help="Print a target's OCI labels as key=value lines",
    )
    p_labels.add_argument("image", metavar="TARGET", help=TARGET_HELP)
    p_labels.add_argument(
        "--tag",
        metavar="TAG",
        help=(
            "Base tag being published; sets the base image reference "
            "recorded for derived images"
        ),
    )
    _add_common_args(p_labels)

    # ── config ──
    p_config = sub.add_parser(
        "config",
        help="Print a target's resolved vars as name=value lines",
    )
    p_config.add_argument("image", metavar="TARGET", help=TARGET_HELP)
    p_config.add_argument(
        "--get",
        metavar="VAR",
        help="Print just this var's value",
    )
    _add_common_args(p_config)

    # ── inspect ──
    p_inspect = sub.add_parser(
        "inspect",
        help="Inspect local Docker images",
    )
    p_inspect.add_argument(
        "image",
        nargs="?",
        default=None,
        metavar="TARGET",
        help=f"{TARGET_HELP} (inspects all if omitted)",
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
        metavar="TARGET",
        help=f"{TARGET_HELP} (queries all if omitted)",
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
    "targets": cmd_targets,
    "validate": cmd_validate,
    "tags": cmd_tags,
    "build-args": cmd_build_args,
    "labels": cmd_labels,
    "config": cmd_config,
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
