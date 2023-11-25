# rdma-pipe

Pipe data across RDMA (InfiniBand, RoCE).

Use `rdcp` to copy files over RDMA. Uses `ssh` to start the receiver on the remote end and then sends the file over.

```bash
$ rdcp -v big_file receiving-host:/dev/null
Bandwidth 5.103 GB/s

# You can also send directory trees.
$ rdcp -v -r node_modules receiving-host:/dev/shm/node_modules
Bandwidth 0.432 GB/s
```

Use `rdrecv` and `rdsend` to pipe data over RDMA.

```bash
[receiving-host]$ rdrecv 12345 some_key_string
[sending-host]$ echo 'Hello RDMA!' | rdsend receiving-host 12345 some_key_string

# It's nice for sending ZFS snapshots.
backup$ rdrecv 1234 super_great | zfs recv rpool/home
live$ zfs send rpool/home@today | rdsend backup 1234 super_great
```

# Install

```bash
make && sudo cp rd{cp,send,recv} /usr/local/bin
```

You need the rdmacm and libibverbs development libraries.

On Ubuntu:

    # apt install -y rdma-core librdmacm-dev

On CentOS 7:

    # yum install -y rdma-core-devel

# Uninstall

```bash
sudo rm /usr/local/bin/rd{cp,send,recv}
```

## How fast is it?

The following test was done on Infiniband FDR 56 Gbps.

```bash
# Make a test file, pull it into page cache.
[sending-host]$ head -c 10G /dev/zero > big_file
[sending-host]$ cat big_file >/dev/null
# Send it to /dev/null
[receiving-host]$ rdrecv 12345 password_string >/dev/null
[sending-host]$ rdsend -v receiving-host 12345 password_string <big_file
Bandwidth 5.127 GB/s

# For optimized file I/O, set the last arg to a filename.
# This should give you higher write bandwidth on NVMe devices.
# (File I/O uses 8 threads and writes using direct IO when possible.)
# You probably need to play with taskset CPU pinning to get the best perf.
[receiving-host]$ taskset -c 4 rdrecv 12345 password >/dev/null
[sending-host]$ taskset -c 16,20,24 rdsend receiving-host 12345 password source_file
Bandwidth 5.636 GB/s

# If your file is in page cache, just < pipe it to rdsend.
# The O_DIRECT file I/O is slower in that case.
# I would like to make this automatic.

# Write speed is still WIP.
# This is on a 4x NVMe SSD RAID-10, with 14 GB/s write bandwidth in fio.
# The network transfer goes at 5.1 GB/s. The write speed is 3.7 GB/s.
# The bottleneck is the file I/O on the receiving end.
[receiving-host]$ taskset -c 16 rdrecv 12345 password target_file
[sending-host]$ taskset -c 8-16 rdsend receiving-host 12345 password source_file
Bandwidth 3.756 GB/s

# Writing to ZFS is faster as the write lands into the ARC.
# (I think my ZFS settings are running with scissors.)
# For production use, this _might_ be fine if you're just slinging files around in a cluster.
# Now how to get the mdraid + ext4 to match this...
[receiving-host]$ taskset -c 16 rdrecv 12345 password /zfs/target_file
[sending-host]$ taskset -c 8-16 rdsend receiving-host 12345 password source_file
Bandwidth 5.329 GB/s

```

# Usage

## rdcp - Copy files over RDMA

```bash
rdcp [-v] [-r] SRC DST
# -v Print out the bandwidth.
# -r Copy a directory tree.
# SRC The source file or directory.
# DST The destination file or directory.
#
# SRC and DST can be local paths or remote paths.
#
# E.g. /home/user/file, host:file, user@host:file
#
# Examples:
#
# Copy file to a server.
# $ rdcp file server:file
#
# Copy file from a server.
# $ rdcp server:file file
#
# Copy a directory to a server.
# $ rdcp -r dir server:dir
#
# Copy a directory from a server.
# $ rdcp -r server:dir dir
```

## rdsend - Send data over RDMA

```bash
rdsend [-v] HOST PORT KEY [FILE]
# -v Print out the send bandwidth at the end.
```

## rdrecv - Receive data over RDMA

```bash
rdrecv PORT KEY [FILE]
```

To pipe data from hostA to hostB:
```bash
# First set up the receive server on hostB.
# The arguments to rdrecv are port number and a secret key for the receive.
#
# Here we set up the server to listen on port 12345 with the key "secret_key".

[hostB] $ rdrecv 12345 secret_key > mycopy

# Next we send the data from A to B.
# The arguments to rdsend are the server, port, and the secret key.

[hostA] $ rdsend hostB 12345 secret_key < myfile
```

The commands are best executed with rdrecv first, so that rdsend can connect on the first attempt. 

If rdrecv is not up, rdsend tries to connect for ~10 seconds before timing out.

# Notes

Data is sent as-is, so if you need encryption or compression, try piping through `openssl` and `pzstd`. Something like the below.

```bash
recv$ rdrecv 1234 my_key | openssl enc -aes-256-cbc -pbkdf2 -d -k "super_secure" | pzstd -d > wow
send$ pzstd -1 -c wow | openssl enc -aes-256-cbc -pbkdf2 -k "super_secure" | rdsend recv 1234 my_key
```

In my testing, `pzstd` runs at 1.6 GB/s, `openssl` at 500 MB/s. For decent perf, I should roll these into the `rdsend` / `rdrecv` programs.
(OpenSSL running on 16 cores should give you 8 GB/s and I have per-block compression in [crash](https://github.com/kig/crash) that goes at 10+ GB/s on a good day.)

**WARNING** This version is not backwards compatible with the 2019 version. The protocol has changed.
(The old protocol prefixed the send buffers with the length of the buffer. The new protocol uses the RDMA send length field. This change makes the code simpler and we can align the buffers to 4k pages for direct IO.)


# Troubleshooting

## Check that <code>ulimit -l</code> is above 16500

Run <code>ulimit -l</code> on your hosts to find out how much memory you can pin as a non-root user. 
The returned number is in kB. The rdma-pipe utils pin around 16 MB of memory. 
If the <code>ulimit -l</code> result is too small, you need to raise the limit.

Create the file <code>/etc/security/limits.d/rdma.conf</code> with the following contents:

    # configuration for rdma tuning
    *       soft    memlock         unlimited
    *       hard    memlock         unlimited
    # rdma tuning end

Log back in for the changes to take effect.


# License

Copyright 2023 Ilmari Heikkinen

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

