#!/bin/bash

# sync user db for squirrel
# author: CsHeng
# date: 2025-07-22
# ref: https://github.com/rime/squirrel/issues/421#issuecomment-1851849381

if [ -n "$(pgrep 'Squirrel')" ]; then
    cpu_usage=$(ps -p $(pgrep 'Squirrel') -o %cpu=);
    if [ "$(echo "$cpu_usage <= 0.5" | bc -l)" -eq 1 ]; then
        echo "Squirrel is idle, syncing user db"
        cd ~/Library/Rime
        export DYLD_LIBRARY_PATH="/Library/Input Methods/Squirrel.app/Contents/Frameworks"
        "/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel" --quit
        "/Library/Input Methods/Squirrel.app/Contents/MacOS/rime_dict_manager" -s
    else
        echo "Squirrel is running, skipping sync"
    fi
else
    echo "Squirrel is not running, skipping sync"
fi