CC=gcc
CFLAGS=-fopenmp -O2 -mavx -Wall -Werror
INCLUDES=
LDFLAGS=
LIBS=-lrdmacm -libverbs

SRCS=rdsend.c rdrecv.c
OBJS=$(SRCS:.c=.o)
PROG=rdsend rdrecv

all: $(PROG)

debug: CFLAGS=-Wall -Werror -g -DDEBUG
debug: $(PROG)

.c.o:
	$(CC) $(CFLAGS) $(INCLUDES) -c -o $@ $<

rdsend: $(OBJS)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ $@.o $(LDFLAGS) $(LIBS)

rdrecv: $(OBJS)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ $@.o $(LDFLAGS) $(LIBS)

clean:
	$(RM) *.o *~ $(PROG)

install: $(PROG)
	install -m 0755 $(PROG) rdcp /usr/local/bin

uninstall:
	cd /usr/local/bin && $(RM) $(PROG) rdcp
