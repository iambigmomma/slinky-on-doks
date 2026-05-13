#!/bin/bash
# ConnectX-8 PCIe switch firmware re-init for NVIDIA B300 nodes.
#
# In VM environments (DOKS = KVM/QEMU), ConnectX-8 firmware sometimes does not
# fully initialize on boot. The NVIDIA driver then falls back to a 40× slower
# sync path. Symptom: cudaStreamSynchronize > 50% of CUDA API time.
#
# Triggering a resourcedump at offset 0x5024 kicks the firmware into a clean
# state. Takes a few seconds; must be re-run on every VM reboot.
#
# Run on the HOST OS (or via the DaemonSet at manifests/nvidia-b300-init.yaml
# which chroots into the host).
#
# Requires: Mellanox mst tools (mst, resourcedump).
#
# References:
#   - docs/b300-troubleshooting-guide.md §2
set -euo pipefail

if ! command -v mst >/dev/null 2>&1; then
    echo "ERROR: mst not found in PATH. Install Mellanox firmware tools." >&2
    exit 1
fi

echo "Starting ConnectX-8 firmware re-init..."
mst gpu add

shopt -s nullglob
devs=( /dev/mst/netir*_gpu* )
if [ ${#devs[@]} -eq 0 ]; then
    echo "ERROR: No /dev/mst/netir*_gpu* devices found after 'mst gpu add'." >&2
    echo "       Check that the host has ConnectX-8 NICs and mst is healthy." >&2
    exit 2
fi

for dev in "${devs[@]}"; do
    echo "  resourcedump → $dev"
    resourcedump dump -d "$dev" -s 0x5024 > /dev/null 2>&1 || true
done

echo "Done. CX-8 firmware re-init triggered on ${#devs[@]} device(s)."
