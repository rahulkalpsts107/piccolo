set(MPILIBS mpi_cxx mpi open-rte open-pal)
set(STATICLIBS protobuf boost_thread-mt util)
set(DYNAMICLIBS lzo2 pthread rt dl numa)

GET_DIRECTORY_PROPERTY(cmake_include_directories INCLUDE_DIRECTORIES)
SET(include_flag)
FOREACH(it ${cmake_include_directories})
  SET(include_flag ${include_flag} "-I${it}")
ENDFOREACH(it)

GET_DIRECTORY_PROPERTY(cmake_link_directories LINK_DIRECTORIES)
SET(link_flag)
FOREACH(it ${cmake_link_directories})
  SET(link_flag ${link_flag} "-L${it}")
ENDFOREACH(it)

SET(swig_out ${CMAKE_CURRENT_BINARY_DIR}/piccolo_wrap.cc)
SET(swig_shim ${CMAKE_CURRENT_SOURCE_DIR}/python_support.cc)

ADD_CUSTOM_COMMAND(
 OUTPUT ${swig_out}
 COMMAND swig
 ARGS 
 -python -ignoremissing -c++
 -w315 -w317 -w362 -w503 -w451 -w401
 -outdir ${CMAKE_CURRENT_BINARY_DIR} 
 ${include_flag}
 ${MPI_COMPILE_FLAGS}
 -o ${swig_out}
 ${CMAKE_CURRENT_SOURCE_DIR}/python_support.swig
 DEPENDS python_support.swig worker master common kernel example ${EXAMPLE_PB_SRC})
 
ADD_CUSTOM_COMMAND(
  OUTPUT _piccolo.so
  COMMAND g++
  ARGS
  -ggdb2
  -shared
  -fPIC
  ${include_flag}
  ${link_flag}
  -o ${CMAKE_CURRENT_BINARY_DIR}/_piccolo.so
  ${swig_out} ${swig_shim} ${EXAMPLE_PB_HDR} ${EXAMPLE_PB_SRC}
  ${MPI_LINK_FLAGS}
  ${CMAKE_BINARY_DIR}/util/libcommon.a
  ${CMAKE_BINARY_DIR}/worker/libworker.a
  ${CMAKE_BINARY_DIR}/kernel/libkernel.a
  ${CMAKE_BINARY_DIR}/master/libmaster.a
  ${CMAKE_BINARY_DIR}/external/protobuf/libprotobuf.a
  ${CMAKE_BINARY_DIR}/external/google-flags/libgflags.a    
  ${CMAKE_BINARY_DIR}/external/google-logging/libglog.a
  ${CMAKE_BINARY_DIR}/external/google-perftools/libprofiler.a
  ${CMAKE_BINARY_DIR}/external/google-perftools/libgperfbase.a
  -Wl,-Bstatic 
  -lmpi_cxx -lmpi -lopen-rte -lopen-pal
  -Wl,-Bdynamic
  -lpthread -lutil -lnuma
  -llzo2 -lboost_python-mt-py26 -lboost_thread-mt -lblas 
  DEPENDS ${swig_out}
 )
  
 ADD_CUSTOM_TARGET(_piccolo ALL DEPENDS _piccolo.so)