#!/usr/bin/env python3
"""Turn perf-harness summaries into a gh-pages trend site.

Reads the summary.json that scripts/perf-harness.sh writes, appends it to the
history on a gh-pages checkout, and regenerates two things from the whole
history: one self-contained HTML page, and the shields.io endpoint JSON the
README badges read.

    scripts/publish-perf.py --summary output/perf/summary.json --site gh-pages

Nothing here is a build step. The page is one file with inline SVG and no
JavaScript, because a perf page whose charts depend on a CDN is a perf page
that renders as a blank box the first time someone looks at it from a network
that blocks the CDN -- and a proxied corporate network blocking most of them is
the normal case for the people this page is for.

The history is JSON Lines rather than a single JSON document so that appending
is an append. Two runs finishing together can then only lose a line to the
push race, which the caller retries, rather than corrupting the file.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

# The series to chart, in the order they appear on the page. A metric that
# exists in a summary but not here is still kept in the history -- dropping
# data on the way in is not recoverable -- it just gets no chart until it is
# named. Adding a chart is a line here and nothing else.
#
# "higher_is_better" drives only the wording, not the colour: an emulator's
# numbers move for reasons that are not always regressions, and a red badge
# that cries wolf gets ignored precisely when it matters.
CHARTS: list[dict] = [
    {
        "key": "gemm_gflops",
        "title": "GEMM on the emulated gfx1250",
        "unit": "GFLOP/s",
        "badge": "gemm",
        "colour": "#ED1C24",
        "higher_is_better": True,
        "blurb": (
            "128&times;128&times;128 FP32, validated against a CPU reference "
            "each run. This is an instruction-level emulator, so the figure "
            "is a property of the emulator and the dispatch path rather than "
            "of the arithmetic."
        ),
    },
    {
        "key": "nvme_read_GBs",
        "title": "NVMe sequential read (libaio)",
        "unit": "GB/s",
        "badge": "nvme",
        "colour": "#0F4C81",
        "higher_is_better": True,
        "blurb": (
            "128k sequential reads at queue depth 32 from QEMU's emulated "
            "NVMe controller into host memory. The baseline the hipFile "
            "number below is read against."
        ),
    },
    {
        "key": "nvme_hipfile_read_GBs",
        "title": "NVMe sequential read (hipFile, into GPU memory)",
        "unit": "GB/s",
        "badge": "hipfile",
        "colour": "#76B900",
        "higher_is_better": True,
        "blurb": (
            "1&nbsp;MiB blocks off the same filesystem, read through hipFile "
            "straight into GPU memory by a benchmark that then multiplies two "
            "matrices out of what it read &mdash; so a read landing at the "
            "wrong offset fails rather than scores well. The emulated GPU has "
            "no DMA engine, so this is hipFile's bounce-buffer fallback, "
            "which is the path a consumer on this stack actually gets."
        ),
    },
    {
        "key": "ernic_s3_get_GBs",
        "title": "S3 object GET over RDMA",
        "unit": "GB/s",
        "badge": "ernic",
        "colour": "#C8102E",
        "higher_is_better": True,
        "blurb": (
            "1&nbsp;MiB object GETs from the ERNIC emulator's own S3 backend, "
            "in the loopback deployment: one guest, one server, no peer. The "
            "store terminates an HTTP control plane in band on the emulated "
            "NIC and RDMA-writes the object bytes into registered guest "
            "memory, so nothing here is a queue pair between two hosts. "
            "Average over the sweep; the peak is in the run's note."
        ),
    },
    {
        "key": "boot_seconds",
        "title": "Guest boot to SSH",
        "unit": "s",
        "badge": "boot",
        "colour": "#772953",
        "higher_is_better": False,
        "blurb": (
            "Wall clock from <code>compose up</code> to the guest accepting "
            "SSH, with both vfio-user devices attached and KVM enabled. The "
            "cheapest early warning that something in the boot path has "
            "regressed."
        ),
    },
]

# Charted as a ratio rather than a series of its own: the two absolute numbers
# move together whenever the runner does, and what is actually interesting is
# whether the GPU path is losing ground against the host path.
RATIO = {
    "title": "hipFile / libaio",
    "numerator": "nvme_hipfile_read_GBs",
    "denominator": "nvme_read_GBs",
}

MAX_POINTS = 120

CSS = """
:root { color-scheme: light dark; }
body { font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
       Helvetica, Arial, sans-serif; margin: 0 auto; max-width: 62rem;
       padding: 2rem 1.25rem 4rem; }
