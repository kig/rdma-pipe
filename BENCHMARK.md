# RDCP Benchmark Suite

This benchmark suite measures `rdcp` performance for single-host file and directory copies using RDMA loopback, which is useful for testing NVMe storage bandwidth and establishing baseline performance.

## Important Note: RDMA Loopback for Local Copies

**As of this version, rdcp uses RDMA loopback even for localhost-to-localhost copies** instead of falling back to regular `cp`. This is because:

- The RDMA path includes performance optimizations (parallel I/O, O_DIRECT) that regular `cp` lacks
- RDMA loopback performance is better than `cp` on fast storage (NVMe)
- Parallel I/O can better saturate modern NVMe arrays
- This provides consistent behavior whether copying locally or remotely

This means the benchmark now measures RDMA loopback performance rather than plain `cp` performance.

## What It Tests

The benchmark performs the following tests:

1. **Single File Copies** - Tests files of various sizes:
   - 1 MB - Small file performance
   - 10 MB - Medium file performance  
   - 100 MB - Large file performance
   - 1 GB - Very large file performance
   - 5 GB - Maximum test size

2. **Directory Tree Copy** - Tests recursive directory copy:
   - 1000 files organized in subdirectories
   - 100 KB per file (100 MB total)
   - Simulates real-world project structure

## Why Single-Host Benchmarking?

Single-host benchmarking (copying files locally via RDMA loopback) is valuable because:

- **Tests RDMA loopback performance** - Measures RDMA performance without network latency
- **Measures storage bandwidth** - Tests if storage can keep up with RDMA transfer rates
- **Validates rdcp optimizations** - Tests parallel I/O and O_DIRECT optimizations
- **Creates baseline** - Compare with network RDMA performance to identify bottlenecks
- **Tests NVMe arrays** - Parallel I/O can better saturate fast NVMe storage
- **Better than cp** - RDMA path has optimizations that regular cp lacks

## Requirements

- Compiled `rdcp`, `rdsend`, and `rdrecv` binaries
- At least 11 GB free space for tests
- NVMe storage recommended for meaningful results
- Root access to drop caches (optional, for cold-start testing)

## Usage

### Basic Usage

```bash
./benchmark_rdcp.sh
```

This runs all benchmarks in `/tmp/rdcp_bench` (default location).

### Custom Test Directory

```bash
./benchmark_rdcp.sh /mnt/nvme/rdcp_bench
```

Use a custom directory, ideally on NVMe storage for best results.

### Example Output

```
========================================
  RDCP Single-Host Benchmark Suite
========================================

[INFO] Setting up test directory: /tmp/rdcp_bench
[INFO] Filesystem info:
/dev/nvme0n1p1  1.8T  500G  1.3T  29% /mnt/nvme
[OK] Test directory is on NVMe storage

=== Single File Copy Tests ===

[INFO] Benchmarking 1MB file copy
[OK] File copy: 1MB in 0.003s = 0.333 GB/s

[INFO] Benchmarking 10MB file copy
[OK] File copy: 10MB in 0.015s = 0.667 GB/s

[INFO] Benchmarking 100MB file copy
[OK] File copy: 100MB in 0.120s = 0.833 GB/s

[INFO] Benchmarking 1000MB file copy
[OK] File copy: 1000MB in 0.950s = 1.053 GB/s

[INFO] Benchmarking 5000MB file copy
[OK] File copy: 5000MB in 3.500s = 1.429 GB/s

=== Directory Tree Copy Test ===

[INFO] Benchmarking directory tree copy
[OK] Tree copy: 97MB (1000 files) in 2.150s = 0.045 GB/s

========================================
  RDCP SINGLE-HOST BENCHMARK RESULTS
========================================

Filesystem: /dev/nvme0n1p1 1.8T /mnt/nvme

Size (MB)       Time (s)     Bandwidth (GB/s) Type      
--------        --------     --------------- ----      
1               0.003        0.333           file      
10              0.015        0.667           file      
100             0.120        0.833           file      
1000            0.950        1.053           file      
5000            3.500        1.429           file      
97              2.150        0.045           tree      

Average bandwidth: 0.727 GB/s

Results saved to: /tmp/rdcp_bench/results.csv
```

## Interpreting Results

### Expected Performance

