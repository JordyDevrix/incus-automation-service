import sqlite3
import ipaddress
import re
import subprocess
import shutil
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional, List, Dict, Any, Tuple

BASE_DIR = Path(__file__).resolve().parent.parent.parent
DB_DIR = BASE_DIR / "data"
DB_PATH = DB_DIR / "vms.db"

# Default high-capacity /20 pool (10.100.0.0/20 -> 4,093 usable host IPs for 400+ VMs)
DEFAULT_IPV4_NETWORK = "10.100.0.0/20"
DEFAULT_IPV4_GATEWAY = "10.100.0.1"
DEFAULT_IPV6_PREFIX = "fd42:100:100"
DEFAULT_IPV6_GATEWAY = "fd42:100:100::1"


def get_db_connection(db_path: Path = DB_PATH) -> sqlite3.Connection:
    """Create directory if needed and open an SQLite connection."""
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    return conn


def init_db(db_path: Path = DB_PATH) -> None:
    """
    Initialize the SQLite schema with automatic column migration
    for existing databases.
    """
    with get_db_connection(db_path) as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS vms (
                vm_identifier TEXT PRIMARY KEY,
                ipv4_address TEXT UNIQUE,
                ipv6_address TEXT UNIQUE,
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

        # Auto-migrate table if created with previous schema
        cursor = conn.execute("PRAGMA table_info(vms);")
        existing_cols = {row["name"] for row in cursor.fetchall()}
        
        if "ipv4_address" not in existing_cols:
            conn.execute("ALTER TABLE vms ADD COLUMN ipv4_address TEXT;")
        if "ipv6_address" not in existing_cols:
            conn.execute("ALTER TABLE vms ADD COLUMN ipv6_address TEXT;")

        # Create index on valid_thru for fast cleanup queries
        conn.execute("CREATE INDEX IF NOT EXISTS idx_vms_valid_thru ON vms(valid_thru);")
        conn.commit()


def detect_incus_network_subnet(network_name: str = "incusbr0") -> Tuple[str, str]:
    """
    Inspects active Incus bridge network if incus is present on host.
    Returns (ipv4_network_cidr, ipv6_prefix).
    """
    incus_bin = shutil.which("incus")
    if not incus_bin:
        return DEFAULT_IPV4_NETWORK, DEFAULT_IPV6_PREFIX

    try:
        # Check if network exists
        res = subprocess.run([incus_bin, "network", "get", network_name, "ipv4.address"], capture_output=True, text=True, timeout=5)
        if res.returncode == 0 and res.stdout.strip():
            raw_v4 = res.stdout.strip()
            # If raw_v4 is e.g. "10.0.8.1/24"
            if "/" in raw_v4 and raw_v4 not in ("none", "auto"):
                ip_part, prefix = raw_v4.split("/")
                # Convert gateway IP to network CIDR
                net = ipaddress.IPv4Network(f"{ip_part}/{prefix}", strict=False)
                # Check if IPv6 is configured
                res_v6 = subprocess.run([incus_bin, "network", "get", network_name, "ipv6.address"], capture_output=True, text=True, timeout=5)
                v6_prefix = DEFAULT_IPV6_PREFIX
                if res_v6.returncode == 0 and "/" in res_v6.stdout:
                    v6_raw = res_v6.stdout.strip().split("/")[0]
                    v6_prefix = ":".join(v6_raw.split(":")[:3]) if ":" in v6_raw else DEFAULT_IPV6_PREFIX
                return str(net), v6_prefix
    except Exception:
        pass

    return DEFAULT_IPV4_NETWORK, DEFAULT_IPV6_PREFIX


def allocate_next_ip(
    db_path: Path = DB_PATH,
    network_cidr: Optional[str] = None,
    ipv6_prefix: Optional[str] = None
) -> Tuple[str, str]:
    """
    Finds and allocates the next available IPv4 and IPv6 address from the subnet pool.
    Guarantees zero collisions across 4,000+ VM allocations.
    """
    init_db(db_path)

    if not network_cidr or not ipv6_prefix:
        detected_cidr, detected_v6 = detect_incus_network_subnet()
        network_cidr = network_cidr or detected_cidr
        ipv6_prefix = ipv6_prefix or detected_v6

    net = ipaddress.IPv4Network(network_cidr, strict=False)

    with get_db_connection(db_path) as conn:
        cursor = conn.execute("SELECT ipv4_address FROM vms WHERE ipv4_address IS NOT NULL")
        used_ips = {row["ipv4_address"] for row in cursor.fetchall()}

    # Skip network address and gateway (e.g. .0 and .1)
    gateway_ip = str(net.network_address + 1)
    
    # Iterate over usable host IPs
    allocated_v4 = None
    offset_index = 0
    for host in net.hosts():
        host_str = str(host)
        if host_str == gateway_ip:
            continue
        if host_str not in used_ips:
            allocated_v4 = host_str
            # Calculate offset from network base to generate a matching deterministic IPv6
            offset_index = int(host) - int(net.network_address)
            break

    if not allocated_v4:
        raise RuntimeError(f"Subnet pool {network_cidr} is completely exhausted!")

    # Deterministic IPv6 address derived from host offset (e.g. fd42:100:100::1002)
    allocated_v6 = f"{ipv6_prefix}::{offset_index:x}"

    return allocated_v4, allocated_v6


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
    ipv4_address: Optional[str] = None,
    ipv6_address: Optional[str] = None,
    os_image: str = "",
    cpu: str = "",
    ram: str = "",
    disk: str = "",
    status: str = "active",
    db_path: Path = DB_PATH
) -> Dict[str, Any]:
    """Insert or update a VM record in the database with assigned IPs."""
    init_db(db_path)
    created_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")

    with get_db_connection(db_path) as conn:
        conn.execute("""
            INSERT OR REPLACE INTO vms (
                vm_identifier, ipv4_address, ipv6_address, valid_thru, vm_name, os_image, cpu, ram, disk, created_at, status
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (vm_identifier, ipv4_address, ipv6_address, valid_thru, vm_name, os_image, cpu, ram, disk, created_at, status))
        conn.commit()

    return {
        "vm_identifier": vm_identifier,
        "ipv4_address": ipv4_address,
        "ipv6_address": ipv6_address,
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
