import sqlite3
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional, List, Dict, Any

BASE_DIR = Path(__file__).resolve().parent.parent.parent
DB_DIR = BASE_DIR / "data"
DB_PATH = DB_DIR / "vms.db"


def get_db_connection(db_path: Path = DB_PATH) -> sqlite3.Connection:
    """Create directory if needed and open an SQLite connection."""
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    return conn


def init_db(db_path: Path = DB_PATH) -> None:
    """Initialize the SQLite schema."""
    with get_db_connection(db_path) as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS vms (
                vm_identifier TEXT PRIMARY KEY,
                valid_thru TEXT,
                vm_name TEXT,
                os_image TEXT,
                cpu TEXT,
                ram TEXT,
                disk TEXT,
                created_at TEXT,
                status TEXT
            );
        """)
        conn.commit()


def calculate_valid_thru(lifetime_str: str, base_time: Optional[datetime] = None) -> Optional[str]:
    """
    Parses human lifetime string (e.g., '24h', '7d', '30d', 'persistent')
    and returns ISO-8601 UTC string for valid_thru.
    """
    if not lifetime_str or lifetime_str.lower() in ("persistent", "forever", "none", "infinite", "0"):
        return None

    if base_time is None:
        base_time = datetime.now(timezone.utc)
    elif base_time.tzinfo is None:
        base_time = base_time.replace(tzinfo=timezone.utc)

    # Match digits + unit (e.g. 7d, 24h, 60m, 2w, 1m)
    match = re.match(r"^(\d+)\s*([a-zA-Z]+)$", lifetime_str.strip())
    if not match:
        # Default to 7 days if unrecognized
        target = base_time + timedelta(days=7)
        return target.strftime("%Y-%m-%d %H:%M:%S")

    amount = int(match.group(1))
    unit = match.group(2).lower()

    if unit in ("h", "hr", "hrs", "hour", "hours"):
        delta = timedelta(hours=amount)
    elif unit in ("d", "day", "days"):
        delta = timedelta(days=amount)
    elif unit in ("w", "wk", "week", "weeks"):
        delta = timedelta(weeks=amount)
    elif unit in ("m", "min", "mins", "minute", "minutes"):
        delta = timedelta(minutes=amount)
    elif unit in ("mon", "month", "months"):
        delta = timedelta(days=amount * 30)
    else:
        delta = timedelta(days=amount)

    target_time = base_time + delta
    return target_time.strftime("%Y-%m-%d %H:%M:%S")


def register_vm(
    vm_identifier: str,
    valid_thru: Optional[str],
    vm_name: str,
    os_image: str = "",
    cpu: str = "",
    ram: str = "",
    disk: str = "",
    status: str = "active",
    db_path: Path = DB_PATH
) -> Dict[str, Any]:
    """Insert or update a VM record in the database."""
    init_db(db_path)
    created_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")

    with get_db_connection(db_path) as conn:
        conn.execute("""
            INSERT OR REPLACE INTO vms (
                vm_identifier, valid_thru, vm_name, os_image, cpu, ram, disk, created_at, status
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (vm_identifier, valid_thru, vm_name, os_image, cpu, ram, disk, created_at, status))
        conn.commit()

    return {
        "vm_identifier": vm_identifier,
        "valid_thru": valid_thru,
        "vm_name": vm_name,
        "os_image": os_image,
        "cpu": cpu,
        "ram": ram,
        "disk": disk,
        "created_at": created_at,
        "status": status
    }


def list_vms(db_path: Path = DB_PATH) -> List[Dict[str, Any]]:
    """Return all VM records from the database."""
    init_db(db_path)
    with get_db_connection(db_path) as conn:
        cursor = conn.execute("SELECT * FROM vms ORDER BY created_at DESC")
        rows = cursor.fetchall()
        return [dict(row) for row in rows]


def get_vm(vm_identifier: str, db_path: Path = DB_PATH) -> Optional[Dict[str, Any]]:
    """Fetch single VM record by identifier."""
    init_db(db_path)
    with get_db_connection(db_path) as conn:
        cursor = conn.execute("SELECT * FROM vms WHERE vm_identifier = ?", (vm_identifier,))
        row = cursor.fetchone()
        return dict(row) if row else None


def delete_vm(vm_identifier: str, db_path: Path = DB_PATH) -> bool:
    """Delete a VM record by identifier."""
    init_db(db_path)
    with get_db_connection(db_path) as conn:
        cursor = conn.execute("DELETE FROM vms WHERE vm_identifier = ?", (vm_identifier,))
        conn.commit()
        return cursor.rowcount > 0
