#!/usr/bin/env python3
"""Exercise the real release script in disposable fake-toolchain repositories."""
import os, pathlib, shutil, subprocess, tempfile
source = pathlib.Path(__file__).resolve().parent / "build-release.sh"


def fake_app(deterministic_rc: int, integration_rc: int) -> str:
    """A stand-in for the built app, with the self-test exit codes we want.

    0 = clean, 1 = a demonstrated defect, 2 = nothing failed but something could
    not be exercised. The release script must treat those three differently.
    """
    return (
        "#!/bin/bash\n"
        'if [[ "$*" == *--self-test*--deterministic* || "$*" == *--deterministic* ]]; then\n'
        f'  echo "deterministic: 1 passed, 0 failed"; exit {deterministic_rc}\n'
        "fi\n"
        'if [[ "$*" == *--integration* ]]; then\n'
        f'  echo "integration:   1 passed, 0 failed"; exit {integration_rc}\n'
        "fi\n"
        'if [[ "$*" == *--version* ]]; then echo "LocalNook fixture"; exit 0; fi\n'
        "exit 0\n"
    )


FAKE_APP_BINARY = {
    # These three never reach the self-test; the build fails earlier.
    "compiler": fake_app(0, 0),
    "missing": fake_app(0, 0),
    "stale": fake_app(0, 0),
    # The deterministic half fails.
    "tests": fake_app(1, 0),
    # The deterministic half is clean and the integration half demonstrates a
    # defect. This must still block.
    "integration_defect": fake_app(0, 1),
    # The integration half could not exercise something. This must NOT block.
    "integration_unverified": fake_app(0, 2),
}
# Scenarios that must BLOCK a release, and — at the end — two that must not.
# "integration_defect" is the policy that matters: a demonstrated product defect
# blocks whichever half of the suite found it. "integration_unverified" is its
# counterpart: a scenario that could not be exercised is a limitation, not a
# defect, and must not redden the build.
BLOCKING = ("compiler", "missing", "stale", "tests", "integration_defect")
for scenario in BLOCKING:
    with tempfile.TemporaryDirectory(prefix="localnook-release-test-") as root:
        root = pathlib.Path(root)
        (root / "scripts").mkdir(); (root / "bin").mkdir(); (root / "dist").mkdir()
        shutil.copy(source, root / "scripts/build-release.sh")
        (root / "scripts/test-release.py").write_text("# Recursion disabled in fixture\n")
        (root / "scripts/test-install.py").write_text("# Recursion disabled in fixture\n")
        (root / "scripts/test-isolation.py").write_text("# Recursion disabled in fixture\n")
        (root / "scripts/make-icon.swift").write_text("")
        (root / "VERSION").write_text("0.1.0")
        (root / "LICENSE").write_text("test")
        (root / "MPL-2.0.txt").write_text("test")
        (root / "THIRD_PARTY_LICENSES.md").write_text("test")
        (root / "dist/LocalNook.app").mkdir(); (root / "dist/LocalNook.dmg").touch()
        (root / "fakebin").mkdir()
        binary = root / "fakebin/LocalNook"
        binary.write_text(FAKE_APP_BINARY[scenario]); binary.chmod(0o755)
        os.utime(binary, (1, 1))
        scripts = {
          "git": "echo deadbeef",
          "swift": f"""if [[ "$*" == *--show-bin-path* ]]; then echo '{root}/fakebin'; exit 0; fi
if [[ "$*" == 'package clean' ]]; then exit 0; fi
if [[ "$*" == build* ]]; then
  case '{scenario}' in
    compiler) exit 1;;
    missing) rm -f '{binary}';;
    tests|integration_defect) sleep 1; touch '{binary}';;
  esac
fi
exit 0""",
          "iconutil": "exit 0", "codesign": "exit 0", "plutil": "exit 0",
          "hdiutil": "echo PACKAGED >> packaged; exit 0"
        }
        for name, body in scripts.items():
            p = root / "bin" / name; p.write_text("#!/bin/bash\n" + body + "\n"); p.chmod(0o755)
        env = dict(os.environ, PATH=str(root / "bin") + ":" + os.environ["PATH"])
        result = subprocess.run(["/bin/bash", str(root / "scripts/build-release.sh")], env=env,
                                cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        assert result.returncode != 0, (scenario, result.stdout.decode())
        assert not (root / "dist/LocalNook.app").exists(), scenario
        assert not (root / "dist/LocalNook.dmg").exists(), scenario
        assert not (root / "packaged").exists(), scenario
        if scenario == "tests":
            assert b"DETERMINISTIC SUITE FAILED" in result.stdout, result.stdout.decode()
        if scenario == "integration_defect":
            assert b"INTEGRATION CHECK FAILED" in result.stdout, result.stdout.decode()
        print("PASS release gate blocks:", scenario)

# ── An unverified scenario is a limitation, not a blocker ────────────────────
# The complement of the above, and the reason the exit code has three states
# rather than two: without this the only safe policy is "gate on everything",
# which reddens the build whenever the window server declines to deliver an
# event, and teaches people to ignore the gate.
with tempfile.TemporaryDirectory(prefix="localnook-release-test-") as root:
    scenario = "integration_unverified"
    root = pathlib.Path(root)
    (root / "scripts").mkdir(); (root / "bin").mkdir(); (root / "dist").mkdir()
    shutil.copy(source, root / "scripts/build-release.sh")
    (root / "scripts/test-release.py").write_text("# Recursion disabled in fixture\n")
    (root / "scripts/test-install.py").write_text("# Recursion disabled in fixture\n")
    (root / "scripts/test-isolation.py").write_text("# Recursion disabled in fixture\n")
    (root / "scripts/make-icon.swift").write_text("")
    (root / "VERSION").write_text("0.1.0")
    for name in ("LICENSE", "MPL-2.0.txt", "THIRD_PARTY_LICENSES.md"):
        (root / name).write_text("test")
    (root / "fakebin").mkdir()
    binary = root / "fakebin/LocalNook"
    binary.write_text(FAKE_APP_BINARY[scenario]); binary.chmod(0o755)
    scripts = {
        "git": "echo deadbeef",
        "swift": f"""if [[ "$*" == *--show-bin-path* ]]; then echo '{root}/fakebin'; exit 0; fi
if [[ "$*" == 'package clean' ]]; then exit 0; fi
if [[ "$*" == build* ]]; then sleep 1; touch '{binary}'; fi
exit 0""",
        "iconutil": "exit 0", "codesign": "exit 0", "plutil": "exit 0",
        "hdiutil": "exit 0",
    }
    for name, body in scripts.items():
        p = root / "bin" / name
        p.write_text("#!/bin/bash\n" + body + "\n")
        p.chmod(0o755)
    env = dict(os.environ, PATH=str(root / "bin") + ":" + os.environ["PATH"])
    result = subprocess.run(
        ["/bin/bash", str(root / "scripts/build-release.sh"), "--no-dmg"], env=env,
        cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    out = result.stdout.decode()
    assert result.returncode == 0, out
    assert (root / "dist/LocalNook.app").exists(), "an unverified scenario must still package: " + out
    assert "unverified scenarios" in out, out
    assert "not fully verified" in out, out
    print("PASS release gate does not block:", scenario)

print(f"{len(BLOCKING)} blocking + 1 non-blocking release scenarios passed")
