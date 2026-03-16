#!/bin/bash
set -e

# Quick benchmark setup script
# Usage: ./quick-benchmark.sh [aws|azure|gcp]

PROVIDER=${1:-aws}
REGION=${2:-us-east-1}

echo "========================================="
echo "RDMA-Pipe Benchmark Quick Start"
echo "Provider: $PROVIDER"
echo "Region: $REGION"
echo "========================================="

# Check prerequisites
command -v terraform >/dev/null 2>&1 || { echo "terraform required but not installed. Aborting." >&2; exit 1; }
command -v ansible >/dev/null 2>&1 || { echo "ansible required but not installed. Aborting." >&2; exit 1; }

# Create working directory
WORK_DIR="benchmark-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "Working directory: $WORK_DIR"

# Copy scripts
cp -r ../scripts .
cp -r ../terraform/$PROVIDER .

# Initialize Terraform
cd $PROVIDER
terraform init

echo ""
echo "Ready to provision infrastructure."
echo "Next steps:"
echo "  1. Review and customize terraform.tfvars"
echo "  2. Run: terraform plan"
echo "  3. Run: terraform apply"
echo "  4. Run benchmark: ../scripts/run-benchmarks.sh"
