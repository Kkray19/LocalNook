#!/usr/bin/env python3
"""Exercise install.sh's failure paths in a disposable directory.

Every scenario installs into a temporary directory that this script created
and will delete. The real installation in /Applications is never a target,
never stopped, and never read: a recovery test that destroys the thing it is
meant to protect has proved nothing worth having.
"""
import hashlib
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile

SCRIPT = pathlib.Path(__file__).resolve().parent / "install.sh"
APP = "LocalNook.app"

passed = failed = 0


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ✓ {name}")
    else:
        failed += 1
        print(f"  ✗ {name}" + (f"  — {detail}" if detail else ""))


def sha(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def make_bundle(root, marker, *, runnable=True, self_test_ok=True):
    """A minimal bundle shaped like the real one, with a distinguishable binary."""
    app = pathlib.Path(root) / APP
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/Resources").mkdir(parents=True)
    (app / "Contents/Info.plist").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0"><dict>'
        "<key>CFBundleExecutable</key><string>LocalNook</string>"
        "<key>CFBundleIdentifier</key><string>com.localnook.test</string>"
        "</dict></plist>\n"
    )
    exe = app / "Contents/MacOS/LocalNook"
    body = ["#!/bin/bash", f"# marker: {marker}"]
    if not runnable:
        body.append("exit 3")
    else:
        body.append('if [[ "$*" == *--self-test* ]]; then')
        body.append("  exit 0" if self_test_ok else "  exit 1")
        body.append("fi")
        body.append('if [[ "$*" == *--version* ]]; then echo "' + marker + '"; exit 0; fi')
        body.append("exit 0")
    exe.write_text("\n".join(body) + "\n")
    exe.chmod(0o755)
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)],
                   check=True, capture_output=True)
    return app


def fake_tools(root, *, codesign_fails_on=None, cp_fails=False):
    """Shims placed ahead of the real tools on PATH."""
    binroot = pathlib.Path(root) / "bin"
    binroot.mkdir(exist_ok=True)
    real_codesign = shutil.which("codesign")
    if codesign_fails_on:
        script = (
            "#!/bin/bash\n"
            f'if [[ "$*" == *"{codesign_fails_on}"* && "$*" == *--verify* ]]; then exit 1; fi\n'
            f'exec {real_codesign} "$@"\n'
        )
    else:
        script = f'#!/bin/bash\nexec {real_codesign} "$@"\n'
    p = binroot / "codesign"
    p.write_text(script)
    p.chmod(0o755)
    if cp_fails:
        p = binroot / "cp"
        p.write_text("#!/bin/bash\nexit 1\n")
        p.chmod(0o755)
    return binroot


def run(source, target, extra_path=None, args=()):
    env = dict(os.environ)
    if extra_path:
        env["PATH"] = f"{extra_path}:{env['PATH']}"
    return subprocess.run(
        ["/bin/bash", str(SCRIPT), "--source", str(source), "--target", str(target),
         "--no-launch", *args],
        env=env, capture_output=True, text=True, errors="replace", timeout=120,
    )


def scenario(title):
    print(f"\n{title}")


# ── 1. A clean first install ─────────────────────────────────────────────────
with tempfile.TemporaryDirectory(prefix="localnook-install-") as tmp:
    scenario("First install into an empty directory")
    src = make_bundle(pathlib.Path(tmp) / "src", "NEW")
    target = pathlib.Path(tmp) / "Applications"
    target.mkdir()
    r = run(src, target)
    check("succeeds", r.returncode == 0, r.stdout + r.stderr)
    check("the app lands at the target", (target / APP).is_dir())
    check("the installed binary matches the candidate",
          (target / APP).is_dir()
          and sha(target / APP / "Contents/MacOS/LocalNook")
          == sha(src / "Contents/MacOS/LocalNook"))
    leftovers = [p.name for p in target.iterdir() if p.name.startswith(".LocalNook")]
    check("no staging or backup directories are left behind", not leftovers, str(leftovers))

# ── 2. Replacing an existing install ─────────────────────────────────────────
with tempfile.TemporaryDirectory(prefix="localnook-install-") as tmp:
    scenario("Replacing a working installation")
    target = pathlib.Path(tmp) / "Applications"
    target.mkdir()
    old = make_bundle(pathlib.Path(tmp) / "old", "OLD")
    shutil.copytree(old, target / APP)
    src = make_bundle(pathlib.Path(tmp) / "src", "NEW")
    r = run(src, target)
    check("succeeds", r.returncode == 0, r.stdout + r.stderr)
    installed = subprocess.run(
        [str(target / APP / "Contents/MacOS/LocalNook"), "--version"],
        capture_output=True, text=True, errors="replace").stdout.strip()
    check("the new version replaced the old one", installed == "NEW", installed)
    leftovers = [p.name for p in target.iterdir() if p.name.startswith(".LocalNook")]
    check("the backup is removed once the replacement is verified",
          not leftovers, str(leftovers))

