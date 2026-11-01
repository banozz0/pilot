#!/usr/bin/env python3
"""System widget's feed (ADR 0016): reads this Mac, changes nothing, prints one {"type": "data", ...} line. What never
changes before a restart (model, chip, GPU, shell) is read once by system_profiler and kept in TMPDIR, keyed by the boot
time; each run then reads only CPU, memory, disk, battery and uptime, well inside Pilot's 5 s."""
import json
import os
import platform
import pwd
import re
import subprocess
import sys
import time

CACHE = os.path.join(os.environ.get("TMPDIR") or "/tmp", "pilot-desk-system")


def run(*argv, wait=3):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=wait).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def sysctl(name):
    return run("/usr/sbin/sysctl", "-n", name).strip()


def boot():
    m = re.search(r"sec = (\d+)", sysctl("kern.boottime"))
    return int(m.group(1)) if m else 0


def static(booted):
    """Model, chip, cores, GPU and the login shell, from system_profiler once a boot."""
    path = os.path.join(CACHE, "static-v2-%d.json" % booted)
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        pass
    found = {}
    try:
        profile = json.loads(run("/usr/sbin/system_profiler", "-json", "SPHardwareDataType", "SPDisplaysDataType", wait=4) or "{}")
    except ValueError:
        profile = {}
    hw = (profile.get("SPHardwareDataType") or [{}])[0]
    found["model"] = hw.get("machine_name") or sysctl("hw.model")
    found["chip"] = hw.get("chip_type") or sysctl("machdep.cpu.brand_string")
    perf, eff = sysctl("hw.perflevel0.physicalcpu"), sysctl("hw.perflevel1.physicalcpu")
    found["cores"] = sysctl("hw.ncpu") + " cores" + (" (%s P, %s E)" % (perf, eff) if perf and eff else "")
    gpu = (profile.get("SPDisplaysDataType") or [{}])[0]
    found["gpu"] = " · ".join(x for x in [gpu.get("sppci_model"), (gpu.get("sppci_cores") or "") and gpu.get("sppci_cores") + " cores"] if x)
    try:
        found["shell"] = os.path.basename(pwd.getpwnam(os.environ.get("USER") or "").pw_shell)
    except KeyError:
        found["shell"] = ""
    version = run(found["shell"] and "/bin/" + found["shell"] or "/usr/bin/true", "--version", wait=1) if found["shell"] in ("zsh", "bash") else ""
    m = re.search(r"(\d+\.\d+(\.\d+)?)", version)
    if m:
        found["shell"] += " " + m.group(1)
    if found["model"]:
        try:
            os.makedirs(CACHE, exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                json.dump(found, f)
        except OSError:
            pass
    return found


def memory():
    total = int(sysctl("hw.memsize") or 0)
    text = run("/usr/bin/vm_stat")
    size = int((re.search(r"page size of (\d+)", text) or [0, 16384])[1])
    pages = {k.strip().lower(): int(v.strip().rstrip(".")) for k, v in re.findall(r"^([^:\n]+):\s+(\d+)\.?$", text, re.M)}
    used = (pages.get("anonymous pages", pages.get("pages active", 0)) - pages.get("pages purgeable", 0)
            + pages.get("pages wired down", 0) + pages.get("pages occupied by compressor", 0)) * size
    return {"used": max(0, used), "total": total, "percent": round(100 * used / total) if total else None}


def disk():
    try:
        s = os.statvfs("/System/Volumes/Data")
    except OSError:
        s = os.statvfs("/")
    total, free = s.f_blocks * s.f_frsize, s.f_bavail * s.f_frsize
    return {"used": total - free, "total": total, "percent": round(100 * (total - free) / total) if total else None}


def cpu():
    out = run("/bin/ps", "-A", "-o", "%cpu=")
    cores = int(sysctl("hw.ncpu") or 1)
    total = sum(float(x) for x in out.split() if re.match(r"^\d+(\.\d+)?$", x))
    load = sysctl("vm.loadavg").strip("{} ").split()
    return {"percent": min(100, round(total / cores)), "load": load[0] if load else None}


def battery():
    text = run("/usr/bin/pmset", "-g", "batt", wait=2)
    m = re.search(r"(\d+)%;\s*([a-zA-Z ]+);", text)
    return {"percent": int(m.group(1)), "state": m.group(2).strip()} if m else None


def packages():
    count = 0
    for folder in ("/opt/homebrew/Cellar", "/opt/homebrew/Caskroom", "/usr/local/Cellar", "/usr/local/Caskroom"):
        try:
            count += sum(1 for name in os.listdir(folder) if not name.startswith("."))
        except OSError:
            pass
    return count


def uptime(booted):
    seconds = max(0, int(time.time()) - booted)
    days, rest = divmod(seconds, 86400)
    hours, rest = divmod(rest, 3600)
    return ("%dd %dh" % (days, hours)) if days else ("%dh %dm" % (hours, rest // 60))


def main():
    sys.stdin.read()
    booted = boot()
    fixed = static(booted)
    version = platform.mac_ver()[0]
    user = os.environ.get("USER") or ""
    host = run("/usr/sbin/scutil", "--get", "LocalHostName", wait=1).strip() or platform.node().split(".")[0]
    data = dict(fixed, user=user, host=host, os="macOS " + version, kernel="Darwin " + platform.release(),
                arch=platform.machine(), uptime=uptime(booted), packages=packages(),
                cpu=cpu(), memory=memory(), disk=disk(), battery=battery())
    sys.stdout.write(json.dumps({"type": "data", "data": data}, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
