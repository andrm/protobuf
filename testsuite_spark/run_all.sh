#!/bin/bash
# Check SPARK output of the generator. For each directory here:
#
#   *.proto, *.options, *.ads   schema, generator options, parent packages
#   expected_error              the generator must fail with this text
#   roundtrip                   "Ada.Package Type proto.message.name"
#   cases/*.txt                 protobuf text format inputs to round trip
#   any_order                   compare decoded text instead of bytes
#   cases/*.expected            text format expected after a round trip
#   cases/*.status              decoding must fail with this status
#   cases/*.encode_as           encode the input as this message instead
#   cases/*.append              text format encoded after the input, to test
#                               merging of repeated occurrences
#   check.adb                   a program to build and run with the code
#
# Generated code must compile under the runtime's restrictions, contain no
# pragma Assume or Annotate and, when gnatprove is installed, prove with no
# warnings. Set REQUIRE_PROOF=1 to fail when gnatprove is not installed.
#
# Set DIFFERENTIAL=N to also run differential.py on each round trip test:
# N random messages, variants of their encodings and corrupted inputs,
# compared with Python protobuf ($PYTHON, default python3, with the
# protobuf package). DIFFERENTIAL_SEED picks other random inputs.
#
# Usage: run_all.sh [OUTPUT_DIRECTORY [TEST...]]

TESTS=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TESTS/.." && pwd)
OUT="${1:-${TMPDIR:-/tmp}/proto_spark}"
shift
ONLY=" $* "   # Names of tests to run, after the output directory
FAILS=0
PYTHON=${PYTHON:-python3}

if [ -n "$DIFFERENTIAL" ]; then
  # The pure Python implementation of protobuf disagrees with correct
  # decoders on corrupted input: it takes a tag written with more bytes than
  # needed for an unknown field, and IsInitialized misses a map value that
  # lacks a required field. Fedora's python3-protobuf 3.19 is one.
  PB_IMPL=$("$PYTHON" -I -c "from google.protobuf.internal import \
api_implementation as a; print(a.Type())" 2>/dev/null)
  case "$PB_IMPL" in
    "")
      echo "DIFFERENTIAL needs $PYTHON with the protobuf package"
      exit 1;;
    python)
      echo "DIFFERENTIAL needs protobuf with the upb or cpp implementation;"
      echo "$PYTHON has the pure Python one (pip install protobuf in a venv,"
      echo "then set PYTHON)"
      exit 1;;
  esac
fi

fail() {
  echo "$NAME FAILS: $1"
  FAILS=1
}

