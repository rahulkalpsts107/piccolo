.PRECIOUS : %.pb.cc %.pb.h

MPI_INC :=
MPI_LINK := mpic++

#MPI_LINK := /home/power/local/mpich2/bin/mpic++
#MPI_INC := -I/home/power/local/mpich2/include

CFLAGS := -ggdb2 -O0 -Wall -Wno-unused-function -Wno-sign-compare
CXXFLAGS := $(CFLAGS)
CPPFLAGS := $(CPPFLAGS) -I. -Isrc -Iextlib/glog/src/ -Iextlib/gflags/src/  $(MPI_INC)

LDFLAGS := 
LDDIRS := -Lextlib/glog/.libs/ -Lextlib/gflags/.libs/ $(MPI_LIB)

DYNAMIC_LIBS := -lboost_thread -lprotobuf
STATIC_LIBS := -Wl,-Bstatic -lglog -lgflags -Wl,-Bdynamic 

LINK_LIB := ld --eh-frame-hdr -r
LINK_BIN := $(MPI_LINK) $(LDDIRS) 


LIBCOMMON_OBJS := src/util/common.pb.o src/util/file.o src/util/common.o src/util/rpc.o
LIBWORKER_OBJS := src/worker/worker.pb.o src/worker/worker.o src/worker/kernel.o src/master/master.o

%.o: %.cc
	@echo CC :: $<
	@$(CXX) $(CXXFLAGS) $(CPPFLAGS) $(TARGET_ARCH) -c $< -o $@


all: bin/test-shortest-path bin/test-tables

ALL_SOURCES := $(shell find src -name '*.h' -o -name '*.cc' -o -name '*.proto')

depend:
	CPPFLAGS="$(CPPFLAGS)" ./makedep.sh > Makefile.dep

Makefile.dep: $(ALL_SOURCES)
	CPPFLAGS="$(CPPFLAGS)" ./makedep.sh > Makefile.dep

bin/libcommon.a : $(LIBCOMMON_OBJS)
	$(LINK_LIB) $^ -o $@

bin/libworker.a : $(LIBWORKER_OBJS)
	$(LINK_LIB) $^ -o $@
	
bin/test-shortest-path: bin/libworker.a bin/libcommon.a src/test/test-shortest-path.o
	$(LINK_BIN) $(DYNAMIC_LIBS) $^ -o $@ $(STATIC_LIBS)

bin/test-tables: bin/libworker.a bin/libcommon.a src/test/test-tables.o
	$(LINK_BIN) $(DYNAMIC_LIBS) $^ -o $@ $(STATIC_LIBS)

clean:
	find src -name '*.o' -exec rm {} \;
	rm -f bin/*

%.pb.cc %.pb.h : %.proto
	protoc -Isrc/ --cpp_out=$(CURDIR)/src $<

$(shell mkdir -p bin/)
-include Makefile.dep