# ── 3. An invalid candidate must not touch the installation ──────────────────
for label, kwargs in (
    ("a candidate that will not run", {"runnable": False}),
    ("a candidate that fails its own self-test", {"self_test_ok": False}),
):
    with tempfile.TemporaryDirectory(prefix="localnook-install-") as tmp:
        scenario(f"Refusing {label}")
        target = pathlib.Path(tmp) / "Applications"
        target.mkdir()
        old = make_bundle(pathlib.Path(tmp) / "old", "OLD")
        shutil.copytree(old, target / APP)
        before = sha(target / APP / "Contents/MacOS/LocalNook")
        src = make_bundle(pathlib.Path(tmp) / "src", "BAD", **kwargs)
        r = run(src, target)
        check("the install fails", r.returncode != 0)
        check("it stops before touching the target",
              sha(target / APP / "Contents/MacOS/LocalNook") == before)
        installed = subprocess.run(
            [str(target / APP / "Contents/MacOS/LocalNook"), "--version"],
            capture_output=True, text=True, errors="replace").stdout.strip()
        check("the working installation still runs", installed == "OLD", installed)

# ── 4. A missing candidate ───────────────────────────────────────────────────
with tempfile.TemporaryDirectory(prefix="localnook-install-") as tmp:
    scenario("Refusing a candidate that does not exist")
    target = pathlib.Path(tmp) / "Applications"
    target.mkdir()
    old = make_bundle(pathlib.Path(tmp) / "old", "OLD")
    shutil.copytree(old, target / APP)
    r = run(pathlib.Path(tmp) / "nope" / APP, target)
    check("the install fails", r.returncode != 0)
    check("the existing installation survives", (target / APP).is_dir())

# ── 5. Staging fails after validation ────────────────────────────────────────
with tempfile.TemporaryDirectory(prefix="localnook-install-") as tmp:
    scenario("Recovering when staging fails")
    target = pathlib.Path(tmp) / "Applications"
    target.mkdir()
    old = make_bundle(pathlib.Path(tmp) / "old", "OLD")
    shutil.copytree(old, target / APP)
    src = make_bundle(pathlib.Path(tmp) / "src", "NEW")
    binroot = fake_tools(tmp, cp_fails=True)
    r = run(src, target, extra_path=binroot)
    check("the install fails", r.returncode != 0)
    check("the working installation is still in place", (target / APP).is_dir())
    installed = subprocess.run(
        [str(target / APP / "Contents/MacOS/LocalNook"), "--version"],
        capture_output=True, text=True, errors="replace").stdout.strip()
    check("and still runs the old version", installed == "OLD", installed)
    leftovers = [p.name for p in target.iterdir() if p.name.startswith(".LocalNook")]
    check("no staging directory is left behind", not leftovers, str(leftovers))

# ── 6. Verification of the installed copy fails → roll back ──────────────────
with tempfile.TemporaryDirectory(prefix="localnook-install-") as tmp:
    scenario("Rolling back when the installed copy fails verification")
    target = pathlib.Path(tmp) / "Applications"
    target.mkdir()
    old = make_bundle(pathlib.Path(tmp) / "old", "OLD")
    shutil.copytree(old, target / APP)
    src = make_bundle(pathlib.Path(tmp) / "src", "NEW")
    # codesign --verify passes for the candidate and the staged copy, and fails
    # for the bundle once it sits at the final path: the late failure that the
    # rollback exists for.
    binroot = fake_tools(tmp, codesign_fails_on=str(target / APP))
    r = run(src, target, extra_path=binroot)
    check("the install fails", r.returncode != 0)
    check("the previous installation is restored", (target / APP).is_dir())
    installed = subprocess.run(
        [str(target / APP / "Contents/MacOS/LocalNook"), "--version"],
        capture_output=True, text=True, errors="replace").stdout.strip()
    check("the restored copy is the old version, not the broken new one",
          installed == "OLD", installed)
    check("it says it restored", "Restoring" in (r.stdout + r.stderr))
    leftovers = [p.name for p in target.iterdir() if p.name.startswith(".LocalNook")]
    check("no staging or backup directories survive the rollback",
          not leftovers, str(leftovers))

# ── 7. An unwritable target ──────────────────────────────────────────────────
with tempfile.TemporaryDirectory(prefix="localnook-install-") as tmp:
    scenario("Refusing an unwritable install directory")
    target = pathlib.Path(tmp) / "Applications"
    target.mkdir()
    old = make_bundle(pathlib.Path(tmp) / "old", "OLD")
    shutil.copytree(old, target / APP)
    src = make_bundle(pathlib.Path(tmp) / "src", "NEW")
    target.chmod(stat.S_IRUSR | stat.S_IXUSR)
    try:
        r = run(src, target)
        check("the install fails", r.returncode != 0)
        check("it says the directory is not writable",
              "cannot write" in (r.stdout + r.stderr))
    finally:
        target.chmod(0o755)
    check("the existing installation survives", (target / APP).is_dir())

