/* 
 * cc -o rdsend rdsend.c -lrdmacm -libverbs
 * 
 * usage:
 * rdsend <server> <port> <key> 
 *
 * Reads data from stdin and RDMA sends it to the given server and port, authenticating with the key.
 *
 */ 
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include <arpa/inet.h>

#include <rdma/rdma_cma.h>

enum   { 
        RESOLVE_TIMEOUT_MS = 5000, 
}; 

struct pdata { 
        uint64_t	buf_va; 
        uint32_t	buf_rkey;
}; 

void usage() {
    fprintf(stderr, "USAGE: rdsend [-v] <server> <port> <key>\n");
}


int rconnect(char *host, char *port, 
	struct rdma_event_channel *cm_channel, 
	struct rdma_cm_id **cm_id, 
	struct ibv_mr **mr,
	struct ibv_cq **cq,
   	struct ibv_pd **pd,
	struct ibv_comp_channel **comp_chan,
	void *buf, uint32_t buf_len, 
	struct pdata *server_pdata
) {
   	struct rdma_conn_param			conn_param = { };
   	struct addrinfo					*res, *t; 
   	struct addrinfo					hints = { 
   		.ai_family    = AF_INET,
   		.ai_socktype  = SOCK_STREAM
   	};
   	struct ibv_qp_init_attr			qp_attr = { }; 
	int								n; 
   	struct rdma_cm_event			*event;  
	int err;

	err = rdma_create_id(cm_channel, cm_id, NULL, RDMA_PS_TCP);
	if (err)  
		return err;

	n = getaddrinfo(host, port, &hints, &res);
	if (n < 0)  
		return 102;

	/* Connect to remote end */

	for (t = res; t; t = t->ai_next) {
		err = rdma_resolve_addr(*cm_id, NULL, t->ai_addr, RESOLVE_TIMEOUT_MS);
		if (!err)
			break;
	}
	if (err)
		return 103;

	err = rdma_get_cm_event(cm_channel, &event);
	if (err)
		return 104;

	if (event->event != RDMA_CM_EVENT_ADDR_RESOLVED)
		return 105;

	rdma_ack_cm_event(event);

	err = rdma_resolve_route(*cm_id, RESOLVE_TIMEOUT_MS);
	if (err)
		return 106;

	err = rdma_get_cm_event(cm_channel, &event);
	if (err)
		return 107;

	if (event->event != RDMA_CM_EVENT_ROUTE_RESOLVED)
		return 108; 

	rdma_ack_cm_event(event);

	/* Create IB buffers and CQs and things */

	*pd = ibv_alloc_pd((*cm_id)->verbs); 
	if (!*pd) 
		return 109;

	*comp_chan = ibv_create_comp_channel((*cm_id)->verbs);
	if (!*comp_chan) 
		return 110;

	*cq = ibv_create_cq((*cm_id)->verbs, 2,NULL, *comp_chan, 0); 
	if (!*cq) 
		return 111;

	if (ibv_req_notify_cq(*cq, 0))
		return 112;

	*mr = ibv_reg_mr(*pd, buf, buf_len, IBV_ACCESS_LOCAL_WRITE); 
	if (!*mr) 
		return 99;

	//qp_attr.cap.max_send_wr = 2; 
	//qp_attr.cap.max_send_sge = 1;
	//qp_attr.cap.max_recv_wr = 1; 
	//qp_attr.cap.max_recv_sge = 1; 

	qp_attr.send_cq        = *cq;
	qp_attr.recv_cq        = *cq;
	qp_attr.qp_type        = IBV_QPT_RC;

	err = rdma_create_qp(*cm_id, *pd, &qp_attr);
	if (err)
		return 114;


	conn_param.initiator_depth = 1;
	conn_param.retry_count     = 7;

	err = rdma_connect(*cm_id, &conn_param);
	if (err) {
		fprintf(stderr, "rdma_connect() error: %d\n", errno);
		return 115;
	}

	/* Connect! */

	err = rdma_get_cm_event(cm_channel, &event);
	if (err) {
		return 116;
	}

	if (event->event != RDMA_CM_EVENT_ESTABLISHED) {
		rdma_ack_cm_event(event);
		return 117;
	}

	memcpy(server_pdata, event->param.conn.private_data, sizeof(struct pdata));
	rdma_ack_cm_event(event);

	return 0;
}

