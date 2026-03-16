#!/usr/bin/env python3
"""
RDMA Benchmark Results Analyzer
Parses benchmark logs and generates comparison reports
"""

import re
import sys
import json
from pathlib import Path
from datetime import datetime

def parse_bandwidth(log_file):
    """Extract bandwidth from log file"""
    bandwidth_pattern = r'Bandwidth\s+([\d.]+)\s+GB/s'
    time_pattern = r'real\s+(\d+)m([\d.]+)s'
    
    bandwidth = None
    time_seconds = None
    
    try:
        with open(log_file, 'r') as f:
            content = f.read()
            
            # Extract bandwidth
            bw_match = re.search(bandwidth_pattern, content)
            if bw_match:
                bandwidth = float(bw_match.group(1))
            
            # Extract time
            time_match = re.search(time_pattern, content)
            if time_match:
                minutes = int(time_match.group(1))
                seconds = float(time_match.group(2))
                time_seconds = minutes * 60 + seconds
    
    except Exception as e:
        print(f"Error parsing {log_file}: {e}")
    
    return bandwidth, time_seconds

def calculate_speedup(rdma_time, baseline_time):
    """Calculate speedup factor"""
    if rdma_time and baseline_time:
        return baseline_time / rdma_time
    return None

def generate_report(results_dir):
    """Generate comprehensive benchmark report"""
    results_path = Path(results_dir)
    
    if not results_path.exists():
        print(f"Error: Results directory {results_dir} not found")
        return
    
    print("=" * 60)
    print("RDMA Benchmark Analysis Report")
    print("=" * 60)
    print(f"Results Directory: {results_dir}")
    print(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print()
    
    # Parse test results
    results = {}
    
    # Test 1: Basic bandwidth
    bw1, time1 = parse_bandwidth(results_path / "test1_basic_bandwidth.log")
    if bw1:
        results['basic_10gb'] = {'bandwidth': bw1, 'time': time1}
        print(f"Test 1 - Basic RDMA (10GB):")
        print(f"  Bandwidth: {bw1:.2f} GB/s")
        if time1:
            print(f"  Time: {time1:.2f} seconds")
        print()
    
    # Test 2: Large model
    bw2, time2 = parse_bandwidth(results_path / "test2_70gb_model.log")
    if bw2:
        results['model_70gb'] = {'bandwidth': bw2, 'time': time2}
        print(f"Test 2 - Large Model (70GB):")
        print(f"  Bandwidth: {bw2:.2f} GB/s")
        if time2:
            print(f"  Time: {time2:.2f} seconds")
        print()
    
    # Test 3: Write performance
    bw3, time3 = parse_bandwidth(results_path / "test3_write_performance.log")
    if bw3:
        results['write_10gb'] = {'bandwidth': bw3, 'time': time3}
        print(f"Test 3 - Write Performance (10GB):")
        print(f"  Bandwidth: {bw3:.2f} GB/s")
        if time3:
            print(f"  Time: {time3:.2f} seconds")
        print()
    
    # Test 4: SCP baseline
    _, time4 = parse_bandwidth(results_path / "test4_scp_baseline.log")
    if time4:
        results['scp_10gb'] = {'time': time4}
        print(f"Test 4 - SCP Baseline (10GB):")
        print(f"  Time: {time4:.2f} seconds")
        if time1:
            speedup = calculate_speedup(time1, time4)
            print(f"  RDMA Speedup: {speedup:.1f}x faster")
        print()
    
    # Test 6: CPU pinning
    bw6, time6 = parse_bandwidth(results_path / "test6_cpu_pinning.log")
    if bw6:
        results['cpu_pinned'] = {'bandwidth': bw6, 'time': time6}
        print(f"Test 6 - CPU Pinning (10GB):")
        print(f"  Bandwidth: {bw6:.2f} GB/s")
        if time6:
            print(f"  Time: {time6:.2f} seconds")
        if bw1:
            improvement = ((bw6 - bw1) / bw1) * 100
            print(f"  Improvement: {improvement:+.1f}%")
        print()
    
    # Performance classification
    print("=" * 60)
    print("Performance Classification")
    print("=" * 60)
    
    if bw1:
        if bw1 >= 40:
            classification = "NDR (400G) - Excellent"
        elif bw1 >= 20:
            classification = "HDR (200G) - Very Good"
        elif bw1 >= 10:
            classification = "EDR (100G) - Good"
        elif bw1 >= 5:
            classification = "FDR (56G) - Acceptable"
        else:
            classification = "Below FDR - Check Configuration"
        
        print(f"RDMA Generation: {classification}")
        print(f"Measured Bandwidth: {bw1:.2f} GB/s")
        print()
    
    # Verification checklist
    print("=" * 60)
    print("Verification Checklist")
    print("=" * 60)
    
    checks = {
        "RDMA bandwidth > 5 GB/s (FDR minimum)": bw1 and bw1 >= 5,
        "RDMA > 10x faster than SCP": time1 and time4 and calculate_speedup(time1, time4) >= 10,
        "Large file transfer consistent": bw1 and bw2 and abs(bw1 - bw2) / bw1 < 0.2,
        "Write performance reasonable": bw3 and bw3 >= 3.0,
    }
    
    for check, passed in checks.items():
        status = "✓ PASS" if passed else "✗ FAIL"
        print(f"{status}: {check}")
    
    print()
    
    # Save JSON results
    json_output = results_path / "results.json"
    with open(json_output, 'w') as f:
        json.dump(results, f, indent=2)
    print(f"JSON results saved to: {json_output}")
    
    print("=" * 60)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: ./analyze-results.py <results-directory>")
        sys.exit(1)
    
    generate_report(sys.argv[1])
