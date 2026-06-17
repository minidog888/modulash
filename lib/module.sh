#!/bin/bash
# ============================================
# Modulash Module Management Library
# Provides functions for installing, enabling,
# disabling, and listing modules.
# ============================================
import "@lib/generator.sh"
: "${PROJECT_ROOT:=$(pwd)}"
export MODULE_VENDOR_DIR="$PROJECT_ROOT/vendor"
export MODULE_COMMANDS_DIR="$PROJECT_ROOT/bin/commands"
export MODULE_CONFIG_FILE="$PROJECT_ROOT/modulash.json"

# ============================================
# Module Install (from Git or local path)
# ============================================
module_install_module() {
    local source_url="$1"
    local module_name="$2"
    local target_dir="$MODULE_VENDOR_DIR/$module_name"

    if [[ -d "$target_dir" ]]; then
        echo "Error: Module '$module_name' already exists." >&2
        return 1
    fi

    mkdir -p "$MODULE_VENDOR_DIR"

    if [[ -d "$source_url" ]]; then
        cp -r "$source_url" "$target_dir"
    elif [[ "$source_url" =~ ^https?:// ]] || [[ "$source_url" =~ \.git$ ]]; then
        if ! command -v git >/dev/null 2>&1; then
            echo "Error: git is required to install from Git." >&2
            return 1
        fi
        git clone "$source_url" "$target_dir" || return 1
    else
        echo "Error: Unsupported source format. Use local path or Git URL." >&2
        return 1
    fi

    if [[ ! -f "$target_dir/modulash.json" ]]; then
        echo "Error: Source does not contain modulash.json. Installation failed." >&2
        rm -rf "$target_dir"
        return 1
    fi

    echo "Module '$module_name' installed successfully."
    return 0
}

# ============================================
# Module Sync: Check dependencies from modulash.json
# ============================================
module_sync_modules() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq is required for module sync." >&2
        return 1
    fi

    local config_file="$MODULE_CONFIG_FILE"
    if [[ ! -f "$config_file" ]]; then
        echo "Error: modulash.json not found. Run 'modulash init' first." >&2
        return 1
    fi

    local deps_json
    deps_json="$(jq -r '.dependencies // {}' "$config_file")"
    local modules
    modules="$(jq -r 'keys[]' <<< "$deps_json")"
    if [[ -z "$modules" ]]; then
        echo "No dependencies found."
        return 0
    fi

    echo "Syncing modules declared in $config_file..."
    local failed=0
    for mod in $modules; do
        if [[ -d "$MODULE_VENDOR_DIR/$mod" ]]; then
            echo "Module '$mod' already installed."
        else
            echo "Module '$mod' not installed. Run 'module_install_module' to install."
            ((failed++))
        fi
    done

    if [[ $failed -gt 0 ]]; then
        echo "Some modules are missing. Use 'module_install_module <source> <name>' to install them."
        return 1
    fi
    echo "All dependencies are installed."
    return 0
}

# ============================================
# Registry helper
# ============================================
module_get_registry_url() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq is required to read registry URL." >&2
        return 1
    fi

    local config_file="$MODULE_CONFIG_FILE"
    if [[ ! -f "$config_file" ]]; then
        echo "http://localhost:8000/api/packages"
        return 0
    fi
    jq -r '.registry.default // "http://localhost:8000/api/packages"' "$config_file"
}