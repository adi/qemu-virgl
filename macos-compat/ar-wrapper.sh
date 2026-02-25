#!/bin/sh
# Wrapper that expands response files for macOS ar
# Usage: ar-wrapper.sh csr output.a @output.a.rsp
FLAGS=$1; shift
OUT=$1; shift
RSP=${1#@}  # strip leading @
exec /usr/bin/ar "$FLAGS" "$OUT" $(cat "$RSP")
