#!/usr/bin/env python3
"""
RDMA Exporter for Prometheus — RoCEv2 + GPUDirect RDMA Observability

Collects deep RDMA metrics from:
  - /sys/class/infiniband/<dev>/ports/1/counters/      (port counters)
  - /sys/class/infiniband/<dev>/ports/1/hw_counters/    (hardware counters: ECN, CNP, etc.)
  - `rdma res list qp/pd/mr/cq`                         (active QPs, PDs, MRs, CQs)
  - `rdma link` / `rdma dev`                            (link state, device info)
  - GID table from sysfs                                (RoCE routing addresses)
  - `ethtool -S <netdev>`                               (PFC pause frames, ECN marks)
  - `nvidia-smi topo -m`                                (GPU-to-NIC PCIe topology)
  - `nvidia-smi --query-gpu`                            (GPU UUIDs, PCI bus IDs)
  - `lsmod | grep peermem`                              (GPUDirect RDMA peermem status)

Exposes all metrics in Prometheus text format on port 9402.
No external dependencies — Python 3 stdlib only.

Dynamic configuration via environment variables (see ConfigMap / .env):
  NVIDIA_SMI_PATH         Explicit nvidia-smi path (empty = auto-discover)
  NVIDIA_LD_LIBRARY_PATH  LD_LIBRARY_PATH for nvidia-smi (default /run/nvidia/driver/usr/lib64)
  HOST_ROOT               Chroot root for host binaries (default /host)
  CACHE_TTL               Device/topology cache TTL in seconds (default 60)
  METRICS_CACHE_TTL       Background collection interval (default 10)
  ENABLE_GPU              Set to 0 to skip GPU discovery (default 1)
  ENABLE_ETHTOOL          Set to 0 to skip ethtool queries (default 1)
  ENABLE_RDMA_RES         Set to 0 to skip rdma res list queries (default 1)
  LOG_LEVEL               debug|info|warn (default info)
  SCRAPE_TIMEOUT          Per-command timeout in seconds (default 30)
  RDMA_EXPORTER_PORT      Listen port (default 9402)
  RDMA_EXPORTER_ADDR      Listen address (default 0.0.0.0)
"""

import http.server
import json
import os
import re
import subprocess
import sys
import time
import threading
import traceback
import concurrent.futures
import urllib.request
import urllib.error
import urllib.parse

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------
EXPORTER_VERSION = "3.2.2"

# ---------------------------------------------------------------------------
# Configuration — all read from environment, with defaults
# ---------------------------------------------------------------------------

LISTEN_PORT = int(os.environ.get("RDMA_EXPORTER_PORT", "9402"))
LISTEN_ADDR = os.environ.get("RDMA_EXPORTER_ADDR", "0.0.0.0")
HOST_ROOT = os.environ.get("HOST_ROOT", "/host")
SYS_INFINIBAND = os.environ.get("SYS_INFINIBAND", "/sys/class/infiniband")
SYS_NET = os.environ.get("SYS_NET", "/sys/class/net")

CACHE_TTL = int(os.environ.get("CACHE_TTL", "60"))
METRICS_CACHE_TTL = int(os.environ.get("METRICS_CACHE_TTL", "10"))
SCRAPE_TIMEOUT = int(os.environ.get("SCRAPE_TIMEOUT", "30"))

ENABLE_GPU = os.environ.get("ENABLE_GPU", "1") == "1"
ENABLE_ETHTOOL = os.environ.get("ENABLE_ETHTOOL", "1") == "1"
ENABLE_RDMA_RES = os.environ.get("ENABLE_RDMA_RES", "1") == "1"

LOG_LEVEL = os.environ.get("LOG_LEVEL", "info").lower()

NVIDIA_SMI_PATH_EXPLICIT = os.environ.get("NVIDIA_SMI_PATH", "").strip() or None
NVIDIA_LD_LIBRARY_PATH = os.environ.get(
    "NVIDIA_LD_LIBRARY_PATH", "/run/nvidia/driver/usr/lib64"
)

# Aggregation (built-in — no separate pod needed)
AGGREGATE_CACHE_TTL = int(os.environ.get("AGGREGATE_CACHE_TTL", "10"))
AGGREGATE_SCRAPE_TIMEOUT = int(os.environ.get("AGGREGATE_SCRAPE_TIMEOUT", "10"))
AGGREGATE_MAX_WORKERS = int(os.environ.get("AGGREGATE_MAX_WORKERS", "16"))

# Cluster identity — inject as `environment` label on every metric for multi-cluster federation.
# Set via helm value `clusterName` (becomes CLUSTER_NAME env var). Empty = no label added.
CLUSTER_NAME = os.environ.get("CLUSTER_NAME", "").strip()

# K8s in-cluster API (auto-configured from mounted service account)
_K8S_API = f"https://{os.environ.get('KUBERNETES_SERVICE_HOST', 'kubernetes.default.svc')}:{os.environ.get('KUBERNETES_SERVICE_PORT', '443')}"
_SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def _log(level, msg):
    if {"debug": 0, "info": 1, "warn": 2}.get(LOG_LEVEL, 1) <= {"debug": 0, "info": 1, "warn": 2}.get(level, 1):
        print(f"[{level.upper()}] {msg}", file=sys.stderr)

def log_debug(msg): _log("debug", msg)
def log_info(msg):  _log("info",  msg)
def log_warn(msg):  _log("warn",  msg)

# ---------------------------------------------------------------------------
# nvidia-smi discovery
# ---------------------------------------------------------------------------

# Candidate paths to search for nvidia-smi on the host filesystem.
# Ordered by likelihood on a typical GPU Operator deployment.
_NVIDIA_SMI_CANDIDATES = [
    f"{HOST_ROOT}/usr/bin/nvidia-smi",
    f"{HOST_ROOT}/run/nvidia/driver/usr/bin/nvidia-smi",
    f"{HOST_ROOT}/usr/local/bin/nvidia-smi",
    f"{HOST_ROOT}/opt/nvidia/nsight-systems-cli/bin/nvidia-smi",
    f"{HOST_ROOT}/usr/libexec/nvidia/bin/nvidia-smi",
    f"{HOST_ROOT}/bin/nvidia-smi",
    f"{HOST_ROOT}/sbin/nvidia-smi",
]

def _find_nvidia_smi():
    """Find nvidia-smi on the host. Returns (path, chroot_relative_path).

    Quiet by design — logging of state transitions is handled by
    _ensure_nvidia_smi() so repeated calls (every cache refresh) don't spam.
    """
    # Explicit override via env var
    if NVIDIA_SMI_PATH_EXPLICIT:
        full = NVIDIA_SMI_PATH_EXPLICIT
        if os.path.exists(full):
            chroot_rel = full.replace(HOST_ROOT, "", 1)
            return full, chroot_rel
        return None, None

    for candidate in _NVIDIA_SMI_CANDIDATES:
        if os.path.exists(candidate):
            chroot_rel = candidate.replace(HOST_ROOT, "", 1)
            return candidate, chroot_rel
    return None, None

