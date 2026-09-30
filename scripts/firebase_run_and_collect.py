#!/usr/bin/env python3
# firebase_run_and_collect.py — generischer Test-Lab-Lauf für die Farm.
#
# Läuft in GitHub Actions: startet eine Robo-/Instrumentation-Matrix auf
# Firebase Test Lab, wartet, lädt Belege und normalisiert auf result.json
# (schema_version 2). Enthält KEINE App-Quellcode- oder Secret-Logik.
#
# Steuerung über Umgebungsvariablen:
#   FIREBASE_PROJECT  Standard: nectar-android-testlab-01
#   MODE              smoke|standard|release
#   APP_ID, PACKAGE, COMMIT_SHA, VERSION_NAME, VERSION_CODE
#   ARTIFACT          Pfad zur APK
#   ARTIFACT_SHA256   erwartete Prüfsumme (fail closed)
#   RESULTS_ROOT      Standard: $RUNNER_TEMP/nectar-evidence
#   RESULTS_DIR_NAME  Ergebnis-Unterordner
#   TL_TIMEOUT        je Gerät, z.B. 2m (Standard 2m)
#   ALLOW_PHYSICAL    1 → release darf ein physisches Gerät nutzen
import glob
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

PROJECT = os.environ.get("FIREBASE_PROJECT", "nectar-android-testlab-01")
MODE = os.environ.get("MODE", "smoke")
APP_ID = os.environ.get("APP_ID", "app")
PACKAGE = os.environ.get("PACKAGE", "")
COMMIT = os.environ.get("COMMIT_SHA", "")
VERSION_NAME = os.environ.get("VERSION_NAME", "")
VERSION_CODE = os.environ.get("VERSION_CODE", "0")
ARTIFACT = os.environ.get("ARTIFACT", "")
ART_SHA = os.environ.get("ARTIFACT_SHA256", "")
RESULTS_ROOT = os.environ.get("RESULTS_ROOT", os.path.join(os.environ.get("RUNNER_TEMP", "/tmp"), "nectar-evidence"))
RESULTS_DIR_NAME = os.environ.get("RESULTS_DIR_NAME", f"testlab-{int(time.time())}")
TL_TIMEOUT = os.environ.get("TL_TIMEOUT", "2m")
ALLOW_PHYSICAL = os.environ.get("ALLOW_PHYSICAL", "0") == "1"
MIN_SDK = int(os.environ.get("MIN_SDK", "26"))
TARGET_SDK = int(os.environ.get("TARGET_SDK", "36"))

LIMIT_VIRTUAL, LIMIT_PHYSICAL = 10, 5


def log(msg):
    print(f"[testlab] {msg}", flush=True)


def gcloud(*args, capture=True):
    r = subprocess.run(["gcloud", *args], capture_output=capture, text=True)
    if r.returncode != 0 and capture:
        raise RuntimeError(f"gcloud {' '.join(args[:2])} fehlgeschlagen: {r.stderr[:400]}")
    return r.stdout


def token():
    return subprocess.run(["gcloud", "auth", "print-access-token"],
                          capture_output=True, text=True).stdout.strip()


def curl_api(url):
    r = subprocess.run(["curl", "-sS", "-H", f"Authorization: Bearer {token()}", url],
                       capture_output=True, text=True)
    return json.loads(r.stdout)


# ── Prüfsumme fail-closed ──────────────────────────────────────
if ART_SHA:
    actual = subprocess.run(["sha256sum", ARTIFACT], capture_output=True, text=True).stdout.split()[0]
    if actual != ART_SHA:
        log(f"PRÜFSUMME WEICHT AB: {actual} != {ART_SHA}")
        sys.exit(2)
    log(f"Prüfsumme verifiziert: {ART_SHA[:16]}…")

os.makedirs(RESULTS_ROOT, exist_ok=True)
EV = os.path.join(RESULTS_ROOT, RESULTS_DIR_NAME)
os.makedirs(EV, exist_ok=True)


def emit_result(result):
    path = os.path.join(RESULTS_ROOT, "result.json")
    json.dump(result, open(path, "w"), ensure_ascii=False, indent=2)
    log(f"result.json: {path}")


def fail(verdict, blockers):
    emit_result({
        "schema_version": 2, "request_id": RESULTS_DIR_NAME, "app": APP_ID, "package": PACKAGE,
        "commit_sha": COMMIT, "artifact_name": os.path.basename(ARTIFACT),
        "artifact_sha256": ART_SHA or "", "version_name": VERSION_NAME, "version_code": int(VERSION_CODE or 0),
        "mode": MODE, "backend": "firebase-test-lab", "test_type": "robo",
        "project_id": PROJECT, "firebase_matrix_id": "", "devices": [],
        "tests_passed": 0, "tests_failed": 0, "crashes": 0, "anrs": 0,
        "infra_failures": 0, "verdict": verdict, "blockers": blockers,
        "evidence_dir": EV, "timestamp_utc": datetime.now(timezone.utc).isoformat(),
    })
    sys.exit(0 if verdict in ("PASS", "FAIL") else 0)


