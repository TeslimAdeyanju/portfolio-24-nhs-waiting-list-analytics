"""
NHS Waiting List Analytics - Data Download Script
==================================================
Downloads Referral to Treatment (RTT) waiting time data from NHS England.

Data source:
    NHS England Statistics - RTT Waiting Times
    https://www.england.nhs.uk/statistics/statistical-work-areas/rtt-waiting-times/

Financial year pages use the format: rtt-data-2024-25
File naming pattern: Incomplete-Provider-Mar25-XLSX-9M-revised.xlsx

We download Provider-level files only (not Commissioner):
    - Incomplete-Provider    → waiting list snapshot
    - Admitted-Provider      → treated (admitted pathway)
    - NonAdmitted-Provider   → treated (non-admitted pathway)
    - New-Periods-Provider   → new referrals (clock starts)

Usage:
    python data_download.py                          # 2019-20 → 2024-25
    python data_download.py --start-year 2022        # 2022-23 only if --end-year not given
    python data_download.py --start-year 2019 --end-year 2025

Author: Teslim Uthman Adeyanju
Date:   April 2026
"""

import time
import logging
import argparse
from pathlib import Path

import requests
from bs4 import BeautifulSoup

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

RAW_DATA_DIR = Path(__file__).parent.parent / "data" / "raw"
RAW_DATA_DIR.mkdir(parents=True, exist_ok=True)

# Real URL pattern confirmed from NHS England website
FY_PAGE_URL = (
    "https://www.england.nhs.uk/statistics/statistical-work-areas/"
    "rtt-waiting-times/rtt-data-{fy}/"
)

# Provider-level file type keywords (matched against href, case-insensitive)
# Order matters: "NonAdmitted" must come before "Admitted" to avoid false matches
PROVIDER_FILE_TYPES = [
    "Incomplete-Provider",
    "NonAdmitted-Provider",
    "Admitted-Provider",
    "New-Periods-Provider",
]

HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (compatible; NHSDataAnalytics/1.0; "
        "portfolio research; +https://github.com/teslimadeyanju)"
    )
}

REQUEST_DELAY_SECONDS = 1.5

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def fy_slug(start_year: int) -> str:
    """
    Convert a start year to the NHS England FY slug used in URLs.
    e.g. 2024 → '2024-25'
    """
    return f"{start_year}-{str(start_year + 1)[-2:]}"


def fetch_page(url: str) -> BeautifulSoup | None:
    try:
        r = requests.get(url, headers=HEADERS, timeout=30)
        r.raise_for_status()
        return BeautifulSoup(r.text, "html.parser")
    except requests.RequestException as exc:
        log.warning("Could not fetch %s: %s", url, exc)
        return None


def extract_provider_links(soup: BeautifulSoup) -> list[tuple[str, str]]:
    """
    Extract all Provider-level xls/xlsx download links from a FY page.
    2019-22 uses .xls; 2022-23 onwards uses .xlsx.
    Returns list of (filename, full_url, file_type).
    """
    found = []
    for a in soup.find_all("a", href=True):
        href: str = a["href"]
        if not (href.lower().endswith(".xlsx") or href.lower().endswith(".xls")):
            continue
        href_lower = href.lower()
        for file_type in PROVIDER_FILE_TYPES:
            if file_type.lower() in href_lower:
                filename = href.split("/")[-1]
                full_url = href if href.startswith("http") else (
                    "https://www.england.nhs.uk" + href
                )
                found.append((filename, full_url, file_type))
                break   # don't double-count
    return found


def download_file(url: str, dest: Path) -> str:
    """Download a file. Returns 'ok', 'skipped', or 'failed'."""
    if dest.exists():
        return "skipped"
    try:
        r = requests.get(url, headers=HEADERS, timeout=300, stream=True)
        r.raise_for_status()
        with open(dest, "wb") as fh:
            for chunk in r.iter_content(chunk_size=65536):
                fh.write(chunk)
        size_kb = dest.stat().st_size / 1024
        log.info("    [ok] %-60s  %.0f KB", dest.name, size_kb)
        return "ok"
    except requests.RequestException as exc:
        log.error("    [fail] %s — %s", dest.name, exc)
        if dest.exists():
            dest.unlink()
        return "failed"


# ---------------------------------------------------------------------------
# Core download logic
# ---------------------------------------------------------------------------

def download_financial_year(fy_start: int) -> dict[str, int]:
    slug = fy_slug(fy_start)
    url  = FY_PAGE_URL.format(fy=slug)
    log.info("=" * 70)
    log.info("Financial year: %s   %s", slug, url)

    soup = fetch_page(url)
    if soup is None:
        log.warning("  Page unavailable — skipping FY %s", slug)
        return {"ok": 0, "skipped": 0, "failed": 0}

    links = extract_provider_links(soup)
    if not links:
        log.warning("  No Provider xlsx links found on page for FY %s", slug)
        return {"ok": 0, "skipped": 0, "failed": 0}

    fy_dir = RAW_DATA_DIR / slug
    fy_dir.mkdir(exist_ok=True)

    counts = {"ok": 0, "skipped": 0, "failed": 0}
    by_type: dict[str, int] = {}

    for filename, full_url, file_type in links:
        dest   = fy_dir / filename
        result = download_file(full_url, dest)
        counts[result] += 1
        by_type[file_type] = by_type.get(file_type, 0) + 1

        if result == "ok":
            time.sleep(REQUEST_DELAY_SECONDS)

    log.info(
        "  FY %s done — %d downloaded, %d skipped, %d failed",
        slug, counts["ok"], counts["skipped"], counts["failed"]
    )
    log.info("  File types found: %s", by_type)
    return counts


def download_all(start_year: int, end_year: int) -> None:
    """Download all FY data from start_year up to (not including) end_year+1."""
    totals = {"ok": 0, "skipped": 0, "failed": 0}

    for fy_start in range(start_year, end_year + 1):
        c = download_financial_year(fy_start)
        for k in totals:
            totals[k] += c[k]

    log.info("=" * 70)
    log.info(
        "All done — Downloaded: %d | Skipped: %d | Failed: %d",
        totals["ok"], totals["skipped"], totals["failed"]
    )
    log.info("Files saved to: %s", RAW_DATA_DIR.resolve())


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args():
    parser = argparse.ArgumentParser(
        description="Download NHS England RTT Provider-level xlsx files."
    )
    parser.add_argument(
        "--start-year", type=int, default=2019,
        help="First FY start year (e.g. 2019 = FY 2019/20). Default: 2019"
    )
    parser.add_argument(
        "--end-year", type=int, default=2024,
        help="Last FY start year (inclusive). Default: 2024 (= FY 2024/25)"
    )
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    download_all(args.start_year, args.end_year)