h1 { margin-bottom: .25rem; }
h2 { margin-top: 2.5rem; border-bottom: 1px solid #8884; padding-bottom: .3rem; }
.sub { color: #7a7a7a; margin-top: 0; }
.blurb { color: #6a6a6a; max-width: 46rem; }
.latest { font-size: 2rem; font-weight: 600; }
.unit { font-size: 1rem; font-weight: 400; color: #7a7a7a; }
.skip { color: #b06000; font-size: .9rem; }
table { border-collapse: collapse; font-size: .86rem; width: 100%; }
th, td { text-align: left; padding: .35rem .6rem; border-bottom: 1px solid #8883; }
th { color: #7a7a7a; font-weight: 600; }
td.num { text-align: right; font-variant-numeric: tabular-nums; }
code { background: #8881; padding: .1em .35em; border-radius: 3px; }
footer { margin-top: 3rem; color: #7a7a7a; font-size: .85rem; }
svg { max-width: 100%; height: auto; }
"""


def load_history(path: Path) -> list[dict]:
    """Every run recorded so far, oldest first.

    A malformed line is skipped rather than fatal. The history is appended to
    by CI jobs that can be cancelled mid-write, and one truncated line at the
    end of the file must not take the whole site down with it.
    """
    if not path.exists():
        return []
    runs = []
    for lineno, line in enumerate(path.read_text().splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        try:
            run = json.loads(line)
        except json.JSONDecodeError as exc:
            print(
                f"warning: {path}:{lineno}: skipping bad line: {exc}", file=sys.stderr
            )
            continue
        # `null`, a bare number and `[]` are all valid JSON and none of them is
        # a run. A truncation that lands on a line boundary can produce one, and
        # everything downstream -- the sort key, every metric lookup -- assumes
        # a mapping. Skipping here is what the docstring above promises.
        if not isinstance(run, dict):
            print(
                f"warning: {path}:{lineno}: skipping non-object line "
                f"({type(run).__name__})",
                file=sys.stderr,
            )
            continue
        runs.append(run)
    runs.sort(key=lambda r: r.get("generated", ""))
    return runs


def metric(run: dict, key: str) -> tuple[float | None, str]:
    """A run's value for *key*, and the note explaining an absent one."""
    m = (run.get("metrics") or {}).get(key)
    if not m:
        return None, "not recorded"
    if m.get("status") != "ok" or m.get("value") is None:
        return None, str(m.get("note") or m.get("status") or "skipped")
    return float(m["value"]), str(m.get("note") or "")


def fmt(value: float | None) -> str:
    if value is None:
        return "&mdash;"
    if value >= 100:
        return f"{value:,.0f}"
    if value >= 1:
        return f"{value:,.2f}"
    return f"{value:,.4g}"


def sparkline(points: list[tuple[str, float]], colour: str) -> str:
    """An inline SVG line chart with a filled area and a y axis.

    Hand-rolled rather than pulled from a charting library: the whole point of
    the page is that it is one file that renders anywhere, and this is thirty
    lines against a dependency and a build step.
    """
    if not points:
        return '<p class="skip">No data points yet.</p>'
    if len(points) == 1:
        return (
            f'<p class="skip">One data point so far '
            f"({fmt(points[0][1])}); a trend needs two.</p>"
        )

    w, h, pad_l, pad_r, pad_t, pad_b = 900, 240, 62, 12, 14, 34
    values = [v for _, v in points]
    lo, hi = min(values), max(values)
    # A flat series would divide by zero and, worse, draw a line along the
    # very bottom of the box as if it had collapsed. Pad the range instead.
    if hi - lo < abs(hi) * 1e-9 or hi == lo:
        pad = abs(hi) * 0.1 or 1.0
        lo, hi = lo - pad, hi + pad
    else:
        margin = (hi - lo) * 0.1
        lo, hi = lo - margin, hi + margin

    def x(i: int) -> float:
        return pad_l + i * (w - pad_l - pad_r) / (len(points) - 1)

    def y(v: float) -> float:
        return pad_t + (hi - v) * (h - pad_t - pad_b) / (hi - lo)

    line = " ".join(f"{x(i):.1f},{y(v):.1f}" for i, (_, v) in enumerate(points))
    area = (
        f"{pad_l:.1f},{h - pad_b:.1f} {line} {x(len(points) - 1):.1f},{h - pad_b:.1f}"
    )

    gridlines = []
    for frac in (0.0, 0.25, 0.5, 0.75, 1.0):
        v = lo + (hi - lo) * frac
        yy = y(v)
        gridlines.append(
            f'<line x1="{pad_l}" y1="{yy:.1f}" x2="{w - pad_r}" y2="{yy:.1f}" '
            f'stroke="#8883" stroke-width="1"/>'
            f'<text x="{pad_l - 6}" y="{yy + 4:.1f}" text-anchor="end" '
            f'font-size="11" fill="#8a8a8a">{fmt(v)}</text>'
        )

    # First and last only: with a hundred points every label would overlap,
    # and the table underneath carries the exact timestamps anyway.
    labels = []
    for i in (0, len(points) - 1):
        stamp = points[i][0][:10]
        anchor = "start" if i == 0 else "end"
        labels.append(
            f'<text x="{x(i):.1f}" y="{h - 10}" text-anchor="{anchor}" '
            f'font-size="11" fill="#8a8a8a">{html.escape(stamp)}</text>'
        )

    dots = (
        "".join(
            f'<circle cx="{x(i):.1f}" cy="{y(v):.1f}" r="2.5" fill="{colour}"/>'
            for i, (_, v) in enumerate(points)
        )
        if len(points) <= 40
        else ""
    )

    return (
        f'<svg viewBox="0 0 {w} {h}" role="img" '
        f'aria-label="trend, {len(points)} runs">'
        f"{''.join(gridlines)}"
        f'<polygon points="{area}" fill="{colour}" fill-opacity="0.10"/>'
        f'<polyline points="{line}" fill="none" stroke="{colour}" '
        f'stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>'
        f"{dots}{''.join(labels)}</svg>"
    )


def badge(label: str, message: str, colour: str) -> dict:
    return {
        "schemaVersion": 1,
        "label": label,
        "message": message,
        "color": colour,
    }


def render(runs: list[dict], site: Path) -> None:
    latest = runs[-1]
    recent = runs[-MAX_POINTS:]
    perf = site / "perf"
    perf.mkdir(parents=True, exist_ok=True)

    sections = []
    for chart in CHARTS:
        key = chart["key"]
        points = []
        for run in recent:
            value, _ = metric(run, key)
            if value is not None:
                points.append((run.get("generated", ""), value))

        value, note = metric(latest, key)
        if value is None:
            headline = (
                f'<p class="skip">Not measured in the latest run: '
                f"{html.escape(note)}</p>"
            )
            badge_msg, badge_colour = "n/a", "lightgrey"
        else:
            headline = (
                f'<p class="latest">{fmt(value)} '
                f'<span class="unit">{chart["unit"]}</span></p>'
            )
            badge_msg = f"{fmt(value)} {chart['unit']}".replace("&mdash;", "-")
            badge_colour = chart["colour"].lstrip("#")

        rows = []
        for run in reversed(recent[-12:]):
            v, n = metric(run, key)
            sha = (run.get("meta", {}).get("sha") or "")[:7]
            run_id = run.get("meta", {}).get("run_id") or ""
            rows.append(
                f"<tr><td>{html.escape(run.get('generated', '')[:19])}</td>"
                f"<td><code>{html.escape(sha) or '&mdash;'}</code></td>"
                f'<td class="num">{fmt(v)}</td>'
                f"<td>{html.escape(n)}</td>"
                f"<td><code>{html.escape(run_id)}</code></td></tr>"
            )

        sections.append(
            f'<h2 id="{html.escape(chart["badge"])}">'
            f"{html.escape(chart['title'])}</h2>"
            f'<p class="blurb">{chart["blurb"]}</p>'
            f"{headline}"
            f"{sparkline(points, chart['colour'])}"
            f"<table><thead><tr><th>when (UTC)</th><th>commit</th>"
            f'<th class="num">{html.escape(chart["unit"])}</th>'
            f"<th>note</th><th>run</th></tr></thead>"
            f"<tbody>{''.join(rows)}</tbody></table>"
        )

        (perf / f"badge-{chart['badge']}.json").write_text(
            json.dumps(badge(chart["badge"], badge_msg, badge_colour), indent=2) + "\n"
        )

    # The ratio section.
    ratio_points = []
    for run in recent:
        num, _ = metric(run, RATIO["numerator"])
        den, _ = metric(run, RATIO["denominator"])
        if num is not None and den:
            ratio_points.append((run.get("generated", ""), num / den))

    # The headline is the LATEST run's ratio or nothing at all -- never the
    # last run that happened to have both numbers. Falling back to an older
    # point would print a stale figure in the same styling every other section
    # uses for the current one, which is worse than printing none: the page
    # would look like it measured something it did not.
    latest_num, latest_num_note = metric(latest, RATIO["numerator"])
    latest_den, latest_den_note = metric(latest, RATIO["denominator"])
    if latest_num is not None and latest_den:
        ratio_headline = (
            f'<p class="latest">{fmt(latest_num / latest_den)}'
            f'<span class="unit">&times;</span></p>'
        )
    else:
        why = latest_num_note if latest_num is None else latest_den_note
        ratio_headline = (
            f'<p class="skip">Not measured in the latest run: '
            f"{html.escape(why or 'one of the two inputs is missing')}.</p>"
        )

    sections.append(
        f'<h2 id="ratio">{html.escape(RATIO["title"])}</h2>'
        f'<p class="blurb">The hipFile number divided by the libaio number '
        f"from the same boot. Both move whenever the runner does; this does "
        f"not, so it is the series to watch for a real change in the GPU I/O "
        f"path.</p>" + ratio_headline + sparkline(ratio_points, "#4285F4")
    )

    # One overall badge, so the README can carry a single "does the combined
    # stack come up at all" shield next to the per-metric ones.
    measured = sum(1 for c in CHARTS if metric(latest, c["key"])[0] is not None)
    (perf / "badge-integration.json").write_text(
        json.dumps(
            badge(
                "integration",
                f"{measured}/{len(CHARTS)} metrics",
                "brightgreen"
                if measured == len(CHARTS)
                else "yellow"
                if measured
                else "red",
            ),
            indent=2,
        )
        + "\n"
    )

    meta = latest.get("meta", {})
    images = meta.get("images", {})
    image_rows = "".join(
        f"<tr><td>{html.escape(k.replace('_image', ''))}</td>"
        f"<td><code>{html.escape(v)}</code></td></tr>"
        for k, v in sorted(images.items())
        if v
    )

    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>batesste-ci-images &mdash; integration performance</title>
<style>{CSS}</style>
</head>
<body>
<h1>Integration performance</h1>
<p class="sub">Two guests in sequence: one on a rocjitsu emulated gfx1250 with
an emulated NVMe controller, one on a rocm-ernic RDMA NIC serving its own S3
store &mdash; both devices over vfio-user, and the combination no single image
can test on its own. {len(runs)} run(s) recorded; generated
{html.escape(generated)}.</p>

<p class="blurb"><strong>Read these as trends, not as hardware numbers.</strong>
Every device here is emulated and the GPU is an instruction-level model, so the
absolute figures say nothing about silicon. What they are good for is noticing
the day one of them moves.</p>

{"".join(sections)}

<h2 id="images">Images in the latest run</h2>
<table><thead><tr><th>component</th><th>tag</th></tr></thead>
<tbody>{image_rows or '<tr><td colspan="2">not recorded</td></tr>'}</tbody></table>

<footer>
<p>Generated by <code>scripts/publish-perf.py</code> from
<code>perf/history.jsonl</code>. Raw history:
<a href="perf/history.jsonl">history.jsonl</a>.</p>
<p><a href="https://github.com/sbates130272/batesste-ci-images">sbates130272/batesste-ci-images</a></p>
</footer>
</body>
</html>
"""
    (site / "index.html").write_text(page)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--summary",
        type=Path,
        help="summary.json from perf-harness.sh; omit to "
        "re-render the site from the existing history",
    )
    ap.add_argument(
        "--site", type=Path, required=True, help="gh-pages checkout to write into"
    )
    args = ap.parse_args()

    history = args.site / "perf" / "history.jsonl"
    history.parent.mkdir(parents=True, exist_ok=True)

    if args.summary:
        try:
            summary = json.loads(args.summary.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            print(f"error: cannot read {args.summary}: {exc}", file=sys.stderr)
            return 1
        summary.setdefault("generated", datetime.now(timezone.utc).isoformat())
        # A leading newline when the file does not already end in one. The
        # docstring on load_history names the case that produces a truncated
        # final line; appending blindly would concatenate this run onto it and
        # lose BOTH -- the truncated one and the one just measured -- while
        # still printing "appended" and exiting 0.
        needs_newline = False
        if history.exists() and history.stat().st_size:
            with history.open("rb") as fh:
                fh.seek(-1, os.SEEK_END)
                needs_newline = fh.read(1) != b"\n"
        with history.open("a") as fh:
            fh.write(
                ("\n" if needs_newline else "")
                + json.dumps(summary, sort_keys=True)
                + "\n"
            )
        print(f"appended a run to {history}")

    runs = load_history(history)
    if not runs:
        print("error: no history to render and no summary given", file=sys.stderr)
        return 1

    render(runs, args.site)
    print(f"rendered {args.site / 'index.html'} from {len(runs)} run(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
