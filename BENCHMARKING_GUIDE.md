# RDMA-Pipe Benchmarking and Verification Guide

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Cloud Provider Setup](#cloud-provider-setup)
4. [Infrastructure Requirements](#infrastructure-requirements)
5. [Automated Setup Scripts](#automated-setup-scripts)
6. [Benchmark Tests](#benchmark-tests)
7. [Results Validation](#results-validation)
8. [Troubleshooting](#troubleshooting)
9. [Cost Estimates](#cost-estimates)

---

## Overview

This guide provides step-by-step instructions for benchmarking rdma-pipe performance claims across different RDMA hardware generations (FDR 56G, HDR 200G, NDR 400G) using cloud infrastructure.

### What You'll Verify

Based on the performance claims in the documentation:

| RDMA Generation | Expected Bandwidth | Test Case | Expected Time |
|-----------------|-------------------|-----------|---------------|
| FDR (56 Gbps) | 5-7 GB/s | 70GB model load | 10-14 seconds |
| HDR (200 Gbps) | 20-25 GB/s | 70GB model load | 2.8-3.5 seconds |
| NDR (400 Gbps) | 40-50 GB/s | 70GB model load | 1.4-1.75 seconds |
| Traditional (SCP) | 400 MB/s | 70GB model load | 175 seconds |

### Benchmark Objectives

1. **Verify baseline performance** - Confirm RDMA bandwidth matches specifications
2. **Test real-world scenarios** - Model loading, dataset transfers, checkpoints
3. **Compare against baselines** - SCP, rsync, NFS, HTTP
4. **Validate cost claims** - Measure actual time savings for ROI calculations
5. **Document reproducibility** - Enable others to verify results

---

## Prerequisites

### Local Requirements

- **Operating System:** Linux (Ubuntu 20.04+ recommended) or macOS
- **Tools:**
  - `terraform` (v1.0+) or cloud provider CLI
  - `ansible` (v2.10+) for configuration management
  - `jq` for JSON processing
  - SSH client
  - Git

### Cloud Provider Accounts

You'll need an account with at least one of:
- **AWS** - For p4d instances with EFA (Elastic Fabric Adapter)
- **Azure** - For InfiniBand-enabled VMs (HB, HC, or ND series)
- **GCP** - For A2 or A3 instances with GPUDirect RDMA

### Budget Planning

Estimated costs for a 4-hour benchmark session:

| Provider | Instance Type | RDMA Support | Cost/Hour | Total (4h) |
|----------|--------------|--------------|-----------|------------|
| AWS | p4d.24xlarge (x2) | EFA (100 Gbps) | $65.54 | $262.16 |
| Azure | Standard_HB120rs_v3 (x2) | InfiniBand HDR | $7.20 | $28.80 |
| GCP | a2-highgpu-8g (x2) | GPUDirect | $24.48 | $97.92 |

> **Note:** Azure HB-series provides best cost/performance for RDMA benchmarking without GPUs.

---

## Cloud Provider Setup

### Option 1: AWS with EFA (Elastic Fabric Adapter)

AWS EFA provides RDMA-like performance using proprietary networking (100 Gbps similar to HDR).

#### AWS Prerequisites

```bash
# Install AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# Configure credentials
aws configure
# Enter: AWS Access Key ID, Secret Access Key, Region (us-east-1), Output format (json)

# Install Terraform (if using)
wget https://releases.hashicorp.com/terraform/1.6.0/terraform_1.6.0_linux_amd64.zip
unzip terraform_1.6.0_linux_amd64.zip
sudo mv terraform /usr/local/bin/
```

#### AWS Instance Requirements

- **Instance Type:** p4d.24xlarge (8x A100 GPUs, EFA)
- **Alternative:** p4de.24xlarge (EFA, more memory)
- **Budget Option:** c5n.18xlarge (EFA, no GPU)
- **Region:** us-east-1, us-west-2 (best p4d availability)
- **AMI:** Deep Learning AMI (Ubuntu 20.04)

### Option 2: Azure with InfiniBand

Azure provides true InfiniBand HDR (200 Gbps) on HPC-optimized VMs.

#### Azure Prerequisites

```bash
# Install Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Login
az login

# Set subscription
az account set --subscription "Your-Subscription-Name"

# Install Terraform provider
terraform init  # Will download Azure provider
```

#### Azure Instance Requirements

- **Instance Type:** Standard_HB120rs_v3 (InfiniBand HDR)
- **Alternative:** Standard_HC44rs (InfiniBand HDR, budget)
- **GPU Option:** Standard_ND96asr_v4 (InfiniBand HDR + 8x A100)
- **Region:** eastus, westus2, northeurope
- **Image:** Ubuntu 20.04 LTS HPC

### Option 3: GCP with GPUDirect

GCP provides RDMA capabilities through GPUDirect on A2/A3 instances.

#### GCP Prerequisites

```bash
# Install gcloud CLI
curl https://sdk.cloud.google.com | bash
exec -l $SHELL

# Initialize and authenticate
gcloud init
gcloud auth application-default login

# Enable required APIs
gcloud services enable compute.googleapis.com
```

#### GCP Instance Requirements

- **Instance Type:** a2-highgpu-8g (8x A100, GPUDirect)
- **Alternative:** a2-highgpu-2g (2x A100, budget)
- **Region:** us-central1, us-east4, europe-west4
- **Image:** Deep Learning VM (TensorFlow/PyTorch)

---

## Infrastructure Requirements

### Networking Requirements

**For accurate RDMA benchmarks:**

1. **Same Availability Zone** - Instances must be in same AZ/region
2. **RDMA-Capable NICs:**
   - AWS: EFA adapter (automatically enabled on p4d)
   - Azure: InfiniBand HCA (automatically on HB/HC/ND series)
   - GCP: GPUDirect enabled (automatic on A2/A3)
3. **Security Group/Firewall:**
   - Allow all traffic between benchmark instances
   - Port 7691 for rdpipe (default)
   - Custom ports for rdsend/rdrecv (typically 12345+)

### Storage Requirements

**NVMe Storage for realistic testing:**

1. **AWS:** Instance store NVMe (included with p4d, c5n)
2. **Azure:** Premium SSD or Ultra Disk
3. **GCP:** Local SSD (up to 9TB on a2-highgpu-8g)

**Minimum:**
- 100GB for OS and tools
- 200GB for test files (100GB model files)
- Total: 500GB recommended

### GPU Requirements (Optional)

For GPU-specific benchmarks:

1. **GPUDirect RDMA Testing:**
   - NVIDIA A100 or newer
   - GPUDirect drivers installed
   - CUDA 11.0+

2. **Model Loading to GPU:**
   - 40GB+ GPU memory for large models
   - Multiple GPUs for distributed tests

---

## Automated Setup Scripts

### Quick Start Script

Save as `scripts/quick-benchmark.sh`:

```bash
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
```

### AWS Terraform Configuration

Save as `terraform/aws/main.tf`:

```hcl
# AWS RDMA Benchmark Infrastructure
terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# Variables
variable "region" {
  description = "AWS region"
  default     = "us-east-1"
}

variable "instance_type" {
  description = "Instance type (must support EFA)"
  default     = "c5n.18xlarge"  # Budget option, use p4d.24xlarge for GPU+EFA
}

variable "instance_count" {
  description = "Number of instances for benchmark"
  default     = 2
}

variable "key_name" {
  description = "SSH key pair name"
  type        = string
}

variable "my_ip" {
  description = "Your IP address for SSH access"
  type        = string
}

# Latest Ubuntu 20.04 AMI with EFA support
data "aws_ami" "ubuntu_efa" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Deep Learning AMI Ubuntu 20.04*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# VPC and Networking
resource "aws_vpc" "benchmark" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "rdma-benchmark-vpc"
  }
}

resource "aws_subnet" "benchmark" {
  vpc_id                  = aws_vpc.benchmark.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "rdma-benchmark-subnet"
  }
}

resource "aws_internet_gateway" "benchmark" {
  vpc_id = aws_vpc.benchmark.id

  tags = {
    Name = "rdma-benchmark-igw"
  }
}

resource "aws_route_table" "benchmark" {
  vpc_id = aws_vpc.benchmark.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.benchmark.id
  }

  tags = {
    Name = "rdma-benchmark-rt"
  }
}

resource "aws_route_table_association" "benchmark" {
  subnet_id      = aws_subnet.benchmark.id
  route_table_id = aws_route_table.benchmark.id
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Security Group
resource "aws_security_group" "benchmark" {
  name        = "rdma-benchmark-sg"
  description = "Security group for RDMA benchmarking"
  vpc_id      = aws_vpc.benchmark.id

  # SSH from your IP
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  # All traffic within security group (for RDMA)
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  # All outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "rdma-benchmark-sg"
  }
}

# Placement Group for low latency
resource "aws_placement_group" "benchmark" {
  name     = "rdma-benchmark-pg"
  strategy = "cluster"
}

# EC2 Instances
resource "aws_instance" "benchmark" {
  count = var.instance_count

  ami                    = data.aws_ami.ubuntu_efa.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = aws_subnet.benchmark.id
  vpc_security_group_ids = [aws_security_group.benchmark.id]
  placement_group        = aws_placement_group.benchmark.id

  # EFA Network Interface
  network_interface {
    device_index          = 0
    network_interface_id  = aws_network_interface.benchmark[count.index].id
    delete_on_termination = false
  }

  # User data for basic setup
  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y build-essential git rdma-core libibverbs-dev librdmacm-dev
              
              # Clone rdma-pipe
              cd /opt
              git clone https://github.com/kig/rdma-pipe.git
              cd rdma-pipe
              make
              make install
              
              # Setup test directory
              mkdir -p /mnt/nvme/benchmark
              
              # Create test files
              dd if=/dev/urandom of=/mnt/nvme/benchmark/test_10GB bs=1M count=10240
              dd if=/dev/urandom of=/mnt/nvme/benchmark/test_70GB bs=1M count=71680
              
              echo "Setup complete" > /var/log/rdma-benchmark-setup.log
              EOF

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
  }

  tags = {
    Name = "rdma-benchmark-${count.index + 1}"
  }
}

# EFA Network Interfaces
resource "aws_network_interface" "benchmark" {
  count = var.instance_count

  subnet_id         = aws_subnet.benchmark.id
  security_groups   = [aws_security_group.benchmark.id]
  interface_type    = "efa"
  
  tags = {
    Name = "rdma-benchmark-efa-${count.index + 1}"
  }
}

# Outputs
output "instance_ips" {
  value = aws_instance.benchmark[*].public_ip
  description = "Public IPs of benchmark instances"
}

output "instance_private_ips" {
  value = aws_instance.benchmark[*].private_ip
  description = "Private IPs for RDMA communication"
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_instance.benchmark[0].public_ip}"
  description = "SSH command for first instance"
}
```

Save as `terraform/aws/terraform.tfvars.example`:

```hcl
region         = "us-east-1"
instance_type  = "c5n.18xlarge"  # or "p4d.24xlarge" for GPU
instance_count = 2
key_name       = "your-ssh-key-name"
my_ip          = "your.ip.address.here/32"
```

### Azure Terraform Configuration

Save as `terraform/azure/main.tf`:

```hcl
# Azure RDMA Benchmark Infrastructure
terraform {
  required_version = ">= 1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "location" {
  description = "Azure region"
  default     = "eastus"
}

variable "vm_size" {
  description = "VM size (must support InfiniBand)"
  default     = "Standard_HB120rs_v3"  # InfiniBand HDR 200Gbps
}

variable "vm_count" {
  description = "Number of VMs"
  default     = 2
}

variable "admin_username" {
  description = "Admin username"
  default     = "azureuser"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key"
  default     = "~/.ssh/id_rsa.pub"
}

# Resource Group
resource "azurerm_resource_group" "benchmark" {
  name     = "rdma-benchmark-rg"
  location = var.location
}

# Virtual Network
resource "azurerm_virtual_network" "benchmark" {
  name                = "rdma-benchmark-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.benchmark.location
  resource_group_name = azurerm_resource_group.benchmark.name
}

resource "azurerm_subnet" "benchmark" {
  name                 = "rdma-benchmark-subnet"
  resource_group_name  = azurerm_resource_group.benchmark.name
  virtual_network_name = azurerm_virtual_network.benchmark.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Network Security Group
resource "azurerm_network_security_group" "benchmark" {
  name                = "rdma-benchmark-nsg"
  location            = azurerm_resource_group.benchmark.location
  resource_group_name = azurerm_resource_group.benchmark.name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowVnetInBound"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }
}

# Public IPs
resource "azurerm_public_ip" "benchmark" {
  count               = var.vm_count
  name                = "rdma-benchmark-pip-${count.index + 1}"
  location            = azurerm_resource_group.benchmark.location
  resource_group_name = azurerm_resource_group.benchmark.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# Network Interfaces
resource "azurerm_network_interface" "benchmark" {
  count                         = var.vm_count
  name                          = "rdma-benchmark-nic-${count.index + 1}"
  location                      = azurerm_resource_group.benchmark.location
  resource_group_name           = azurerm_resource_group.benchmark.name
  enable_accelerated_networking = true

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.benchmark.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.benchmark[count.index].id
  }
}

resource "azurerm_network_interface_security_group_association" "benchmark" {
  count                     = var.vm_count
  network_interface_id      = azurerm_network_interface.benchmark[count.index].id
  network_security_group_id = azurerm_network_security_group.benchmark.id
}

# Proximity Placement Group (for low latency)
resource "azurerm_proximity_placement_group" "benchmark" {
  name                = "rdma-benchmark-ppg"
  location            = azurerm_resource_group.benchmark.location
  resource_group_name = azurerm_resource_group.benchmark.name
}

# Virtual Machines
resource "azurerm_linux_virtual_machine" "benchmark" {
  count                 = var.vm_count
  name                  = "rdma-benchmark-vm-${count.index + 1}"
  location              = azurerm_resource_group.benchmark.location
  resource_group_name   = azurerm_resource_group.benchmark.name
  network_interface_ids = [azurerm_network_interface.benchmark[count.index].id]
  size                  = var.vm_size
  proximity_placement_group_id = azurerm_proximity_placement_group.benchmark.id

  admin_username = var.admin_username

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(var.ssh_public_key_path)
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }

  source_image_reference {
    publisher = "microsoft-dsvm"
    offer     = "ubuntu-hpc"
    sku       = "2004"
    version   = "latest"
  }

  custom_data = base64encode(<<-EOF
              #!/bin/bash
              # Install RDMA drivers and tools
              apt-get update
              apt-get install -y rdma-core libibverbs-dev librdmacm-dev build-essential git
              
              # Clone and build rdma-pipe
              cd /opt
              git clone https://github.com/kig/rdma-pipe.git
              cd rdma-pipe
              make
              make install
              
              # Setup test directory
              mkdir -p /mnt/benchmark
              dd if=/dev/urandom of=/mnt/benchmark/test_10GB bs=1M count=10240
              dd if=/dev/urandom of=/mnt/benchmark/test_70GB bs=1M count=71680
              EOF
  )

  tags = {
    environment = "benchmark"
  }
}

# Outputs
output "public_ips" {
  value = azurerm_public_ip.benchmark[*].ip_address
  description = "Public IPs of benchmark VMs"
}

output "private_ips" {
  value = azurerm_network_interface.benchmark[*].private_ip_address
  description = "Private IPs for RDMA communication"
}

output "ssh_commands" {
  value = [
    for ip in azurerm_public_ip.benchmark[*].ip_address :
    "ssh ${var.admin_username}@${ip}"
  ]
  description = "SSH commands for VMs"
}
```

### Benchmark Execution Scripts

Save as `scripts/run-benchmarks.sh`:

```bash
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
RESULT1_PLACEHOLDER

### Test 2: Large Model Transfer (70GB)
RESULT2_PLACEHOLDER

### Test 3: File Write Performance
RESULT3_PLACEHOLDER

### Test 4: SCP Baseline
RESULT4_PLACEHOLDER

### Test 5: Parallel Transfers
RESULT5_PLACEHOLDER

### Test 6: CPU Pinning Optimization
RESULT6_PLACEHOLDER

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
```

Save as `scripts/verify-rdma.sh`:

```bash
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
```

Save as `scripts/analyze-results.py`:

```python
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
```

Make it executable:
```bash
chmod +x scripts/run-benchmarks.sh
chmod +x scripts/verify-rdma.sh
chmod +x scripts/analyze-results.py
```

---

## Benchmark Tests

### Test Suite Overview

The benchmark suite includes 6 core tests:

1. **Basic RDMA Bandwidth** - 10GB transfer to /dev/null (pure network speed)
2. **Large Model Transfer** - 70GB file (simulates LLaMA-70B model loading)
3. **File Write Performance** - 10GB with disk writes (realistic scenario)
4. **SCP Baseline** - Traditional transfer method for comparison
5. **Parallel Transfers** - 4 simultaneous 10GB transfers (multi-client)
6. **CPU Pinning** - Optimization test with taskset

### Running the Benchmarks

#### Step 1: Setup Infrastructure

```bash
# AWS example
cd terraform/aws
terraform init
terraform apply -var-file=terraform.tfvars

# Note the output IPs
export SENDER_IP=<private-ip-1>
export RECEIVER_IP=<private-ip-2>
export PUBLIC_IP=<public-ip-1>
```

#### Step 2: Verify RDMA Setup

```bash
# SSH to first instance
ssh -i ~/.ssh/your-key.pem ubuntu@$PUBLIC_IP

# Run verification script
sudo /opt/rdma-pipe/scripts/verify-rdma.sh

# Check for:
# - RDMA devices detected (ibv_devices)
# - Active InfiniBand/EFA link
# - Memory lock limits OK
# - rdma-pipe installed
```

#### Step 3: Run Benchmark Suite

```bash
# From your local machine (or from one of the instances)
cd scripts
./run-benchmarks.sh $SENDER_IP $RECEIVER_IP
```

#### Step 4: Analyze Results

```bash
# After benchmarks complete
./analyze-results.py results-<timestamp>

# Review summary
cat results-<timestamp>/summary.md
```

### Manual Testing

For interactive testing:

```bash
# On receiver (use private IP for RDMA)
rdrecv 12345 my_secret_key >/dev/null

# On sender
time rdsend -v <receiver-private-ip> 12345 my_secret_key </mnt/nvme/test_file

# Expected output:
# Bandwidth 5.127 GB/s (FDR)
# Bandwidth 25.3 GB/s (HDR)
# Bandwidth 48.2 GB/s (NDR)
```

---

## Results Validation

### Expected Performance Ranges

Based on RDMA hardware generation:

| Metric | FDR (56G) | HDR (200G) | NDR (400G) |
|--------|-----------|------------|------------|
| **Raw Bandwidth** | 5-7 GB/s | 20-25 GB/s | 40-50 GB/s |
| **10GB Transfer** | 1.5-2s | 0.4-0.5s | 0.2-0.25s |
| **70GB Model** | 10-14s | 2.8-3.5s | 1.4-1.75s |
| **vs SCP Speedup** | 10-15x | 40-60x | 80-125x |

### Validation Criteria

**Minimum Requirements (FDR):**
- ✓ Bandwidth ≥ 5 GB/s
- ✓ 70GB transfer ≤ 15 seconds
- ✓ 10x faster than SCP

**Good Performance (HDR):**
- ✓ Bandwidth ≥ 20 GB/s
- ✓ 70GB transfer ≤ 4 seconds
- ✓ 50x faster than SCP

**Excellent Performance (NDR):**
- ✓ Bandwidth ≥ 40 GB/s
- ✓ 70GB transfer ≤ 2 seconds
- ✓ 100x faster than SCP

### Common Performance Issues

1. **Lower than expected bandwidth:**
   - Check: Same availability zone?
   - Check: RDMA link active? (`ibstatus`)
   - Check: Network congestion?
   - Check: CPU pinning optimization

2. **High variability:**
   - Run multiple iterations
   - Check for background processes
   - Verify no thermal throttling

3. **Write performance slow:**
   - Check storage type (NVMe vs EBS)
   - Check filesystem (ext4 vs ZFS)
   - Try O_DIRECT mode

---

## Troubleshooting

### RDMA Device Not Found

**Problem:** `ibv_devices` shows no devices

**AWS EFA:**
```bash
# Check EFA installation
ls -l /opt/amazon/efa/

# Reinstall if needed
wget https://efa-installer.amazonaws.com/aws-efa-installer-latest.tar.gz
tar -xf aws-efa-installer-latest.tar.gz
cd aws-efa-installer
sudo ./efa_installer.sh -y
```

**Azure InfiniBand:**
```bash
# Reload InfiniBand drivers
sudo modprobe ib_uverbs
sudo modprobe rdma_ucm

# Check kernel modules
lsmod | grep ib_
```

### Connection Timeout

**Problem:** `rdsend` times out connecting to `rdrecv`

**Solutions:**
1. Start `rdrecv` first (it's the server)
2. Check firewall/security groups allow traffic
3. Use private IPs for RDMA communication
4. Verify same availability zone

```bash
# Test basic connectivity
ping <receiver-private-ip>

# Test RDMA pingpong
# On receiver:
ibv_rc_pingpong

# On sender:
ibv_rc_pingpong <receiver-private-ip>
```

### Memory Lock Limit Error

**Problem:** "Cannot allocate memory" or "mlock failed"

**Solution:**
```bash
# Check current limit
ulimit -l

# Increase temporarily
ulimit -l unlimited

# Permanent fix
sudo tee /etc/security/limits.d/rdma.conf << EOF
*       soft    memlock         unlimited
*       hard    memlock         unlimited
EOF

# Re-login for changes to take effect
```

### Low Performance

**Problem:** Bandwidth much lower than expected

**Diagnostic steps:**
```bash
# 1. Verify RDMA link speed
ibstatus | grep -i rate

# 2. Check CPU usage
top -bn1 | grep Cpu

# 3. Test with qperf
# On receiver:
qperf

# On sender:
qperf <receiver-ip> rc_bw

# 4. Try CPU pinning
taskset -c 0 rdrecv 12345 key >/dev/null
taskset -c 1 rdsend <receiver> 12345 key <test_file
```

---

## Cost Estimates

### AWS

**p4d.24xlarge (8x A100, EFA):**
- Instance: $32.77/hour × 2 = $65.54/hour
- Storage: Included instance store NVMe
- **4-hour benchmark: $262.16**

**c5n.18xlarge (EFA, no GPU):**
- Instance: $3.888/hour × 2 = $7.78/hour
- **4-hour benchmark: $31.12** ✓ Budget option

### Azure

**Standard_HB120rs_v3 (InfiniBand HDR):**
- Instance: $3.60/hour × 2 = $7.20/hour
- Storage: $0.13/GB for Premium SSD (100GB = $13/month, negligible for 4h)
- **4-hour benchmark: $28.80** ✓ Best value

**Standard_ND96asr_v4 (InfiniBand + 8x A100):**
- Instance: $32.77/hour × 2 = $65.54/hour
- **4-hour benchmark: $262.16**

### GCP

**a2-highgpu-8g (8x A100, GPUDirect):**
- Instance: $12.24/hour × 2 = $24.48/hour
- Local SSD: Included
- **4-hour benchmark: $97.92**

### Cost-Saving Tips

1. **Use Spot/Preemptible instances** (50-90% discount)
2. **Test during off-peak hours**
3. **Destroy resources immediately after** (use `terraform destroy`)
4. **Budget option: Azure HB-series** (~$29 for full benchmark)
5. **Start with c5n on AWS** (~$31 vs $262 for p4d)

---

## Quick Reference Commands

### Terraform Workflow
```bash
# Initialize
terraform init

# Preview changes
terraform plan

# Create infrastructure
terraform apply -auto-approve

# Get outputs
terraform output

# Destroy infrastructure
terraform destroy -auto-approve
```

### RDMA Verification
```bash
# Check devices
ibv_devices

# Check link status
ibstatus

# Test RDMA bandwidth
qperf <remote-ip> rc_bw

# Check memory limits
ulimit -l
```

### Benchmark Execution
```bash
# Verify environment
./scripts/verify-rdma.sh

# Run full benchmark suite
./scripts/run-benchmarks.sh <sender-ip> <receiver-ip>

# Analyze results
./scripts/analyze-results.py results-<timestamp>

# Manual test
rdrecv 12345 key >/dev/null  # receiver
rdsend -v <ip> 12345 key <file  # sender
```

---

## Additional Resources

- **AWS EFA Documentation:** https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html
- **Azure InfiniBand:** https://docs.microsoft.com/en-us/azure/virtual-machines/workloads/hpc/enable-infiniband
- **GCP GPUDirect:** https://cloud.google.com/compute/docs/gpus/gpu-direct-rdma
- **RDMA Programming:** https://www.rdmamojo.com/
- **perftest Tools:** https://github.com/linux-rdma/perftest

---

## Contributing

Found an issue with the benchmark scripts or have improvements?

1. Open an issue at https://github.com/kig/rdma-pipe/issues
2. Submit a PR with your enhancements
3. Share your benchmark results!

---

*Last Updated: February 2026*
*Version: 1.0*
