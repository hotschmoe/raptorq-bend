#!/bin/bash
# Builds the phase-breakdown binary build/profile/phases from a PRIVATE copy of src/ whose solver.bend has the cut harness
# (tools/profile/solver_cut_append.bend) appended; the real src/solver.bend is not modified.
# The harness uses solver.bend internals (written against commit e29b139; adapt names if solver.bend is refactored).
#   tools/profile/mk_phases.sh && tools/profile/run_phases.sh build/profile/phases "1000 4000" "16 1024" 3
set -e
export PATH="$HOME/.bend/bin:/usr/bin:/bin:$PATH" BEND_NO_TELEMETRY=1
D=${B:-build/profile}/ph; rm -rf $D; mkdir -p $D/tools/profile
cp -r src $D/src
cat tools/profile/solver_cut_append.bend >> $D/src/solver.bend
cp tools/profile/phases.bend $D/tools/profile/
bend $D/tools/profile/phases.bend -o ${B:-build/profile}/phases
