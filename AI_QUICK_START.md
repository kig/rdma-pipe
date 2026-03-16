# Quick Start: AI/ML Workflows with rdma-pipe

This guide provides copy-paste examples for common AI/ML scenarios using rdma-pipe.

## Prerequisites

```bash
# Install on Ubuntu
sudo apt install -y rdma-core librdmacm-dev ruby
cd /path/to/rdma-pipe
sudo make install

# Verify RDMA network
ibv_devices  # Should list your RDMA devices
ibstatus     # Should show active link
```

## Common Workflows

### 1. Load Large Language Model Weights

```bash
# Load LLaMA-70B model (70 GB) from weights server
# Traditional: ~3 minutes with SCP
# RDMA: ~14 seconds

rdcp -v weights-server:/models/llama-2-70b /local/nvme/models/llama-2-70b

# Load multiple models in parallel
rdcp -v weights-server:/models/llama-2-7b /local/nvme/models/llama-2-7b &
rdcp -v weights-server:/models/llama-2-13b /local/nvme/models/llama-2-13b &
rdcp -v weights-server:/models/llama-2-70b /local/nvme/models/llama-2-70b &
wait
```

### 2. Load HuggingFace Models

```bash
# Sync entire HuggingFace cache from a central server
# This is useful when you have pre-downloaded models on a central server

rdcp -r -v weights-server:~/.cache/huggingface/hub /local/nvme/.cache/huggingface/hub

# Or specific model
rdcp -r -v weights-server:~/.cache/huggingface/hub/models--meta-llama--Llama-2-70b-hf \
          /local/nvme/.cache/huggingface/hub/models--meta-llama--Llama-2-70b-hf
```

### 3. Transfer Training Dataset

```bash
# Transfer ImageNet dataset (150 GB)
# Traditional: ~25 minutes
# RDMA: ~30 seconds

rdcp -r -v data-server:/datasets/imagenet /local/nvme/datasets/imagenet

# Transfer specific splits
rdcp -v data-server:/datasets/imagenet/train.tar /local/nvme/datasets/train.tar &
rdcp -v data-server:/datasets/imagenet/val.tar /local/nvme/datasets/val.tar &
wait
```

### 4. Save Training Checkpoint

```bash
# During training, save checkpoint to backup server
# From within your training script or manually:

rdcp -v /local/nvme/checkpoints/checkpoint_epoch_100.pt \
     backup-server:/checkpoints/run_2024_experiment/checkpoint_epoch_100.pt

# Full checkpoint directory
rdcp -r -v /local/nvme/checkpoints/run_2024_experiment \
           backup-server:/checkpoints/run_2024_experiment
```

### 5. Restore from Checkpoint

```bash
# Resume training from a checkpoint
rdcp -v backup-server:/checkpoints/run_2024_experiment/checkpoint_epoch_100.pt \
     /local/nvme/checkpoint_resume.pt

# Then in your Python training code:
# checkpoint = torch.load('/local/nvme/checkpoint_resume.pt')
# model.load_state_dict(checkpoint['model_state_dict'])
```

### 6. Distribute Model Shards for Model Parallelism

```bash
# Distribute shards of a large model to multiple GPU workers
# Example: GPT-3 175B split across 8 nodes

for i in {0..7}; do
  rdcp -v weights-server:/models/gpt-175b/shard_${i}.pt \
       gpu-worker-${i}:/local/nvme/model_shard.pt &
done
wait

echo "All shards distributed"
```

### 7. Stream Preprocessing Pipeline

```bash
# On preprocessing server, start streaming preprocessed data
rdrecv 7691 preprocess_key | python preprocess.py | rdsend training-node-1 7692 training_key

# On training node, receive and cache
rdrecv 7692 training_key > /local/nvme/preprocessed_data.bin
```

### 8. Multi-Node Pipeline with rdpipe

```bash
# Process data through multiple stages across different servers
rdpipe \
  data-server:'< raw_videos.tar' \
  preprocess-server:'python extract_frames.py' \
  feature-server:'python extract_features.py' \
  training-server:'> training_features.bin'

# More complex pipeline with branching (tee to multiple destinations)
rdpipe \
  source:'zfs send tank/datasets@snapshot' \
  backup1:'tee >(zfs recv tank/datasets)' \
  backup2:'tee >(zfs recv tank/datasets)' \
  archive:'zfs recv tank/datasets'
```

### 9. Deploy Model to Multiple Inference Servers

