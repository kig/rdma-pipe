# rdma-pipe

Pipe data across RDMA (InfiniBand, RoCE).

Use `rdcp` to copy files over RDMA. Uses `ssh` to start the receiver on the remote end and then sends the file over.

```bash
$ rdcp -v big_file receiving-host:/dev/shm/big_file
Bandwidth 5.103 GB/s

# You can also send directory trees.
$ rdcp -v -r node_modules receiving-host:/dev/shm/node_modules
Bandwidth 0.432 GB/s
```

Use `rdrecv` and `rdsend` to pipe data over RDMA.

```bash
[receiving-host]$ rdrecv 12345 password_string
[sending-host]$ echo 'Hello RDMA!' | rdsend receiving-host 12345 password_string
```

NOTE: This version is not backwards compatible with the 2019 version. The protocol has changed.
(The old protocol prefixed the send buffers with the length of the buffer. The new protocol uses the RDMA send length field. This change makes the code simpler and we can align the buffers to 4k pages for direct IO.)


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

# For optimized file I/O, you can pass a filename as the last arg.
# In file I/O mode, the file is read in using multiple threads, and written out similarly.
# This should give you higher write bandwidth on NVMe and fast networks.
[receiving-host]$ rdrecv 12345 password target_file
[sending-host]$ rdsend receiving-host 12345 password source_file
```

# Installation

Install the rdmacm and libibverbs development libraries.

On Ubuntu:

    # apt install -y rdma-core librdmacm-dev

On CentOS 7:

    # yum install -y rdma-core-devel

Compile the programs:

    $ make

Install the programs to somewhere in your path:

    $ cp rdcp rdsend rdrecv /usr/local/bin/


# Usage

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

If rdrecv is not up, rdsend tries to connect for 180 seconds before timing out.


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

MIT

Ilmari Heikkinen (c) 2023
