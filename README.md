# rdma-pipe

Utilities to send data over RDMA networks (InfiniBand, RoCE).

# Why would you want to use this?

Maybe you have large files to copy around and you want to use all the bandwidth you can get.

5.3 GB/s file copy from ext4 RAID-10 to ZFS page cache across two Mellanox ConnectX-3 adapters.

3.7 GB/s file copy from page cache to ext4 RAID-10 (the hardware and filesystem can do 10+ GB/s, still ways to go).

# What's in the box

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
sudo make install
```

You need the rdmacm and libibverbs development libraries. The rdpipe utility also needs ruby.

On Ubuntu:

    # apt install -y rdma-core librdmacm-dev ruby

On CentOS 7:

    # yum install -y rdma-core-devel ruby

# Uninstall

```bash
sudo make uninstall
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


## rdpipe

The <code>rdpipe</code> utility sends its <code>stdin</code> to a command running on a remote host and writes the results to its <code>stdout</code>.
The send and receive operations are done in parallel over RDMA.

To pipe data from localhost to a command on remote host:

    $ rdpipe other_host:'wc -c' < myfile

Maybe you've got a fast checksum server and you'd like to <code>sha1sum</code> a file:

    $ rdpipe other_host:'sha1sum' < myfile

If you want to save the data to a file, you can use the <code>></code> operator, <code>cat >file</code> or <code>tee</code>:

    $ rdpipe other_host:'> mycopy' < myfile
    $ rdpipe other_host:'tee mycopy | wc -c; echo done' < myfile

For a more useful example, pull a ZFS snapshot from the file server to backup replica:

    $ rdpipe backup@fileserver:'zfs send -I tank/media@latest_backup tank/media@head' | pv | zfs recv tank/media

If you want to pipe data across multiple hosts, you can give rdpipe multiple commands:

    $ rdpipe fs1:'zfs send tank/media@snap' \
             fs2:'tee >(zfs recv tank/media)' \
             backup:'tee >(zfs recv tank/media)' \
             logs:'tee >(sha1sum >> snap_sha1) | wc -c >> snap_sizes; echo done'

Multi-host pipelines send data directly between the hosts. The pipeline setup and control is done from the machine running rdpipe.
The above pipeline would send data from *fs1* to *fs2*, then from *fs2* to *backup*, then from *backup* to *logs*. 

A major benefit of this kind of setup is that the pipeline can run at link speed rather than having to send the same data to multiple places from the same server.
If you implemented the same process by sending data from *fs1* to all three servers simultaneously, the maximum speed you could reach is a third of your uplink bandwidth.
With a pipeline, you can theoretically reach full uplink bandwidth.

Note that the pipeline processes data at the speed of the slowest command in the pipeline.
In the above example <code>sha1sum</code> might bottleneck your pipeline to 700 MB/s, or slow disks on backup to 150 MB/s.

If your pipeline starts from a remote file, you can use the <code><</code> operator. If you want to write the pipeline to a remote file, you can use the <code>></code> operator:

    $ rdpipe fs1:'< textfile' CAPS:'tr [:lower:] [:upper:]' fs2:'> TEXTFILE'

Note that multi-host pipelines use the same port number *7691* for the receive server on every host. 
So if you try to pipe data back to a server already on the pipeline, it will fail and you get to go kill stray processes (patches welcome!)

### rdpipe operators *<*, *>* and *>>*

The *<*, *>* and *>>* operators are used for lifting files directly into the pipeline and writing output directly to files. They exist primarily for performance reasons, 
as piping data through <code>cat</code> has a visible performance penalty on my network, especially with machines under load.

To use them, start the command with them. For example, <code>rdpipe host:'< file1' host2:'> file2'</code> copies *file1* from *host* to *file2* on *host2*.

If you use *<* in the middle of the pipeline, the output of the previous pipeline segment is directed to <code>/dev/null</code>. In practice, this waits until the
previous pipeline segments finish executing and starts a new pipeline that runs after the previous one.

