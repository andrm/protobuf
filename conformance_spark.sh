#!/bin/bash
# Run Google's conformance tests against code generated with runtime=spark.
#
# Usage: conformance_spark.sh PROTOBUF_SOURCE_DIRECTORY
#
# This is a diagnostic. The SPARK output needs bounds on every string, bytes
# and repeated field, and can't represent recursion, groups or unknown fields,
# so source/conformance_spark/conformance_spark.options sets bounds and
# ignores fields, and ada_spark_failing_tests.txt lists the failures this
# causes. The testee only supports protobuf input and output.
#
# The test runner is taken from $CONFORMANCE_TEST_RUNNER, or from the cache
# that conformance.sh uses. Otherwise it is built in that cache directory,
# out of tree, so the protobuf checkout stays clean.

set -e -x

PB_DIR=$1
PB_CACHE=${1}_cache
ROOT=$(cd "$(dirname "$0")" && pwd)
OUT=$ROOT/.objs/conformance_spark

if [ ! -f "$PB_DIR/conformance/conformance.proto" ] ; then
  echo Can not find the protobuf repo
  exit 0
fi

RUNNER=${CONFORMANCE_TEST_RUNNER:-$PB_CACHE/conformance_test_runner}

if [ ! -x "$RUNNER" ] ; then
  cmake -S "$PB_DIR" -B "$PB_CACHE/build" -Dprotobuf_BUILD_CONFORMANCE=ON \
    -Dprotobuf_BUILD_TESTS=OFF
  cmake --build "$PB_CACHE/build" --target conformance_test_runner
  RUNNER=$PB_CACHE/build/conformance_test_runner
fi

rm -rf "$OUT/generated" "$OUT/proto"
mkdir -p "$OUT/generated" "$OUT/proto/google/protobuf"

# TestAllRequiredTypesProto2 has required recursive fields, which can't be
# ignored, and no binary test uses it, so it is removed from a copy of the
# schema.
awk '
  /^message TestAllRequiredTypesProto2 \{/ { skip = 1 }
  skip { depth += gsub(/\{/, "{") - gsub(/\}/, "}"); if (depth == 0) skip = 0; next }
  { print }
' "$PB_DIR/src/google/protobuf/test_messages_proto2.proto" \
  > "$OUT/proto/google/protobuf/test_messages_proto2.proto"

PATH=$ROOT/.objs/compiler:$PATH protoc \
  --ada_opt="runtime=spark,options=$ROOT/source/conformance_spark/conformance_spark.options" \
  --ada_out="$OUT/generated" \
  -I"$OUT/proto" -I"$PB_DIR/src" -I"$PB_DIR/conformance" \
  conformance.proto \
  google/protobuf/test_messages_proto2.proto \
  google/protobuf/test_messages_proto3.proto \
  google/protobuf/any.proto \
  google/protobuf/duration.proto \
  google/protobuf/empty.proto \
  google/protobuf/field_mask.proto \
  google/protobuf/struct.proto \
  google/protobuf/timestamp.proto \
  google/protobuf/wrappers.proto

gprbuild -p -P "$ROOT/gnat/conformance_spark.gpr"

# A runner built by conformance.sh needs its libjsoncpp from the cache
export LD_LIBRARY_PATH=$PB_CACHE${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

"$RUNNER" \
  --failure_list "$ROOT/ada_spark_failing_tests.txt" \
  --output_dir "$OUT" \
  "$OUT/conformance-spark_run"
