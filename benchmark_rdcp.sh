#!/bin/bash
#
# benchmark_rdcp.sh - Benchmark rdcp for single-host file and directory copies
#
# This benchmark tests rdcp performance on a single host, which is useful for:
# - Testing NVMe storage bandwidth
# - Measuring file copy performance using RDMA loopback
# - Validating rdcp performance optimizations (parallel I/O, O_DIRECT)
# - Creating baseline performance measurements
#
# Note: rdcp now uses RDMA loopback even for localhost-to-localhost copies
# instead of falling back to regular cp, because the RDMA path has better
# performance optimizations (parallel I/O, O_DIRECT).
#
# Usage: ./benchmark_rdcp.sh [test_dir]
#   test_dir - Directory to use for tests (default: /tmp/rdcp_bench)
#              Should be on fast storage (NVMe) for meaningful results

set -e

# Configuration
TEST_DIR="${1:-/tmp/rdcp_bench}"
RDCP="./rdcp"

# Test file sizes (in MB)
FILE_SIZES=(1 10 100 1000 5000)

# Directory tree test configuration
DIR_TREE_FILES=1000
DIR_TREE_FILE_SIZE_KB=100

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Check if rdcp exists
check_prerequisites() {
    if [ ! -x "$RDCP" ]; then
        log_error "rdcp not found or not executable at $RDCP"
        log_info "Run 'make' to build rdcp first"
        exit 1
    fi
    
    # Check if we have enough space
    local parent_dir=$(dirname "$TEST_DIR")
    if [ ! -d "$parent_dir" ]; then
        parent_dir="."
    fi
    local available_space=$(df -BM "$parent_dir" 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/M//' || echo "0")
    
    if [ -n "$available_space" ] && [ "$available_space" -gt 0 ] 2>/dev/null; then
        local required_space=$((10000 + 1000))  # Max file size + buffer
        if [ "$available_space" -lt "$required_space" ]; then
            log_warning "Only ${available_space}MB available, need at least ${required_space}MB"
            log_warning "Some large file tests may fail"
        fi
    fi
}

# Setup test directory
setup_test_dir() {
    log_info "Setting up test directory: $TEST_DIR"
    mkdir -p "$TEST_DIR"
    mkdir -p "$TEST_DIR/source"
    mkdir -p "$TEST_DIR/target"
    
    # Show filesystem info
    log_info "Filesystem info:"
    df -h "$TEST_DIR" | tail -1
    
    # Try to detect if this is NVMe
    local mount_point=$(df "$TEST_DIR" | tail -1 | awk '{print $1}')
    if [[ $mount_point == *"nvme"* ]]; then
        log_success "Test directory is on NVMe storage"
    else
        log_warning "Test directory may not be on NVMe storage (device: $mount_point)"
        log_warning "For best results, use NVMe storage"
    fi
}

# Cleanup test directory
cleanup_test_dir() {
    log_info "Cleaning up test directory"
    rm -rf "$TEST_DIR"
}

# Create test file of specified size in MB
create_test_file() {
    local size_mb=$1
    local filename=$2
    
    log_info "Creating ${size_mb}MB test file: $filename"
    
    # Use /dev/urandom for somewhat realistic data (not compressible)
    # For large files, use dd with larger block size for speed
    if [ "$size_mb" -lt 100 ]; then
        dd if=/dev/urandom of="$filename" bs=1M count="$size_mb" 2>/dev/null
    else
        # For larger files, use bigger blocks and fewer seeks
        dd if=/dev/urandom of="$filename" bs=4M count=$((size_mb / 4)) 2>/dev/null
    fi
    
    log_success "Created $(du -h "$filename" | cut -f1) file"
}

# Create directory tree for testing
create_test_tree() {
    local tree_dir=$1
    local num_files=$2
    local file_size_kb=$3
    
    log_info "Creating directory tree: $num_files files of ${file_size_kb}KB each"
    
    mkdir -p "$tree_dir"
    
    # Create directory structure (simulate real project)
    mkdir -p "$tree_dir/src"
    mkdir -p "$tree_dir/lib"
    mkdir -p "$tree_dir/docs"
    mkdir -p "$tree_dir/tests"
    
    local files_per_dir=$((num_files / 4))
    
    for dir in src lib docs tests; do
        for i in $(seq 1 $files_per_dir); do
            dd if=/dev/urandom of="$tree_dir/$dir/file_$i.dat" bs=1K count="$file_size_kb" 2>/dev/null
        done
    done
    
    local total_size=$(du -sh "$tree_dir" | cut -f1)
    log_success "Created directory tree: $num_files files, total size $total_size"
}

# Benchmark single file copy
benchmark_file() {
    local size_mb=$1
    local source_file="$TEST_DIR/source/testfile_${size_mb}mb"
    local target_file="$TEST_DIR/target/testfile_${size_mb}mb"
    
    # Clean target
    rm -f "$target_file"
    
    # Create source file if it doesn't exist
    if [ ! -f "$source_file" ]; then
        create_test_file "$size_mb" "$source_file"
    fi
    
    log_info "Benchmarking ${size_mb}MB file copy"
    
    # Warm up - drop caches to simulate cold start
    sync
    if [ -w /proc/sys/vm/drop_caches ]; then
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    fi
    
    # Run benchmark with timing
    local start_time=$(date +%s.%N)
    
    # Run rdcp with verbose to get bandwidth
    local output=$($RDCP -v "$source_file" "$target_file" 2>&1)
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    
    # Extract bandwidth if reported
    local bandwidth=$(echo "$output" | grep -oP "Bandwidth \K[0-9.]+" || echo "N/A")
    
    # Calculate bandwidth if not reported
    if [ "$bandwidth" = "N/A" ]; then
        local size_bytes=$((size_mb * 1024 * 1024))
        bandwidth=$(echo "scale=3; $size_bytes / $duration / 1000000000" | bc)
    fi
    
    # Verify copy succeeded
    if [ ! -f "$target_file" ]; then
        log_error "Copy failed - target file not created"
        return 1
    fi
    
    local source_size=$(stat -c%s "$source_file")
    local target_size=$(stat -c%s "$target_file")
    
    if [ "$source_size" != "$target_size" ]; then
        log_error "Copy failed - size mismatch (source: $source_size, target: $target_size)"
        return 1
    fi
    
    log_success "File copy: ${size_mb}MB in ${duration}s = ${bandwidth} GB/s"
    
    # Output CSV format for easy parsing
    echo "${size_mb},${duration},${bandwidth},file" >> "$TEST_DIR/results.csv"
    
    # Clean up target to save space
    rm -f "$target_file"
}

# Benchmark directory tree copy
benchmark_tree() {
    local source_tree="$TEST_DIR/source/tree"
    local target_tree="$TEST_DIR/target/tree"
    
    # Clean target
    rm -rf "$target_tree"
    
    # Create source tree if it doesn't exist
    if [ ! -d "$source_tree" ]; then
        create_test_tree "$source_tree" "$DIR_TREE_FILES" "$DIR_TREE_FILE_SIZE_KB"
    fi
    
    log_info "Benchmarking directory tree copy"
    
    # Warm up - drop caches
    sync
    if [ -w /proc/sys/vm/drop_caches ]; then
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    fi
    
    # Calculate total size
    local total_size_bytes=$(du -sb "$source_tree" | cut -f1)
    local total_size_mb=$((total_size_bytes / 1024 / 1024))
    
    # Run benchmark with timing
    local start_time=$(date +%s.%N)
    
    # Run rdcp with -r for recursive and verbose for bandwidth
    local output=$($RDCP -v -r "$source_tree" "$target_tree" 2>&1)
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    
    # Extract bandwidth if reported
    local bandwidth=$(echo "$output" | grep -oP "Bandwidth \K[0-9.]+" || echo "N/A")
    
    # Calculate bandwidth if not reported
    if [ "$bandwidth" = "N/A" ]; then
        bandwidth=$(echo "scale=3; $total_size_bytes / $duration / 1000000000" | bc)
    fi
    
    # Verify copy succeeded
    if [ ! -d "$target_tree" ]; then
        log_error "Tree copy failed - target directory not created"
        return 1
    fi
    
    local source_count=$(find "$source_tree" -type f | wc -l)
    local target_count=$(find "$target_tree" -type f | wc -l)
    
    if [ "$source_count" != "$target_count" ]; then
        log_error "Tree copy failed - file count mismatch (source: $source_count, target: $target_count)"
        return 1
    fi
    
    log_success "Tree copy: ${total_size_mb}MB ($source_count files) in ${duration}s = ${bandwidth} GB/s"
    
    # Output CSV format
    echo "${total_size_mb},${duration},${bandwidth},tree" >> "$TEST_DIR/results.csv"
    
    # Clean up target to save space
    rm -rf "$target_tree"
}

# Print summary report
print_summary() {
    echo ""
    echo "========================================"
    echo "  RDCP SINGLE-HOST BENCHMARK RESULTS"
    echo "========================================"
    echo ""
    
    if [ ! -f "$TEST_DIR/results.csv" ]; then
        log_error "No results found"
        return
    fi
    
    echo "Filesystem: $(df -h "$TEST_DIR" | tail -1 | awk '{print $1, $2, $6}')"
    echo ""
    
    printf "%-15s %-12s %-15s %-10s\n" "Size (MB)" "Time (s)" "Bandwidth (GB/s)" "Type"
    printf "%-15s %-12s %-15s %-10s\n" "--------" "--------" "---------------" "----"
    
    while IFS=, read -r size duration bandwidth type; do
        printf "%-15s %-12s %-15s %-10s\n" "$size" "$duration" "$bandwidth" "$type"
    done < "$TEST_DIR/results.csv"
    
    echo ""
    
    # Calculate average bandwidth
    local avg_bandwidth=$(awk -F, '{sum+=$3; count++} END {if(count>0) print sum/count; else print "0"}' "$TEST_DIR/results.csv")
    echo "Average bandwidth: ${avg_bandwidth} GB/s"
    
    echo ""
    echo "Results saved to: $TEST_DIR/results.csv"
    echo ""
}

# Main benchmark routine
run_benchmarks() {
    log_info "Starting rdcp single-host benchmarks"
    
    # Initialize results file
    echo "size_mb,duration_s,bandwidth_gbs,type" > "$TEST_DIR/results.csv"
    
    # Test single file copies
    echo ""
    log_info "=== Single File Copy Tests ==="
    for size in "${FILE_SIZES[@]}"; do
        benchmark_file "$size" || log_error "Benchmark failed for ${size}MB file"
        echo ""
    done
    
    # Test directory tree copy
    echo ""
    log_info "=== Directory Tree Copy Test ==="
    benchmark_tree || log_error "Tree benchmark failed"
    echo ""
    
    print_summary
}

# Main script
main() {
    echo ""
    echo "========================================"
    echo "  RDCP Single-Host Benchmark Suite"
    echo "========================================"
    echo ""
    
    check_prerequisites
    setup_test_dir
    
    # Trap cleanup on exit
    trap cleanup_test_dir EXIT
    
    run_benchmarks
    
    log_success "Benchmark complete!"
}

# Run main
main
