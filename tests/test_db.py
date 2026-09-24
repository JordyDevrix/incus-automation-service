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


def test_sqlite_crud(tmp_path):
    test_db = tmp_path / "test_vms.db"
    
    # Init
    db.init_db(test_db)
    
    # Insert
    row = db.register_vm(
        vm_identifier="test-srv-01-abc123",
        valid_thru="2026-01-08 12:00:00",
        vm_name="test-srv-01",
        os_image="ubuntu-24.04",
        cpu="2",
        ram="4GiB",
        disk="40GiB",
        db_path=test_db
    )
    assert row["vm_identifier"] == "test-srv-01-abc123"

    # Fetch
    fetched = db.get_vm("test-srv-01-abc123", db_path=test_db)
    assert fetched is not None
    assert fetched["valid_thru"] == "2026-01-08 12:00:00"
    assert fetched["vm_name"] == "test-srv-01"

    # List
    all_vms = db.list_vms(db_path=test_db)
    assert len(all_vms) == 1

    # Delete
    deleted = db.delete_vm("test-srv-01-abc123", db_path=test_db)
    assert deleted is True
    assert db.get_vm("test-srv-01-abc123", db_path=test_db) is None
