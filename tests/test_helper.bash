#!/usr/bin/env bash
# ============================================
# Test Helper — common setup
# ============================================

setup() {
    export PROJECT_ROOT="$BATS_TEST_DIRNAME/.."
    export PATH="$PROJECT_ROOT/bin:$PATH"
    export CLISH_DEV_MODE=true
    cd "$PROJECT_ROOT" || return 1
}

run_clish() {
    run ./bin/clish "$@"
}

assert_output_contains() {
    local expected="$1"
    if [[ ! "$output" == *"$expected"* ]]; then
        echo "Expected output to contain '$expected' but got:"
        echo "$output"
        return 1
    fi
}

# 从 clish.build.json 读取 output 字段
get_build_output() {
    local config="$PROJECT_ROOT/clish.build.json"
    if [[ -f "$config" ]] && command -v jq >/dev/null 2>&1; then
        jq -r '.output // "./dist/modulash"' "$config"
    else
        echo "./dist/modulash"
    fi
}