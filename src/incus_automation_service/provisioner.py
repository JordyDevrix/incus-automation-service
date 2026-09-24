import asyncio
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from .models import VMProvisionRequest, ProvisionResult
from . import db

BASE_DIR = Path(__file__).resolve().parent.parent.parent
DEFAULT_SCRIPT_PATH = BASE_DIR / "scripts" / "provision_vm.sh"


class VMProvisioner:
    """Executes the provisioning bash script directly with CLI flags."""

    def __init__(self, script_path: Path = DEFAULT_SCRIPT_PATH):
        self.script_path = script_path

    async def execute_async(
        self,
        request: VMProvisionRequest,
        timeout_seconds: int = 300
    ) -> ProvisionResult:
        """
        Executes scripts/provision_vm.sh asynchronously with CLI arguments.
        """
        script_file_str = str(self.script_path.resolve())

        if not os.path.isfile(script_file_str):
            raise FileNotFoundError(f"Provisioning script not found at {script_file_str}")

        vm_identifier = request.get_effective_identifier()
        valid_thru = db.calculate_valid_thru(request.lifetime)

        # Build CLI arguments
        cmd_args = [
            "bash",
            script_file_str,
            "--name", request.vm_name,
            "--image", request.os_image,
            "--cpu", str(request.cpu_count),
            "--ram", str(request.ram_size),
            "--disk", str(request.disk_size),
            "--user", request.admin_user,
            "--lifetime", request.lifetime,
            "--vm-id", vm_identifier
        ]

        if request.admin_ssh_key:
            cmd_args.extend(["--ssh-key", request.admin_ssh_key])

        if request.dry_run:
            cmd_args.append("--dry-run")

        env = os.environ.copy()
        if request.dry_run:
            env["DRY_RUN"] = "1"

        start_time = time.time()
        timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")

        try:
            process = await asyncio.create_subprocess_exec(
                *cmd_args,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                env=env
            )

            stdout_bytes, stderr_bytes = await asyncio.wait_for(
                process.communicate(),
                timeout=timeout_seconds
            )
            exit_code = process.returncode if process.returncode is not None else -1
            stdout = stdout_bytes.decode("utf-8", errors="replace")
            stderr = stderr_bytes.decode("utf-8", errors="replace")

        except asyncio.TimeoutError:
            exit_code = -1
            stdout = ""
            stderr = f"Execution timed out after {timeout_seconds} seconds"
        except Exception as exc:
            exit_code = -1
            stdout = ""
            stderr = f"Error executing provisioning script: {exc}"

        duration = round(time.time() - start_time, 2)
        success = (exit_code == 0)
        message = "VM provisioned successfully" if success else f"Provisioning failed with exit code {exit_code}"

        # Register VM record in SQLite database
        try:
            status_str = "active" if success else "failed"
            if request.dry_run:
                status_str = "dry_run"
            db.register_vm(
                vm_identifier=vm_identifier,
                valid_thru=valid_thru,
                vm_name=request.vm_name,
                os_image=request.os_image,
                cpu=str(request.cpu_count),
                ram=str(request.ram_size),
                disk=str(request.disk_size),
                status=status_str
            )
        except Exception as db_err:
            stderr += f"\n[WARN] Failed to write to SQLite DB: {db_err}"

        return ProvisionResult(
            success=success,
            vm_name=request.vm_name,
            vm_identifier=vm_identifier,
            valid_thru=valid_thru,
            stdout=stdout,
            stderr=stderr,
            exit_code=exit_code,
            duration_seconds=duration,
            dry_run=request.dry_run,
            message=message,
            timestamp=timestamp
        )

    def execute_sync(
        self,
        request: VMProvisionRequest,
        timeout_seconds: int = 300
    ) -> ProvisionResult:
        """Synchronous execution wrapper."""
        return asyncio.run(self.execute_async(request, timeout_seconds=timeout_seconds))
