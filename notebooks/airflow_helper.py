"""
Airflow helper — upload skryptu do GCS i uruchomienie DAG.

Pobierz na swój serwer JupyterHub:
    gsutil cp gs://<DAG_BUCKET>/helpers/airflow_helper.py .

Użycie:
    import airflow_helper as ah
    ah.run_and_wait("my_analysis.py")          # upload + trigger + czeka
    ah.run("my_analysis.py")                   # upload + trigger (nie czeka)
    ah.upload("my_analysis.py")                # tylko upload
"""

import json
import os
import time
import urllib.request
from pathlib import Path

AIRFLOW_HOST = os.environ.get("AIRFLOW_HOST", "http://airflow-webserver.airflow.svc.cluster.local:8080")
DAG_BUCKET   = os.environ.get("DAG_BUCKET", "")
_ANALITYK     = os.environ.get("JUPYTERHUB_USER", "analityk01")
_PASS        = _ANALITYK + "Pass123!"


def _token() -> str:
    req = urllib.request.Request(
        "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token",
        headers={"Metadata-Flavor": "Google"},
    )
    return json.loads(urllib.request.urlopen(req).read())["access_token"]


def _api(method: str, path: str, body: dict = None) -> dict:
    import base64
    creds = base64.b64encode(f"{_ANALITYK}:{_PASS}".encode()).decode()
    req = urllib.request.Request(
        f"{AIRFLOW_HOST}/api/v1{path}",
        data=json.dumps(body).encode() if body else None,
        headers={"Authorization": f"Basic {creds}", "Content-Type": "application/json"},
        method=method,
    )
    try:
        return json.loads(urllib.request.urlopen(req).read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{method} {path} → {e.code}: {e.read().decode()}") from e


def upload(local_path: str) -> str:
    """Wgraj plik do gs://<DAG_BUCKET>/dags/<analityk>/<plik>."""
    if not DAG_BUCKET:
        raise RuntimeError("DAG_BUCKET nie ustawiony — sprawdź zmienne środowiskowe")
    name = Path(local_path).name
    blob = f"dags/{_ANALITYK}/{name}"
    url  = f"https://storage.googleapis.com/upload/storage/v1/b/{DAG_BUCKET}/o?uploadType=media&name={blob}"
    with open(local_path, "rb") as f:
        data = f.read()
    req = urllib.request.Request(
        url, data=data,
        headers={"Authorization": f"Bearer {_token()}", "Content-Type": "text/plain"},
        method="POST",
    )
    urllib.request.urlopen(req)
    print(f"Upload OK → gs://{DAG_BUCKET}/{blob}")
    return blob


def trigger(script_name: str) -> str:
    """Odpala DAG analityk_run_script. Zwraca dag_run_id."""
    result = _api("POST", "/dags/analityk_run_script/dagRuns",
                  {"conf": {"analityk_id": _ANALITYK, "script_name": script_name}})
    run_id = result["dag_run_id"]
    print(f"DAG uruchomiony → {AIRFLOW_HOST}/dags/analityk_run_script/grid")
    return run_id


def wait(run_id: str, poll: int = 5, timeout: int = 300) -> str:
    """Czeka na zakończenie run. Zwraca 'success' lub 'failed'."""
    elapsed, last = 0, None
    while elapsed < timeout:
        time.sleep(poll)
        elapsed += poll
        state = _api("GET", f"/dags/analityk_run_script/dagRuns/{run_id}")["state"]
        if state != last:
            print(f"  [{elapsed:3d}s] {state}")
            last = state
        if state in ("success", "failed"):
            print("OK" if state == "success" else "BLAD")
            return state
    raise TimeoutError(f"Przekroczono {timeout}s")


def run(local_path: str) -> str:
    """Upload + trigger."""
    upload(local_path)
    return trigger(Path(local_path).name)


def run_and_wait(local_path: str, poll: int = 5, timeout: int = 300) -> str:
    """Upload + trigger + czeka na wynik."""
    return wait(run(local_path), poll=poll, timeout=timeout)
