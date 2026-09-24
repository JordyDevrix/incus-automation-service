import pytest
from fastapi.testclient import TestClient
from incus_automation_service.main import app

client = TestClient(app)


def test_health_endpoint():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_index_page():
    response = client.get("/")
    assert response.status_code == 200
    assert "Incus VM Provisioner" in response.text


def test_preview_command():
    payload = {
        "vm_name": "preview-srv-01",
        "os_image": "debian-12",
        "cpu_count": "4",
        "ram_size": "8GiB",
        "disk_size": "60GiB",
        "lifetime": "30d"
    }
    response = client.post("/api/v1/preview", json=payload)
    assert response.status_code == 200
    data = response.json()
    assert "preview-srv-01" in data["vm_identifier"]
    assert "scripts/provision_vm.sh" in data["command_preview"]
    assert data["valid_thru"] is not None


def test_provision_vm_endpoint_dry_run():
    payload = {
        "vm_name": "api-direct-vm",
        "os_image": "ubuntu-24.04",
        "admin_ssh_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest",
        "cpu_count": "2",
        "ram_size": "4GiB",
        "disk_size": "40GiB",
        "lifetime": "7d",
        "dry_run": True
    }
    response = client.post("/api/v1/provision", json=payload)
    assert response.status_code == 200
    data = response.json()
    assert data["success"] is True
    assert data["vm_name"] == "api-direct-vm"
    assert data["exit_code"] == 0
    assert "api-direct-vm" in data["stdout"]


def test_sqlite_vms_api():
    # List
    response = client.get("/api/v1/vms")
    assert response.status_code == 200
    assert "vms" in response.json()


def test_invalid_vm_name():
    payload = {
        "vm_name": "invalid name with spaces!",
        "os_image": "ubuntu-24.04"
    }
    response = client.post("/api/v1/preview", json=payload)
    assert response.status_code == 422