```bash
# Deploy same model to 10 inference servers in parallel
SERVERS=(inference-{1..10})

for server in "${SERVERS[@]}"; do
  (
    echo "Deploying to $server..."
    rdcp -v weights-server:/models/production/llama-2-70b-chat \
         $server:/srv/models/active
    ssh $server "systemctl restart inference-service"
    echo "$server ready"
  ) &
done
wait

echo "Deployment complete to ${#SERVERS[@]} servers"
```

### 10. Synchronize Experiment Results

```bash
# After training experiments, collect results from multiple workers
WORKERS=(gpu-{1..8})

mkdir -p /local/results/experiment_123

for worker in "${WORKERS[@]}"; do
  rdcp -r ${worker}:/local/nvme/experiments/exp_123/results \
       /local/results/experiment_123/${worker} &
done
wait

# Aggregate results
python aggregate_results.py /local/results/experiment_123/
```

## Integration Examples

### Python Training Script Integration

```python
import subprocess
import os

def download_model_rdma(model_name, cache_dir="/local/nvme/models"):
    """Download model weights via RDMA"""
    model_path = os.path.join(cache_dir, model_name)
    
    if not os.path.exists(model_path):
        print(f"Downloading {model_name} via RDMA...")
        subprocess.run([
            "rdcp", "-v", "-r",
            f"weights-server:/models/{model_name}",
            model_path
        ], check=True)
        print(f"Downloaded to {model_path}")
    
    return model_path

def save_checkpoint_rdma(checkpoint_path, remote_server="backup-server"):
    """Save checkpoint to remote server via RDMA"""
    remote_path = f"{remote_server}:/checkpoints/{os.path.basename(checkpoint_path)}"
    
    # Run in background to not block training
    subprocess.Popen([
        "rdcp", "-v",
        checkpoint_path,
        remote_path
    ])

# Usage in training script
if __name__ == "__main__":
    # Download model weights
    model_path = download_model_rdma("llama-2-70b")
    
    # Your training code here
    # ...
    
    # Save checkpoint
    save_checkpoint_rdma("/local/nvme/checkpoint_epoch_50.pt")
```

### Bash Script for Model Management

```bash
#!/bin/bash
# model_manager.sh - Manage model weights cache

MODEL_SERVER="weights-server"
CACHE_DIR="/local/nvme/models"

function cache_model() {
    local model_name=$1
    local model_path="${CACHE_DIR}/${model_name}"
    
    if [ -d "$model_path" ]; then
        echo "Model $model_name already cached"
        return 0
    fi
    
    echo "Caching $model_name..."
    rdcp -v -r "${MODEL_SERVER}:/models/${model_name}" "$model_path"
    
    if [ $? -eq 0 ]; then
        echo "Successfully cached $model_name"
        return 0
    else
        echo "Failed to cache $model_name"
        return 1
    fi
}

function list_cached_models() {
    echo "Cached models in $CACHE_DIR:"
    du -sh ${CACHE_DIR}/* 2>/dev/null | sort -h
}

function clear_cache() {
    echo "Clearing model cache..."
    rm -rf ${CACHE_DIR}/*
    echo "Cache cleared"
}

# Command handling
case "$1" in
    cache)
        cache_model "$2"
        ;;
    list)
        list_cached_models
        ;;
    clear)
        clear_cache
        ;;
    *)
        echo "Usage: $0 {cache|list|clear} [model_name]"
        echo "  cache <name>  - Download and cache a model"
        echo "  list          - List cached models"
        echo "  clear         - Clear all cached models"
        exit 1
        ;;
esac
```

### PyTorch DataLoader with RDMA Prefetch

```python
import subprocess
import threading
from pathlib import Path

class RDMADataPrefetcher:
    """Prefetch datasets via RDMA in background"""
    
    def __init__(self, data_server, local_cache="/local/nvme/datasets"):
        self.data_server = data_server
        self.local_cache = Path(local_cache)
        self.local_cache.mkdir(parents=True, exist_ok=True)
        self.threads = []
    
    def prefetch(self, dataset_name):
        """Start prefetching dataset in background"""
        def _download():
            remote_path = f"{self.data_server}:/datasets/{dataset_name}"
            local_path = self.local_cache / dataset_name
            
            if not local_path.exists():
                subprocess.run([
                    "rdcp", "-v", "-r",
                    remote_path, str(local_path)
                ], check=True)
        
        thread = threading.Thread(target=_download)
        thread.start()
        self.threads.append(thread)
        
        return self.local_cache / dataset_name
    
    def wait(self):
        """Wait for all prefetch operations to complete"""
        for thread in self.threads:
            thread.join()
        self.threads = []

# Usage
prefetcher = RDMADataPrefetcher("data-server")

# Start prefetching datasets
train_path = prefetcher.prefetch("imagenet/train")
val_path = prefetcher.prefetch("imagenet/val")

# Do some other setup work while datasets download
model = create_model()
optimizer = create_optimizer(model)

# Wait for datasets to finish downloading
prefetcher.wait()

# Now load datasets (from local cache)
train_dataset = ImageFolder(train_path)
val_dataset = ImageFolder(val_path)
```