# nvidia-smi is discovered at startup AND re-evaluated on every DeviceCache
# refresh (every CACHE_TTL seconds). The NVIDIA GPU Operator driver container
# extracts nvidia-smi to /run/nvidia/driver/usr/bin/ asynchronously; if this
# exporter starts before that extraction completes (e.g. on a node that just
# recovered from NotReady), a one-shot startup discovery would permanently
# cache "no nvidia-smi" for the pod's lifetime and emit stub GPU metrics.
# Re-checking on each refresh lets the exporter self-heal once the driver
# container finishes — no pod restart required.
_NVIDIA_SMI_PATH = None
_NVIDIA_SMI_CHROOT_PATH = None
_USE_CHROOT = False
_NVIDIA_ISOLATED_DIR = "/tmp/nvidia-isolated"
_nvidia_smi_last_logged = None  # last reported state, to log only on transitions

def _setup_nvidia_isolated_dir():
    """Create an isolated lib dir on the host containing only libnvidia-ml.so.

    The host's /run/nvidia/driver/usr/lib64/ contains BOTH libnvidia-ml.so AND
    the host's libc.so.6 (glibc 2.35). If LD_LIBRARY_PATH points there, the
    dynamic linker picks up the host's glibc, causing:
      "symbol lookup error: libc.so.6: undefined symbol: __rtld_libc_freeres, GLIBC_PRIVATE"
    Symlinking only the nvidia ML lib into an isolated dir makes the container's
    glibc (in /lib64) be used instead. Idempotent and safe to call repeatedly.
    """
    host_iso_dir = f"{HOST_ROOT}{_NVIDIA_ISOLATED_DIR}"
    try:
        os.makedirs(host_iso_dir, exist_ok=True)
    except OSError:
        return
    for lib in ("libnvidia-ml.so.580.126.20", "libnvidia-ml.so.1", "libnvidia-ml.so"):
        src = f"/run/nvidia/driver/usr/lib64/{lib}"
        dst = f"{host_iso_dir}/{lib}"
        if os.path.exists(f"{HOST_ROOT}{src}") and not os.path.exists(dst):
            try:
                os.symlink(src, dst)
            except OSError:
                pass
    try:
        os.chmod(host_iso_dir, 0o755)
    except OSError:
        pass

def _ensure_nvidia_smi():
    """(Re)discover nvidia-smi and update the chroot globals.

    Called at startup and on every DeviceCache.refresh(). Only logs on state
    transitions (None<->found) to avoid flooding the log on each refresh.
    """
    global _NVIDIA_SMI_PATH, _NVIDIA_SMI_CHROOT_PATH, _USE_CHROOT, _nvidia_smi_last_logged

    path, chroot_rel = _find_nvidia_smi()

    if path is not None:
        use_chroot = os.path.isdir(HOST_ROOT)
        # Transitioning into chroot for the first time -> set up isolated libs.
        if use_chroot and not _USE_CHROOT:
            _setup_nvidia_isolated_dir()
        _NVIDIA_SMI_PATH = path
        _NVIDIA_SMI_CHROOT_PATH = chroot_rel
        _USE_CHROOT = use_chroot
    else:
        _NVIDIA_SMI_PATH = None
        _NVIDIA_SMI_CHROOT_PATH = None
        _USE_CHROOT = False

    state = _NVIDIA_SMI_PATH or "none"
    if state != _nvidia_smi_last_logged:
        if _NVIDIA_SMI_PATH is not None:
            log_info(f"nvidia-smi: discovered at {_NVIDIA_SMI_PATH} (chroot={_USE_CHROOT})")
        else:
            log_warn("nvidia-smi: not found in any candidate path (will retry on next cache refresh)")
        _nvidia_smi_last_logged = state

# Initial discovery at startup.
_ensure_nvidia_smi()
log_info(f"Chroot: {_USE_CHROOT}, nvidia-smi: {_NVIDIA_SMI_PATH}, isolated_lib: {_NVIDIA_ISOLATED_DIR}")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def read_file(path):
    """Read a sysfs file, return stripped string or None."""
    try:
        with open(path, "r") as f:
            return f.read().strip()
    except (IOError, OSError):
        return None

def read_file_int(path):
    """Read a sysfs file, return int or None."""
    val = read_file(path)
    if val is None:
        return None
    try:
        return int(val)
    except ValueError:
        try:
            return int(val, 16)  # some sysfs files are hex
        except ValueError:
            return None

def run_cmd(cmd, timeout=None):
    """Run a shell command, return stdout string or empty."""
    if timeout is None:
        timeout = SCRAPE_TIMEOUT
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return result.stdout.strip()
    except (subprocess.TimeoutExpired, Exception):
        return ""

def run_host_cmd(cmd, timeout=None):
    """Run a command on the host filesystem via chroot."""
    if not _USE_CHROOT:
        return run_cmd(cmd, timeout=timeout)
    if timeout is None:
        timeout = SCRAPE_TIMEOUT

    # If the command starts with nvidia-smi, substitute the discovered path
    # and use the isolated lib directory (no host glibc — avoids GLIBC_PRIVATE conflict)
    if cmd.strip().startswith("nvidia-smi") and _NVIDIA_SMI_CHROOT_PATH:
        cmd = cmd.replace("nvidia-smi", _NVIDIA_SMI_CHROOT_PATH, 1)
        return run_cmd(
            f"chroot {HOST_ROOT} env LD_LIBRARY_PATH={_NVIDIA_ISOLATED_DIR} {cmd}",
            timeout=timeout,
        )
    return run_cmd(f"chroot {HOST_ROOT} {cmd}", timeout=timeout)

def get_hostname():
    """Get the node hostname from the environment or OS."""
    node_name = os.environ.get("NODE_NAME", "")
    if node_name:
        return node_name
    try:
        with open("/proc/sys/kernel/hostname", "r") as f:
            return f.read().strip()
    except Exception:
        return "unknown"

HOSTNAME = get_hostname()

# ---------------------------------------------------------------------------
# Error tracking (for /metrics/errors)
# ---------------------------------------------------------------------------

_last_collection_error = None
_last_collection_time = 0

# ---------------------------------------------------------------------------
# Device Discovery
# ---------------------------------------------------------------------------