# ── Geräte dynamisch wählen ────────────────────────────────────
try:
    models = json.loads(gcloud("firebase", "test", "android", "models", "list",
                               "--project", PROJECT, "--format=json"))
except Exception as e:
    log(f"Modellliste nicht verfügbar: {e}")
    fail("INFRA_FAIL", ["Cloud Testing API nicht erreichbar"])

virt = [m for m in models if m.get("form") == "VIRTUAL" and not m.get("tags")
        and m.get("formFactor") in ("PHONE", "TABLET")]


def by_id(mid):
    return next((m for m in virt if m["id"] == mid), None)


def best_version(m, cap):
    if m is None:
        return None
    ok = [v for v in sorted(int(v) for v in m["supportedVersionIds"]) if v <= cap]
    return ok[-1] if ok else None


if by_id("MediumPhone.arm") is None:
    fail("INFRA_FAIL", ["kein stabiles MediumPhone.arm in der Modellliste"])

cap_current = min(TARGET_SDK, 36)
devices = []
if MODE == "smoke":
    devices.append(("MediumPhone.arm", best_version(by_id("MediumPhone.arm"), cap_current), "virtual"))
elif MODE == "standard":
    px = by_id("Pixel2.arm")
    lower = None
    if px:
        ok = [v for v in sorted(int(v) for v in px["supportedVersionIds"]) if v >= MIN_SDK]
        lower = ok[0] if ok else None
    if lower is None:
        lower = best_version(by_id("MediumPhone.arm"), max(MIN_SDK, 26))
    devices.append(("Pixel2.arm", lower, "virtual"))
    devices.append(("MediumPhone.arm", best_version(by_id("MediumPhone.arm"), cap_current), "virtual"))
    tab = by_id("MediumTablet.arm")
    if tab:
        devices.append(("MediumTablet.arm", best_version(tab, min(TARGET_SDK, 35)), "virtual"))
elif MODE == "release":
    devices.append(("MediumPhone.arm", best_version(by_id("MediumPhone.arm"), cap_current), "virtual"))
    tab = by_id("MediumTablet.arm")
    if tab:
        devices.append(("MediumTablet.arm", best_version(tab, min(TARGET_SDK, 35)), "virtual"))
else:
    fail("INFRA_FAIL", [f"unbekannter Modus {MODE}"])

# physisches Gerät nur für release und wenn Quote/Flag erlauben
if MODE == "release" and ALLOW_PHYSICAL:
    phys = [m for m in models if m.get("form") == "PHYSICAL" and m.get("formFactor") == "PHONE"
            and not m.get("tags")]
    def rank(m):
        name = (m.get("manufacturer", "") + " " + m.get("name", "")).lower()
        r = 0
        if "samsung" in m.get("manufacturer", "").lower():
            r += 2
        if "galaxy a" in name or "galaxy s" in name:
            r += 2
        hi = max((int(v) for v in m.get("supportedVersionIds", [])), default=0)
        return (min(hi, 37), r)
    phys = sorted(phys, key=rank, reverse=True)
    for m in phys:
        hi = max((int(v) for v in m.get("supportedVersionIds", [])), default=0)
        if hi >= 35:
            devices.append((m["id"], hi, "physical"))
            break

devices = [(m, v, f) for (m, v, f) in devices if v]
if not devices:
    fail("INFRA_FAIL", ["keine Geräte wählbar"])

# ── Quota prüfen (Tool Results, Pacific-Fenster) ───────────────
try:
    now = datetime.now(timezone.utc)
    window_start = now.astimezone(timezone(timedelta(hours=-7))).replace(
        hour=0, minute=0, second=0, microsecond=0)
    virtual_used = physical_used = 0
    for h in curl_api(f"https://toolresults.googleapis.com/toolresults/v1beta3/projects/{PROJECT}/histories").get("histories", []):
        for ex in curl_api(f"https://toolresults.googleapis.com/toolresults/v1beta3/projects/{PROJECT}/histories/{h['historyId']}/executions?pageSize=100").get("executions", []):
            secs = int(ex.get("creationTime", {}).get("seconds", "0"))
            if datetime.fromtimestamp(secs, tz=timezone.utc) >= window_start:
                # physische Zählung hier nicht verlässlich — konservativ virtuell
                virtual_used += 1
    need_virtual = sum(1 for _, _, f in devices if f == "virtual")
    need_physical = sum(1 for _, _, f in devices if f == "physical")
    if virtual_used + need_virtual > LIMIT_VIRTUAL or physical_used + need_physical > LIMIT_PHYSICAL:
        log(f"Quota erschöpft: virtuell {virtual_used}/{LIMIT_VIRTUAL}, physisch {physical_used}/{LIMIT_PHYSICAL}")
        fail("WAITING_FOR_NO_COST_QUOTA",
             [f"Tagesquote: {virtual_used} virtuelle Läufe verbraucht, {need_virtual} benötigt"])
    log(f"Quota ok: {virtual_used}/{LIMIT_VIRTUAL} virtuell belegt, {need_virtual} geplant")
