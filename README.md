# Incus Automation Service

A low-maintenance, single-source-of-truth Incus VM automation service featuring a **multi-step form wizard**, a direct **standalone bash provisioning pipeline**, and **SQLite retention tracking** (`vm_identifier` $\leftrightarrow$ `valid_thru`).

---

## 🎯 Architecture & Key Features

- **Single Source of Truth**: No YAML templates or config files to maintain. The provisioning logic lives solely in [`scripts/provision_vm.sh`](scripts/provision_vm.sh).
- **Page-by-Page Form Wizard**:
  - **Step 1: Workload Identity**: VM name validation, OS image selector (Ubuntu, Debian, Alpine, Arch, Custom), and unique VM identifier.
  - **Step 2: Hardware Resources**: Quick presets (*Small*, *Medium*, *Large*) and custom CPU, RAM, and Disk allocations.
  - **Step 3: Access & Auth**: Admin cloud-init user and SSH public key input.
  - **Step 4: Lifetime & Retention**: Expiration duration (`24h`, `7d`, `30d`, `persistent`) with real-time `valid_thru` date calculation.
  - **Step 5: Review & Provision**: Command preview, execution logs terminal, and SQLite registration.
- **SQLite Database Tracking**:
  - Automatically records `vm_identifier`, `valid_thru`, `vm_name`, `created_at`, and `status` in `data/vms.db`.
- **Periodic Cleanup Script**:
  - Includes [`scripts/cleanup_expired_vms.sh`](scripts/cleanup_expired_vms.sh) for cron/systemd timers to delete expired VMs based on the SQLite `valid_thru` timestamp.

---

## 📁 Project Structure

```
.
├── pyproject.toml                         # Dependencies and build settings
├── scripts/
│   ├── provision_vm.sh                   # Main provisioning bash script (Single source of truth)
│   └── cleanup_expired_vms.sh            # Periodic deletion script for expired VMs
├── src/
│   └── incus_automation_service/
│       ├── __init__.py
│       ├── main.py                       # FastAPI application & entrypoint
│       ├── db.py                         # SQLite database manager
│       ├── models.py                     # Pydantic data schemas
│       ├── provisioner.py                # Async bash runner & DB recorder
│       └── templates/
│           └── index.html                # Multi-step page-to-page form wizard
├── data/                                 # SQLite database storage (vms.db)
└── tests/
    ├── test_api.py                       # API endpoint tests
    ├── test_db.py                        # SQLite CRUD & expiration calculation tests
    └── test_provisioner.py               # Provisioner execution tests
```

---

## 🚀 Quick Start

### 1. Start the Web Service

```bash
uv run incus-automation-service
```
Or with auto-reload:
```bash
uv run uvicorn incus_automation_service.main:app --reload --host 0.0.0.0 --port 8000
```

Open your browser at:
**[http://localhost:8000](http://localhost:8000)**

---

## 💻 Standalone Bash Usage (Direct Execution)

You can provision a VM directly with the bash script:

```bash
bash scripts/provision_vm.sh \
  --name "web-server-01" \
  --image "ubuntu-24.04" \
  --cpu "2" \
  --ram "4GiB" \
  --disk "40GiB" \
  --user "admin" \
  --ssh-key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5..." \
  --lifetime "7d" \
  --vm-id "web-server-01-abc123"
```

To run in simulation / dry-run mode:
```bash
bash scripts/provision_vm.sh --name "test-vm" --dry-run
```

---

## 🗄️ SQLite Database Schema & Periodic Deletion

The database at `data/vms.db` stores:

| Column | Type | Description |
| :--- | :--- | :--- |
| `vm_identifier` | `TEXT PRIMARY KEY` | Unique immutable workload identifier |
| `valid_thru` | `TEXT` | Expiration date (`YYYY-MM-DD HH:MM:SS`) or `NULL` for persistent |
| `vm_name` | `TEXT` | Instance name |
| `os_image` | `TEXT` | OS image alias or remote |
| `cpu`, `ram`, `disk` | `TEXT` | Sizing specifications |
| `created_at` | `TEXT` | Creation timestamp |
| `status` | `TEXT` | `active`, `dry_run`, or `failed` |

### Periodic Cleanup Script
Run periodically via cron (`crontab -e`) to clean up expired VMs:

```bash
# Clean up expired VMs using SQLite valid_thru query
bash scripts/cleanup_expired_vms.sh
```

Example crontab entry (runs every hour):
```cron
0 * * * * cd /path/to/incus-automation-service && bash scripts/cleanup_expired_vms.sh >> /var/log/incus-cleanup.log 2>&1
```

---

## 📡 REST API Reference

- `GET /` — Step-by-step wizard UI
- `POST /api/v1/preview` — Preview calculated command and `valid_thru` date
- `POST /api/v1/provision` — Provision VM via bash script and register in SQLite
- `GET /api/v1/vms` — List all registered workloads in SQLite
- `GET /api/v1/vms/{vm_identifier}` — Fetch single workload by ID
- `DELETE /api/v1/vms/{vm_identifier}` — Remove workload record from DB
- `GET /health` — Service health status

---

## 🧪 Running Tests

```bash
uv run pytest -v
```
