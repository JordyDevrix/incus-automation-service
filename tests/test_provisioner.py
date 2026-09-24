import pytest
from pathlib import Path
from incus_automation_service.provisioner import VMProvisioner
from incus_automation_service.models import VMProvisionRequest


@pytest.mark.asyncio
async def test_provisioner_dry_run():
    req = VMProvisionRequest(
        vm_name="test-direct-vm",
        vm_identifier="test-direct-vm-12345",
        os_image="ubuntu-24.04",
        cpu_count="2",
        ram_size="4GiB",
        disk_size="40GiB",
        admin_user="admin",
        admin_ssh_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey",
        lifetime="7d",
        dry_run=True
    )
    
    provisioner = VMProvisioner()
    result = await provisioner.execute_async(req)
    
    assert result.success is True
    assert result.exit_code == 0
    assert result.dry_run is True
    assert result.vm_identifier == "test-direct-vm-12345"
    assert "test-direct-vm" in result.stdout
    assert "limits.cpu" in result.stdout
