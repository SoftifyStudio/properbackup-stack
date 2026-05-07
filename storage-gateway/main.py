"""
ProperBackup Restrictive Storage Gateway
=========================================
Simulates a very restrictive VPS / object storage endpoint.
Only two operations are allowed:
  1. LIST objects  — GET  /objects
  2. UPLOAD object — POST /objects  (max 900 MB per chunk)

No download, no delete, no update. This is intentional:
the storage tier is append-only and list-only by design.
"""

import hashlib
import json
import os
import time
from pathlib import Path

from fastapi import FastAPI, File, Header, HTTPException, UploadFile
from fastapi.responses import JSONResponse

STORAGE_DIR = Path(os.environ.get("STORAGE_DIR", "/data/objects"))
MAX_CHUNK_BYTES = int(os.environ.get("MAX_CHUNK_BYTES", str(900 * 1024 * 1024)))  # 900 MB
AUTH_TOKEN = os.environ.get("STORAGE_AUTH_TOKEN", "dev-storage-token")

app = FastAPI(title="ProperBackup Restrictive Storage", version="1.0.0")

STORAGE_DIR.mkdir(parents=True, exist_ok=True)


@app.get("/health")
def health():
    return {"status": "ok", "mode": "restrictive", "max_chunk_bytes": MAX_CHUNK_BYTES}


@app.get("/objects")
def list_objects(authorization: str = Header(default="")):
    """List all stored objects — name, size, sha256, uploaded_at."""
    _check_auth(authorization)
    result = []
    for f in sorted(STORAGE_DIR.iterdir()):
        if f.is_file() and not f.name.startswith("."):
            meta_path = STORAGE_DIR / f".{f.name}.meta.json"
            meta = {}
            if meta_path.exists():
                try:
                    meta = json.loads(meta_path.read_text())
                except Exception:
                    pass
            result.append({
                "name": f.name,
                "size": f.stat().st_size,
                "sha256": meta.get("sha256", ""),
                "uploaded_at": meta.get("uploaded_at", ""),
                "original_path": meta.get("original_path", ""),
                "server_id": meta.get("server_id", ""),
            })
    return {"objects": result, "count": len(result)}


@app.post("/objects")
async def upload_object(
    file: UploadFile = File(...),
    authorization: str = Header(default=""),
    x_server_id: str = Header(default="", alias="X-Server-Id"),
    x_original_path: str = Header(default="", alias="X-Original-Path"),
):
    """Upload one chunk (max 900 MB). Rejects anything else."""
    _check_auth(authorization)

    if not file.filename:
        raise HTTPException(status_code=400, detail="Filename required")

    content = await file.read()
    size = len(content)

    if size > MAX_CHUNK_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"Chunk too large: {size} bytes (max {MAX_CHUNK_BYTES})",
        )

    if size == 0:
        raise HTTPException(status_code=400, detail="Empty upload rejected")

    sha = hashlib.sha256(content).hexdigest()
    dest = STORAGE_DIR / file.filename

    dest.write_bytes(content)

    meta = {
        "sha256": sha,
        "size": size,
        "uploaded_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "original_path": x_original_path,
        "server_id": x_server_id,
    }
    meta_path = STORAGE_DIR / f".{file.filename}.meta.json"
    meta_path.write_text(json.dumps(meta, indent=2))

    return JSONResponse(
        status_code=201,
        content={"name": file.filename, "size": size, "sha256": sha},
    )


# ---- ALL other methods are BLOCKED ----

@app.api_route("/objects/{name}", methods=["GET"])
def download_blocked(name: str):
    raise HTTPException(status_code=403, detail="Download is not allowed on this storage tier")


@app.api_route("/objects/{name}", methods=["DELETE"])
def delete_blocked(name: str):
    raise HTTPException(status_code=403, detail="Delete is not allowed on this storage tier")


@app.api_route("/objects/{name}", methods=["PUT", "PATCH"])
def update_blocked(name: str):
    raise HTTPException(status_code=403, detail="Update is not allowed on this storage tier")


def _check_auth(authorization: str):
    if not authorization:
        raise HTTPException(status_code=401, detail="Authorization header required")
    token = authorization.removeprefix("Bearer ").strip()
    if token != AUTH_TOKEN:
        raise HTTPException(status_code=403, detail="Invalid token")