class DeviceCache:
    """Cache for slow-changing data: devices, GIDs, topology, peermem."""

    def __init__(self):
        self.timestamp = 0
        self.devices = []       # list of dicts with dev, port, netdev, state, ...
        self.gids = {}          # dev_name -> list of gid dicts
        self.gpu_topology = {}  # gpu_index -> {uuid, pci_bus, name, numa, nic_affinity}
        self.gpu_to_vf = {}     # gpu_index -> vf_dev_name
        self.vf_to_gpu = {}     # vf_dev_name -> gpu_index
        self.gpu_to_pfs = {}    # gpu_index -> list of pf_dev_names (DirectRDMA/nmstate era)
        self.peermem_loaded = 0
        self.pf_netdevs = {}    # dev_name -> netdev (for ethtool)

    def is_valid(self):
        return time.time() - self.timestamp < CACHE_TTL

    def refresh(self):
        """Re-discover all devices, GIDs, topology."""
        # Re-check nvidia-smi first: the GPU Operator driver container may have
        # finished extracting it since startup (e.g. on a node recovering from
        # NotReady). This self-heals chroot/GPU discovery without a pod restart.
        _ensure_nvidia_smi()
        self.devices = self._discover_devices()
        self.gids = self._discover_gids()
        if ENABLE_GPU:
            self.gpu_topology = self._discover_gpu_topology()
            self.gpu_to_vf, self.vf_to_gpu = self._build_gpu_vf_mapping()
            self.gpu_to_pfs = self._build_gpu_pf_mapping()
            self.peermem_loaded = self._check_peermem()
        else:
            self.gpu_topology = {}
            self.gpu_to_vf = {}
            self.vf_to_gpu = {}
            self.gpu_to_pfs = {}
            self.peermem_loaded = 0
        self.pf_netdevs = self._build_pf_netdevs()
        self.timestamp = time.time()
        log_debug(
            f"Cache refreshed: {len(self.devices)} devices, "
            f"{len(self.gpu_topology)} GPUs, "
            f"peermem={self.peermem_loaded}"
        )

    def _discover_devices(self):
        devices = []

        # Parse `rdma dev` for firmware, node_guid, protocol
        dev_info = {}
        dev_output = run_cmd("rdma dev 2>/dev/null")
        for line in dev_output.split("\n"):
            m = re.match(
                r'\d+:\s+(\S+):\s+node_type\s+(\S+)\s+protocol\s+(\S+)\s+fw\s+(\S+)\s+node_guid\s+(\S+)\s+sys_image_guid\s+(\S+)',
                line
            )
            if m:
                dev_name = m.group(1)
                dev_info[dev_name] = {
                    "node_type": m.group(2),
                    "protocol": m.group(3),
                    "fw": m.group(4),
                    "node_guid": m.group(5),
                    "sys_image_guid": m.group(6),
                }

        # Parse `rdma link` for state, netdev, rate
        link_output = run_cmd("rdma link 2>/dev/null")
        for line in link_output.split("\n"):
            m = re.match(
                r'link\s+(\S+)/(\d+)\s+state\s+(\S+)\s+physical_state\s+(\S+)(?:\s+netdev\s+(\S+))?',
                line
            )
            if m:
                dev_name = m.group(1)
                port = int(m.group(2))
                state = m.group(3)
                phys_state = m.group(4)
                netdev = m.group(5) or ""

                rate = 0
                rate_str = read_file(f"{SYS_INFINIBAND}/{dev_name}/ports/{port}/rate")
                if rate_str:
                    m2 = re.match(r'(\d+)', rate_str)
                    if m2:
                        rate = int(m2.group(1))

                info = dev_info.get(dev_name, {})
                devices.append({
                    "dev": dev_name,
                    "port": port,
                    "netdev": netdev,
                    "state": state,
                    "phys_state": phys_state,
                    "rate": rate,
                    "node_guid": info.get("node_guid", ""),
                    "sys_image_guid": info.get("sys_image_guid", ""),
                    "fw": info.get("fw", ""),
                    "protocol": info.get("protocol", ""),
                    "node_type": info.get("node_type", ""),
                })

        return devices

    def _discover_gids(self):
        gids = {}
        for dev_info in self.devices:
            dev = dev_info["dev"]
            port = dev_info["port"]
            gids_dir = f"{SYS_INFINIBAND}/{dev}/ports/{port}/gids"
            types_dir = f"{SYS_INFINIBAND}/{dev}/ports/{port}/gid_attrs/types"
            ndevs_dir = f"{SYS_INFINIBAND}/{dev}/ports/{port}/gid_attrs/ndevs"

            if not os.path.isdir(gids_dir):
                continue
            try:
                gid_indices = sorted(os.listdir(gids_dir), key=lambda x: int(x) if x.isdigit() else 999)
            except OSError:
                continue

            for idx_name in gid_indices:
                gid_val = read_file(f"{gids_dir}/{idx_name}")
                if not gid_val:
                    continue
                if gid_val.replace("0", "").replace(":", "").strip() == "":
                    continue

                gid_type = read_file(f"{types_dir}/{idx_name}") or ""
                ver = "v2" if "v2" in gid_type.lower() else ("v1" if "v1" in gid_type.lower() else "")
                netdev = read_file(f"{ndevs_dir}/{idx_name}") or ""

                gids.setdefault(dev, []).append({
                    "port": port,
                    "index": int(idx_name) if idx_name.isdigit() else 0,
                    "gid": gid_val,
                    "ver": ver,
                    "netdev": netdev,
                })
        return gids

    def _discover_gpu_topology(self):
        topology = {}
        if not _USE_CHROOT:
            log_debug("GPU discovery skipped: chroot unavailable")
            return topology

        gpu_output = run_host_cmd(
            "nvidia-smi --query-gpu=index,gpu_uuid,name,pci.bus_id --format=csv,noheader 2>/dev/null",
            timeout=15
        )
        if not gpu_output:
            log_debug("GPU discovery: nvidia-smi returned no GPU output")
            return topology

        for line in gpu_output.split("\n"):
            parts = [p.strip() for p in line.split(",")]
            if len(parts) >= 4 and parts[0].isdigit():
                idx = int(parts[0])
                topology[idx] = {
                    "uuid": parts[1],
                    "name": parts[2],
                    "pci_bus": parts[3],
                    "numa": "",
                    "nic_affinity": {},
                }

        if not topology:
            return topology

        # Get topology matrix (PCIe affinity + NUMA)
        topo_output = run_host_cmd("nvidia-smi topo -m 2>/dev/null", timeout=15)
        if not topo_output:
            log_debug("GPU discovery: nvidia-smi topo returned no output")
            return topology

        lines = topo_output.split("\n")

        # Parse GPU rows: GPU0, GPU1, ... columns = NIC0, NIC1, ...
        nic_legend = {}
        in_legend = False
        for line in lines:
            if "NIC Legend" in line:
                in_legend = True
                continue
            if in_legend:
                m = re.match(r'\s*(NIC\d+):\s+(\S+)', line)
                if m:
                    nic_legend[m.group(1)] = m.group(2)

        for line in lines:
            m = re.match(r'^(GPU(\d+))\t(.+)', line)
            if not m:
                continue
            gpu_label = m.group(1)
            idx = int(m.group(2))
            row = m.group(3)

            if idx not in topology:
                continue

            parts = row.split("\t")
            # Column layout: [GPU0..GPU(N-1) cols][NIC0..NIC cols][CPU Affinity][NUMA Affinity][GPU NUMA ID].
            # The first len(topology) columns are GPU-to-GPU affinities (including the
            # "X" self diagonal) — NOT NIC columns. They must be skipped, otherwise every
            # NIC affinity label shifts by the GPU count: e.g. GPU0's real PIX peer
            # mlx5_0 (NIC0, column N+0) gets read as NIC{N} and reported as mlx5_8, etc.
            num_gpus = len(topology)
            num_nics = len(nic_legend)
            for i, part in enumerate(parts):
                if i < num_gpus:
                    continue  # GPU x GPU columns (self/NV#) — not NIC affinities
                nic_idx = i - num_gpus
                if nic_idx >= num_nics:
                    # Past the NIC columns: CPU affinity / NUMA affinity / GPU NUMA ID.
                    # NUMA affinity is the first single-digit encountered after NIC cols.
                    part = part.strip()
                    if nic_idx == num_nics and part.isdigit() and len(part) == 1:
                        topology[idx]["numa"] = part
                    break
                nic_label = f"NIC{nic_idx}"
                if nic_label in nic_legend:
                    topology[idx]["nic_affinity"][nic_legend[nic_label]] = part.strip()

        log_info(f"GPU discovery: found {len(topology)} GPUs")
        return topology

    def _build_gpu_vf_mapping(self):
        gpu_to_vf = {}
        vf_to_gpu = {}
        for gpu_idx, info in self.gpu_topology.items():
            for dev, aff in info.get("nic_affinity", {}).items():
                if not dev.startswith("mlx5_"):
                    continue
                if aff != "PIX":
                    continue
                try:
                    dev_num = int(dev.split("_")[1])
                except (ValueError, IndexError):
                    continue
                # VFs on this cluster are mlx5_16..23
                if dev_num >= 16:
                    gpu_to_vf[gpu_idx] = dev
                    vf_to_gpu[dev] = gpu_idx
                    break
        return gpu_to_vf, vf_to_gpu

    def _build_gpu_pf_mapping(self):
        """Map each GPU to its PIX-affinity PF(s).

        This is the DirectRDMA / nmstate-era equivalent of the SR-IOV VF mapping
        above. Without SR-IOV there are no VFs (mlx5_16..23) on the host; GPUDirect
        RDMA runs over the PFs (mlx5_0..15) directly, so the GPU->PF topology is
        the relevant mapping. A GPU typically has two PIX-affinity PFs (the two
        ports of its nearest NIC), so unlike the VF mapping we keep all of them
        rather than breaking after the first. mlx5_bond_* is skipped naturally
        (its name segment after 'mlx5_' is 'bond', which int() rejects)."""
        gpu_to_pfs = {}
        for gpu_idx, info in self.gpu_topology.items():
            for dev, aff in info.get("nic_affinity", {}).items():
                if not dev.startswith("mlx5_"):
                    continue
                if aff != "PIX":
                    continue
                try:
                    dev_num = int(dev.split("_")[1])
                except (ValueError, IndexError):
                    continue
                # PFs on this cluster are mlx5_0..15 (complement of the VF range)
                if dev_num < 16:
                    gpu_to_pfs.setdefault(gpu_idx, []).append(dev)
        return gpu_to_pfs

    def _check_peermem(self):
        if not _USE_CHROOT:
            return 0
        output = run_host_cmd("lsmod 2>/dev/null", timeout=5)
        for line in output.split("\n"):
            if "nvidia_peermem" in line or "nv_peermem" in line:
                return 1
        return 0

    def _build_pf_netdevs(self):
        pf_netdevs = {}
        for dev in self.devices:
            if dev["netdev"]:
                pf_netdevs[dev["dev"]] = dev["netdev"]
        return pf_netdevs


