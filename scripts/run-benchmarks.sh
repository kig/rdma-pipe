#!/bin/bash
# RDMA Benchmark Execution Script
# Usage: ./run-benchmarks.sh <sender-ip> <receiver-ip>

set -e

SENDER_IP=${1:-}
RECEIVER_IP=${2:-}

if [ -z "$SENDER_IP" ] || [ -z "$RECEIVER_IP" ]; then
    echo "Usage: $0 <sender-ip> <receiver-ip>"
    echo "Example: $0 10.0.1.4 10.0.1.5"
    exit 1
fi

RESULTS_DIR="results-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS_DIR"

echo "========================================"
echo "RDMA-Pipe Benchmark Suite"
echo "Sender: $SENDER_IP"
echo "Receiver: $RECEIVER_IP"
echo "Results: $RESULTS_DIR"
echo "========================================"
echo ""

# Test 1: Basic RDMA Bandwidth
echo "Test 1: Basic RDMA Bandwidth (10GB transfer to /dev/null)"
echo "Starting receiver..."
ssh ubuntu@$RECEIVER_IP "rdrecv 12345 benchmark_key >/dev/null" &
RECEIVER_PID=$!
sleep 2

echo "Starting sender..."
ssh ubuntu@$SENDER_IP "time rdsend -v $RECEIVER_IP 12345 benchmark_key </mnt/nvme/benchmark/test_10GB" 2>&1 | tee "$RESULTS_DIR/test1_basic_bandwidth.log"

wait $RECEIVER_PID 2>/dev/null || true
echo ""

# Test 2: Large File Transfer (70GB - simulating LLaMA-70B model)
echo "Test 2: Large Model Transfer (70GB file)"
echo "Starting receiver..."
ssh ubuntu@$RECEIVER_IP "rdrecv 12346 model_key >/dev/null" &
RECEIVER_PID=$!
sleep 2

echo "Starting sender..."
ssh ubuntu@$SENDER_IP "time rdsend -v $RECEIVER_IP 12346 model_key </mnt/nvme/benchmark/test_70GB" 2>&1 | tee "$RESULTS_DIR/test2_70gb_model.log"

wait $RECEIVER_PID 2>/dev/null || true
echo ""

# Test 3: File Write Performance
echo "Test 3: File Write Performance (10GB with disk writes)"
echo "Starting receiver..."
ssh ubuntu@$RECEIVER_IP "rdrecv 12347 write_key /mnt/nvme/benchmark/received_10GB" &
RECEIVER_PID=$!
sleep 2

echo "Starting sender..."
ssh ubuntu@$SENDER_IP "time rdsend -v $RECEIVER_IP 12347 write_key </mnt/nvme/benchmark/test_10GB" 2>&1 | tee "$RESULTS_DIR/test3_write_performance.log"

wait $RECEIVER_PID 2>/dev/null || true
ssh ubuntu@$RECEIVER_IP "rm -f /mnt/nvme/benchmark/received_10GB"
echo ""

# Test 4: Baseline - SCP Transfer
echo "Test 4: Baseline SCP Transfer (10GB)"
ssh ubuntu@$RECEIVER_IP "rm -f /mnt/nvme/benchmark/scp_test_10GB"
time ssh ubuntu@$SENDER_IP "scp /mnt/nvme/benchmark/test_10GB ubuntu@$RECEIVER_IP:/mnt/nvme/benchmark/scp_test_10GB" 2>&1 | tee "$RESULTS_DIR/test4_scp_baseline.log"
ssh ubuntu@$RECEIVER_IP "rm -f /mnt/nvme/benchmark/scp_test_10GB"
echo ""

# Test 5: Multiple parallel transfers
echo "Test 5: Parallel Transfers (4x 10GB files simultaneously)"
for i in {1..4}; do
    ssh ubuntu@$RECEIVER_IP "rdrecv $((12348+i)) parallel_${i} >/dev/null" &
done
sleep 2

for i in {1..4}; do
    ssh ubuntu@$SENDER_IP "rdsend -v $RECEIVER_IP $((12348+i)) parallel_${i} </mnt/nvme/benchmark/test_10GB" &
done | tee "$RESULTS_DIR/test5_parallel_transfers.log"

wait
echo ""

# Test 6: CPU Pinning Optimization
echo "Test 6: CPU Pinning Test"
echo "Starting receiver with CPU pinning..."
ssh ubuntu@$RECEIVER_IP "taskset -c 4 rdrecv 12353 pinned_key >/dev/null" &
RECEIVER_PID=$!
sleep 2

echo "Starting sender with CPU pinning..."
ssh ubuntu@$SENDER_IP "taskset -c 16,20,24 time rdsend -v $RECEIVER_IP 12353 pinned_key </mnt/nvme/benchmark/test_10GB" 2>&1 | tee "$RESULTS_DIR/test6_cpu_pinning.log"

wait $RECEIVER_PID 2>/dev/null || true
echo ""

# Generate summary report
echo "Generating summary report..."
cat > "$RESULTS_DIR/summary.md" << 'EOFSUM'
# RDMA Benchmark Results Summary

## Test Configuration
- Sender IP: SENDER_PLACEHOLDER
- Receiver IP: RECEIVER_PLACEHOLDER
- Date: DATE_PLACEHOLDER

## Results

### Test 1: Basic RDMA Bandwidth (10GB)
See test1_basic_bandwidth.log

### Test 2: Large Model Transfer (70GB)
See test2_70gb_model.log

### Test 3: File Write Performance
See test3_write_performance.log

### Test 4: SCP Baseline
See test4_scp_baseline.log

### Test 5: Parallel Transfers
See test5_parallel_transfers.log

### Test 6: CPU Pinning Optimization
See test6_cpu_pinning.log

## Performance Summary

| Test | Transfer Size | Time | Bandwidth |
|------|--------------|------|-----------|
| Basic RDMA | 10 GB | See log | See log |
| Large Model | 70 GB | See log | See log |
| SCP Baseline | 10 GB | See log | See log |

## Verification Checklist

- [ ] RDMA bandwidth > 5 GB/s for FDR
- [ ] RDMA bandwidth > 20 GB/s for HDR
- [ ] RDMA bandwidth > 40 GB/s for NDR
- [ ] 10-125x faster than SCP baseline
- [ ] Consistent performance across multiple runs

EOFSUM

sed -i "s/SENDER_PLACEHOLDER/$SENDER_IP/" "$RESULTS_DIR/summary.md"
sed -i "s/RECEIVER_PLACEHOLDER/$RECEIVER_IP/" "$RESULTS_DIR/summary.md"
sed -i "s/DATE_PLACEHOLDER/$(date)/" "$RESULTS_DIR/summary.md"

echo ""
echo "========================================"
echo "Benchmark Complete!"
echo "Results saved to: $RESULTS_DIR"
echo "========================================"
echo ""
echo "Next steps:"
echo "1. Review $RESULTS_DIR/summary.md"
echo "2. Compare bandwidth against expected values"
echo "3. Run additional tests if needed"
