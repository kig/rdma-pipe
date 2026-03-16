#!/bin/bash
# RDMA Environment Verification Script

echo "========================================"
echo "RDMA Environment Verification"
echo "========================================"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Note: Some checks require root privileges"
    echo "Consider running: sudo $0"
    echo ""
fi

# 1. Check RDMA devices
echo "1. RDMA Devices:"
if command -v ibv_devices &> /dev/null; then
    ibv_devices
    echo ""
    
    # Get device details
    echo "Device Details:"
    ibv_devinfo | grep -E "hca_id|state|active_speed|active_width"
else
    echo "ERROR: ibv_devices not found. Install rdma-core"
fi
echo ""

# 2. Check InfiniBand status
echo "2. InfiniBand Status:"
if command -v ibstatus &> /dev/null; then
    ibstatus
else
    echo "WARNING: ibstatus not found"
fi
echo ""

# 3. Check network interfaces
echo "3. Network Interfaces with RDMA:"
ls -l /sys/class/infiniband/*/device/net/ 2>/dev/null || echo "No InfiniBand devices found"
echo ""

# 4. Check EFA (AWS)
echo "4. EFA Status (AWS):"
if [ -d "/opt/amazon/efa" ]; then
    /opt/amazon/efa/bin/fi_info -p efa || echo "EFA not properly configured"
else
    echo "Not an AWS EFA instance (or EFA not installed)"
fi
echo ""

# 5. Check memory lock limits
echo "5. Memory Lock Limits (for RDMA):"
ulimit -l
if [ "$(ulimit -l)" -lt 16500 ]; then
    echo "WARNING: Memory lock limit too low. Should be > 16500 KB"
    echo "Fix: Add to /etc/security/limits.d/rdma.conf:"
    echo "*       soft    memlock         unlimited"
    echo "*       hard    memlock         unlimited"
fi
echo ""

# 6. Check RDMA-core installation
echo "6. RDMA Libraries:"
ldconfig -p | grep -E "libibverbs|librdmacm" || echo "WARNING: RDMA libraries not found"
echo ""

# 7. Test RDMA communication (if ibv_rc_pingpong available)
echo "7. RDMA Ping Test:"
if command -v ibv_rc_pingpong &> /dev/null; then
    echo "ibv_rc_pingpong available"
    echo "Run on receiver: ibv_rc_pingpong"
    echo "Run on sender: ibv_rc_pingpong <receiver-ip>"
else
    echo "ibv_rc_pingpong not available (install perftest package)"
fi
echo ""

# 8. Check rdma-pipe installation
echo "8. rdma-pipe Installation:"
command -v rdcp &> /dev/null && echo "rdcp: $(which rdcp)" || echo "rdcp: NOT FOUND"
command -v rdsend &> /dev/null && echo "rdsend: $(which rdsend)" || echo "rdsend: NOT FOUND"
command -v rdrecv &> /dev/null && echo "rdrecv: $(which rdrecv)" || echo "rdrecv: NOT FOUND"
echo ""

# 9. System info
echo "9. System Information:"
echo "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo "Kernel: $(uname -r)"
echo "CPU: $(lscpu | grep "Model name" | cut -d: -f2 | xargs)"
echo "Memory: $(free -h | grep Mem | awk '{print $2}')"
echo ""

# 10. Check for NVMe
echo "10. NVMe Storage:"
lsblk -d | grep nvme || echo "No NVMe devices found"
echo ""

echo "========================================"
echo "Verification Complete"
echo "========================================"