# ---------------------------------------------------------------------------
# Metric Collection
# ---------------------------------------------------------------------------

CACHE = DeviceCache()

# ---------------------------------------------------------------------------
# Background Metrics Cache
# ---------------------------------------------------------------------------

_metrics_lock = threading.Lock()
_metrics_cache = ""
_metrics_cache_ts = 0
_metrics_cache_error = None

def ensure_cache():
    if not CACHE.is_valid():
        CACHE.refresh()

def _background_collect():
    global _metrics_cache, _metrics_cache_ts, _metrics_cache_error, _last_collection_error
    try:
        output = render_metrics()
        with _metrics_lock:
            _metrics_cache = output
            _metrics_cache_ts = time.time()
            _metrics_cache_error = None
            _last_collection_error = None
    except Exception as e:
        err = f"{e}"
        with _metrics_lock:
            _metrics_cache_error = err
            _metrics_cache_ts = time.time()
            _last_collection_error = err
        log_warn(f"Background collection failed: {e}")
        traceback.print_exc(file=sys.stderr)

def _metrics_loop():
    while True:
        try:
            _background_collect()
        except Exception as e:
            log_warn(f"Metrics loop exception: {e}")
        time.sleep(METRICS_CACHE_TTL)

def get_cached_metrics():
    with _metrics_lock:
        if _metrics_cache and (time.time() - _metrics_cache_ts) < METRICS_CACHE_TTL * 3:
            # Return a copy of the cached string so the background thread can
            # safely replace _metrics_cache without corrupting an in-flight response.
            return _metrics_cache[:], _metrics_cache_error
    # Cache empty or very stale — collect synchronously
    _background_collect()
    with _metrics_lock:
        return _metrics_cache[:], _metrics_cache_error


# ---------------------------------------------------------------------------
# Built-in Aggregation — merged metrics from ALL DaemonSet pods
# ---------------------------------------------------------------------------
# Eliminates the need for a separate aggregator pod. Each exporter pod can
# serve /aggregate which merges metrics from every DaemonSet pod in the
# cluster. Self-metrics come from the local cache (no HTTP call, no hairpin
# issue). Remote pods are scraped concurrently via ThreadPoolExecutor.
#
# Scalability: with AGGREGATE_MAX_WORKERS=16, a 32-node cluster does 31
# concurrent scrapes (each returns cached data in <100ms). Total aggregation
# time is dominated by the slowest single pod, typically <1s.
# ---------------------------------------------------------------------------

def _k8s_api_headers():
    """Return (headers_dict, namespace) for in-cluster K8s API, or (None, None)."""
    try:
        with open(f"{_SA_DIR}/token") as f:
            token = f.read().strip()
        with open(f"{_SA_DIR}/namespace") as f:
            ns = f.read().strip()
        return {"Authorization": f"Bearer {token}", "Accept": "application/json"}, ns
    except Exception:
        return None, None


def _list_exporter_pods():
    """List (podIP, podName) for all running rdma-exporter DaemonSet pods via K8s API."""
    headers, ns = _k8s_api_headers()
    if not headers:
        return []
    # Label selector used to find peer pods. Defaults to the standard Helm
    # app.kubernetes.io/name label; override via POD_LABEL_SELECTOR for custom
    # label schemes (the chart injects this to stay in sync with the DS selector).
    selector = os.environ.get("POD_LABEL_SELECTOR", "app.kubernetes.io/name=rdma-exporter")
    url = (
        f"{_K8S_API}/api/v1/namespaces/{ns}/pods"
        f"?labelSelector={urllib.parse.quote(selector, safe='')}"
        f"&fieldSelector=status.phase%3DRunning"
    )
    try:
        import ssl as _ssl
        ca = f"{_SA_DIR}/ca.crt"
        ctx = _ssl.create_default_context(cafile=ca) if os.path.exists(ca) else None
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
            data = json.load(resp)
        return [
            (p["status"]["podIP"], p["metadata"]["name"])
            for p in data.get("items", [])
            if p.get("status", {}).get("podIP")
        ]
    except Exception:
        return []


_agg_lock = threading.Lock()
_agg_cache = ""
_agg_cache_ts = 0
_agg_pod_count = 0
_agg_errors = []


def _scrape_remote_pod(pod_ip):
    """Scrape /metrics from a remote DaemonSet pod. Returns string or None."""
    url = f"http://{pod_ip}:{LISTEN_PORT}/metrics"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "rdma-exporter-aggregate"})
        with urllib.request.urlopen(req, timeout=AGGREGATE_SCRAPE_TIMEOUT) as resp:
            return resp.read().decode("utf-8", errors="replace")
    except Exception:
        return None


