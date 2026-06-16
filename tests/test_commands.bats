#!/usr/bin/env bash
# ============================================
# Clish Commands Tests
# ============================================

load test_helper

@test "build command has description" {
    run_clish build --help
    [ "$status" -eq 0 ]
    assert_output_contains "Package Clish project by recursively including script files"
}

@test "dump-autoload command has description" {
    run_clish dump-autoload --help
    [ "$status" -eq 0 ]
    assert_output_contains "Generate aliases and facades from modulash.json"
}