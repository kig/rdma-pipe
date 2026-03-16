# Terraform Configurations for RDMA Benchmarking

This directory contains Infrastructure as Code (IaC) configurations for provisioning RDMA-capable cloud instances for benchmarking.

## Directory Structure

```
terraform/
├── aws/          # AWS configurations (EFA)
├── azure/        # Azure configurations (InfiniBand)
└── gcp/          # GCP configurations (GPUDirect)
```

## Cloud Provider Support

### AWS (Elastic Fabric Adapter)

AWS provides EFA (Elastic Fabric Adapter) which offers RDMA-like performance:

- **Best for:** GPU workloads with EFA (p4d, p5 instances)
- **Budget option:** c5n.18xlarge (~$3.89/hour)
- **Performance:** ~100 Gbps (similar to InfiniBand EDR)
- **Region availability:** us-east-1, us-west-2 (best)

See [aws/README.md](aws/README.md) for detailed setup.

### Azure (InfiniBand HDR)

Azure provides true InfiniBand HDR (200 Gbps) on HPC VMs:

- **Best for:** Cost-effective RDMA benchmarking
- **Recommended:** Standard_HB120rs_v3 (~$3.60/hour)
- **Performance:** 200 Gbps InfiniBand HDR
- **Region availability:** eastus, westus2, northeurope

See [azure/README.md](azure/README.md) for detailed setup.

### GCP (GPUDirect RDMA)

GCP provides RDMA via GPUDirect on A2/A3 instances:

- **Best for:** GPU-to-GPU RDMA testing
- **Recommended:** a2-highgpu-8g (~$12.24/hour)
- **Performance:** GPUDirect RDMA, varies by configuration
- **Region availability:** us-central1, us-east4, europe-west4

See [gcp/README.md](gcp/README.md) for detailed setup.

## Quick Start

### Prerequisites

```bash
# Install Terraform
wget https://releases.hashicorp.com/terraform/1.6.0/terraform_1.6.0_linux_amd64.zip
unzip terraform_1.6.0_linux_amd64.zip
sudo mv terraform /usr/local/bin/

# Verify installation
terraform version
```

### AWS Example

```bash
# Configure AWS credentials
aws configure

# Navigate to AWS config
cd aws/

# Copy and customize variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your settings

# Initialize Terraform
terraform init

# Review plan
terraform plan

# Apply configuration
terraform apply

# Get instance IPs
terraform output
```

### Azure Example

```bash
# Login to Azure
az login

# Navigate to Azure config
cd azure/

# Initialize and apply
terraform init
terraform plan
terraform apply

# Get instance IPs
terraform output
```

### Cleanup

**Important:** Always destroy resources after benchmarking to avoid charges!

```bash
# In the provider directory (aws/ azure/ or gcp/)
terraform destroy -auto-approve
```

## Cost Estimates

4-hour benchmark session (2 instances):

| Provider | Instance Type | Hourly Cost | 4h Total |
|----------|--------------|-------------|----------|
| AWS | c5n.18xlarge | $7.78 | $31.12 |
| AWS | p4d.24xlarge | $65.54 | $262.16 |
| Azure | HB120rs_v3 | $7.20 | $28.80 |
| Azure | ND96asr_v4 | $65.54 | $262.16 |
| GCP | a2-highgpu-8g | $24.48 | $97.92 |

## Common Variables

All configurations support these common variables:

- `region` / `location` - Cloud provider region
- `instance_count` - Number of instances (default: 2)
- `instance_type` / `vm_size` - Instance/VM type
- SSH key configuration

## Security Considerations

- Instances are in same availability zone for low latency
- Security groups allow all traffic between benchmark instances
- SSH access restricted to your IP (configure in tfvars)
- Public IPs for SSH access, private IPs for RDMA

## Terraform State

**Warning:** Terraform state files contain sensitive information.

```bash
# Add to .gitignore
echo "*.tfstate" >> .gitignore
echo "*.tfstate.*" >> .gitignore
echo ".terraform/" >> .gitignore
```

## Advanced Configuration

### Custom Instance Types

Edit `terraform.tfvars`:

```hcl
# AWS - Use p4de for more memory
instance_type = "p4de.24xlarge"

# Azure - Use ND series for GPUs
vm_size = "Standard_ND96asr_v4"

# GCP - Use A3 for latest GPUs
machine_type = "a3-highgpu-8g"
```

### Multiple Regions

```bash
# Deploy to multiple regions for latency testing
terraform workspace new us-west
terraform apply -var="region=us-west-2"

terraform workspace new us-east
terraform apply -var="region=us-east-1"
```

## Troubleshooting

### Quota Limits

**Problem:** Instance quota exceeded

**Solution:**
1. Request quota increase from cloud provider
2. Try different region
3. Use smaller instance type

### Network Configuration

**Problem:** Instances can't communicate

**Solution:**
```bash
# Verify security group/NSG rules
terraform show | grep security

# Check instances in same AZ
terraform show | grep availability_zone
```

### SSH Access Issues

**Problem:** Can't SSH to instances

**Solution:**
```bash
# Verify your IP is allowed
curl ifconfig.me

# Update security group
terraform apply -var="my_ip=$(curl -s ifconfig.me)/32"
```

## See Also

- [BENCHMARKING_GUIDE.md](../BENCHMARKING_GUIDE.md) - Complete guide
- [scripts/](../scripts/) - Benchmark execution scripts
- Cloud provider docs for RDMA/EFA/InfiniBand setup