def _aggregate_metrics():
    """Scrape all DaemonSet pods and merge their metrics. Updates _agg_cache."""
    global _agg_cache, _agg_cache_ts, _agg_pod_count, _agg_errors

    pods = _list_exporter_pods()
    local_hostname = os.environ.get("HOSTNAME", "")
    responses = []
    errors = []

    # Self: use local metrics cache (instant, no network call, no hairpin issue)
    with _metrics_lock:
        if _metrics_cache:
            responses.append(_metrics_cache)

    # Remote pods: scrape concurrently
    remote = [(ip, name) for ip, name in pods if name != local_hostname]
    if remote:
        workers = min(len(remote), AGGREGATE_MAX_WORKERS)
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            future_to_ip = {
                pool.submit(_scrape_remote_pod, ip): ip
                for ip, _ in remote
            }
            for future in concurrent.futures.as_completed(
                future_to_ip,
                timeout=AGGREGATE_SCRAPE_TIMEOUT + 5,
            ):
                ip = future_to_ip[future]
                try:
                    result = future.result()
                    if result:
                        responses.append(result)
                    else:
                        errors.append(f"pod {ip}: scrape returned empty")
                except Exception as e:
                    errors.append(f"pod {ip}: {e}")

    # Merge: deduplicate HELP/TYPE (first wins), metric lines by unique label set
    help_and_type = {}
    metric_lines = {}
    for resp in responses:
        for line in resp.splitlines():
            if line.startswith("# HELP ") or line.startswith("# TYPE "):
                if line not in help_and_type:
                    help_and_type[line] = True
            elif line and not line.startswith("#"):
                metric_lines[line] = True

    merged = "\n".join(list(help_and_type.keys()) + sorted(metric_lines.keys())) + "\n"

    with _agg_lock:
        _agg_cache = merged
        _agg_cache_ts = time.time()
        _agg_pod_count = len(responses)
        _agg_errors = errors

    return merged


def get_aggregated_metrics():
    """Return cached aggregated metrics. Refreshes if stale."""
    with _agg_lock:
        if _agg_cache and (time.time() - _agg_cache_ts) < AGGREGATE_CACHE_TTL * 2:
            return _agg_cache[:]
    # Refresh outside lock to avoid blocking readers
    _aggregate_metrics()
    with _agg_lock:
        return _agg_cache[:]


def _aggregate_loop():
    """Background thread that periodically refreshes the aggregated cache."""
    while True:
        try:
            _aggregate_metrics()
        except Exception:
            pass
        time.sleep(AGGREGATE_CACHE_TTL)


# ---------------------------------------------------------------------------
# Metric collectors
# ---------------------------------------------------------------------------

def collect_port_counters(dev, port):
    metrics = []
    counters_dir = f"{SYS_INFINIBAND}/{dev}/ports/{port}/counters"
    if not os.path.isdir(counters_dir):
        return metrics
    counter_names = {
        "port_rcv_data", "port_xmit_data",
        "port_rcv_packets", "port_xmit_packets",
        "port_rcv_errors", "port_xmit_discards",
        "port_xmit_wait",
        "multicast_rcv_packets", "multicast_xmit_packets",
        "unicast_rcv_packets", "unicast_xmit_packets",
        "link_downed", "link_error_recovery",
        "port_rcv_constraint_errors", "port_xmit_constraint_errors",
        "port_rcv_remote_physical_errors", "port_rcv_switch_relay_errors",
        "symbol_error", "excessive_buffer_overrun_errors",
        "local_link_integrity_errors", "VL15_dropped",
    }
    for name in os.listdir(counters_dir):
        val = read_file_int(f"{counters_dir}/{name}")
        if val is not None:
            mtype = "counter" if name in counter_names else "gauge"
            metrics.append((f"rdma_port_{name}", val, mtype))
    return metrics

def collect_hw_counters(dev, port):
    metrics = []
    hw_dir = f"{SYS_INFINIBAND}/{dev}/ports/{port}/hw_counters"
    if not os.path.isdir(hw_dir):
        return metrics
    for name in os.listdir(hw_dir):
        val = read_file_int(f"{hw_dir}/{name}")
        if val is not None:
            metrics.append((f"rdma_hw_{name}", val, "counter"))
    return metrics

def collect_rdma_resources():
    metrics = []
    totals = {"qps": 0, "pds": 0, "mrs": 0}

    if not ENABLE_RDMA_RES:
        return metrics, totals

    # QPs
    qp_output = run_cmd("rdma res list qp 2>/dev/null")
    qp_by_dev = {}
    qp_by_type = {}
    qp_by_state = {}
    for line in qp_output.split("\n"):
        m = re.match(r'link\s+(\S+)/\d+\s+lqpn\s+\d+\s+type\s+(\S+)\s+state\s+(\S+)', line)
        if m:
            dev, qp_type, state = m.group(1), m.group(2), m.group(3)
            qp_by_dev[dev] = qp_by_dev.get(dev, 0) + 1
            qp_by_type[(dev, qp_type)] = qp_by_type.get((dev, qp_type), 0) + 1
            qp_by_state[(dev, state)] = qp_by_state.get((dev, state), 0) + 1
            totals["qps"] += 1
    for dev, count in qp_by_dev.items():
        metrics.append(("rdma_active_qps", count, "gauge", {"dev": dev}))
    for (dev, qp_type), count in qp_by_type.items():
        metrics.append(("rdma_qps_by_type", count, "gauge", {"dev": dev, "qp_type": qp_type}))
    for (dev, state), count in qp_by_state.items():
        metrics.append(("rdma_qps_by_state", count, "gauge", {"dev": dev, "state": state}))

    # PDs
    pd_output = run_cmd("rdma res list pd 2>/dev/null")
    for line in pd_output.split("\n"):
        m = re.match(r'dev\s+(\S+)\s+pdn\s+\d+', line)
        if m:
            dev = m.group(1)
            metrics.append(("rdma_active_pds", 1, "gauge", {"dev": dev}))
            totals["pds"] += 1
    # aggregate per device
    pd_by_dev = {}
    for m in re.finditer(r'dev\s+(\S+)\s+pdn\s+\d+', pd_output):
        pd_by_dev[m.group(1)] = pd_by_dev.get(m.group(1), 0) + 1
    metrics = [(n, c, t, l) for n, c, t, l in metrics if n != "rdma_active_pds"]
    for dev, count in pd_by_dev.items():
        metrics.append(("rdma_active_pds", count, "gauge", {"dev": dev}))

    # MRs
    mr_output = run_cmd("rdma res list mr 2>/dev/null")
    mr_by_dev = {}
    mr_bytes_by_dev = {}
    for line in mr_output.split("\n"):
        m = re.match(r'dev\s+(\S+)\s+mrn\s+\d+\s+.*mrlen\s+(\d+)', line)
        if m:
            dev, mrlen = m.group(1), int(m.group(2))
            mr_by_dev[dev] = mr_by_dev.get(dev, 0) + 1
            mr_bytes_by_dev[dev] = mr_bytes_by_dev.get(dev, 0) + mrlen
            totals["mrs"] += 1
    for dev, count in mr_by_dev.items():
        metrics.append(("rdma_active_mrs", count, "gauge", {"dev": dev}))
    for dev, total_bytes in mr_bytes_by_dev.items():
        metrics.append(("rdma_registered_memory_bytes", total_bytes, "gauge", {"dev": dev}))

    # CQs
    cq_output = run_cmd("rdma res list cq 2>/dev/null")
    cq_by_dev = {}
    for line in cq_output.split("\n"):
        m = re.match(r'dev\s+(\S+)\s+cqn\s+\d+', line)
        if m:
            cq_by_dev[m.group(1)] = cq_by_dev.get(m.group(1), 0) + 1
    for dev, count in cq_by_dev.items():
        metrics.append(("rdma_active_cqs", count, "gauge", {"dev": dev}))

    return metrics, totals