int rdisconnect(
	struct rdma_event_channel *cm_channel, 
	struct rdma_cm_id *cm_id, 
	struct ibv_mr *mr,
	struct ibv_cq *cq,
   	struct ibv_pd *pd,
	struct ibv_comp_channel *comp_chan
) {
	int err;
	err = rdma_disconnect(cm_id);
	if (err) {
		return 201;
	}
	rdma_destroy_qp(cm_id);
	if (err) return 203;
	err = ibv_dereg_mr(mr);
	if (err) return 204;
	err = ibv_destroy_cq(cq);
	if (err) return 205;
	err = ibv_dealloc_pd(pd);
	if (err) return 206;
	err = ibv_destroy_comp_channel(comp_chan);
	if (err) return 207;
	err = rdma_destroy_id(cm_id);
	if (err) return 208;

	return 0;
}

int max(int a, int b) {
	return a < b ? b : a;
}

int main(int argc, char   *argv[ ]) 
{
   	struct pdata					server_pdata;

   	struct rdma_event_channel		*cm_channel = NULL; 
   	struct rdma_cm_id				*cm_id = NULL; 

   	struct ibv_pd					*pd = NULL; 
   	struct ibv_comp_channel			*comp_chan = NULL; 
   	struct ibv_cq					*cq = NULL; 
   	struct ibv_cq					*evt_cq = NULL; 
   	struct ibv_mr					*mr = NULL; 
   	struct ibv_sge					sge, rsge; 
   	struct ibv_send_wr				send_wr = { }; 
   	struct ibv_send_wr 				*bad_send_wr; 
   	struct ibv_recv_wr				recv_wr = { }; 
   	struct ibv_recv_wr				*bad_recv_wr; 
   	struct ibv_wc					wc; 
   	void							*cq_context; 

	uint32_t						*buf, *buf2, *tmp; 

	uint32_t event_count = 0;
	struct timespec now, tmstart;
	double seconds;

	int64_t read_bytes;
	uint64_t total_bytes, buf_read_bytes;
	int wr_id = 1, more_to_send = 1;
	uint32_t buf_size = 16 * 524288;
	uint32_t buf_len = 0;

	char *host, *ports;
	int port;
	char *key;
	uint32_t keylen;

	int verbose = 0;

	int retries = 0;
	int argv_idx = 1;
	

    if (argc < 4) {
        usage();
        return 1;
    }

    if (strcmp(argv[argv_idx], "-v") == 0) {
    	verbose++;
    	argv_idx++;
    }

    host = argv[argv_idx++];
    ports = argv[argv_idx++];

    port = atoi(ports);

    if (port < 1 || port > 65535)
    {
        usage();
        fprintf(stderr, "\nError: Port should be between 1 and 65535, got %d instead.\n\n", port);
        return 1;
    }

    key = argv[argv_idx++];
    keylen = strlen(key);

	buf = calloc(buf_size*2+4, 1); 
	if (!buf) 
		return 113;
	buf2 = (uint32_t*)(((char*)buf) + buf_size);


    /* RDMA CM */
	cm_channel = rdma_create_event_channel(); 
	if (!cm_channel)  
		return 101; 

	buf_len = buf_size*2+4;

	while (0 != rconnect(host, ports, cm_channel, &cm_id, &mr, &cq, &pd, &comp_chan, buf, buf_len, &server_pdata)) {
		retries++;
		if (retries > 300) {
			fprintf(stderr, "Connection timed out\n");
			return 199;
		}
		rdisconnect(cm_channel, cm_id, mr, cq, pd, comp_chan);
		nanosleep((const struct timespec[]){{0, 10000000L}}, NULL);
	}

	/* Prepost */

	sge.addr = (uintptr_t) buf; 
	sge.length = buf_size;
	sge.lkey = mr->lkey;

	rsge.addr = (uintptr_t) (((char*)buf) + 2*buf_size); 
	rsge.length = 4;
	rsge.lkey = mr->lkey;

	recv_wr.wr_id =     0;                
	recv_wr.sg_list =   &rsge;
	recv_wr.num_sge =   1;

	/* Read some bytes from STDIN, send them over with IBV_WR_SEND */

    clock_gettime(CLOCK_REALTIME, &tmstart);
    total_bytes = 0;

    memcpy((buf+1), key, keylen+1);

	buf_read_bytes = read_bytes = max(0, read(STDIN_FILENO, ((void*)(buf+1))+keylen+1, buf_size-4-keylen-1)) + keylen + 1;
	// while (read_bytes && buf_read_bytes < buf_size-4) {
	// 	read_bytes = read(STDIN_FILENO, ((void*)(buf+1)) + buf_read_bytes, buf_size-4-buf_read_bytes);
	// 	buf_read_bytes += read_bytes;
	// }
	// fprintf(stderr, "%d %d\n", read_bytes, errno);
	buf[0] = buf_read_bytes;
	total_bytes += buf_read_bytes;

	more_to_send = 1;

	while (more_to_send) {
		if (buf_read_bytes == 0) {
			if (buf[0] != buf_read_bytes) {
				return 100;
			}
			more_to_send = 0;
		}

		if (ibv_post_recv(cm_id->qp, &recv_wr, &bad_recv_wr))
			return 1;

		sge.addr 					  = (uintptr_t) buf; 
		sge.length                    = buf_read_bytes + 4;
		sge.lkey                      = mr->lkey;

		send_wr.wr_id                 = wr_id;
		send_wr.opcode                = IBV_WR_SEND;
		send_wr.send_flags            = IBV_SEND_SIGNALED;
		send_wr.sg_list               = &sge;
		send_wr.num_sge               = 1;
		send_wr.wr.rdma.rkey          = ntohl(server_pdata.buf_rkey);
		send_wr.wr.rdma.remote_addr   = ntohl(server_pdata.buf_va);

		if (ibv_post_send(cm_id->qp, &send_wr, &bad_send_wr))
			return 1;

		tmp = buf;
		buf = buf2;
		buf2 = tmp;

		buf_read_bytes = read_bytes = max(0, read(STDIN_FILENO, &buf[1], buf_size-4));
		// while (read_bytes && buf_read_bytes < buf_size-4) {
		// 	read_bytes = read(STDIN_FILENO, ((void*)(&buf[1])) + buf_read_bytes, buf_size-4-buf_read_bytes);
		// 	buf_read_bytes += read_bytes;
		// }
		buf[0] = buf_read_bytes;
		// fprintf(stderr, "%d %d %d\n", read_bytes, buf_read_bytes, buf[0]);
		total_bytes += buf_read_bytes;
		
		/* Wait for a response */

		if (ibv_get_cq_event(comp_chan, &evt_cq, &cq_context))
			return 2;

		if (ibv_req_notify_cq(cq, 0))
			return 3;

		if (ibv_poll_cq(cq, 1, &wc) != 1)
			return 4;

		if (wc.status != IBV_WC_SUCCESS)
			return 5;

		//printf("%d\n", buf[0]);

		if (ibv_get_cq_event(comp_chan, &evt_cq, &cq_context))
			return 6;

		if (ibv_req_notify_cq(cq, 0))
			return 7;

		if (ibv_poll_cq(cq, 1, &wc) != 1)
			return 8;

		if (wc.status != IBV_WC_SUCCESS)
			return 9;

		event_count += 2;
		//printf("%d %d %d\n", read_bytes, buf_read_bytes, buf[0]);
	}

    clock_gettime(CLOCK_REALTIME, &now);
    seconds = (double)((now.tv_sec+now.tv_nsec*1e-9) - (double)(tmstart.tv_sec+tmstart.tv_nsec*1e-9));
    if (verbose > 0) {
	    fprintf(stderr, "Bandwidth %.3f GB/s\n", (total_bytes / seconds) / 1e9);
	}

    ibv_ack_cq_events(cq, event_count);

	rdisconnect(cm_channel, cm_id, mr, cq, pd, comp_chan);
	rdma_destroy_event_channel(cm_channel);

    return 0;
}
