import os
import argparse
from pathlib import Path
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from fastapi.middleware.cors import CORSMiddleware
import uvicorn

from .models import VMProvisionRequest, VMPreviewResponse, ProvisionResult
from .provisioner import VMProvisioner
from . import db

BASE_DIR = Path(__file__).resolve().parent.parent.parent
HTML_TEMPLATE_FILE = Path(__file__).resolve().parent / "templates" / "index.html"

from contextlib import asynccontextmanager

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize SQLite database table on service startup."""
    db.init_db()
    yield

app = FastAPI(
    title="Incus Automation Service",
    description="Streamlined Incus VM provisioning with step-by-step form wizard, single bash script pipeline, and SQLite expiration tracking",
    version="0.2.0",
    lifespan=lifespan
)

# Enable CORS for API clients
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

provisioner = VMProvisioner()


@app.get("/health")
def health():
    """Health check endpoint."""
    return {
        "status": "ok",
        "service": "incus-automation-service",
        "version": "0.2.0",
        "db": "connected"
    }


@app.get("/", response_class=HTMLResponse)
def index_page():
    """Serve the step-by-step workload provisioning wizard."""
    if not HTML_TEMPLATE_FILE.is_file():
        raise HTTPException(status_code=404, detail="Web UI wizard template not found")
    return HTMLResponse(content=HTML_TEMPLATE_FILE.read_text(encoding="utf-8"))


@app.post("/api/v1/preview", response_model=VMPreviewResponse)
def preview_vm_command(payload: VMProvisionRequest):
    """
    Preview the direct bash command execution arguments and calculated valid_thru date.
    """
    vm_id = payload.get_effective_identifier()
    valid_thru = db.calculate_valid_thru(payload.lifetime)
    cmd = f"bash scripts/provision_vm.sh --name '{payload.vm_name}' --image '{payload.os_image}' --cpu '{payload.cpu_count}' --ram '{payload.ram_size}' --disk '{payload.disk_size}' --user '{payload.admin_user}' --lifetime '{payload.lifetime}' --vm-id '{vm_id}'"
    if payload.dry_run:
        cmd += " --dry-run"

    return VMPreviewResponse(
        vm_identifier=vm_id,
        valid_thru=valid_thru,
        command_preview=cmd,
        params=payload.model_dump()
    )


@app.post("/api/v1/provision", response_model=ProvisionResult)
async def provision_vm(payload: VMProvisionRequest):
    """
    Execute scripts/provision_vm.sh directly with CLI arguments and register
    the VM identifier and valid_thru expiration date in the SQLite database.
    """
    try:
        result = await provisioner.execute_async(payload)
        return result
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Provisioning failed: {exc}")


@app.get("/api/v1/vms")
def list_database_vms():
    """List all registered VMs from SQLite database."""
    vms = db.list_vms()
    return {"vms": vms, "total": len(vms)}


@app.get("/api/v1/vms/{vm_identifier}")
def get_database_vm(vm_identifier: str):
    """Get single VM record from SQLite database by identifier."""
    vm = db.get_vm(vm_identifier)
    if not vm:
        raise HTTPException(status_code=404, detail=f"VM with identifier '{vm_identifier}' not found in database")
    return vm


@app.delete("/api/v1/vms/{vm_identifier}")
def delete_database_vm(vm_identifier: str):
    """Delete VM record from SQLite database."""
    deleted = db.delete_vm(vm_identifier)
    if not deleted:
        raise HTTPException(status_code=404, detail=f"VM with identifier '{vm_identifier}' not found")
    return {"status": "deleted", "vm_identifier": vm_identifier}


def main():
    """CLI entrypoint."""
    parser = argparse.ArgumentParser(description="Incus Automation Service")
    parser.add_argument("--host", default="0.0.0.0", help="Host address to bind to (default: 0.0.0.0)")
    parser.add_argument("--port", type=int, default=8000, help="Port to listen on (default: 8000)")
    parser.add_argument("--reload", action="store_true", help="Enable auto-reload on code changes")
    parser.add_argument("--name", type=str, help="CLI mode: VM instance name")
    parser.add_argument("--image", type=str, default="ubuntu-24.04", help="CLI mode: OS image")
    parser.add_argument("--cpu", type=str, default="2", help="CLI mode: CPU cores")
    parser.add_argument("--ram", type=str, default="4GiB", help="CLI mode: RAM size")
    parser.add_argument("--disk", type=str, default="40GiB", help="CLI mode: Disk size")
    parser.add_argument("--lifetime", type=str, default="7d", help="CLI mode: Lifetime (e.g. 7d, 24h)")
    parser.add_argument("--dry-run", action="store_true", help="Run in simulation/dry-run mode")

    args = parser.parse_args()

    if args.name:
        req = VMProvisionRequest(
            vm_name=args.name,
            os_image=args.image,
            cpu_count=args.cpu,
            ram_size=args.ram,
            disk_size=args.disk,
            lifetime=args.lifetime,
            dry_run=args.dry_run
        )
        print(f"Provisioning VM via CLI: {args.name} (dry-run={args.dry_run})...")
        res = provisioner.execute_sync(req)
        print(res.stdout)
        if res.stderr:
            print("STDERR:", res.stderr)
        print(f"Result: {res.message} (Exit Code: {res.exit_code})")
        print(f"Recorded in SQLite: VM_ID={res.vm_identifier}, VALID_THRU={res.valid_thru}")
        return

    uvicorn.run(
        "incus_automation_service.main:app",
        host=args.host,
        port=args.port,
        reload=args.reload
    )


if __name__ == "__main__":
    main()