def collect_ethtool_pfc(netdev):
    metrics = []
    if not netdev or not ENABLE_ETHTOOL:
        return metrics
    output = run_cmd(f"ethtool -S {netdev} 2>/dev/null", timeout=5)
    if not output:
        return metrics
    pfc_patterns = {
        r'rx_prio(\d+)_pause$': ("rdma_pfc_rx_pause", "counter"),
        r'tx_prio(\d+)_pause$': ("rdma_pfc_tx_pause", "counter"),
        r'rx_prio(\d+)_pause_duration$': ("rdma_pfc_rx_pause_duration", "counter"),
        r'tx_prio(\d+)_pause_duration$': ("rdma_pfc_tx_pause_duration", "counter"),
        r'^rx_ecn_mark$': ("rdma_ecn_rx_mark", "counter"),
        r'^tx_ecn_mark$': ("rdma_ecn_tx_mark", "counter"),
        r'^rx_congst_umr$': ("rdma_rx_congestion_umr", "counter"),
        r'^tx_congst_umr$': ("rdma_tx_congestion_umr", "counter"),
        r'^tx_pause_storm_warning_events$': ("rdma_tx_pause_storm_warnings", "counter"),
        r'^tx_pause_storm_error_events$': ("rdma_tx_pause_storm_errors", "counter"),
        r'^rx_pause_ctrl_phy$': ("rdma_rx_pause_ctrl_phy", "counter"),
        r'^tx_pause_ctrl_phy$': ("rdma_tx_pause_ctrl_phy", "counter"),
    }
    for line in output.split("\n"):
        line = line.strip()
        m = re.match(r'\s*(.+?):\s*(\d+)', line)
        if not m:
            continue
        stat_name = m.group(1).strip()
        value = int(m.group(2))
        for pattern, (metric_name, metric_type) in pfc_patterns.items():
            m2 = re.match(pattern, stat_name)
            if m2:
                labels = {}
                if m2.lastindex and m2.lastindex >= 1 and m2.group(1) and m2.group(1).isdigit():
                    labels["priority"] = m2.group(1)
                metrics.append((metric_name, value, metric_type, labels))
                break
    return metrics

def collect_lid(dev, port):
    lid = read_file(f"{SYS_INFINIBAND}/{dev}/ports/{port}/lid")
    if lid is not None:
        try:
            return int(lid, 16) if lid.startswith("0x") else int(lid)
        except ValueError:
            return 0
    return 0

def collect_device_info(dev_info):
    return {
        "dev": dev_info["dev"],
        "netdev": dev_info["netdev"],
        "state": dev_info["state"],
        "phys_state": dev_info["phys_state"],
        "rate": str(dev_info["rate"]),
        "node_guid": dev_info["node_guid"],
        "sys_image_guid": dev_info["sys_image_guid"],
        "fw": dev_info["fw"],
        "protocol": dev_info["protocol"],
        "node_type": dev_info["node_type"],
    }

# ---------------------------------------------------------------------------
# Prometheus Output
# ---------------------------------------------------------------------------

def escape_label_val(val):
    val = str(val)
    return val.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')

def format_labels(labels):
    parts = []
    for k, v in sorted(labels.items()):
        parts.append(f'{k}="{escape_label_val(v)}"')
    return "{" + ",".join(parts) + "}" if parts else ""

