#!/usr/bin/env python3
# firebase_run_and_collect.py — generischer Test-Lab-Lauf für die Farm.
#
# Läuft in GitHub Actions: startet eine Robo-/Instrumentation-Matrix auf
# Firebase Test Lab, wartet, sammelt Evidence und normalisiert auf
# result.json (schema_version 2). Enthält KEINE App-Quellcode- oder
# Secret-Logik.
#
# Evidence-Quellen (alle über die Test-Lab-/Tool-Results-API, die der
# CI-Dienstaccount mit minimalen Rollen lesen darf):
#   Testing API      → Matrix-Status, Executions, device-Environment
#   Tool Results API → Step-Outcome je Gerät, Screenshots (thumbnails)
#   GCS (optional)   → Logcat/Videos, nur wenn der Bucket lesbar ist
#
# Fail-closed Regeln:
#   - Prüfsumme falsch/fehlt Bindung        → INFRA_FAIL, keine Matrix
#   - Quote nicht ausreichend               → WAITING_FOR_NO_COST_QUOTA
#   - Billing/Bezahlung nötig               → ZERO_COST_BLOCKED
#   - App-Crash/ANR (Zielpaket)             → FAIL (kein automatischer Retry)
#   - Google-/Netz-/Auth-/Matrix-Problem    → INFRA_FAIL (max. 1 Retry)
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
import base64
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
MAX_INFRA_RETRIES = 1  # Retry-Policy: nur INFRA, nur einmal, quota-guardiert