### Kubernetes Job for Model Distribution

```yaml
# model-distribution-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: distribute-model-weights
spec:
  parallelism: 10  # Distribute to 10 nodes in parallel
  completions: 10
  template:
    spec:
      containers:
      - name: model-distributor
        image: rdma-tools:latest
        command:
        - /bin/bash
        - -c
        - |
          # Get pod index
          POD_INDEX=${HOSTNAME##*-}
          
          # Download model shard for this pod
          rdcp -v weights-server:/models/gpt-175b/shard_${POD_INDEX}.pt \
               /local/nvme/model_shard.pt
          
          # Signal readiness
          touch /tmp/model-ready
        
        volumeMounts:
        - name: local-nvme
          mountPath: /local/nvme
        - name: rdma-device
          mountPath: /dev/infiniband
        
        resources:
          limits:
            rdma/hca: 1  # Request RDMA device
      
      volumes:
      - name: local-nvme
        hostPath:
          path: /local/nvme
      - name: rdma-device
        hostPath:
          path: /dev/infiniband
      
      restartPolicy: Never
```

## Performance Tips

### 1. Maximize Bandwidth

```bash
# Use taskset to pin processes to specific CPUs for better performance
taskset -c 16 rdrecv 12345 mykey target_file &
taskset -c 8-16 rdsend receiving-host 12345 mykey source_file

# Use multiple parallel transfers for directories
# rdcp -r will use tar which may be slower for large files
# Instead, transfer large files individually in parallel
for file in /models/large_model/*.bin; do
  rdcp -v $file remote:$(basename $file) &
done
wait
```

### 2. Use Local NVMe Cache

```bash
# Always cache to local NVMe, not network filesystems
# Network FS: 100-200 MB/s writes
# Local NVMe: 3000-7000 MB/s writes

# Good
rdcp weights-server:/models/big_model /local/nvme/models/big_model

# Avoid if possible
rdcp weights-server:/models/big_model /nfs/shared/models/big_model
```

### 3. Pre-warm Cache

```bash
# Pre-load frequently used models at boot time
cat > /etc/rc.local << 'EOF'
#!/bin/bash
rdcp -r weights-server:/models/llama-2-70b /local/nvme/models/llama-2-70b &
rdcp -r weights-server:/models/stable-diffusion-xl /local/nvme/models/sd-xl &
exit 0
EOF

chmod +x /etc/rc.local
```

### 4. Monitor Transfers

```bash
# Use -v flag to see bandwidth
rdcp -v large_file remote:large_file

# Log all transfers
rdcp -v $1 $2 2>&1 | tee -a /var/log/rdma-transfers.log
```

## Troubleshooting

### Connection Timeout

```bash
# Ensure rdrecv is started first
# On receiver:
rdrecv 12345 mykey > output_file

# Then on sender (within 10 seconds):
rdsend receiver 12345 mykey < input_file
```

### Memory Lock Limit

```bash
# Check limit
ulimit -l

# If < 16500, fix it:
sudo tee /etc/security/limits.d/rdma.conf << EOF
*       soft    memlock         unlimited
*       hard    memlock         unlimited
EOF

# Log out and back in
```

### Verify RDMA Working

```bash
# Test RDMA performance
# On receiver:
rdrecv 12345 test > /dev/null

# On sender:
dd if=/dev/zero bs=1M count=10000 | rdsend -v receiver 12345 test

# Should show 5+ GB/s on InfiniBand FDR
```

## Additional Resources

- **[AI Model Loading Performance Guide](AI_MODEL_LOADING_GUIDE.md)** - Comprehensive guide with cost analysis
- **[Main README](README.md)** - Full rdma-pipe documentation
- **[GitHub Issues](https://github.com/kig/rdma-pipe/issues)** - Report bugs or request features

## Quick Reference

| Task | Command |
|------|---------|
| Copy file | `rdcp source.file remote:dest.file` |
| Copy directory | `rdcp -r source_dir remote:dest_dir` |
| Show bandwidth | `rdcp -v source remote:dest` |
| Stream data | `rdrecv PORT KEY \| process \| rdsend NEXT_HOST PORT KEY` |
| Multi-stage pipeline | `rdpipe host1:'cmd1' host2:'cmd2' host3:'cmd3'` |
| Read from remote | `rdpipe host:'< file' local:'process'` |
| Write to remote | `rdpipe local:'process' host:'> file'` |