run_case() {
  local J=$1 PROTOS=() P
  rm -rf "$OUT"; mkdir -p "$OUT/gen" "$OUT/obj" "$OUT/rt"

  for P in "$J"/*.proto; do PROTOS+=("$(basename "$P")"); done

  if ! PATH="$ROOT/.objs/compiler:$PATH" protoc -I"$J" \
      --ada_opt="runtime=spark,options_path=$J" --ada_out="$OUT/gen" \
      "${PROTOS[@]}" > "$OUT/protoc.log" 2>&1
  then
    if [ -f "$J/expected_error" ] \
      && grep -qF "$(cat "$J/expected_error")" "$OUT/protoc.log"
    then
      return 0
    fi

    cat "$OUT/protoc.log"
    fail "generator failed"
    return 1
  fi

  if [ -f "$J/expected_error" ]; then
    fail "generator should have failed"
    return 1
  fi

  cp "$J"/*.ads "$OUT/gen/" 2>/dev/null

  cat > "$OUT/generated.gpr" <<G
with "$ROOT/gnat/protobuf_spark_runtime.gpr";

project Generated is
   for Source_Dirs use ("gen");
   for Object_Dir use "obj";
   for Languages use ("Ada");

   package Compiler is
      for Default_Switches ("Ada") use ("-gnatW8", "-g", "-gnata", "-gnatwe");
      for Local_Configuration_Pragmas use
        "$ROOT/source/spark_runtime/restrictions.adc";
   end Compiler;
end Generated;
G

  if ! gprbuild -q -c -p -P "$OUT/generated.gpr" > "$OUT/build.log" 2>&1; then
    cat "$OUT/build.log"
    fail "generated code doesn't compile"
    return 1
  fi

  if grep -n -i -E 'pragma +(Assume|Annotate)|Assume *=>' "$OUT"/gen/*.ad[sb] \
    > "$OUT/assume.log"
  then
    cat "$OUT/assume.log"
    fail "generated code has assumptions or proof justifications"
    return 1
  fi

  if [ -n "$REQUIRE_PROOF" ] && ! command -v gnatprove > /dev/null; then
    fail "gnatprove is not installed"
    return 1
  fi

  if command -v gnatprove > /dev/null; then
    if ! (cd "$OUT" && gnatprove -P generated.gpr --mode=all --level=2 -j0 \
        --report=fail --warnings=error --checks-as-errors=on) \
        > "$OUT/prove.log" 2>&1
    then
      grep -E 'warning|error|high|medium|low' "$OUT/prove.log" | head -20
      fail "generated code doesn't prove"
      return 1
    fi
  fi

  if [ -f "$J/roundtrip" ]; then
    local PACKAGE TYPE MESSAGE T
    read -r PACKAGE TYPE MESSAGE < "$J/roundtrip"

    sed -e "s/@PACKAGE@/$PACKAGE/g" -e "s/@TYPE@/$TYPE/g" \
      "$TESTS/roundtrip.adb.in" > "$OUT/rt/roundtrip.adb"

    # Built apart from generated.gpr, because restrictions apply to a whole
    # program and this test program is not meant to follow them.
    cat > "$OUT/roundtrip.gpr" <<G
with "$ROOT/gnat/protobuf_spark_runtime.gpr";

project Roundtrip is
   for Source_Dirs use ("rt", "gen");
   for Object_Dir use "rt";
   for Exec_Dir use "rt";
   for Main use ("roundtrip.adb");
   for Languages use ("Ada");

   package Compiler is
      for Default_Switches ("Ada") use ("-gnatW8", "-g", "-gnata");
   end Compiler;
end Roundtrip;
G

    if [ -f "$J/check.adb" ]; then
      cp "$J/check.adb" "$OUT/rt/"
      sed -i 's/for Main use ("roundtrip.adb");/for Main use ("roundtrip.adb", "check.adb");/' \
        "$OUT/roundtrip.gpr"
    fi

    if ! gprbuild -q -p -P "$OUT/roundtrip.gpr" > "$OUT/rt.log" 2>&1; then
      cat "$OUT/rt.log"
      fail "round trip program doesn't compile"
      return 1
    fi

    if [ -f "$J/check.adb" ] && ! "$OUT/rt/check" > "$OUT/check.log" 2>&1
    then
      fail "check failed: $(cat "$OUT/check.log")"
    fi

    for T in "$J"/cases/*.txt; do
      local BASE IN=$OUT/in.bin RES=$OUT/out.bin ENCODE_AS=$MESSAGE
      BASE=$(basename "$T" .txt)
      rm -f "$IN" "$RES"

      if [ -f "$J/cases/$BASE.encode_as" ]; then
        ENCODE_AS=$(cat "$J/cases/$BASE.encode_as")
      fi

      if ! protoc -I"$J" --encode="$ENCODE_AS" "${PROTOS[@]}" < "$T" > "$IN"
      then
        fail "$BASE: bad test input"
        continue
      fi

      if [ -f "$J/cases/$BASE.append" ] && ! protoc -I"$J" \
          --encode="$ENCODE_AS" "${PROTOS[@]}" < "$J/cases/$BASE.append" \
          >> "$IN"
      then
        fail "$BASE: bad appended input"
        continue
      fi

      if [ -f "$J/cases/$BASE.status" ]; then
        if "$OUT/rt/roundtrip" "$IN" "$RES" > "$OUT/run.log" 2>&1; then
          fail "$BASE: decoding should have failed"
        elif [ "$(cat "$OUT/run.log")" != "$(cat "$J/cases/$BASE.status")" ]
        then
          fail "$BASE: wrong status $(cat "$OUT/run.log")"
        fi
        continue
      fi

      if ! "$OUT/rt/roundtrip" "$IN" "$RES" > "$OUT/run.log" 2>&1; then
        fail "$BASE: round trip failed: $(cat "$OUT/run.log")"
        continue
      fi

      local EXPECTED=$J/cases/$BASE.expected

      if [ ! -f "$J/any_order" ] && [ ! -f "$EXPECTED" ] \
        && ! cmp -s "$IN" "$RES"
      then
        fail "$BASE: encoded bytes differ"
        continue
      fi

      protoc -I"$J" --decode="$MESSAGE" "${PROTOS[@]}" \
        < "$RES" > "$OUT/out.txt"

      if [ -f "$EXPECTED" ]; then
        cp "$EXPECTED" "$OUT/want.txt"
      else
        protoc -I"$J" --decode="$MESSAGE" "${PROTOS[@]}" \
          < "$IN" > "$OUT/want.txt"
      fi

      if ! cmp -s "$OUT/want.txt" "$OUT/out.txt"; then
        fail "$BASE: decoded values differ"
      fi
    done

    if [ -n "$DIFFERENTIAL" ]; then
      if ! protoc -I"$J" --include_imports \
          --descriptor_set_out="$OUT/descriptors.pb" "${PROTOS[@]}" \
        || ! "$PYTHON" -I "$TESTS/differential.py" "$OUT/descriptors.pb" \
          "$J" "$MESSAGE" "$OUT/rt/roundtrip" "$OUT/differential" \
          --count "$DIFFERENTIAL" --seed "${DIFFERENTIAL_SEED:-1}" \
          > "$OUT/differential.log" 2>&1
      then
        cat "$OUT/differential.log"
        fail "differential test"
      fi
    fi
  fi
}

for J in "$TESTS"/*; do
  NAME=$(basename "$J")

  if [ -d "$J" ] && { [ "$ONLY" = "  " ] || [[ "$ONLY" == *" $NAME "* ]]; }
  then
    BEFORE=$FAILS
    FAILS=0
    run_case "$J"

    if [ "$FAILS" = 0 ]; then
      echo "$NAME OK"
    fi

    FAILS=$((FAILS | BEFORE))
  fi
done

exit $FAILS
