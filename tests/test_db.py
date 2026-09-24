import pytest
from datetime import datetime, timezone
from pathlib import Path
from incus_automation_service import db


def test_calculate_valid_thru():
    base = datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc)
    
    # 24 hours
    res_24h = db.calculate_valid_thru("24h", base_time=base)
    assert res_24h == "2026-01-02 12:00:00"

    # 7 days
    res_7d = db.calculate_valid_thru("7d", base_time=base)
    assert res_7d == "2026-01-08 12:00:00"

    # Persistent
    res_inf = db.calculate_valid_thru("persistent", base_time=base)
    assert res_inf is None


def test_allocate_next_ip_pool(tmp_path):
    test_db = tmp_path / "test_ip_vms.db"
    db.init_db(test_db)

    # First allocation (skips gateway 10.100.0.1 -> 10.100.0.2)
    ip4_1, ip6_1 = db.allocate_next_ip(db_path=test_db)
    assert ip4_1 == "10.100.0.2"
    assert "fd42:100:100" in ip6_1

    # Register first VM
    db.register_vm(
        vm_identifier="student-vm-001",
        valid_thru=None,
        vm_name="student-vm-001",
        ipv4_address=ip4_1,
        ipv6_address=ip6_1,
        db_path=test_db
    )

    # Second allocation (should get 10.100.0.3)
    ip4_2, ip6_2 = db.allocate_next_ip(db_path=test_db)
    assert ip4_2 == "10.100.0.3"
    assert ip4_2 != ip4_1

    # Test scaling to 450 student VMs without collision
    allocated_set = {ip4_1, ip4_2}
    db.register_vm(
        vm_identifier="student-vm-002",
        valid_thru=None,
        vm_name="student-vm-002",
        ipv4_address=ip4_2,
        ipv6_address=ip6_2,
        db_path=test_db
    )

    for i in range(3, 450):
        v4, v6 = db.allocate_next_ip(db_path=test_db)
        assert v4 not in allocated_set
        allocated_set.add(v4)
        db.register_vm(
            vm_identifier=f"student-vm-{i:03d}",
            valid_thru=None,
            vm_name=f"student-vm-{i:03d}",
            ipv4_address=v4,
            ipv6_address=v6,
            db_path=test_db
        )

    assert len(allocated_set) == 449


def test_sqlite_crud(tmp_path):
    test_db = tmp_path / "test_vms.db"
    
    # Init
    db.init_db(test_db)
    
    # Insert
    row = db.register_vm(
        vm_identifier="test-srv-01-abc123",
        valid_thru="2026-01-08 12:00:00",
        vm_name="test-srv-01",
        ipv4_address="10.100.0.5",
        ipv6_address="fd42:100:100::5",
        os_image="ubuntu-24.04",
        cpu="2",
        ram="4GiB",
        disk="40GiB",
        db_path=test_db
    )
    assert row["vm_identifier"] == "test-srv-01-abc123"
    assert row["ipv4_address"] == "10.100.0.5"

    # Fetch
    fetched = db.get_vm("test-srv-01-abc123", db_path=test_db)
    assert fetched is not None
    assert fetched["valid_thru"] == "2026-01-08 12:00:00"
    assert fetched["ipv4_address"] == "10.100.0.5"

    # List
    all_vms = db.list_vms(db_path=test_db)
    assert len(all_vms) == 1

    # Delete
    deleted = db.delete_vm("test-srv-01-abc123", db_path=test_db)
    assert deleted is True
    assert db.get_vm("test-srv-01-abc123", db_path=test_db) is None
