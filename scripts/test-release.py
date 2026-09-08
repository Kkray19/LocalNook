#!/usr/bin/env python3
"""Exercise the real release script in disposable fake-toolchain repositories."""
import os, pathlib, shutil, subprocess, tempfile
source = pathlib.Path(__file__).resolve().parent / "build-release.sh"
for scenario in ("compiler", "missing", "stale", "tests"):
    with tempfile.TemporaryDirectory(prefix="localnook-release-test-") as root:
        root = pathlib.Path(root)
        (root / "scripts").mkdir(); (root / "bin").mkdir(); (root / "dist").mkdir()
        shutil.copy(source, root / "scripts/build-release.sh")
        (root / "scripts/test-release.py").write_text("# Recursion disabled in fixture\n")
        (root / "scripts/test-install.py").write_text("# Recursion disabled in fixture\n")
        (root / "scripts/make-icon.swift").write_text("")
        (root / "VERSION").write_text("0.1.0")
        (root / "LICENSE").write_text("test")
        (root / "MPL-2.0.txt").write_text("test")
        (root / "THIRD_PARTY_LICENSES.md").write_text("test")
        (root / "dist/LocalNook.app").mkdir(); (root / "dist/LocalNook.dmg").touch()
        (root / "fakebin").mkdir()
        binary = root / "fakebin/LocalNook"
        binary.write_text("#!/bin/bash\nexit 1\n"); binary.chmod(0o755)
        os.utime(binary, (1, 1))
        scripts = {
          "git": "echo deadbeef",
          "swift": f"""if [[ "$*" == *--show-bin-path* ]]; then echo '{root}/fakebin'; exit 0; fi
if [[ "$*" == 'package clean' ]]; then exit 0; fi
if [[ "$*" == build* ]]; then
  case '{scenario}' in
    compiler) exit 1;;
    missing) rm -f '{binary}';;
    tests) sleep 1; touch '{binary}';;
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
        if scenario == "tests": assert b"DETERMINISTIC SUITE FAILED" in result.stdout, result.stdout.decode()
        print("PASS release gate:", scenario)
print("4 release regression scenarios passed")
