#!/usr/bin/env python3
"""Prove the self-test never touches the user's real preferences or files.

The point is *never touched*, not *restored afterwards*. A restore is only as
good as the code path that performs it, and no code path runs on SIGKILL. So
this samples the production state while the suite is still running, and checks
three ways of ending a run:

    completion   the suite finishes on its own
    interruption SIGTERM part-way through
    forced       SIGKILL part-way through — nothing gets to clean up

Sentinels are written into the production domain and the production support
directory first, so a failure shows up as a changed value rather than as an
absence nobody notices. The sentinel keys are removed at the end; nothing else
in the domain is written at any point.
"""
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import signal
import subprocess
import sys
import time

DOMAIN = "com.localnook.app"
SUPPORT = pathlib.Path.home() / "Library/Application Support/LocalNook"
SENTINEL_KEY = "isolation.sentinel"
SENTINEL_FILE = SUPPORT / "isolation-sentinel.json"
SENTINEL_VALUE = f"do-not-touch-{os.getpid()}"

passed = failed = 0


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ✓ {name}")
    else:
        failed += 1
        print(f"  ✗ {name}" + (f"  — {detail}" if detail else ""))


def production_domain() -> dict:
    out = subprocess.run(["defaults", "export", DOMAIN, "-"],
                         capture_output=True).stdout
    try:
        return plistlib.loads(out)
    except Exception:
        return {}


def support_fingerprint() -> dict:
    """Name → sha256 for every file LocalNook keeps for the user."""
    prints = {}
    if not SUPPORT.is_dir():
        return prints
    for path in sorted(SUPPORT.rglob("*")):
        if path.is_file():
            prints[str(path.relative_to(SUPPORT))] = hashlib.sha256(
                path.read_bytes()).hexdigest()
    return prints


def write_sentinels():
    subprocess.run(["defaults", "write", DOMAIN, SENTINEL_KEY, "-string",
                    SENTINEL_VALUE], check=True)
    SUPPORT.mkdir(parents=True, exist_ok=True)
    SENTINEL_FILE.write_text(json.dumps({"sentinel": SENTINEL_VALUE}))


def remove_sentinels():
    subprocess.run(["defaults", "delete", DOMAIN, SENTINEL_KEY],
                   capture_output=True)
    SENTINEL_FILE.unlink(missing_ok=True)


def disposable_artifacts() -> list:
    """Temporary directories the suite creates for itself."""
    tmp = pathlib.Path(os.environ.get("TMPDIR", "/tmp"))
    return sorted(tmp.glob("LocalNook-tests-*"))


def disposable_domains() -> list:
    root = pathlib.Path.home() / "Library/Preferences"
    return sorted(root.glob("com.localnook.tests.*.plist"))


def run_scenario(binary, label, terminate_after=None, signal_to_send=None):
    print(f"\n{label}")

    before_domain = production_domain()
    before_files = support_fingerprint()
    check("the sentinel is in place before the run",
          before_domain.get(SENTINEL_KEY) == SENTINEL_VALUE)

    process = subprocess.Popen(
        [binary, "--self-test", "--deterministic"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )

    # Sample while it is still running. This is the part a restore-based scheme
    # cannot satisfy: during the run, the production domain must already be
    # untouched, not merely destined to be put back.
    samples = []
    deadline = time.time() + (terminate_after or 25)
    while time.time() < deadline and process.poll() is None:
        time.sleep(1.0)
        samples.append((production_domain(), support_fingerprint()))
        if terminate_after and len(samples) >= 3:
            break

    check("the run was still going while sampled",
          len(samples) > 0 and (process.poll() is None or terminate_after is None),
          "the process exited before it could be sampled")

    drifted = [i for i, (dom, files) in enumerate(samples)
               if dom != before_domain or files != before_files]
    check(f"production state is unchanged during the run ({len(samples)} samples)",
          not drifted, f"changed at sample(s) {drifted}")

    if signal_to_send is not None:
        process.send_signal(signal_to_send)
    try:
        process.wait(timeout=90)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=20)

    after_domain = production_domain()
    after_files = support_fingerprint()
    check("the production preferences are unchanged after the run",
          after_domain == before_domain,
          "keys differing: " + ", ".join(sorted(
              set(after_domain) ^ set(before_domain)
              or {k for k in before_domain if before_domain[k] != after_domain.get(k)})))
    check("the production files are unchanged after the run",
          after_files == before_files,
          f"before {len(before_files)} files, after {len(after_files)}")
    check("the sentinel key still holds its value",
          after_domain.get(SENTINEL_KEY) == SENTINEL_VALUE,
          f"got {after_domain.get(SENTINEL_KEY)!r}")
    check("the sentinel file still holds its value",
          SENTINEL_FILE.is_file()
          and json.loads(SENTINEL_FILE.read_text()).get("sentinel") == SENTINEL_VALUE)


def main():
    binary = sys.argv[1] if len(sys.argv) > 1 else None
    if not binary:
        for candidate in ["dist/LocalNook.app/Contents/MacOS/LocalNook",
                          "/Applications/LocalNook.app/Contents/MacOS/LocalNook"]:
            if pathlib.Path(candidate).is_file():
                binary = candidate
                break
    if not binary or not pathlib.Path(binary).is_file():
        print("no LocalNook binary found; pass one as an argument", file=sys.stderr)
        return 2

    # A bundled binary, so it resolves the real bundle identifier. An unbundled
    # one uses a different preferences domain entirely and would prove nothing.
    if ".app/Contents/MacOS" not in binary:
        print("the binary must be inside a .app bundle, or the production "
              "domain under test is not the one it would use", file=sys.stderr)
        return 2

    print(f"binary: {binary}")
    print(f"domain: {DOMAIN}")
    print(f"files:  {SUPPORT}")

    stale = disposable_artifacts()
    write_sentinels()
    try:
        run_scenario(binary, "Completion — the suite runs to the end")
        run_scenario(binary, "Interruption — SIGTERM part-way through",
                     terminate_after=6, signal_to_send=signal.SIGTERM)
        run_scenario(binary, "Forced termination — SIGKILL, nothing cleans up",
                     terminate_after=6, signal_to_send=signal.SIGKILL)

        print("\nDisposable resources")
        created = [p for p in disposable_artifacts() if p not in stale]
        check("the suite used its own disposable directories",
              len(created) > 0 or len(disposable_artifacts()) > 0,
              "no LocalNook-tests-* directory was created")
        check("no disposable preferences domain leaks into the real one",
              SENTINEL_KEY in production_domain()
              and not any(k.startswith("com.localnook.tests")
                          for k in production_domain()))
        # Killed runs cannot clean up after themselves; that is the price of
        # never writing to production, and these are temporary directories the
        # system reclaims. Removing them here keeps the machine tidy.
        for path in created:
            shutil.rmtree(path, ignore_errors=True)
        for path in disposable_domains():
            path.unlink(missing_ok=True)
        print(f"  · cleaned up {len(created)} disposable director"
              f"{'y' if len(created) == 1 else 'ies'}")
    finally:
        remove_sentinels()

    print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
