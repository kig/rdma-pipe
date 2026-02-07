# Guide to Optimizing rdma-pipe Performance

## Current Status

The file write function in `rdrecv.c` reportedly bottlenecks at <3GB/s on some systems. However, without proper hardware and measurement tools, we cannot identify the actual bottlenecks or validate optimizations.

## Why Speculative Optimization Doesn't Work

Making changes without evidence is problematic:

1. **Unknown bottleneck location** - Could be network, CPU, disk I/O, or memory
2. **No baseline measurements** - Don't know current performance characteristics
3. **Cannot validate improvements** - Changes might help, hurt, or do nothing
4. **Risk of introducing bugs** - Complex changes without testing

## What's Actually Needed

### 1. Hardware Requirements

To test rdma-pipe performance, you need:

- **RDMA-capable network adapters**
  - InfiniBand (FDR, HDR, or newer)
  - RoCE (RDMA over Converged Ethernet)
  - Minimum 25 Gbps, ideally 50-100 Gbps

- **Fast storage**
  - NVMe SSD array with >5 GB/s write bandwidth
  - Multiple drives in RAID configuration preferred
  - Fast filesystem (ext4, XFS, or ZFS)

- **Two test machines**
  - Modern CPUs with multiple cores
  - Sufficient RAM (32GB+)
  - Connected via RDMA network

### 2. Profiling Tools

Before optimizing, identify bottlenecks:

```bash
# CPU profiling
perf record -g rdrecv 12345 password target_file
perf report

# I/O monitoring
iostat -x 1

# System-wide monitoring
top -H  # See CPU usage per thread
iotop   # See I/O per process

# RDMA-specific tools
ibstat  # Check InfiniBand status
perfquery  # RDMA performance counters
```

### 3. Benchmark Suite

Create reproducible tests:

```bash
# Create test file
dd if=/dev/zero of=testfile bs=1M count=10240  # 10GB

# Baseline test
time rdcp -v testfile remote:/dev/null

# Test with different file sizes
for size in 1G 5G 10G 50G; do
    dd if=/dev/zero of=test_${size} bs=1M count=${size}000
    rdcp -v test_${size} remote:/dev/null
done

# Test different patterns
# - Sequential reads/writes
# - Random I/O
# - Small files vs large files
# - Single file vs directory tree (rdcp -r)
```

### 4. Identify Bottlenecks

Common bottlenecks and how to identify them:

**Network bottleneck:**
- RDMA link not fully utilized
- Check with `perfquery` and network monitoring
- Solution: Optimize RDMA parameters, check for packet loss

**CPU bottleneck:**
- High CPU usage in profiling
- Threads waiting for CPU
- Solution: Reduce context switches, optimize hot loops

**Disk I/O bottleneck:**
- High iowait in `top`
- Low disk throughput in `iostat`
- Solution: Use O_DIRECT, parallel I/O, or different filesystem

**Memory bottleneck:**
- Memory bandwidth saturation
- High cache misses
- Solution: Optimize buffer sizes, memory alignment

### 5. Targeted Optimizations

Only after identifying bottlenecks:

**If CPU-bound:**
- Reduce syscalls (pwrite vs lseek+write)
- Optimize memory copy operations
- Use SIMD instructions if appropriate

**If I/O-bound:**
- Tune I/O scheduler
- Adjust filesystem parameters
- Use O_DIRECT for large sequential writes
- Parallel I/O with multiple threads

**If network-bound:**
- Tune RDMA parameters
- Adjust buffer sizes
- Check for congestion/packet loss

### 6. Validation

After each change:

```bash
# Run benchmark suite
./run_benchmarks.sh

# Compare results
# - Throughput (GB/s)
# - CPU usage
# - I/O wait time
# - Network utilization

# Ensure no regressions
# - Test all file sizes
# - Test both rdcp and rdrecv/rdsend directly
# - Test recursive copies
```

## Example Workflow

1. **Setup hardware**
   ```bash
   # Verify RDMA connectivity
   ibstat
   
   # Check storage performance
   fio --name=test --ioengine=libaio --rw=write --bs=8M --size=10G --direct=1
   ```

2. **Baseline measurements**
   ```bash
   # Test current performance
   rdcp -v 10G_file remote:/dev/null
   # Note: throughput, CPU usage, I/O stats
   ```

3. **Profile**
   ```bash
   # On receiver
   perf record -g rdrecv 12345 password /mnt/nvme/output
   
   # On sender
   perf record -g rdsend remote 12345 password input_file
   
   # Analyze
   perf report
   ```

4. **Identify bottleneck**
   - If profiling shows ftruncate() is slow → consider removing it
   - If lseek() overhead is high → consider pwrite()
   - If single-threaded I/O is slow → consider parallel writes

5. **Implement fix**
   - Make minimal, targeted change
   - Document expected improvement

6. **Benchmark**
   ```bash
   # Test with same workload
   rdcp -v 10G_file remote:/dev/null
   # Compare with baseline
   ```

7. **Iterate**
   - If improvement is real and significant → keep change
   - If no improvement or regression → revert
   - Profile again to find next bottleneck

## What NOT to Do

❌ **Don't** make changes without profiling data  
❌ **Don't** optimize based on assumptions  
❌ **Don't** add complexity without evidence it helps  
❌ **Don't** trust "should be faster" - measure it  
❌ **Don't** optimize without baseline benchmarks  

## Current Code Assessment

The existing code in `rdrecv.c` shows:

- **Parallel I/O support** - Already uses 8 threads with O_DIRECT
- **Optimized buffer size** - 8 MiB buffers
- **RDMA optimization** - Direct memory access patterns

Likely areas to investigate (with profiling):
1. Single-threaded fallback path (lseek/write loop)
2. ftruncate() calls in hot path
3. Error handling overhead
4. Thread synchronization costs

But again: **measure first, optimize second**.

## Conclusion

Performance optimization requires:
1. Proper hardware for testing
2. Profiling to identify bottlenecks
3. Targeted fixes based on data
4. Benchmarking to validate improvements

Without these, optimization is just guesswork and likely to waste time or make things worse.
