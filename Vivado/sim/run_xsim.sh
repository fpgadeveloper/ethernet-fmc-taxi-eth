#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# run_xsim.sh — compile and run the taxi_rgmii_mac testbench with Vivado xsim.
#
# Copyright (c) 2026 Opsero Electronic Design Inc.
#
# Usage: Vivado/sim/run_xsim.sh [--gui]
#   Builds in Vivado/sim/xsim_work (created), prints the TB result and exits
#   non-zero unless the log contains "TB RESULT: PASS".
#   Sources scripts/env.local.sh (repo-level opsero-agent checkout) if it
#   exists; otherwise xvlog/xelab/xsim must already be on PATH.

set -euo pipefail

SIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SIM_DIR/../.." && pwd)"                 # ethernet-fmc-taxi-eth
TAXI_DIR="$REPO_DIR/submodules/taxi"
HDL_DIR="$REPO_DIR/Vivado/src/hdl"
ENV_LOCAL="$(cd "$REPO_DIR/../.." 2>/dev/null && pwd)/scripts/env.local.sh"
WORK="$SIM_DIR/xsim_work"
TOP=tb_taxi_rgmii_mac

if ! command -v xvlog >/dev/null 2>&1 && [ -f "$ENV_LOCAL" ]; then
    # the vendor settings scripts are not clean under 'set -u' / 'set -e'
    set +eu
    # shellcheck disable=SC1090
    source "$ENV_LOCAL" >/dev/null 2>&1
    set -eu
fi
command -v xvlog >/dev/null 2>&1 || { echo "error: xvlog not on PATH (source Vivado settings64.sh)"; exit 2; }
: "${XILINX_VIVADO:?XILINX_VIVADO not set}"

# Taxi .sv sources from the design's source list (taxi_sources.tcl)
mapfile -t TAXI_SRCS < <(sed -n '/set taxi_rtl_rel {/,/^}/p' "$REPO_DIR/Vivado/scripts/taxi_sources.tcl" \
                         | grep -E '\.sv$' | sed "s#^[[:space:]]*#$TAXI_DIR/#")

rm -rf "$WORK"
mkdir -p "$WORK"

GUI_ARGS=()
if [ "${1:-}" = "--gui" ]; then GUI_ARGS=(--gui); fi

(
    cd "$WORK"
    xvlog -sv "${TAXI_SRCS[@]}" "$HDL_DIR/taxi_rgmii_mac_core.sv" "$HDL_DIR/taxi_rgmii_mac.v" "$SIM_DIR/$TOP.sv" > xvlog.log 2>&1 \
        || { cat xvlog.log; exit 1; }
    xvlog "$XILINX_VIVADO/data/verilog/src/glbl.v" >> xvlog.log 2>&1
    xelab -L work -L unisims_ver "$TOP" glbl --snapshot "$TOP" -timescale 1ns/1ps > xelab.log 2>&1 \
        || { cat xelab.log; exit 1; }
    if [ ${#GUI_ARGS[@]} -gt 0 ]; then
        xsim "$TOP" --gui
    else
        xsim "$TOP" -runall > xsim.log 2>&1 || true
        grep -E '^(PASS|FAIL|TB|PHY model)' xsim.log
        grep -q '^TB RESULT: PASS' xsim.log
    fi
)