def log(msg):
    print(f"[testlab] {msg}", flush=True)


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def gcloud(*args):
    r = subprocess.run(["gcloud", *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"gcloud {' '.join(args[:2])} fehlgeschlagen: {r.stderr[:400]}")
    return r.stdout


def token():
    return subprocess.run(["gcloud", "auth", "print-access-token"],
                          capture_output=True, text=True).stdout.strip()


def curl_api(url):
    r = subprocess.run(["curl", "-sS", "-H", f"Authorization: Bearer {token()}", url],
                       capture_output=True, text=True)
    return json.loads(r.stdout)


STARTED_UTC = now_iso()
os.makedirs(RESULTS_ROOT, exist_ok=True)
EV = os.path.join(RESULTS_ROOT, RESULTS_DIR_NAME)
os.makedirs(EV, exist_ok=True)


def base_result(verdict, blockers, **kw):
    r = {
        "schema_version": 2,
        "request_id": RESULTS_DIR_NAME,
        "app": APP_ID, "package": PACKAGE,
        "commit_sha": COMMIT,
        "artifact_name": os.path.basename(ARTIFACT) if ARTIFACT else "",
        "artifact_sha256": ART_SHA or "",
        "artifact_kind": "apk",
        "version_name": VERSION_NAME, "version_code": int(VERSION_CODE or 0),
        "mode": MODE, "backend": "firebase-test-lab", "test_type": "robo",
        "project_id": PROJECT,
        "firebase_matrix_id": "",
        "started_utc": STARTED_UTC,
        "finished_utc": now_iso(),
        "devices": [],
        "tests_passed": 0, "tests_failed": 0, "crashes": 0, "anrs": 0,
        "screenshots": 0, "infra_failures": 0,
        "verdict": verdict, "blockers": blockers,
        "evidence_dir": EV, "timestamp_utc": now_iso(),
    }
    r.update(kw)
    return r


def emit_result(result):
    path = os.path.join(RESULTS_ROOT, "result.json")
    json.dump(result, open(path, "w"), ensure_ascii=False, indent=2)
    with open(os.path.join(RESULTS_ROOT, "SUMMARY.md"), "w") as fh:
        fh.write(f"# {result['app']} — {result['mode']} (Firebase Test Lab)\n\n")
        fh.write(f"- Verdikt: **{result['verdict']}**\n")
        fh.write(f"- Matrix: `{result.get('firebase_matrix_id','')}` ({result['project_id']})\n")
        fh.write(f"- Geräte: {'; '.join(d['model'] + '/' + str(d['version']) + ' ' + str(d.get('outcome') or d['state']) for d in result['devices'])}\n")
        fh.write(f"- Commit: `{result['commit_sha'][:12]}` · {result['version_name']} ({result['version_code']})\n")
        fh.write(f"- Artefakt: `{result['artifact_name']}` SHA-256 `{result['artifact_sha256'][:16]}…`\n")
        fh.write(f"- Crashes {result['crashes']} · ANRs {result['anrs']} · Screenshots {result['screenshots']}\n")
        if result["blockers"]:
            fh.write("\n## Blocker\n" + "\n".join(f"- {b}" for b in result["blockers"]) + "\n")
    log(f"result.json: {path} · Verdikt {result['verdict']}")


def fail(verdict, blockers, **kw):
    emit_result(base_result(verdict, blockers, **kw))
    sys.exit(0)


# ── Prüfsumme fail-closed: falsche Bindung → INFRA_FAIL, keine Matrix ──
if not ARTIFACT or not os.path.isfile(ARTIFACT):
    fail("INFRA_FAIL", ["Artefakt fehlt auf dem Runner — Identity-Bindung nicht beweisbar"])
if not ART_SHA:
    fail("INFRA_FAIL", ["keine erwartete Prüfsumme angegeben — Identity-Bindung nicht beweisbar"])
actual_sha = subprocess.run(["sha256sum", ARTIFACT], capture_output=True, text=True).stdout.split()[0]
if actual_sha != ART_SHA:
    log(f"PRÜFSUMME WEICHT AB: {actual_sha} != {ART_SHA}")
    fail("INFRA_FAIL", [f"Artefakt-Prüfsumme weicht ab: {actual_sha[:16]}… != erwartet {ART_SHA[:16]}… — getesteter Build gehört nicht zur angegebenen Identität"])
log(f"Prüfsumme verifiziert: {actual_sha[:16]}…")

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
need_virtual = sum(1 for _, _, f in devices if f == "virtual")
need_physical = sum(1 for _, _, f in devices if f == "physical")


# ── Quota: Gerätezäufe (Steps) seit Mitternacht Pacific ────────
def quota_used():
    now = datetime.now(timezone.utc)
    window_start = now.astimezone(timezone(timedelta(hours=-7))).replace(
        hour=0, minute=0, second=0, microsecond=0)
    virtual = physical = 0
    for h in curl_api(f"https://toolresults.googleapis.com/toolresults/v1beta3/projects/{PROJECT}/histories").get("histories", []):
        for ex in curl_api(f"https://toolresults.googleapis.com/toolresults/v1beta3/projects/{PROJECT}/histories/{h['historyId']}/executions?pageSize=100").get("executions", []):
            secs = int(ex.get("creationTime", {}).get("seconds", "0"))
            if datetime.fromtimestamp(secs, tz=timezone.utc) >= window_start:
                steps = curl_api(f"https://toolresults.googleapis.com/toolresults/v1beta3/projects/{PROJECT}/histories/{h['historyId']}/executions/{ex['executionId']}/steps?pageSize=100")
                # CI zählt konservativ: alle heute erzeugten Steps als virtuell
                virtual += len(steps.get("steps", [])) or 1
    return virtual, physical


def quota_allows(extra_v, extra_p):
    try:
        virtual, physical = quota_used()
    except Exception as e:
        log(f"Quota-Prüfung fehlgeschlagen ({e}) — fahre nicht ohne Beleg fort")
        return False
    log(f"Quota: {virtual}/{LIMIT_VIRTUAL} virtuell belegt, benötigt {extra_v}")
    return virtual + extra_v <= LIMIT_VIRTUAL and physical + extra_p <= LIMIT_PHYSICAL


if not quota_allows(need_virtual, need_physical):
    fail("WAITING_FOR_NO_COST_QUOTA",
         [f"Tagesquote reicht nicht: {need_virtual} virtuelle Läufe benötigt — keine kostenpflichtige Ausführung, kein Konto-Rotieren"])

# ── Matrix starten/pollen (Retry-Policy: 1 INFRA-Retry, kein App-Retry) ──
dev_args = []
for m, v, f in devices:
    dev_args += ["--device", f"model={m},version={v},locale=de,orientation=portrait"]
with open(os.path.join(EV, "devices.txt"), "w") as fh:
    fh.writelines(f"form={f} model={m} version={v} locale=de orientation=portrait\n" for m, v, f in devices)

attempt = 0
launched_matrices = []
while True:
    attempt += 1
    launch_ts = int(time.time()) - 120
    results_dir = f"farm-{APP_ID}-{MODE}-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
    log(f"Starte Matrix (Versuch {attempt}, {len(devices)} Geräte, Robo, Timeout {TL_TIMEOUT})")
    r = subprocess.run(["gcloud", "firebase", "test", "android", "run", "--project", PROJECT,
                        "--type", "robo", "--app", ARTIFACT, *dev_args,
                        "--timeout", TL_TIMEOUT, "--results-dir", results_dir, "--async"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        err = r.stderr[:800]
        if re.search(r"quota|exceeded", err, re.I):
            fail("WAITING_FOR_NO_COST_QUOTA", [err[:200]])
        if re.search(r"billing|payment", err, re.I):
            fail("ZERO_COST_BLOCKED", [err[:200]])
        if attempt <= MAX_INFRA_RETRIES and quota_allows(need_virtual, need_physical):
            log(f"Launch-Fehler (INFRA) — genau ein Retry: {err[:200]}")
            time.sleep(20)
            continue
        fail("INFRA_FAIL", [f"Launch fehlgeschlagen: {err[:200]}"], attempts=attempt)

    hid_m = re.search(r"histories/(bh\.[a-z0-9]+)", r.stdout)
    if not hid_m:
        if attempt <= MAX_INFRA_RETRIES and quota_allows(need_virtual, need_physical):
            log("Keine History-ID in der Launch-Antwort — genau ein Retry")
            time.sleep(20)
            continue
        fail("INFRA_FAIL", ["keine History-ID in der Launch-Antwort"], attempts=attempt)
    hid = hid_m.group(1)

    mid = None
    for _ in range(20):
        data = curl_api(f"https://toolresults.googleapis.com/toolresults/v1beta3/projects/{PROJECT}/histories/{hid}/executions?pageSize=50")
        ids = sorted({e["testExecutionMatrixId"] for e in data.get("executions", [])
                      if int(e.get("creationTime", {}).get("seconds", "0")) >= launch_ts
                      and e.get("testExecutionMatrixId", "").startswith("matrix-")})
        if ids:
            mid = ids[0]
            break
        time.sleep(10)
    if not mid:
        if attempt <= MAX_INFRA_RETRIES and quota_allows(need_virtual, need_physical):
            log("API-Matrix-ID nicht ermittelbar — genau ein Retry")
            time.sleep(20)
            continue
        fail("INFRA_FAIL", ["API-Matrix-ID nicht ermittelbar"], attempts=attempt)
    log(f"Matrix: {mid}")
    launched_matrices.append(mid)

    final = {}
    for i in range(120):  # max 30 min
        final = curl_api(f"https://testing.googleapis.com/v1/projects/{PROJECT}/testMatrices/{mid}")
        st = final.get("state", "")
        if st in ("FINISHED", "ERROR", "INVALID", "CANCELLED"):
            break
        if i % 8 == 0:
            log(f"  Zustand {st} ({i * 15}s)")
        time.sleep(15)
    mstate = final.get("state", "")
    json.dump(final, open(os.path.join(EV, f"matrix-attempt{attempt}.json"), "w"),
              ensure_ascii=False, indent=2)

    if mstate == "FINISHED":
        break
    if attempt <= MAX_INFRA_RETRIES and quota_allows(need_virtual, need_physical):
        log(f"Matrix endete in {mstate or 'TIMEOUT'} (INFRA) — genau ein Retry")
        time.sleep(20)
        continue
    fail("INFRA_FAIL", [f"Matrix-Endzustand: {mstate or 'TIMEOUT'} (nach {attempt} Versuch(en))"],
         attempts=attempt, launched_matrices=launched_matrices)

finished_utc = now_iso()
log(f"Endzustand: {mstate}")

# ── Evidence: Steps (Outcome), Thumbnails (Screenshots), GCS (optional) ──
gcs = final.get("resultStorage", {}).get("googleCloudStorage", {}).get("gcsPath", "")
tr = final.get("resultStorage", {}).get("toolResultsHistory", {})
tre = final.get("resultStorage", {}).get("toolResultsExecution", {})
step_map = {}
if tr.get("historyId") and tre.get("executionId"):
    steps = curl_api(f"https://toolresults.googleapis.com/toolresults/v1beta3/projects/{PROJECT}/histories/{tr['historyId']}/executions/{tre['executionId']}/steps?pageSize=50")
    json.dump(steps, open(os.path.join(EV, "steps.json"), "w"), ensure_ascii=False, indent=2)
    step_map = {s.get("stepId", ""): s for s in steps.get("steps", [])}

devices_out, passed, failed, errors = [], 0, 0, 0
screenshots = 0
for e in final.get("testExecutions", []):
    env_dev = (e.get("environment", {}).get("androidDevice") or {})
    step_id = (e.get("toolResultsStep", {}) or {}).get("stepId", "")
    step = step_map.get(step_id, {})
    outcome = (step.get("outcome", {}) or {}).get("summary", "")
    dur = (step.get("runDuration", {}) or {}).get("seconds", "")
    st = e.get("state", "")
    devices_out.append({
        "model": env_dev.get("androidModelId", "?"),
        "version": str(env_dev.get("androidVersionId", "?")),
        "api_level": env_dev.get("androidVersionId", "?"),
        "locale": env_dev.get("locale", "de"),
        "orientation": env_dev.get("orientation", "portrait"),
        "form": "virtual",
        "state": st, "outcome": outcome or None,
        "run_seconds": int(dur) if dur else None,
    })
    if outcome == "success" and st == "FINISHED":
        passed += 1
    elif outcome == "failure" or st == "FAILED":
        failed += 1
    else:
        errors += 1

    # Screenshots direkt über die Tool Results API (kein GCS-Zugriff nötig)
    if tr.get("historyId") and tre.get("executionId") and step_id:
        dev_tag = f"{env_dev.get('androidModelId', 'device')}-{env_dev.get('androidVersionId', 'api')}"
        shots_dir = os.path.join(EV, "screenshots", dev_tag)
        os.makedirs(shots_dir, exist_ok=True)
        try:
            thumbs = curl_api(f"https://toolresults.googleapis.com/toolresults/v1beta3/projects/{PROJECT}/histories/{tr['historyId']}/executions/{tre['executionId']}/steps/{step_id}/thumbnails")
            for idx, t in enumerate(thumbs.get("thumbnails", [])):
                data = (t.get("thumbnail") or {}).get("data", "")
                if data:
                    with open(os.path.join(shots_dir, f"{idx:02d}.png"), "wb") as fh:
                        fh.write(base64.b64decode(data))
                    screenshots += 1
        except Exception as ex:
            log(f"Thumbnail-Abruf für {dev_tag} fehlgeschlagen: {str(ex)[:120]}")

# GCS-Vollbelege (Logcat/Videos) — optional; der Google-verwaltete Bucket
# ist für den CI-SA leserechtlich geschlossen (dokumentiert in der Registry).
gcs_downloaded = False
if gcs:
    try:
        subprocess.run(["gcloud", "storage", "cp", "-r", gcs, os.path.join(EV, "artifacts", ""),
                        "--quiet"], capture_output=True, text=True, timeout=240)
        gcs_downloaded = bool(glob.glob(os.path.join(EV, "artifacts", "**", "*"), recursive=True))
    except Exception:
        pass

# Crash/ANR aus Logcat (paketbezogen), falls Logcat vorliegt; primär zählt
# Googles Step-Outcome (Test Lab markiert Crashes/ANRs als FAILED).
crashes = anrs = 0
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

# physische Geräte aus devices.txt markieren
try:
    launched = [l for l in open(os.path.join(EV, "devices.txt")) if l.startswith("form=")]
    for i, line in enumerate(launched):
        if i < len(devices_out) and " form=physical" in line:
            devices_out[i]["form"] = "physical"
except Exception:
    pass

# ── Verdict ────────────────────────────────────────────────────
blockers = []
verdict = "INFRA_FAIL"
if mstate == "FINISHED":
    if errors == 0 and failed == 0 and crashes == 0 and anrs == 0 and screenshots > 0 and passed > 0:
        verdict = "PASS"
    else:
        if crashes:
            blockers.append(f"{crashes} Abstürze des Zielpakets im Logcat")
        if anrs:
            blockers.append(f"{anrs} ANRs des Zielpakets im Logcat")
        for d in devices_out:
            if d["outcome"] == "failure":
                blockers.append(f"{d['model']} {d['version']}: FAILED (Test Lab Outcome)")
            elif d["state"] not in ("FINISHED",):
                blockers.append(f"{d['model']} {d['version']}: Zustand {d['state']}")
        if screenshots == 0:
            blockers.append("kein Bildschirmbeleg gesichert (keine Thumbnails/Artefakte)")
        verdict = "FAIL" if (failed > 0 or crashes > 0 or anrs > 0) else "INFRA_FAIL"
else:
    blockers.append(f"Matrix-Endzustand: {mstate}")

result = base_result(verdict, blockers,
                     devices=devices_out, tests_passed=passed, tests_failed=failed,
                     infra_failures=errors, crashes=crashes, anrs=anrs,
                     screenshots=screenshots,
                     firebase_matrix_id=mid,
                     firebase_history=tr.get("historyId", ""),
                     firebase_gcs_path=gcs,
                     firebase_gcs_download="ok" if gcs_downloaded else "closed-managed-bucket",
                     attempts=attempt,
                     launched_matrices=launched_matrices,
                     identity={
                         "app": APP_ID, "package": PACKAGE, "commit_sha": COMMIT,
                         "artifact_sha256": actual_sha, "version_name": VERSION_NAME,
                         "version_code": int(VERSION_CODE or 0), "project": PROJECT,
                         "test_type": "robo", "backend": "firebase-test-lab",
                     },
                     finished_utc=finished_utc)
emit_result(result)
log(f"Verdikt: {verdict}")
