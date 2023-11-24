/*
 * build:
 * cc -o rdrecv rdrecv.c -lrdmacm -libverbs
 *
 * usage:
 * rdrecv <port> <key>
 *
 * Waits for client to connect to given port and authenticate with the key.
 *
 * lib:libibverbs-dev
 */
#define _GNU_SOURCE

#include <arpa/inet.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <rdma/rdma_cma.h>

// #include "fast_memcpy.h"
// Use zstd to compress data on the fly.
// #include <zstd.h>
// Use OpenMP to parallelize compression and IO.
#include <omp.h>

enum {
  RESOLVE_TIMEOUT_MS = 5000,
};

struct pdata {
  uint64_t buf_va;
  uint32_t buf_rkey;
};

void usage() {
  fprintf(stderr, "USAGE: rdrecv [-v] <port> <key> [filename]\n");
}

void wrongkey() { fprintf(stderr, "Wrong key received\n"); }

int max(int a, int b) { return a < b ? b : a; }

int main(int argc, char *argv[]) {
  struct pdata rep_pdata;

  struct rdma_event_channel *cm_channel;
  struct rdma_cm_id *listen_id;
  struct rdma_cm_id *cm_id;
  struct rdma_cm_event *event;
  struct rdma_conn_param conn_param = {};

  struct ibv_pd *pd;
  struct ibv_comp_channel *comp_chan;
  struct ibv_cq *cq;
  struct ibv_cq *evt_cq;
  struct ibv_mr *mr;
  struct ibv_qp_init_attr qp_attr = {};
  struct ibv_sge sge;
  struct ibv_send_wr send_wr = {};
  struct ibv_send_wr *bad_send_wr;
  struct ibv_recv_wr recv_wr = {};
  struct ibv_recv_wr *bad_recv_wr;
  struct ibv_wc wc;
  void *cq_context;

  struct sockaddr_in sin;

  uint32_t *buf, *buf2, *tmp;
  // 8 MiB
  uint32_t buf_size = 16 * 524288;

  int err;
  uint32_t event_count = 0;

  int port;
  char *key, *cbuf, *ports;
  uint32_t keylen, keyIdx = 0, i = 0;

  int verbose = 0;

  int argv_idx = 1;

  if (argc < 3) {
    usage();
    return 1;
  }

  if (strcmp(argv[argv_idx], "-v") == 0) {
    verbose++;
    argv_idx++;
  }

  ports = argv[argv_idx++];

  port = atoi(ports);

  if (port < 1 || port > 65535) {
    usage();
    fprintf(stderr,
            "\nError: Port should be between 1 and 65535, got %d instead.\n\n",
            port);
    return 1;
  }

  key = argv[argv_idx++];
  keylen = strlen(key);

  int use_parallel_writes = 0;

  int fd = STDOUT_FILENO;
  int fds[8];
  if (argv_idx < argc) {
    // Open the file for writing.
    fd = open(argv[argv_idx], O_WRONLY | O_CREAT | O_TRUNC,
              S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH);
    if (fd < 0) {
      fprintf(stderr, "Error opening file %s (%d)\n", argv[argv_idx], errno);
      return 200;
    }
    use_parallel_writes = 1;
    // Open 8 parallel file descriptors.
    for (int i = 0; i < 8; i++) {
      fds[i] = open(argv[argv_idx], O_WRONLY | O_DIRECT);
      if (fds[i] < 0) {
        use_parallel_writes = 0;
      }
    }
  }

  /* Set up RDMA CM structures */

  cm_channel = rdma_create_event_channel();
  if (!cm_channel)
    return 1;

  err = rdma_create_id(cm_channel, &listen_id, NULL, RDMA_PS_TCP);
  if (err)
    return err;

  sin.sin_family = AF_INET;
  sin.sin_port = htons(port);
  sin.sin_addr.s_addr = INADDR_ANY;

  /* Bind to local port and listen for connection request */

  err = rdma_bind_addr(listen_id, (struct sockaddr *)&sin);
  if (err)
    return 1;

  err = rdma_listen(listen_id, 1);
  if (err)
    return 1;

  err = rdma_get_cm_event(cm_channel, &event);
  if (err)
    return err;

  if (event->event != RDMA_CM_EVENT_CONNECT_REQUEST)
    return 1;

  cm_id = event->id;

  rdma_ack_cm_event(event);

  /* Create verbs objects now that we know which device to use */

  pd = ibv_alloc_pd(cm_id->verbs);
  if (!pd)
    return 1;

  comp_chan = ibv_create_comp_channel(cm_id->verbs);
  if (!comp_chan)
    return 1;

  cq = ibv_create_cq(cm_id->verbs, 2, NULL, comp_chan, 0);
  if (!cq)
    return 1;

  if (ibv_req_notify_cq(cq, 0))
    return 1;

  if (posix_memalign((void *)&buf, 4096, buf_size * 2)) {
    perror("posix_memalign failed");
    return 1;
  }

  buf2 = ((void *)buf) + buf_size;

  mr = ibv_reg_mr(pd, buf, buf_size * 2,
                  IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_READ |
                      IBV_ACCESS_REMOTE_WRITE);
  if (!mr)
    return 1;

  // qp_attr.cap.max_send_wr = 1;
  // qp_attr.cap.max_send_sge = 1;
  // qp_attr.cap.max_recv_wr = 1;
  // qp_attr.cap.max_recv_sge = 1;

  qp_attr.send_cq = cq;
  qp_attr.recv_cq = cq;

  qp_attr.qp_type = IBV_QPT_RC;

  err = rdma_create_qp(cm_id, pd, &qp_attr);
  if (err)
    return err;

  /* Post receive before accepting connection */
  sge.addr = (uintptr_t)buf2;
  sge.length = buf_size;
  sge.lkey = mr->lkey;

  recv_wr.sg_list = &sge;
  recv_wr.num_sge = 1;

  if (ibv_post_recv(cm_id->qp, &recv_wr, &bad_recv_wr))
    return 1;

  rep_pdata.buf_va = htonl((uintptr_t)buf);
  rep_pdata.buf_rkey = htonl(mr->rkey);

  conn_param.responder_resources = 1;
  conn_param.private_data = &rep_pdata;
  conn_param.private_data_len = sizeof rep_pdata;

  send_wr.opcode = IBV_WR_SEND;
  send_wr.send_flags = IBV_SEND_SIGNALED;
  send_wr.sg_list = &sge;
  send_wr.num_sge = 1;

  /* Accept connection */

  err = rdma_accept(cm_id, &conn_param);
  if (err)
    return 1;

  err = rdma_get_cm_event(cm_channel, &event);
  if (err)
    return err;

  if (event->event != RDMA_CM_EVENT_ESTABLISHED)
    return 1;

  rdma_ack_cm_event(event);

  ssize_t total_bytes = 0;

  uint32_t bufMsgLen = 0;
  uint32_t buf2MsgLen = 0;

  while (1) {
    /* Wait for receive completion */
    // printf("wait recv\n");

    if (ibv_get_cq_event(comp_chan, &evt_cq, &cq_context))
      return 1;

    // printf("ibv_req_notify_cq\n");
    if (ibv_req_notify_cq(cq, 0))
      return 2;

    // printf("ibv_poll_cq\n");
    if (ibv_poll_cq(cq, 1, &wc) < 1)
      return 3;

    if (wc.status != IBV_WC_SUCCESS) // spark error
    {
      fprintf(stderr, "%s\n", ibv_wc_status_str(wc.status));
      return 4;
    }

    // Print out the length of the received data.
    // fprintf(stderr, "Received %d bytes\n", wc.byte_len);
    buf2MsgLen = wc.byte_len;

    // printf("got recv\n");

    /* Flip buffers */

    tmp = buf;
    buf = buf2;
    buf2 = tmp;

    uint32_t tmpLen = bufMsgLen;
    bufMsgLen = buf2MsgLen;
    buf2MsgLen = tmpLen;

    uint32_t msgLen = bufMsgLen;

    if (msgLen > 0) {
      // printf("recv\n");

      sge.addr = (uintptr_t)buf2;

      if (ibv_post_recv(cm_id->qp, &recv_wr, &bad_recv_wr))
        return 5;
    }

    sge.length = 1;
    if (ibv_post_send(cm_id->qp, &send_wr, &bad_send_wr))
      return 6;
    sge.length = buf_size;

    // printf("send\n");

    /* Wait for send completion */

    if (ibv_get_cq_event(comp_chan, &evt_cq, &cq_context))
      return 7;

    if (ibv_req_notify_cq(cq, 0))
      return 8;

    if (ibv_poll_cq(cq, 1, &wc) < 1)
      return 9;

    if (wc.status != IBV_WC_SUCCESS)
      return 10;

    // fprintf(fprintf, "ack\n");

    event_count += 2;

    // fprintf(fprintf, "msgLen %d\n", msgLen);
    // fprintf(fprintf, "buf[(buf_size/4) - 1]: %d\n", buf[(buf_size/4) - 1]);
    // fprintf(fprintf, "buf[0]: %d\n", buf[0]);
    if (msgLen <= buf_size) {
      cbuf = (char *)buf;
      // Get the key first.
      for (i = 0; i < msgLen && keyIdx < keylen + 1; i++, keyIdx++,
          cbuf++) { // include the zero byte at the end of the key
        if (*cbuf != key[keyIdx]) {
          wrongkey();
          ibv_ack_cq_events(cq, event_count);
          return 20;
        }
      }
      if (i == 0) { // Second time around, we have the key.
        // Only do parallel IO_DIRECT writes if we have IO_DIRECT support,
        // we're writing to a sector-aligned address and the message is
        // sector-aligned.
        if (use_parallel_writes == 0 || total_bytes % 4096 != 0 ||
            msgLen != 8 * 1048576) {
          lseek(fd, total_bytes, SEEK_SET);
          ssize_t res = write(fd, cbuf, msgLen);
          while (res < msgLen) {
            res += write(fd, cbuf+res, msgLen-res);
          }
          total_bytes += res;
          if (res == -1) {
            fprintf(stderr, "Write error %d\n", errno);
            break;
          }
        } else {
          // Add msgLen to the fd file size.
          if (ftruncate(fd, total_bytes + msgLen) != 0) {
            fprintf(stderr, "ftruncate error %d\n", errno);
            break;
          }
          // Striped parallel write to the file.
          ssize_t buf_written_bytes = 0;
          int error = 0;
#pragma omp parallel for
          for (int j = 0; j < 8; j++) {
            // Seek to the correct position.
            lseek(fds[j], total_bytes + j * 1048576, SEEK_SET);
            ssize_t res = 0;
            // Write the data.
            while (res < 1048576) {
              res += write(fds[j], cbuf + j * 1048576 + res, 1048576 - res);
            }
// Atomic add to buf_written_bytes
#pragma omp atomic
            buf_written_bytes += res;

            if (res == -1) {
              fprintf(stderr, "Write error %d\n", errno);
              error = 1;
            }
          }
          if (error == 1) {
            break;
          }
          total_bytes += buf_written_bytes;
        }
      }
      // printf("%d\n", msgLen);
    }

    if (msgLen == 0) {
      break;
    }
  }

  close(fd);
  for (i = 0; i < 8; i++) {
    close(fds[i]);
  }

  ibv_ack_cq_events(cq, event_count);

  return 0;
}
