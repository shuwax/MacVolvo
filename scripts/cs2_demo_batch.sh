#!/bin/bash
# Build CS2 shader recipes by playing back demo files.
# Usage: ./cs2_demo_batch.sh [folder/with/demos] [timescale=16]
#
# CS2 compiles Metal pipeline archives as it renders each frame. Playing back
# demos at high speed (16x-32x) causes CS2 to visit many map locations quickly,
# producing recipes that pipeline-setup later compiles into Metal archives so
# subsequent launches skip the GPU compilation stutter.
set -euo pipefail

DEMO_DIR="${1:-$HOME/Downloads/demos}"
TIMESCALE="${2:-16}"
ROOT="$HOME/Library/Application Support/MacVolvo"
CACHE="$ROOT/cache/pipelines"
CFGDIR="$ROOT/environment/drive_c/Program Files (x86)/Steam/steamapps/common/Counter-Strike Global Offensive/game/csgo/cfg"
DEMOCFG="$CFGDIR/macvolvo_demo.cfg"
MACVOLVO="/Applications/MacVolvo.app/Contents/Helpers/ow2-setup"

[ -d "$DEMO_DIR" ] || { echo "Folder not found: $DEMO_DIR"; exit 1; }

DEMOS=("$DEMO_DIR"/*.dem)
[ ${#DEMOS[@]} -eq 0 ] && { echo "No .dem files in $DEMO_DIR"; exit 1; }

cleanup_democfg() {
    echo "" > "$DEMOCFG" 2>/dev/null || true
}
trap cleanup_democfg EXIT

TOTAL_BEFORE=$(find "$CACHE" -name "*.json" -path "*/recipes/*" 2>/dev/null | wc -l | tr -d ' ')
echo "=== CS2 Demo Batch ==="
echo "Demos:           ${#DEMOS[@]}"
echo "Timescale:       ${TIMESCALE}x"
echo "Recipes before:  $TOTAL_BEFORE"
echo ""

DEMO_NUM=0
for DEMO in "${DEMOS[@]}"; do
    DEMO_NUM=$((DEMO_NUM + 1))
    DEMO_NAME=$(basename "$DEMO")
    WIN_DEMO="Z:$(echo "$DEMO" | tr '/' '\\')"

    BEFORE=$(find "$CACHE" -name "*.json" -path "*/recipes/*" 2>/dev/null | wc -l | tr -d ' ')
    echo "[$DEMO_NUM/${#DEMOS[@]}] $DEMO_NAME (recipes before: $BEFORE)"

    # Make sure CS2/Wine is not already running
    if pgrep -if "cs2.exe" > /dev/null 2>&1; then
        echo "  Closing previous CS2..."
        "$MACVOLVO" close-client 2>/dev/null || true
        pkill -f "cs2.exe" 2>/dev/null || true
        for i in $(seq 1 15); do
            sleep 2
            pgrep -if "cs2.exe" > /dev/null 2>&1 || { echo "  CS2 closed (${i}x2s)"; break; }
        done
    fi

    # Write the demo path into macvolvo_demo.cfg; CS2 executes it via +exec macvolvo_demo
    printf 'bind "F9" "demo_timescale %s"\nplaydemo "%s"\n' "$TIMESCALE" "$WIN_DEMO" > "$DEMOCFG"

    # Launch CS2 via MacVolvo
    echo "  Launching CS2..."
    "$MACVOLVO" launch --game cs2 2>/dev/null &
    LAUNCH_PID=$!

    # Wait for CS2 to start
    for i in $(seq 1 60); do
        sleep 2
        if pgrep -if "cs2.exe" > /dev/null 2>&1; then
            echo "  CS2 ready (${i}x2s)"
            break
        fi
    done
    wait $LAUNCH_PID 2>/dev/null || true

    # Wait for the demo to load, send F9 (set timescale), then minimize the window
    sleep 25
    CS2_PID=$(pgrep -if "cs2.exe" | head -1)
    if [ -n "$CS2_PID" ]; then
        osascript << APPLESCRIPT 2>/dev/null || true
tell application "System Events"
    set frontmost of (first process whose unix id is $CS2_PID) to true
    delay 1
    key code 101
    delay 0.5
    set miniaturized of (first window of (first process whose unix id is $CS2_PID)) to true
end tell
APPLESCRIPT
    fi
    osascript -e "display notification \"Demo: $DEMO_NAME @ ${TIMESCALE}x\" with title \"MacVolvo Batch\"" 2>/dev/null || true

    # Monitor recipe count; 60s with no new recipes = demo finished
    PREV=$BEFORE
    IDLE=0
    while pgrep -if "cs2.exe" > /dev/null 2>&1; do
        sleep 5
        COUNT=$(find "$CACHE" -name "*.json" -path "*/recipes/*" 2>/dev/null | wc -l | tr -d ' ')
        NEW=$((COUNT - PREV))
        if [ $NEW -gt 0 ]; then
            echo "  $(date '+%H:%M:%S') | $COUNT recipes (+$NEW)"
            PREV=$COUNT
            IDLE=0
        else
            IDLE=$((IDLE + 5))
            echo -ne "  \r$(date '+%H:%M:%S') | $COUNT recipes (idle: ${IDLE}s)    "
            if [ $IDLE -ge 60 ]; then
                echo ""
                echo "  No new recipes for 60s — closing CS2..."
                "$MACVOLVO" close-client 2>/dev/null || true
                pkill -f "cs2.exe" 2>/dev/null || true
                for i in $(seq 1 15); do
                    sleep 2
                    pgrep -if "cs2.exe" > /dev/null 2>&1 || break
                done
                break
            fi
        fi
    done

    AFTER=$(find "$CACHE" -name "*.json" -path "*/recipes/*" 2>/dev/null | wc -l | tr -d ' ')
    echo ""
    echo "  New recipes: $((AFTER - BEFORE))"
    echo ""
    sleep 3
done

TOTAL_AFTER=$(find "$CACHE" -name "*.json" -path "*/recipes/*" 2>/dev/null | wc -l | tr -d ' ')
echo "=== Done ==="
echo "Recipes before: $TOTAL_BEFORE"
echo "Recipes after:  $TOTAL_AFTER"
echo "New total:      $((TOTAL_AFTER - TOTAL_BEFORE))"
