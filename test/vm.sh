#!/bin/sh

set -eu

PROJECT_DIR=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)

colima status >/dev/null 2>&1 || colima start
colima ssh -- sh -lc "cd '$PROJECT_DIR' && sh test/run.sh"
colima ssh -- sudo unshare -n -- sh -lc "cd '$PROJECT_DIR' && sh test/netns.sh"