Similarly, *>* ends the preceding pipeline and starts a new one after it. If a *>* segment has no input, it creates an new file using 
<code>truncate</code>, or in the case of using the *>>* operator, <code>touch</code>.

The normal <code>rdpipe</code> segment receives data from the previous host, sends it through the given command, and forwards the output to the next host:
<code>rdrecv \| ($cmd) \| rdsend next_host</code>. With the *<* operator, <code>rdpipe</code> passes it as an input file redirect to <code>rdsend</code> and
redirects the input to <code>/dev/null</code>: <code>rdrecv > /dev/null; rdsend next_host $cmd</code>. The *>* and *>>* operators do a similar transform, sending
an empty stream to the next host: <code>rdrecv > $cmd; rdsend next_host</code>


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


# Project goals

* Copy files from one host to another as fast as the network allows. 
    * We want the file to be in usable state ASAP, so writing to the page cache is perfectly fine.
* Workloads to optimize
    * rdcp -r weights-server:huggingface/hub/models_dir worker:.cache/huggingface/hub/models_dir
        * `-r` is slow on large files because it pipes the directory tree through `tar`.
        * We should send the small files first with tar, then send the large files with separate sends. Or make a faster tar.
    * zfs send | rdsend backup & rdrecv | zfs recv
        * The [`rdpipe`](rdpipe) utility was written for this use case. `rdpipe 'zfs send' backup:'zfs recv'`
        * Maybe rewrite it in bash :-)
    * rdcp --sync -r ingest-server:/videos ./videos/

# Alternatives

NVMEoF - export NVMe devices over Fabrics. Great performance, but exports an entire NVMe namespace.

* [nvmetcli](https://git.infradead.org/users/hch/nvmetcli.git) - NVMe target config tool
* [Simple script to export an NVMe disk over TCP or RDMA](https://gist.github.com/kig/edfba72e7de681542ec2939ede2f1199)
* If you have a static file cache, you could `mount -o ro` the exported device from multiple hosts. But now you have to umount & remount the filesystem to see changes.
* If you want to export a RAID array, you'd need to export each disk separately and then reassemble the array on the receiving end. If you want to export to multiple clients, maybe `mdadm --assemble --readonly` would work?
* fio to remote PCIe Gen3 NVMeof/RDMA: 2.6 GB/s reads and 2 GB/s writes, performing the same as a local device.
* fio to remote PCIe Gen4 NVMeof/RDMA: 5.1 GB/s reads, local drive hit 7.4 GB/s reads, so we're network-limited here.
* NVMeoF/TCP is slower than NVMeoF/RDMA here (1.5 GB/s reads, 1.2 GB/s writes), probably because of my ancient NICs & ipoib.

`nginx` - serve files over HTTP, using curl to download to /dev/null. 1.9 GB/s. 0.9 GB/s with HTTPS.

`ssh` - pipe the data over SSH to /dev/null. 400 MB/s. If I split the file into ten 1 GB chunks and send them in parallel, I get 1.5 GB/s. `for f in {0..9}; do dd if=input_file of=/dev/stdout bs=10MB count=100 iflag=skip_bytes skip=${f}GB | ssh remote dd if=/dev/stdin of=/dev/null bs=8MB oflag=seek_bytes seek=${f}GB & done; wait`. Doing actual file writes is slower, about 400 MB/s.

`scp` - copy files over SSH. Uses the ssh connection to send the file. Reaches 400 MB/s here.

`rsync` - sync directories to a remote host. 377 MB/s.

`rcopy` - copy files over RDMA. 480 MB/s, probably because the write is slow. (Similar to rdrecv > file.)

`wdt` - copy files over TCP. Supposed to be super fast, need to test. https://github.com/facebook/wdt

# Benchmarks

The following tests were done on Infiniband FDR 56 Gbps. Network test with qperf achieves 49 Gbps.

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