except Exception as e:
    log(f"Quota-Prüfung fehlgeschlagen ({e}) — fahre mit Warnung fort")

# ── Matrix starten ─────────────────────────────────────────────
dev_args = []
for m, v, f in devices:
    dev_args += ["--device", f"model={m},version={v},locale=de,orientation=portrait"]
with open(os.path.join(EV, "devices.txt"), "w") as fh:
    fh.writelines(f"form={f} model={m} version={v} locale=de orientation=portrait\n" for m, v, f in devices)

launch_ts = int(time.time()) - 120
results_dir = f"farm-{APP_ID}-{MODE}-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
cmd = ["gcloud", "firebase", "test", "android", "run", "--project", PROJECT,
       "--type", "robo", "--app", ARTIFACT, *dev_args,
       "--timeout", TL_TIMEOUT, "--results-dir", results_dir, "--async"]
log(f"Starte Matrix: {len(devices)} Geräte, Robo, Timeout {TL_TIMEOUT}")
r = subprocess.run(cmd, capture_output=True, text=True)
if r.returncode != 0:
    err = r.stderr[:800]
    if re.search(r"quota|exceeded", err, re.I):
        fail("WAITING_FOR_NO_COST_QUOTA", [err[:200]])
    if re.search(r"billing|payment", err, re.I):
        fail("ZERO_COST_BLOCKED", [err[:200]])
    fail("INFRA_FAIL", [f"Launch fehlgeschlagen: {err[:200]}"])

hid_m = re.search(r"histories/(bh\.[a-z0-9]+)", r.stdout)
if not hid_m:
    fail("INFRA_FAIL", ["keine History-ID in der Launch-Antwort"])
hid = hid_m.group(1)
log(f"History: {hid}")


def resolve_matrix_id():
    data = curl_api(f"https://toolresults.googleapis.com/toolresults/v1beta3/projects/{PROJECT}/histories/{hid}/executions?pageSize=50")
    ids = sorted({e["testExecutionMatrixId"] for e in data.get("executions", [])
                  if int(e.get("creationTime", {}).get("seconds", "0")) >= launch_ts
                  and e.get("testExecutionMatrixId", "").startswith("matrix-")})
    return ids[0] if ids else None


mid = None
for _ in range(20):
    mid = resolve_matrix_id()
    if mid:
        break
    time.sleep(10)
if not mid:
    fail("INFRA_FAIL", ["API-Matrix-ID nicht ermittelbar"])
log(f"Matrix: {mid}")

# ── Pollen bis Endzustand ──────────────────────────────────────
final = {}
for i in range(120):  # max 30 min
    final = curl_api(f"https://testing.googleapis.com/v1/projects/{PROJECT}/testMatrices/{mid}")
    st = final.get("state", "")
    if st in ("FINISHED", "ERROR", "INVALID", "CANCELLED"):
        break
    if i % 8 == 0:
        log(f"  Zustand {st} ({i * 15}s)")
    time.sleep(15)
json.dump(final, open(os.path.join(EV, "matrix.json"), "w"), ensure_ascii=False, indent=2)
mstate = final.get("state", "")
log(f"Endzustand: {mstate}")

# ── Belege + Auswertung ────────────────────────────────────────
gcs = final.get("resultStorage", {}).get("googleCloudStorage", {}).get("gcsPath", "")
if gcs:
    log(f"Lade Belege: {gcs}")
    subprocess.run(["gcloud", "storage", "cp", "-r", gcs, os.path.join(EV, "artifacts", ""),
                    "--quiet"], capture_output=True, text=True)
tr = final.get("resultStorage", {}).get("toolResultsHistory", {})
tre = final.get("resultStorage", {}).get("toolResultsExecution", {})
if tr.get("historyId") and tre.get("executionId"):
    steps = curl_api(f"https://toolresults.googleapis.com/toolresults/v1beta3/projects/{PROJECT}/histories/{tr['historyId']}/executions/{tre['executionId']}/steps?pageSize=50")
    json.dump(steps, open(os.path.join(EV, "steps.json"), "w"), ensure_ascii=False, indent=2)