def render_metrics():
    ensure_cache()

    lines = []
    emitted = set()

    def emit_help(name, help_text, metric_type):
        if name not in emitted:
            lines.append(f"# HELP {name} {help_text}")
            lines.append(f"# TYPE {name} {metric_type}")
            emitted.add(name)

    def emit(name, value, labels):
        # Inject environment label for multi-cluster federation when CLUSTER_NAME is set.
        # This is the single point of injection — every metric emitted below inherits it.
        if CLUSTER_NAME:
            labels = {**labels, "environment": CLUSTER_NAME}
        label_str = format_labels(labels)
        lines.append(f"{name}{label_str} {value}")

    # Always emit exporter info (always emitted, no conditional)
    emit_help("rdma_exporter_info", "RDMA Exporter build information", "gauge")
    emit("rdma_exporter_info", 1, {
        "version": EXPORTER_VERSION,
        "chroot": str(_USE_CHROOT),
        "nvidia_smi_path": _NVIDIA_SMI_PATH or "none",
        "hostname": HOSTNAME,
    })

    # Always emit exporter_up (1 if last scrape succeeded, 0 if error)
    emit_help("rdma_exporter_up", "RDMA Exporter health: 1=ok, 0=scrape error", "gauge")
    with _metrics_lock:
        up_val = 0 if _metrics_cache_error else 1
    emit("rdma_exporter_up", up_val, {"node": HOSTNAME})

    # ------------------------------------------------------------------
    # 1. Device info + link state + LID
    # ------------------------------------------------------------------
    for dev_info in CACHE.devices:
        dev = dev_info["dev"]
        port = dev_info["port"]
        info_labels = collect_device_info(dev_info)
        info_labels["node"] = HOSTNAME
        info_labels["port"] = str(port)
        emit_help("rdma_device_info", "RDMA device information", "gauge")
        emit("rdma_device_info", 1, info_labels)

        state_val = 1 if dev_info["state"] == "ACTIVE" else 0
        emit_help("rdma_link_state", "Link state: 1=ACTIVE, 0=DOWN", "gauge")
        emit("rdma_link_state", state_val, {"node": HOSTNAME, "dev": dev, "port": str(port)})

        lid = collect_lid(dev, port)
        emit_help("rdma_lid", "Local Identifier (LID) — should be 0 for pure RoCEv2", "gauge")
        emit("rdma_lid", lid, {"node": HOSTNAME, "dev": dev, "port": str(port)})

    # Always emit rdma_active_devices (0 if no active devices — prevents flapping)
    active_devs = [d for d in CACHE.devices if d["state"] == "ACTIVE"]
    emit_help("rdma_active_devices", "Number of active RDMA devices on this node", "gauge")
    emit("rdma_active_devices", len(active_devs), {"node": HOSTNAME})

    # Always emit total device count too (ACTIVE + INACTIVE + DOWN).
    # Use this for "Monitored Nodes" panels so nodes with all-DOWN devices
    # still show up in Prometheus (avoids gap when all devices transiently go DOWN).
    emit_help("rdma_total_devices", "Total RDMA devices discovered on this node (any state)", "gauge")
    emit("rdma_total_devices", len(CACHE.devices), {"node": HOSTNAME})

    # ------------------------------------------------------------------
    # 2. Port counters
    # ------------------------------------------------------------------
    for dev_info in CACHE.devices:
        dev = dev_info["dev"]
        port = dev_info["port"]
        base_labels = {"node": HOSTNAME, "dev": dev, "port": str(port)}
        for metric_name, value, metric_type in collect_port_counters(dev, port):
            help_text = f"RDMA port counter: {metric_name.replace('rdma_port_', '')}"
            emit_help(metric_name, help_text, metric_type)
            emit(metric_name, value, base_labels)

    # ------------------------------------------------------------------
    # 3. Hardware counters
    # ------------------------------------------------------------------
    for dev_info in CACHE.devices:
        dev = dev_info["dev"]
        port = dev_info["port"]
        base_labels = {"node": HOSTNAME, "dev": dev, "port": str(port)}
        for metric_name, value, metric_type in collect_hw_counters(dev, port):
            help_text = f"RDMA hardware counter: {metric_name.replace('rdma_hw_', '')}"
            emit_help(metric_name, help_text, metric_type)
            emit(metric_name, value, base_labels)

    # ------------------------------------------------------------------
    # 4. PFC / ECN / Congestion
    # ------------------------------------------------------------------
    for dev_info in CACHE.devices:
        dev = dev_info["dev"]
        netdev = dev_info["netdev"]
        if not netdev:
            continue
        pfc_metrics = collect_ethtool_pfc(netdev)
        for metric_name, value, metric_type, extra_labels in pfc_metrics:
            labels = {"node": HOSTNAME, "dev": dev, "netdev": netdev}
            labels.update(extra_labels)
            help_text = f"Ethernet/PFC counter: {metric_name.replace('rdma_', '')}"
            emit_help(metric_name, help_text, metric_type)
            emit(metric_name, value, labels)

    # ------------------------------------------------------------------
    # 5. RDMA resources
    # ------------------------------------------------------------------
    res_metrics, res_totals = collect_rdma_resources()

    # Track which devices had real data for each resource type
    devices_with_mrs = set()
    devices_with_mr_bytes = set()
    for item in res_metrics:
        if len(item) == 4:
            metric_name, value, metric_type, extra_labels = item
        else:
            metric_name, value, metric_type = item
            extra_labels = {}
        labels = {"node": HOSTNAME}
        labels.update(extra_labels)
        dev_label = extra_labels.get("dev", "")
        if metric_name == "rdma_active_qps":
            emit_help(metric_name, "Active Queue Pairs per RDMA device", "gauge")
        elif metric_name == "rdma_qps_by_type":
            emit_help(metric_name, "Queue Pairs by type (RC, UD, GSI) per device", "gauge")
        elif metric_name == "rdma_qps_by_state":
            emit_help(metric_name, "Queue Pairs by state per device", "gauge")
        elif metric_name == "rdma_active_pds":
            emit_help(metric_name, "Active Protection Domains per RDMA device", "gauge")
        elif metric_name == "rdma_active_mrs":
            emit_help(metric_name, "Active Memory Registrations per RDMA device", "gauge")
            if dev_label:
                devices_with_mrs.add(dev_label)
        elif metric_name == "rdma_registered_memory_bytes":
            emit_help(metric_name, "Total registered memory bytes per device", "gauge")
            if dev_label:
                devices_with_mr_bytes.add(dev_label)
        elif metric_name == "rdma_active_cqs":
            emit_help(metric_name, "Active Completion Queues per RDMA device", "gauge")
        emit(metric_name, value, labels)

    # Emit stub 0 values for devices that had no MRs registered.
    # Without this, Grafana panels for rdma_active_mrs / rdma_registered_memory_bytes
    # show "No data" when no MRs are active on any device.
    all_devs = [d["dev"] for d in CACHE.devices]
    for dev in all_devs:
        if dev not in devices_with_mrs:
            emit_help("rdma_active_mrs", "Active Memory Registrations per RDMA device", "gauge")
            emit("rdma_active_mrs", 0, {"node": HOSTNAME, "dev": dev})
        if dev not in devices_with_mr_bytes:
            emit_help("rdma_registered_memory_bytes", "Total registered memory bytes per device", "gauge")
            emit("rdma_registered_memory_bytes", 0, {"node": HOSTNAME, "dev": dev})

    # Node-level aggregates
    emit_help("rdma_node_total_qps", "Total active QPs on this node", "gauge")
    emit("rdma_node_total_qps", res_totals["qps"], {"node": HOSTNAME})
    emit_help("rdma_node_total_pds", "Total active PDs on this node", "gauge")
    emit("rdma_node_total_pds", res_totals["pds"], {"node": HOSTNAME})
    emit_help("rdma_node_total_mrs", "Total active MRs on this node", "gauge")
    emit("rdma_node_total_mrs", res_totals["mrs"], {"node": HOSTNAME})

    # ------------------------------------------------------------------
    # 6. GID info
    # ------------------------------------------------------------------
    for dev, gid_list in CACHE.gids.items():
        for gid_info in gid_list:
            emit_help("rdma_gid_info", "RDMA GID — RoCEv2 routing address", "gauge")
            emit("rdma_gid_info", 1, {
                "node": HOSTNAME,
                "dev": dev,
                "port": str(gid_info["port"]),
                "gid_index": str(gid_info["index"]),
                "gid": gid_info["gid"],
                "gid_ver": gid_info["ver"],
                "netdev": gid_info["netdev"],
            })

    # ------------------------------------------------------------------
    # 7. GPU metrics — always emit, even when empty (stability)
    # ------------------------------------------------------------------
    if ENABLE_GPU:
        if CACHE.gpu_topology:
            for gpu_idx, info in CACHE.gpu_topology.items():
                emit_help("rdma_gpu_info", "GPU device information", "gauge")
                emit("rdma_gpu_info", 1, {
                    "node": HOSTNAME,
                    "gpu_index": str(gpu_idx),
                    "gpu_uuid": info["uuid"],
                    "gpu_name": info["name"],
                    "pci_bus": info["pci_bus"],
                    "numa": info["numa"],
                })

                for nic_dev, aff in info.get("nic_affinity", {}).items():
                    emit_help("rdma_gpu_nic_affinity", "GPU-to-NIC PCIe topology affinity", "gauge")
                    emit("rdma_gpu_nic_affinity", 1, {
                        "node": HOSTNAME,
                        "gpu_index": str(gpu_idx),
                        "gpu_uuid": info["uuid"],
                        "rdma_dev": nic_dev,
                        "affinity": aff,
                    })

                if gpu_idx in CACHE.gpu_to_vf:
                    vf_dev = CACHE.gpu_to_vf[gpu_idx]
                    vf_gid = ""
                    if vf_dev in CACHE.gids and CACHE.gids[vf_dev]:
                        vf_gid = CACHE.gids[vf_dev][0]["gid"]
                    emit_help("rdma_gpu_to_vf_mapping", "GPU-to-VF mapping for GPUDirect RDMA", "gauge")
                    emit("rdma_gpu_to_vf_mapping", 1, {
                        "node": HOSTNAME,
                        "gpu_index": str(gpu_idx),
                        "gpu_uuid": info["uuid"],
                        "pci_bus": info["pci_bus"],
                        "rdma_dev": vf_dev,
                        "gid": vf_gid,
                    })

                # GPU -> PF mapping (DirectRDMA / nmstate era: no SR-IOV VFs on the
                # host, GPUDirect runs over the PFs). Each GPU may map to multiple
                # PIX-affinity PFs (typically the two ports of its nearest NIC).
                for pf_dev in CACHE.gpu_to_pfs.get(gpu_idx, []):
                    pf_gid = ""
                    if pf_dev in CACHE.gids and CACHE.gids[pf_dev]:
                        pf_gid = CACHE.gids[pf_dev][0]["gid"]
                    emit_help("rdma_gpu_to_pf_mapping", "GPU-to-PF mapping for GPUDirect RDMA (DirectRDMA/nmstate; no SR-IOV VFs)", "gauge")
                    emit("rdma_gpu_to_pf_mapping", 1, {
                        "node": HOSTNAME,
                        "gpu_index": str(gpu_idx),
                        "gpu_uuid": info["uuid"],
                        "pci_bus": info["pci_bus"],
                        "rdma_dev": pf_dev,
                        "gid": pf_gid,
                    })
        else:
            # No GPUs found — emit stub metrics so Grafana queries don't go empty
            emit_help("rdma_gpu_info", "GPU device information", "gauge")
            emit("rdma_gpu_info", 0, {
                "node": HOSTNAME,
                "gpu_index": "",
                "gpu_uuid": "none",
                "gpu_name": "none",
                "pci_bus": "",
                "numa": "",
            })
    else:
        log_debug("GPU metrics disabled via ENABLE_GPU=0")

    # ------------------------------------------------------------------
    # 8. Peermem status
    # ------------------------------------------------------------------
    emit_help("rdma_peermem_loaded", "nvidia_peermem module loaded (1=yes, 0=no)", "gauge")
    emit("rdma_peermem_loaded", CACHE.peermem_loaded, {"node": HOSTNAME})

    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# HTTP Server
