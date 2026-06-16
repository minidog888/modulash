#!/usr/bin/env bash
# ============================================
# Clish Basic Tests
# ============================================

load test_helper

@test "clish shows version" {
    run_clish --version
    [ "$status" -eq 0 ]
    assert_output_contains "Clish Console version"
}

@test "clish lists available commands" {
    run_clish
    [ "$status" -eq 0 ]
    assert_output_contains "Available commands:"
    assert_output_contains "build"
}

@test "clish unknown command fails" {
    run_clish unknown-command-xyz
    [ "$status" -ne 0 ]
    assert_output_contains "Command 'unknown-command-xyz' not found."
}

@test "clish build creates output file" {
    # 获取配置中的输出路径
    local output_path
    output_path="$(get_build_output)"
    # 删除旧文件（如果存在）
    rm -f "$output_path"
    run_clish build --force
    [ "$status" -eq 0 ]
    assert_output_contains "Build completed"
    # 检查文件是否存在
    [ -f "$output_path" ]
}

@test "clish dump-autoload runs without errors" {
    run_clish dump-autoload
    [ "$status" -eq 0 ]
    assert_output_contains "Generated aliases"
}