#!/usr/bin/env python3
"""Turn one Dockerfile Test run's job list into per-artifact shields endpoints.

    gh api repos/$REPO/actions/runs/$RUN_ID/jobs --paginate > jobs.json
    scripts/publish-build-status.py --jobs jobs.json --site gh-pages \
        --run-url https://github.com/owner/repo/actions/runs/$RUN_ID

shields.io has no `job` parameter -- it accepts one and ignores it, so a badge
asking for a single job's conclusion silently reports the whole workflow's
instead, and every artifact in the README showed the same colour. The only way
to get a real per-job badge is to publish the conclusions ourselves and point
the README at shields' `endpoint` type, which is what this does.

One file per job under `builds/`, named by the same slug ci-images-tool.py
computes for the README, plus `builds/index.json` carrying the run the badges
came from. Writing the whole directory from scratch each time is deliberate:
a target deleted from images.yml should lose its badge rather than keep
serving the last answer anyone measured for it.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import UTC, datetime
from pathlib import Path

JOB_PREFIX = "Build "
# Must match ci-images-tool.py's STATUS_BASES_JOB: one job builds ubuntu-base
# and ubuntu-libvfio-user together.
BASES_JOB = "Build Base Images"

# conclusion -> (message, colour). A job that was never queued is not in the
# API response at all and gets NOT_BUILT below.
#
# "skipped" is the one worth being careful about. The workflow path-filters its
# matrix, so a push that touched one image skips the other twenty -- that is a
# correct, healthy run, and colouring it red would train everyone to ignore the
# table. It is not green either: nothing was proven about that artifact on this
# commit. Grey, saying so.
CONCLUSIONS: dict[str, tuple[str, str]] = {
    "success": ("passing", "brightgreen"),
    "failure": ("failing", "red"),
    "cancelled": ("cancelled", "inactive"),
    "skipped": ("not rebuilt", "lightgrey"),
    "timed_out": ("timed out", "red"),
    "action_required": ("action required", "yellow"),
    "neutral": ("neutral", "lightgrey"),
}
NOT_BUILT = ("no run", "lightgrey")


def slug(job: str) -> str:
    """The badge filename for *job*, matching status_badge_slug() in the tool.

    Job names carry `@` and `.` (``Build ubuntu-qcow2-gen@ernic-rocjitsu``),
    neither of which belongs in a URL path served off gh-pages, so everything
    outside [a-z0-9] collapses to a single dash.
    """

    return re.sub(r"[^a-z0-9]+", "-", job.lower()).strip("-")


def badge(label: str, message: str, colour: str) -> dict:
    return {
        "schemaVersion": 1,
        "label": label,
        "message": message,
        "color": colour,
    }


def job_badges(jobs: list[dict]) -> dict[str, dict]:
    """One shields endpoint per `Build *` job, keyed by badge filename."""

    out: dict[str, dict] = {}
    for job in jobs:
        name = str(job.get("name", ""))
        if not name.startswith(JOB_PREFIX):
            continue
        # A job still running when the publisher queries the API has no
        # conclusion yet. That is this job's own tier only in the pathological
        # case; normally it means a tier was still finishing, and reporting
        # "pending" beats inventing a pass.
        if job.get("status") != "completed":
            message, colour = "pending", "lightgrey"
        else:
            message, colour = CONCLUSIONS.get(
                str(job.get("conclusion")), ("unknown", "lightgrey")
            )
        label = "build" if name == BASES_JOB else name[len(JOB_PREFIX) :]
        out[slug(name)] = badge(label, message, colour)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--jobs",
        type=Path,
        required=True,
        help="JSON from `gh api .../actions/runs/<id>/jobs --paginate`",
    )
    ap.add_argument(
        "--site", type=Path, required=True, help="gh-pages checkout to write into"
    )
    ap.add_argument("--run-url", default="", help="recorded in builds/index.json")
    ap.add_argument("--sha", default="", help="recorded in builds/index.json")
    args = ap.parse_args()

    try:
        payload = json.loads(args.jobs.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        print(f"error: cannot read {args.jobs}: {exc}", file=sys.stderr)
        return 1

    # `gh api --paginate` on this endpoint yields the envelope, but a plain
    # `--jq .jobs` upstream of us yields the bare list. Accept both rather than
    # make the workflow's quoting load-bearing.
    jobs = payload.get("jobs", payload) if isinstance(payload, dict) else payload
    if not isinstance(jobs, list):
        print(f"error: {args.jobs} has no job list", file=sys.stderr)
        return 1

    badges = job_badges(jobs)
    if not badges:
        # Refusing here is the point. An empty write would blank every badge on
        # the site, and "all grey" is indistinguishable from a genuinely broken
        # workflow -- so leave the last good answer up and fail loudly.
        print(f"error: no '{JOB_PREFIX}*' jobs in {args.jobs}", file=sys.stderr)
        return 1

    builds = args.site / "builds"
    builds.mkdir(parents=True, exist_ok=True)
    for stale in sorted(builds.glob("badge-*.json")):
        stale.unlink()

    for name, body in sorted(badges.items()):
        (builds / f"badge-{name}.json").write_text(json.dumps(body, indent=2) + "\n")

    (builds / "index.json").write_text(
        json.dumps(
            {
                "schema_version": 1,
                "generated": datetime.now(UTC).isoformat(),
                "run_url": args.run_url,
                "sha": args.sha,
                "badges": sorted(badges),
            },
            indent=2,
        )
        + "\n"
    )
    print(f"wrote {len(badges)} build badges to {builds}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