# ---------------------------------------------------------------------------

class MetricsHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"OK\n")

        elif self.path == "/metrics":
            output, error = get_cached_metrics()
            if error:
                self.send_response(503)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(f"# Error collecting metrics: {error}\n".encode("utf-8"))
            else:
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
                self.end_headers()
                try:
                    self.wfile.write(output.encode("utf-8"))
                except (BrokenPipeError, ConnectionResetError, OSError):
                    # Client closed connection mid-response (e.g. Prometheus timeout).
                    # This is normal during scrape overlap — no action needed.
                    pass

        elif self.path == "/metrics/errors":
            # Debug endpoint — returns JSON diagnostics
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            with _metrics_lock:
                error = _metrics_cache_error
            with _agg_lock:
                agg_pod_count = _agg_pod_count
                agg_errors = _agg_errors[:]
            info = {
                "last_collection_error": error,
                "hostname": HOSTNAME,
                "exporter_version": EXPORTER_VERSION,
                "nvidia_smi_path": _NVIDIA_SMI_PATH,
                "nvidia_smi_chroot_path": _NVIDIA_SMI_CHROOT_PATH,
                "nvidia_smi_candidates_searched": _NVIDIA_SMI_CANDIDATES,
                "use_chroot": _USE_CHROOT,
                "nvidia_ld_library_path": NVIDIA_LD_LIBRARY_PATH,
                "gpu_count": len(CACHE.gpu_topology),
                "rdma_device_count": len(CACHE.devices),
                "active_devices": len([d for d in CACHE.devices if d["state"] == "ACTIVE"]),
                "gpu_to_vf": {str(k): v for k, v in CACHE.gpu_to_vf.items()},
                "peermem_loaded": CACHE.peermem_loaded,
                "cache_valid": CACHE.is_valid(),
                "cache_age_seconds": int(time.time() - CACHE.timestamp),
                "aggregate_pods_scraped": agg_pod_count,
                "aggregate_errors": agg_errors,
                "env": {
                    "ENABLE_GPU": str(ENABLE_GPU),
                    "ENABLE_ETHTOOL": str(ENABLE_ETHTOOL),
                    "ENABLE_RDMA_RES": str(ENABLE_RDMA_RES),
                    "CACHE_TTL": str(CACHE_TTL),
                    "METRICS_CACHE_TTL": str(METRICS_CACHE_TTL),
                    "AGGREGATE_CACHE_TTL": str(AGGREGATE_CACHE_TTL),
                    "LOG_LEVEL": LOG_LEVEL,
                    "HOST_ROOT": HOST_ROOT,
                },
            }
            self.wfile.write(json.dumps(info, indent=2).encode("utf-8"))

        elif self.path == "/aggregate":
            # Merged metrics from ALL DaemonSet pods in the cluster.
            # Self-metrics come from local cache (no HTTP call). Remote pods
            # are scraped concurrently. Cached and refreshed in background.
            output = get_aggregated_metrics()
            if not output:
                self.send_response(503)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                try:
                    self.wfile.write(b"# No metrics available\n")
                except OSError:
                    pass
            else:
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
                self.end_headers()
                try:
                    self.wfile.write(output.encode("utf-8"))
                except OSError:
                    pass

        elif self.path == "/":
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(
                b"<html><body>"
                b"<h1>RDMA Exporter v" + EXPORTER_VERSION.encode() + b"</h1>"
                b"<p><a href='/metrics'>Metrics</a> (this node)</p>"
                b"<p><a href='/aggregate'>Aggregate</a> (all nodes)</p>"
                b"<p><a href='/health'>Health</a></p>"
                b"<p><a href='/metrics/errors'>Diagnostics</a> (JSON)</p>"
                b"</body></html>"
            )
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass

    def handle_error(self):
        # Suppress traceback dumps for expected client-abort errors
        # (ConnectionResetError/BrokenPipe when Prometheus closes the connection).
        # Only print for unexpected errors.
        _, exc, _ = sys.exc_info()
        if isinstance(exc, (BrokenPipeError, ConnectionResetError, ConnectionAbortedError)):
            pass
        else:
            super().handle_error()


def main():
    log_info(f"RDMA Exporter v{EXPORTER_VERSION} starting on {LISTEN_ADDR}:{LISTEN_PORT}")
    log_info(f"Hostname: {HOSTNAME}")
    log_info(f"Chroot: {_USE_CHROOT}, nvidia-smi: {_NVIDIA_SMI_PATH}")
    log_info(f"GPU: enabled={ENABLE_GPU}, ETHTOOL: enabled={ENABLE_ETHTOOL}, RDMA_RES: enabled={ENABLE_RDMA_RES}")
    log_info(f"Cache TTL: {CACHE_TTL}s, Metrics TTL: {METRICS_CACHE_TTL}s")

    CACHE.refresh()
    log_info(
        f"Discovered {len(CACHE.devices)} RDMA devices, "
        f"{len([d for d in CACHE.devices if d['state']=='ACTIVE'])} active; "
        f"{len(CACHE.gpu_topology)} GPUs; "
        f"peermem={CACHE.peermem_loaded}"
    )

    t = threading.Thread(target=_metrics_loop, daemon=True)
    t.start()
    log_info(f"Background metrics collector started (TTL={METRICS_CACHE_TTL}s)")

    ta = threading.Thread(target=_aggregate_loop, daemon=True)
    ta.start()
    log_info(f"Aggregation collector started (TTL={AGGREGATE_CACHE_TTL}s)")

    class QuietThreadingHTTPServer(http.server.ThreadingHTTPServer):
        """ThreadingHTTPServer that handles each request in its own thread.

        The base ThreadingHTTPServer spawns a thread per request via
        process_request(). The previous implementation overrode process_request()
        and called finish_request() directly, which accidentally disabled
        threading and made /health block behind slow /metrics or /aggregate
        scrapes. We now override process_request_thread() (the work done inside
        the spawned thread) so threading is preserved and expected client-abort
        errors are still suppressed.
        """
        daemon_threads = True

        def process_request_thread(self, request, client_address):
            try:
                self.finish_request(request, client_address)
            except Exception:
                self.handle_error(request, client_address)
            finally:
                self.shutdown_request(request)

        def handle_error(self, request, client_address):
            """Suppress tracebacks for client-abort errors (ConnectionReset, BrokenPipe)."""
            _, exc, _ = sys.exc_info()
            if isinstance(exc, (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError)):
                pass
            else:
                super().handle_error(request, client_address)

    server = QuietThreadingHTTPServer((LISTEN_ADDR, LISTEN_PORT), MetricsHandler)
    log_info(f"Listening on {LISTEN_ADDR}:{LISTEN_PORT}/metrics | /aggregate")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log_info("Shutting down")
        server.shutdown()

if __name__ == "__main__":
    main()