step_map = {s.get("stepId", ""): s for s in
            json.load(open(os.path.join(EV, "steps.json"))).get("steps", [])} if os.path.exists(os.path.join(EV, "steps.json")) else {}

execs = final.get("testExecutions", [])
devices_out, passed, failed, errors = [], 0, 0, 0
for e in execs:
    env_dev = (e.get("environment", {}).get("androidDevice") or {})
    step = step_map.get((e.get("toolResultsStep", {}) or {}).get("stepId", ""), {})
    outcome = (step.get("outcome", {}) or {}).get("summary", "")
    dur = (step.get("runDuration", {}) or {}).get("seconds", "")
    st = e.get("state", "")
    devices_out.append({
        "model": env_dev.get("androidModelId", "?"), "version": str(env_dev.get("androidVersionId", "?")),
        "locale": env_dev.get("locale", "de"), "orientation": env_dev.get("orientation", "portrait"),
        "state": st, "outcome": outcome or None,
        "run_seconds": int(dur) if dur else None,
    })
    if outcome == "success" and st == "FINISHED":
        passed += 1
    elif outcome == "failure" or st == "FAILED":
        failed += 1
    else:
        errors += 1

crashes = anrs = 0
screens = 0
pkg_esc = re.escape(PACKAGE)
for p in glob.glob(os.path.join(EV, "artifacts", "**", "logcat"), recursive=True):
    try:
        lines = open(p, encoding="utf-8", errors="replace").read().splitlines()
        for i, ln in enumerate(lines):
            if "FATAL EXCEPTION" in ln and re.search(rf"Process:\s*{pkg_esc}\b", "\n".join(lines[i:i + 40])):
                crashes += 1
            elif f"ANR in {PACKAGE}" in ln:
                anrs += 1
    except Exception:
        pass
screens = len(glob.glob(os.path.join(EV, "artifacts", "**", "*.png"), recursive=True))

sha256 = subprocess.run(["sha256sum", ARTIFACT], capture_output=True, text=True).stdout.split()[0]
verdict = "INFRA_FAIL"
blockers = []
if mstate == "FINISHED":
    if errors == 0 and failed == 0 and crashes == 0 and anrs == 0 and screens > 0 and passed > 0:
        verdict = "PASS"
    else:
        verdict = "FAIL"
        if crashes:
            blockers.append(f"{crashes} Abstürze im Logcat")
        if anrs:
            blockers.append(f"{anrs} ANRs im Logcat")
        for d in devices_out:
            if d["outcome"] == "failure":
                blockers.append(f"{d['model']} {d['version']}: FAILED")
        if screens == 0:
            blockers.append("kein Bildschirmbeleg gesichert")
else:
    blockers.append(f"Matrix-Endzustand: {mstate}")

result = {
    "schema_version": 2, "request_id": RESULTS_DIR_NAME, "app": APP_ID, "package": PACKAGE,
    "commit_sha": COMMIT, "artifact_name": os.path.basename(ARTIFACT), "artifact_sha256": sha256,
    "version_name": VERSION_NAME, "version_code": int(VERSION_CODE or 0),
    "mode": MODE, "backend": "firebase-test-lab", "test_type": "robo", "project_id": PROJECT,
    "firebase_matrix_id": mid,
    "firebase_gcs_path": gcs,
    "firebase_history": tr.get("historyId", ""),
    "devices": devices_out,
    "tests_passed": passed, "tests_failed": failed, "crashes": crashes, "anrs": anrs,
    "screenshots": screens, "infra_failures": errors,
    "verdict": verdict, "blockers": blockers,
    "evidence_dir": EV, "timestamp_utc": datetime.now(timezone.utc).isoformat(),
}
json.dump(result, open(os.path.join(EV, "result.json"), "w"), ensure_ascii=False, indent=2)
with open(os.path.join(RESULTS_ROOT, "SUMMARY.md"), "w") as fh:
    fh.write(f"# {APP_ID} — {MODE} (Firebase Test Lab)\n\n- Verdikt: **{verdict}**\n")
    fh.write(f"- Matrix: `{mid}`\n- Geräte: {'; '.join(d['model'] + '/' + d['version'] + ' ' + str(d['outcome']) for d in devices_out)}\n")
    fh.write(f"- Commit: `{COMMIT[:12]}` · {VERSION_NAME} ({VERSION_CODE})\n")
    fh.write(f"- Crashes {crashes} · ANRs {anrs} · Screenshots {screens}\n")
emit_result(result)
log(f"Verdikt: {verdict}")
