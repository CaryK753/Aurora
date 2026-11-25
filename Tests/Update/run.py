"""在临时目录验证签名检查、实际拉起新包、退出前等待和回滚。"""
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]


def wait_for(check, seconds=15):
    deadline = time.monotonic() + seconds
    while not check():
        if time.monotonic() >= deadline:
            raise AssertionError("timed out waiting for fixture")
        time.sleep(0.05)


def bundle(path, executable, identifier, version):
    binary = path / "Contents/MacOS/Aurora"
    binary.parent.mkdir(parents=True)
    shutil.copy2(executable, binary)
    info = dict(CFBundleIdentifier=identifier, CFBundleExecutable="Aurora",
                CFBundleName="Aurora Update Fixture", CFBundlePackageType="APPL",
                CFBundleVersion="1", CFBundleShortVersionString=version, LSUIElement=True)
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "-s", "-", str(path)], check=True)


def check_install(root, binary, version, corrupt=False):
    root.mkdir()
    identifier = "com.example.auroratest." + uuid.uuid4().hex
    app = root / "Installed Fixture.app"
    stage = root / "Updates" / version
    src = stage / "unpacked/Aurora.app"
    bundle(app, binary, identifier, "1.0")
    bundle(src, binary, identifier, version)
    if corrupt:
        (src / "Contents/Info.plist").write_bytes(b"broken")
    script = subprocess.check_output([binary, "--script", identifier], text=True)
    with subprocess.Popen(["sleep", "60"]) as old:
        try:
            helper = subprocess.Popen(["/bin/sh", "-c", script, "updater", app, src, str(old.pid),
                                       "not set", str(uuid.uuid4()).upper(), stage])
            time.sleep(0.4)
            assert helper.poll() is None
            assert not list(root.glob(".aurora-update-*"))
        finally:
            old.terminate()
    try:
        success = version in ("2.0", "2.1") and not corrupt
        result = helper.wait(timeout=35)
        assert (result == 0) == success, (result, (stage.parent / "install.log").read_text())
        installed = version if success else "1.0"
        wait_for(lambda: (root / ("started-" + installed)).is_file())
        pid = int((root / ("started-" + installed)).read_text())
        os.kill(pid, 0)
        assert plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"] == installed
        assert stage.exists() != success
        assert not list(root.glob(".aurora-update-*"))
        print("PASS", root.name, "running version", installed, flush=True)
    finally:
        (root / "stop").touch()
        if helper.poll() is None:
            helper.terminate()
            helper.wait()
        for receipt in root.glob("started-*"):
            pid = receipt.read_text()
            wait_for(lambda: subprocess.run(["ps", "-p", pid], stdout=subprocess.DEVNULL).returncode != 0)


with tempfile.TemporaryDirectory(prefix="aurora-update-test-") as temporary:
    root = pathlib.Path(temporary).resolve()
    binary = root / "fixture"
    subprocess.run(["swiftc", str(ROOT / "Sources/Aurora/Core/UpdateInstaller.swift"),
                    str(ROOT / "Sources/Aurora/ApplicationTermination.swift"),
                    str(ROOT / "Tests/Update/main.swift"), "-o", binary], check=True)
    check_install(root / "successful update", binary, "2.0")
    check_install(root / "launch retry", binary, "2.1")
    check_install(root / "rejected signature", binary, "2.0", corrupt=True)
    check_install(root / "failed startup", binary, "3.0")
    for mode in ["--quit-panel", "--quit-retry", "--quit-system"]:
        folder = root / mode
        app = folder / "Quit Fixture.app"
        bundle(app, binary, "com.example.quit." + uuid.uuid4().hex, "1.0")
        subprocess.run([app / "Contents/MacOS/Aurora", mode], check=True, timeout=10)
        assert (folder / "responsive").exists() and (folder / "approved").exists()
        assert (folder / "restored").exists() == (mode == "--quit-retry")
        print("PASS", mode, "main thread responsive and process exited")
