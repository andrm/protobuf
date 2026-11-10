PROTOBUF_DIR ?= $(GITHUB_WORKSPACE)/google
GPRBUILD_FLAGS = -p -j0
PREFIX                 ?= /usr
GPRDIR                 ?= $(PREFIX)/share/gpr
LIBDIR                 ?= $(PREFIX)/lib
BINDIR                 ?= $(PREFIX)/bin
DATAROOTDIR            ?= $(PREFIX)/share
INSTALL_PROJECT_DIR    ?= $(DESTDIR)$(GPRDIR)
INSTALL_INCLUDE_DIR    ?= $(DESTDIR)$(PREFIX)/include/ada-protobuf
INSTALL_LIBRARY_DIR    ?= $(DESTDIR)$(LIBDIR)
INSTALL_BIN_DIR        ?= $(DESTDIR)$(BINDIR)
INSTALL_ALI_DIR        ?= ${INSTALL_LIBRARY_DIR}/ada-protobuf
INSTALL_GDB_PLUGIN_DIR ?= $(DESTDIR)$(DATAROOTDIR)/gdb/python/ada-protobuf
INSTALL                ?= install

GPRINSTALL_FLAGS = --prefix=$(PREFIX) --sources-subdir=$(INSTALL_INCLUDE_DIR)\
 --lib-subdir=$(INSTALL_ALI_DIR) --project-subdir=$(INSTALL_PROJECT_DIR)\
 --link-lib-subdir=$(INSTALL_LIBRARY_DIR) --exec-subdir=$(INSTALL_BIN_DIR)

all:
	gprbuild $(GPRBUILD_FLAGS) -P gnat/protobuf_runtime.gpr
	gprbuild $(GPRBUILD_FLAGS) -P gnat/protoc_gen_ada.gpr

install:
	gprinstall $(GPRINSTALL_FLAGS) -p -P gnat/protobuf_runtime.gpr
	gprinstall $(GPRINSTALL_FLAGS) -p -P gnat/protoc_gen_ada.gpr --mode=usage
	$(INSTALL) -D gdb/python/protobuf.py $(INSTALL_GDB_PLUGIN_DIR)/protobuf.py

clean:
	gprclean -q -P gnat/protoc_gen_ada.gpr
	gprclean -q -P gnat/protobuf_runtime.gpr

# Fails on any unproved check, any GNATprove warning, and any assumption or
# proof justification in the SPARK runtime
prove-spark:
	! grep -n -i -E 'pragma +(Assume|Annotate)|Assume *=>' \
	  source/spark_runtime/*.ad[sb]
	gnatprove -P gnat/protobuf_spark_runtime.gpr --mode=all --level=2 -j0 \
	  --report=fail --warnings=error --checks-as-errors=on

check:
	@echo Compile some predefined .proto files
	for J in any duration empty field_mask struct timestamp wrappers; do\
	  echo $$J; PATH=.objs/compiler/:$$PATH \
	  protoc --ada_out=source/runtime/generated \
	   /usr/include/google/protobuf/$$J.proto; done
	gprbuild -P gnat/protobuf_runtime.gpr
	@echo Run generator option tests
	gprbuild -p -P gnat/compiler_tests.gpr
	.objs/compiler_tests/compiler_options_test source/compiler_tests/fixtures
	.objs/compiler_tests/compiler_bounds_test
	@echo Run SPARK runtime tests
	gprbuild -p -P gnat/pb_spark_test.gpr
	.objs/spark_runtime_tests/pb_spark_test
	@echo Run regression tests
	./testsuite/run_all.sh
	@echo Run SPARK output tests
	./testsuite_spark/run_all.sh
	@echo Run conformance test if any
	./conformance.sh $(PROTOBUF_DIR)
	@echo Run SPARK conformance test if any, as a diagnostic
	-./conformance_spark.sh $(PROTOBUF_DIR)
