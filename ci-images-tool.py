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
DEFAULT_QEMU_COMMIT = "v10.2.2"
DEFAULT_LIBVFIO_USER_COMMIT = "082925c65d98021af5c0f36f60a98e0bb6ddb329"
DEFAULT_REGISTRY = "docker.io"
DEFAULT_IMAGE_TAG = "latest"
DEFAULT_USERNAME = "batesste"
DEFAULT_PASSWORD = "changeme"
DEFAULT_RELEASE = "noble"
DEFAULT_ARCH = "amd64"
DEFAULT_CUDA_VERSION = "latest"
DEFAULT_ROCM_VERSION = "latest"

ENV_SEARCH_PATHS = [
    ".env",
    "/etc/batesste-ci-images/.env",
]


def resolve_image_tag(raw: str | None = None) -> str:
    """Return the effective OCI image tag.

    When unset, empty, or set to ``auto``/``date``, use today's date in the
    form ``may-26-2026``. Otherwise return the provided tag (e.g. ``latest``).
    """

    if raw is None:
        raw = os.environ.get("IMAGE_TAG", "")
    tag = (raw or "").strip()
    if not tag or tag.lower() in {"auto", "date"}:
        return datetime.now(tz=timezone.utc).strftime("%B-%d-%Y").lower()
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
    qemu_minimal_repo: str = ""
    qemu_minimal_commit: str = ""

    username: str = DEFAULT_USERNAME
    vm_name: str = ""
    password: str = DEFAULT_PASSWORD
    release: str = DEFAULT_RELEASE
    arch: str = DEFAULT_ARCH
    cuda_version: str = DEFAULT_CUDA_VERSION
    rocm_version: str = DEFAULT_ROCM_VERSION


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
        qemu_commit=os.environ.get("QEMU_COMMIT", DEFAULT_QEMU_COMMIT),
        libvfio_user_commit=os.environ.get(
            "LIBVFIO_USER_COMMIT",
            DEFAULT_LIBVFIO_USER_COMMIT,
        ),
        qemu_minimal_repo=os.environ.get("QEMU_MINIMAL_REPO", ""),
        qemu_minimal_commit=os.environ.get("QEMU_MINIMAL_COMMIT", ""),
        username=os.environ.get("USERNAME", DEFAULT_USERNAME),
        vm_name=os.environ.get("VM_NAME", ""),
        password=os.environ.get("PASSWORD", DEFAULT_PASSWORD),
        release=os.environ.get("RELEASE", DEFAULT_RELEASE),
        arch=os.environ.get("ARCH", DEFAULT_ARCH),
        cuda_version=os.environ.get("CUDA_VERSION", DEFAULT_CUDA_VERSION),
        rocm_version=os.environ.get("ROCM_VERSION", DEFAULT_ROCM_VERSION),
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


def resolve_image_dirs(workdir: Path, image_arg: str | None) -> list[str]:
    """If the caller specified a single image name, return
    it; otherwise discover all."""
    if image_arg:
        dockerfile = workdir / image_arg / "Dockerfile"
        if not dockerfile.is_file():
            console.print(f"[red]Error:[/] Dockerfile not found in {image_arg}")
            sys.exit(1)
        return [image_arg]
    return discover_images(workdir)


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