On modern NVMe storage:
- **Sequential writes**: 3-7 GB/s for PCIe Gen3, up to 14 GB/s for Gen4
- **Small files**: Lower bandwidth due to metadata overhead
- **Large files**: Should approach storage limits
- **Directory trees**: Much slower due to many small files and metadata

### Bottleneck Identification

If results are lower than expected:

1. **Storage bottleneck**: Check if on HDD/SATA SSD instead of NVMe
   - HDDs: 100-200 MB/s
   - SATA SSDs: 500-600 MB/s  
   - NVMe Gen3: 3-7 GB/s
   - NVMe Gen4: 7-14 GB/s

2. **Filesystem overhead**: ext4, XFS, and ZFS have different characteristics
   - ext4: Good all-around performance
   - XFS: Better for large files
   - ZFS: Adds compression/checksumming overhead

3. **System load**: Check CPU and memory usage during test
   - High CPU: Compression or checksum overhead
   - High I/O wait: Storage bottleneck

4. **Page cache**: Results may vary on repeated runs
   - First run: Cold cache (realistic)
   - Second run: Warm cache (faster but not realistic)
   - Benchmark drops caches between tests for consistency

### Comparison with Network RDMA

Compare these single-host results with network RDMA results:

```bash
# Single host (this benchmark)
./benchmark_rdcp.sh /mnt/nvme/bench

# Network RDMA (between two hosts)
# On remote host:
rdrecv 12345 password /mnt/nvme/target_file

# On local host:  
rdsend -v remote_host 12345 password /mnt/nvme/source_file
```

If network RDMA is slower than single-host, the bottleneck is the network.  
If network RDMA matches single-host, the bottleneck is storage.

## Output Files

The benchmark creates:

- **results.csv** - Machine-readable results for further analysis
  ```csv
  size_mb,duration_s,bandwidth_gbs,type
  1,0.003,0.333,file
  10,0.015,0.667,file
  ...
  ```

- **Test files** - Cleaned up automatically after benchmark completes

## Advanced Usage

### Modify Test Parameters

Edit the script to change test parameters:

```bash
# Test file sizes (in MB)
FILE_SIZES=(1 10 100 1000 5000 10000)  # Add 10 GB test

# Directory tree configuration
DIR_TREE_FILES=5000     # More files
DIR_TREE_FILE_SIZE_KB=50  # Smaller files
```

### Skip Large File Tests

If space is limited:

```bash
# Edit FILE_SIZES in the script
FILE_SIZES=(1 10 100)  # Only test up to 100 MB
```

### Repeated Runs

For statistical significance:

```bash
for i in {1..5}; do
    echo "Run $i"
    ./benchmark_rdcp.sh /mnt/nvme/bench_$i
done
```

## Troubleshooting

### "rdcp not found"

Build the project first:
```bash
make
```

### "Not enough space"

Use a smaller test directory or skip large file tests:
```bash
./benchmark_rdcp.sh /mnt/nvme/small_bench
# Then edit FILE_SIZES in script to remove 5000 MB test
```

### "Permission denied" for drop_caches

The benchmark works without root, but won't drop caches:
```bash
# Run as root for more consistent results
sudo ./benchmark_rdcp.sh
```

### Inconsistent results

1. Check system load: `top`, `iotop`
2. Run multiple times and average
3. Use NVMe storage for consistent results
4. Close other applications

## Integration with CI/CD

The benchmark outputs CSV format for easy integration:

```bash
#!/bin/bash
# Example CI benchmark script
./benchmark_rdcp.sh /tmp/bench

# Check if bandwidth meets minimum threshold
MIN_BANDWIDTH=0.5  # GB/s
AVG=$(awk -F, 'NR>1 {sum+=$3; count++} END {print sum/count}' /tmp/bench/results.csv)

if (( $(echo "$AVG < $MIN_BANDWIDTH" | bc -l) )); then
    echo "FAIL: Average bandwidth $AVG GB/s below minimum $MIN_BANDWIDTH GB/s"
    exit 1
else
    echo "PASS: Average bandwidth $AVG GB/s"
fi
```

## See Also

- `OPTIMIZATION_GUIDE.md` - Methodology for performance optimization
- `README.md` - General rdma-pipe documentation
- `Makefile` - Build instructions