# ── 8. It stops only the process running from the target ─────────────────────
with tempfile.TemporaryDirectory(prefix="localnook-install-") as tmp:
    scenario("Stopping only the process running from the target")
    target = pathlib.Path(tmp) / "Applications"
    target.mkdir()
    other_dir = pathlib.Path(tmp) / "elsewhere"
    other_dir.mkdir()
    # A long-lived process with the same executable name, from another path.
    bystander_app = make_bundle(other_dir, "BYSTANDER")
    bystander_exe = bystander_app / "Contents/MacOS/LocalNook"
    bystander_exe.write_text("#!/bin/bash\nsleep 120\n")
    bystander_exe.chmod(0o755)
    bystander = subprocess.Popen([str(bystander_exe)],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        old = make_bundle(pathlib.Path(tmp) / "old", "OLD")
        shutil.copytree(old, target / APP)
        src = make_bundle(pathlib.Path(tmp) / "src", "NEW")
        r = run(src, target)
        check("the install succeeds", r.returncode == 0, r.stdout + r.stderr)
        check("a same-named process from another path is left running",
              bystander.poll() is None)
    finally:
        bystander.terminate()
        try:
            bystander.wait(timeout=10)
        except subprocess.TimeoutExpired:
            bystander.kill()

# ── 9. It actually stops a process running from the target ───────────────────
# This path was untested until it was about to run against a live installation:
# every earlier scenario had an empty target or a bystander elsewhere, so the
# stop branch was skipped and reported nothing.
with tempfile.TemporaryDirectory(prefix="localnook-install-") as tmp:
    scenario("Stopping the process that is running from the target")
    target = pathlib.Path(tmp) / "Applications"
    target.mkdir()
    old = make_bundle(pathlib.Path(tmp) / "old", "OLD")
    shutil.copytree(old, target / APP)
    installed_exe = target / APP / "Contents/MacOS/LocalNook"
    installed_exe.write_text("#!/bin/bash\nsleep 120\n")
    installed_exe.chmod(0o755)
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(target / APP)],
                   check=True, capture_output=True)
    victim = subprocess.Popen([str(installed_exe)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        src = make_bundle(pathlib.Path(tmp) / "src", "NEW")
        r = run(src, target)
        output = r.stdout + r.stderr
        check("the install succeeds", r.returncode == 0, output)
        check("it reports stopping the running process", "Stopping the running" in output)
        try:
            victim.wait(timeout=15)
            stopped = True
        except subprocess.TimeoutExpired:
            stopped = False
        check("the process running from the target is actually stopped", stopped)
        installed = subprocess.run(
            [str(installed_exe), "--version"],
            capture_output=True, text=True, errors="replace").stdout.strip()
        check("the new version replaced it", installed == "NEW", installed)
    finally:
        if victim.poll() is None:
            victim.kill()
            victim.wait(timeout=10)

# ── 10. A process that refuses to die ────────────────────────────────────────
# SIGTERM ignored: the script must escalate, and must not proceed if it still
# cannot stop it — replacing a bundle out from under a live process is how an
# installation ends up half-written.
with tempfile.TemporaryDirectory(prefix="localnook-install-") as tmp:
    scenario("Escalating past a process that ignores SIGTERM")
    target = pathlib.Path(tmp) / "Applications"
    target.mkdir()
    old = make_bundle(pathlib.Path(tmp) / "old", "OLD")
    shutil.copytree(old, target / APP)
    installed_exe = target / APP / "Contents/MacOS/LocalNook"
    installed_exe.write_text("#!/bin/bash\ntrap '' TERM\nsleep 120\n")
    installed_exe.chmod(0o755)
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(target / APP)],
                   check=True, capture_output=True)
    stubborn = subprocess.Popen([str(installed_exe)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        src = make_bundle(pathlib.Path(tmp) / "src", "NEW")
        r = run(src, target)
        check("the install still succeeds after escalating", r.returncode == 0,
              r.stdout + r.stderr)
        try:
            stubborn.wait(timeout=15)
            stopped = True
        except subprocess.TimeoutExpired:
            stopped = False
        check("the stubborn process is killed rather than worked around", stopped)
        installed = subprocess.run(
            [str(installed_exe), "--version"],
            capture_output=True, text=True, errors="replace").stdout.strip()
        check("the new version replaced it", installed == "NEW", installed)
    finally:
        if stubborn.poll() is None:
            stubborn.kill()
            stubborn.wait(timeout=10)

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