def ensure_builder() -> None:
    """Create or select the buildx builder."""
    # Allow create to fail (e.g., builder already exists), but
    # capture output so we can report it if selecting the builder fails.
    create_proc = subprocess.run(
        [
            "docker",
            "buildx",
            "create",
            "--name",
            "builder",
            "--use",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    use_proc = subprocess.run(
        ["docker", "buildx", "use", "builder"],
        capture_output=True,
        text=True,
        check=False,
    )
    if use_proc.returncode != 0:
        console.print(
            "[red]Error:[/] failed to select docker buildx builder 'builder'."
        )
        if create_proc.returncode != 0 and create_proc.stderr:
            console.print("[red]docker buildx create stderr:[/]")
            console.print(create_proc.stderr.strip())
        if use_proc.stderr:
            console.print("[red]docker buildx use stderr:[/]")
            console.print(use_proc.stderr.strip())
        sys.exit(1)


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

    if not dry_run:
        ensure_buildx()
        ensure_builder()
        docker_login(cfg)

    for image_dir in image_dirs:
        ref_tag = tagged_ref(cfg, image_dir)
        ref_latest = tagged_ref(cfg, image_dir, tag="latest")

        build_args: list[str] = [
            f"QEMU_REPO={cfg.qemu_repo}",
            f"QEMU_COMMIT={cfg.qemu_commit}",
            f"LIBVFIO_USER_COMMIT={cfg.libvfio_user_commit}",
            f"QEMU_MINIMAL_REPO={cfg.qemu_minimal_repo}",
            f"QEMU_MINIMAL_COMMIT={cfg.qemu_minimal_commit}",
            f"USERNAME={cfg.username}",
            f"VM_NAME={cfg.vm_name}",
            f"PASSWORD={cfg.password}",
            f"RELEASE={cfg.release}",
            f"ARCH={cfg.arch}",
        ]
        if image_dir == "ubuntu-cuda-rocm":
            build_args += [
                f"CUDA_VERSION={cfg.cuda_version}",
                f"ROCM_VERSION={cfg.rocm_version}",
            ]
        if args.cache_bust:
            build_args.append(f"CACHE_BUST={args.cache_bust}")

        cmd: list[str] = ["docker", "buildx", "build"]
        for ba in build_args:
            cmd += ["--build-arg", ba]
        if args.no_cache:
            cmd.append("--no-cache")
        cmd += ["--tag", ref_tag]
        cmd += ["--tag", ref_latest]
        cmd += ["--load"]
        cmd += [
            "-f",
            str(cfg.workdir / image_dir / "Dockerfile"),
        ]
        cmd.append(str(cfg.workdir / image_dir))

        console.rule(f"[bold]Building {image_dir}[/]")
        _print_build_summary(cfg, image_dir, args)

        if dry_run:
            console.print("[yellow]dry-run:[/] " + " ".join(cmd))
            continue

        subprocess.run(cmd, check=True)

        if has_credentials(cfg):
            console.rule("[bold]Pushing to registry[/]")
            subprocess.run(["docker", "push", ref_tag], check=True)
            subprocess.run(
                ["docker", "push", ref_latest],
                check=True,
            )
            console.print(f"[green]Pushed[/] {ref_tag}")
        else:
            console.print("[dim]Registry credentials not provided, skipping push[/]")

        console.rule(f"[bold green]Build complete: {image_dir}[/]")


def _print_build_summary(
    cfg: Config,
    image_dir: str,
    args: argparse.Namespace,
) -> None:
    """Pretty-print the build configuration."""
    ref = tagged_ref(cfg, image_dir)
    table = Table(
        title="Build Configuration",
        show_header=False,
    )
    table.add_column("Key", style="bold")
    table.add_column("Value")
    table.add_row("Image", ref)
    table.add_row("Directory", image_dir)
    table.add_row("QEMU Commit", cfg.qemu_commit)
    if cfg.libvfio_user_commit:
        table.add_row(
            "libvfio-user Commit",
            cfg.libvfio_user_commit,
        )
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
        ref_tag = tagged_ref(cfg, image_dir)
        ref_latest = tagged_ref(cfg, image_dir, tag="latest")
        console.rule(f"[bold]Pushing {image_dir}[/]")
        subprocess.run(["docker", "push", ref_tag], check=True)
        subprocess.run(["docker", "push", ref_latest], check=True)
        console.print(f"[green]Pushed[/] {ref_tag}")


def cmd_list(args: argparse.Namespace) -> None:
    """List all discoverable image directories."""

    cfg = load_config(env_file=args.env_file)
    dirs = discover_images(cfg.workdir)

    table = Table(title="Discoverable Images")
    table.add_column("#", style="dim")
    table.add_column("Directory")
    table.add_column("Full Reference")

    for idx, d in enumerate(dirs, 1):
        table.add_row(str(idx), d, tagged_ref(cfg, d))

    console.print(table)


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
        ref = tagged_ref(cfg, image_dir)
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
