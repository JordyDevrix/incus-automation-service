import uuid
from typing import Optional, List, Dict, Any
from pydantic import BaseModel, Field


class VMProvisionRequest(BaseModel):
    """Payload for provisioning a new Incus VM."""
    vm_name: str = Field(
        default="web-server-01",
        description="Name of the Incus VM instance",
        min_length=1,
        max_length=64,
        pattern=r"^[a-zA-Z0-9][a-zA-Z0-9\._-]*$"
    )
    os_image: str = Field(
        default="ubuntu-24.04",
        description="Operating system image (e.g., ubuntu-24.04, debian-12, alpine-3.20)"
    )
    cpu_count: str = Field(
        default="2",
        description="Number of CPU cores (e.g., 1, 2, 4, 8)"
    )
    ram_size: str = Field(
        default="4GiB",
        description="RAM size (e.g., 2GiB, 4GiB, 8GiB, 16GiB)"
    )
    disk_size: str = Field(
        default="40GiB",
        description="Disk storage size (e.g., 20GiB, 40GiB, 100GiB)"
    )
    admin_user: str = Field(
        default="admin",
        description="Admin username for cloud-init",
        min_length=1,
        max_length=32
    )
    admin_ssh_key: str = Field(
        default="",
        description="Public SSH key for admin access"
    )
    lifetime: str = Field(
        default="7d",
        description="Lifetime duration before cleanup (e.g., 24h, 7d, 30d, persistent)"
    )
    vm_identifier: Optional[str] = Field(
        default=None,
        description="Unique immutable VM identifier (auto-generated if omitted)"
    )
    dry_run: bool = Field(
        default=False,
        description="If True, simulates provisioning without calling Incus"
    )

    def get_effective_identifier(self) -> str:
        """Return provided identifier or generate a clean unique identifier."""
        if self.vm_identifier and self.vm_identifier.strip():
            return self.vm_identifier.strip()
        # Generate clean short identifier prefixed by instance name
        short_id = uuid.uuid4().hex[:8]
        return f"{self.vm_name}-{short_id}"


class VMPreviewResponse(BaseModel):
    """Preview of calculated parameters and CLI command before provisioning."""
    vm_identifier: str
    valid_thru: Optional[str]
    command_preview: str
    params: Dict[str, Any]


class ProvisionResult(BaseModel):
    """Result of running the Incus VM provisioning bash script."""
    success: bool
    vm_name: str
    vm_identifier: str
    valid_thru: Optional[str]
    stdout: str
    stderr: str
    exit_code: int
    duration_seconds: float
    dry_run: bool
    message: str
    timestamp: str
