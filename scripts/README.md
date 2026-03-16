# RDMA-Pipe Benchmark Scripts

This directory contains scripts for benchmarking and verifying RDMA-pipe performance.

## Quick Start

```bash
# 1. Verify RDMA environment
./verify-rdma.sh

# 2. Run benchmark suite
./run-benchmarks.sh <sender-ip> <receiver-ip>

# 3. Analyze results
./analyze-results.py results-<timestamp>
```

## Scripts

### quick-benchmark.sh
Sets up a benchmark environment with Terraform and cloud provider of choice.

```bash
./quick-benchmark.sh [aws|azure|gcp] [region]
```

### verify-rdma.sh
Verifies that RDMA is properly configured on the system.

```bash
./verify-rdma.sh
```

Checks:
- RDMA devices detected
- InfiniBand/EFA link status
- Memory lock limits
- RDMA libraries installed
- rdma-pipe binaries available

### run-benchmarks.sh
Runs a comprehensive benchmark suite comparing RDMA performance.

```bash
./run-benchmarks.sh <sender-private-ip> <receiver-private-ip>
```

Tests performed:
1. Basic RDMA bandwidth (10GB to /dev/null)
2. Large model transfer (70GB file)
3. File write performance (10GB with disk writes)
4. SCP baseline (for comparison)
5. Parallel transfers (4x simultaneous)
6. CPU pinning optimization

### analyze-results.py
Parses benchmark results and generates a comprehensive report.

```bash
./analyze-results.py results-<timestamp>
```

Outputs:
- Bandwidth measurements for each test
- Performance classification (FDR/HDR/NDR)
- Speedup vs baseline
- Pass/fail verification checklist
- JSON results file

## Prerequisites

- Terraform (for infrastructure provisioning)
- Ansible (for configuration management)
- Python 3.6+ (for analysis script)
- SSH access to benchmark instances
- RDMA-capable cloud instances

## Example Workflow

### AWS with EFA

```bash
# 1. Setup infrastructure
cd terraform/aws
terraform init
terraform apply

# Note the output IPs
SENDER=10.0.1.4
RECEIVER=10.0.1.5
PUBLIC_IP=52.1.2.3

# 2. Verify RDMA on both instances
ssh ubuntu@$PUBLIC_IP ./verify-rdma.sh

# 3. Run benchmarks
cd ../../scripts
./run-benchmarks.sh $SENDER $RECEIVER

# 4. Analyze
./analyze-results.py results-*/
```

### Azure with InfiniBand

```bash
# Similar workflow using Azure-specific IPs
cd terraform/azure
terraform apply

# Get IPs from outputs
# Run benchmarks
cd ../../scripts
./run-benchmarks.sh <azure-sender-ip> <azure-receiver-ip>
```

## Interpreting Results

### Expected Performance

| RDMA Type | Bandwidth | 10GB Time | 70GB Time |
|-----------|-----------|-----------|-----------|
| FDR (56G) | 5-7 GB/s | 1.5-2s | 10-14s |
| HDR (200G) | 20-25 GB/s | 0.4-0.5s | 2.8-3.5s |
| NDR (400G) | 40-50 GB/s | 0.2-0.25s | 1.4-1.75s |
| SCP (baseline) | 0.3-0.5 GB/s | 20-30s | 140-230s |

### Validation Criteria

✓ **Pass:** RDMA bandwidth ≥ 5 GB/s  
✓ **Pass:** 10x+ faster than SCP  
✓ **Pass:** Consistent across tests (<20% variation)

## Troubleshooting

**No RDMA devices found:**
```bash
# Check kernel modules
lsmod | grep ib_
# Reinstall drivers if needed
```

**Low performance:**
```bash
# Check link speed
ibstatus | grep Rate
# Try CPU pinning
taskset -c 0 rdrecv ...
```

**Connection timeout:**
```bash
# Ensure receiver is started first
# Check security group allows traffic
# Use private IPs for RDMA
```

## See Also

- [BENCHMARKING_GUIDE.md](../BENCHMARKING_GUIDE.md) - Complete benchmarking guide
- [Terraform configs](../terraform/) - Infrastructure as code
- [Main README](../README.md) - rdma-pipe documentation
