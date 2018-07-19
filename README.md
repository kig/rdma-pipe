# rdma-pipe

Utility programs to pipe data across a RDMA-capable network (e.g. InfiniBand, RoCE).

Benchmarked on QDR InfiniBand network to go at 3 GB/s when piping a file to remote `/dev/null`, 1.7 GB/s when piping from page cache to `wc -c`.



# Installation

Install the rdmacm and libibverbs development libraries, and Ruby for the rdpipe utility.

On CentOS 7:

    # yum install -y rdma-core-devel ruby

Compile the programs:

    $ make

Install the programs to somewhere on your path:

    $ cp rdpipe rdsend rdrecv /usr/local/bin/


## Check that <code>ulimit -l</code> is above 16500

Run <code>ulimit -l</code> on your hosts to find out how much memory you can pin as a non-root user. 
The returned number is in kB. The rdma-pipe utils pin around 16 MB of memory. 
If the <code>ulimit -l</code> result is too small, you need to raise the limit.

On CentOS 7, create the file <code>/etc/security/limits.d/rdma.conf</code> with the following contents:

    # configuration for rdma tuning
    *       soft    memlock         unlimited
    *       hard    memlock         unlimited
    # rdma tuning end

Log back in for the changes to take effect.


## SSH keys

The <code>rdpipe</code> utility uses SSH as the control channel.
For convenience, set up public key authentication between your hosts.
For example, run <code>ssh-keygen</code> on one host and copy it over to the other host 
<code>cat ~/.ssh/id_rsa.pub | ssh other_host 'cat >> ~/.ssh/authorized_keys'</code>

If you set a passphrase for the generated key, you can use <code>ssh-agent</code> and <code>ssh-add</code> to add it to your 
keyring and avoid having to re-enter the passphrase every time.


# Usage

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


## rdsend and rdrecv

The <code>rdsend</code> and <code>rdrecv</code> utilities make up a client-server pair for sending data over RDMA.

To pipe data from hostA to hostB:

    # First set up the receive server on hostB.
    # The arguments to rdrecv are port number and a secret key for the receive.
    #
    # Here we set up the server to listen on port 12345 with the key "secret_key".
    
    [hostB] $ rdrecv 12345 secret_key > mycopy
    
    # Next we send the data from A to B.
    # The arguments to rdsend are the server, port, and the secret key.
    
    [hostA] $ rdsend hostB 12345 secret_key < myfile

The commands above are better executed with rdrecv first, that way rdsend can connect on the first attempt. 
To make pipeline writing easier, rdsend tries to connect to the rdrecv server for 3 seconds before timing out.

