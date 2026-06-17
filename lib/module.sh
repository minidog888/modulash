#!/bin/bash
# ============================================
# Modulash Module Management Library
# Provides functions for installing, enabling,
# disabling, and listing modules.
# ============================================

# Remove fixed PROJECT_ROOT dependency; use PWD dynamically
export MODULE_VENDOR_DIR="${MODULE_VENDOR_DIR:-$PWD/vendor}"
export MODULE_COMMANDS_DIR="${MODULE_COMMANDS_DIR:-$PWD/bin/commands}"

# Helper: Get registry URL from modulash.json in current directory
module_get_registry_url() {
    local config_file="$PWD/modulash.json"
    if ! command -v jq >/dev/null 2>&1; then
        echo "http://localhost:8000/api/packages"
        return 0
    fi
    if [[ ! -f "$config_file" ]]; then
        echo "http://localhost:8000/api/packages"
        return 0
    fi
    jq -r '.registry.default // "http://localhost:8000/api/packages"' "$config_file"
}

# Helper: Match version constraint against list of available versions
module_match_version() {
    local constraint="$1"
    shift
    local versions=("$@")
    local best=""

    if [[ "$constraint" == ^* ]]; then
        local base="${constraint#^}"
        local major="${base%%.*}"
        for v in "${versions[@]}"; do
            if [[ "$v" == "$major"* ]] || [[ "$v" == "$major."* ]]; then
                if [[ -z "$best" ]] || [[ "$v" > "$best" ]]; then
                    best="$v"
                fi
            fi
        done
    elif [[ "$constraint" == ~* ]]; then
        local base="${constraint#~}"
        local prefix="${base%.*}"
        for v in "${versions[@]}"; do
            if [[ "$v" == "$prefix"* ]]; then
                if [[ -z "$best" ]] || [[ "$v" > "$best" ]]; then
                    best="$v"
                fi
            fi
        done
    elif [[ "$constraint" == "*" ]]; then
        best="${versions[-1]}"
    else
        for v in "${versions[@]}"; do
            if [[ "$v" == "$constraint" ]]; then
                best="$v"
                break
            fi
        done
    fi

    echo "$best"
}

# Install a dependency by name and version constraint
module_install_dependency() {
    local dep_name="$1"
    local constraint="$2"
    local registry_url
    registry_url="$(module_get_registry_url)"
    if [[ -z "$registry_url" ]]; then
        echo "[ERROR] No registry URL configured" >&2
        return 1
    fi

    echo "[DEBUG] Installing $dep_name ($constraint) from $registry_url" >&2

    local api_url="$registry_url/$dep_name"
    local package_info
    if ! package_info=$(curl -s "$api_url"); then
        echo "[ERROR] Failed to fetch package info from $api_url" >&2
        return 1
    fi

    if ! echo "$package_info" | jq -e . >/dev/null 2>&1; then
        echo "[ERROR] Invalid JSON from registry: $api_url" >&2
        echo "$package_info" | head -c 200 >&2
        return 1
    fi

    local versions
    versions=($(echo "$package_info" | jq -r '.versions[].version' | sort -V))
    if [[ ${#versions[@]} -eq 0 ]]; then
        echo "[ERROR] No versions available for $dep_name" >&2
        return 1
    fi

    local matched_version
    matched_version="$(module_match_version "$constraint" "${versions[@]}")"
    if [[ -z "$matched_version" ]]; then
        echo "[ERROR] No version matches constraint '$constraint' for $dep_name" >&2
        echo "[INFO] Available versions: ${versions[*]}" >&2
        return 1
    fi

    echo "[INFO] Matched version: $matched_version" >&2

    local tarball_url
    tarball_url=$(echo "$package_info" | jq -r --arg ver "$matched_version" '.versions[] | select(.version == $ver) | .download_url // ""')
    if [[ -z "$tarball_url" || "$tarball_url" == "null" ]]; then
        tarball_url="$registry_url/$dep_name/download/$matched_version"
        echo "[WARN] download_url missing, using constructed URL: $tarball_url" >&2
    fi

    local target_dir="$PWD/vendor/$dep_name"
    if [[ -d "$target_dir" ]]; then
        echo "[INFO] Module $dep_name already installed" >&2
        return 0
    fi

    mkdir -p "$PWD/vendor"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local tarball="$tmp_dir/package.tar.gz"
    echo "[INFO] Downloading $tarball_url ..." >&2
    if ! curl -L -o "$tarball" "$tarball_url"; then
        echo "[ERROR] Failed to download tarball from $tarball_url" >&2
        return 1
    fi

    if ! tar -xzf "$tarball" -C "$tmp_dir"; then
        echo "[ERROR] Failed to extract tarball" >&2
        return 1
    fi

    local pkg_dir
    pkg_dir="$(_find_pkg_dir "$tmp_dir")"
    if [[ -z "$pkg_dir" ]]; then
        echo "[ERROR] No modulash.json found in extracted archive" >&2
        return 1
    fi

    mkdir -p "$target_dir"
    cp -r "$pkg_dir"/* "$target_dir"/

    # Source bootstrap directly (no if)
    source "$target_dir/bootstrap.sh" 2>/dev/null || true

    # Enable module (link commands)
    module_enable_module "$dep_name"

    echo "[SUCCESS] Installed $dep_name ($matched_version)" >&2
    return 0
}

# Helper: Find directory containing modulash.json
_find_pkg_dir() {
    local root="$1"
    if [[ -f "$root/modulash.json" ]]; then
        echo "$root"
        return 0
    fi
    for d in "$root"/*/; do
        if [[ -f "$d/modulash.json" ]]; then
            echo "$d"
            return 0
        fi
    done
    return 1
}

# Enable a module (create symlink to commands)
module_enable_module() {
    local module_name="$1"
    local module_dir="$PWD/vendor/$module_name"
    local commands_dir="$PWD/bin/commands"
    if [[ ! -d "$module_dir" ]]; then
        echo "Error: Module '$module_name' not installed" >&2
        return 1
    fi
    if [[ ! -f "$module_dir/modulash.json" ]]; then
        echo "Error: Invalid module (no modulash.json)" >&2
        return 1
    fi
    mkdir -p "$commands_dir"
    if [[ -d "$module_dir/commands" ]]; then
        rm -rf "$commands_dir/$module_name"
        ln -s "$module_dir/commands" "$commands_dir/$module_name"
        echo "[INFO] Enabled commands for $module_name" >&2
        return 0
    else
        echo "[INFO] Module $module_name has no commands" >&2
        return 0
    fi
}

# Disable a module
module_disable_module() {
    local module_name="$1"
    local commands_dir="$PWD/bin/commands"
    if [[ -L "$commands_dir/$module_name" ]] || [[ -d "$commands_dir/$module_name" ]]; then
        rm -rf "$commands_dir/$module_name"
        echo "Disabled $module_name"
        return 0
    else
        echo "Module not enabled: $module_name"
        return 1
    fi
}

# List modules
module_list_modules() {
    local vendor_dir="$PWD/vendor"
    local commands_dir="$PWD/bin/commands"
    if [[ ! -d "$vendor_dir" ]]; then
        echo "No modules installed"
        return 0
    fi
    echo "Installed modules:"
    for mod_dir in "$vendor_dir"/*/; do
        if [[ -d "$mod_dir" ]]; then
            local mod_name
            mod_name="$(basename "$mod_dir")"
            if [[ -f "$mod_dir/modulash.json" ]]; then
                local status
                if [[ -L "$commands_dir/$mod_name" ]] || [[ -d "$commands_dir/$mod_name" ]]; then
                    status="enabled"
                else
                    status="installed (not linked)"
                fi
                echo "  $mod_name - $status"
            else
                echo "  $mod_name - invalid"
            fi
        fi
    done
}

# Sync dependencies: install missing ones from registry
module_sync_modules() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "[ERROR] jq is required for module sync" >&2
        return 1
    fi
    local config_file="$PWD/modulash.json"
    if [[ ! -f "$config_file" ]]; then
        echo "[ERROR] modulash.json not found in $PWD" >&2
        return 1
    fi

    local deps_json
    deps_json="$(jq -r '.dependencies // {}' "$config_file")"
    local modules
    modules="$(jq -r 'keys[]' <<< "$deps_json")"
    if [[ -z "$modules" ]]; then
        echo "[INFO] No dependencies found in $config_file"
        return 0
    fi

    echo "[INFO] Syncing dependencies from $config_file ..."
    local failed=0
    for mod in $modules; do
        local constraint
        constraint="$(jq -r ".\"$mod\"" <<< "$deps_json")"
        if [[ -d "$PWD/vendor/$mod" ]]; then
            echo "[INFO]   $mod already installed"
        else
            echo "[INFO]   Installing $mod ($constraint)..."
            if ! module_install_dependency "$mod" "$constraint"; then
                echo "[ERROR]   Failed to install $mod" >&2
                ((failed++))
            fi
        fi
    done

    if [[ $failed -gt 0 ]]; then
        echo "[ERROR] Some dependencies failed to install" >&2
        return 1
    fi
    echo "[SUCCESS] All dependencies installed"
    return 0
}

# Install a module from Git/local path (kept for backward compatibility)
module_install_module() {
    local source_url="$1"
    local module_name="$2"
    local target_dir="$PWD/vendor/$module_name"

    if [[ -d "$target_dir" ]]; then
        echo "Error: Module '$module_name' already exists" >&2
        return 1
    fi

    mkdir -p "$PWD/vendor"

    if [[ -d "$source_url" ]]; then
        cp -r "$source_url" "$target_dir"
    elif [[ "$source_url" =~ ^https?:// ]] || [[ "$source_url" =~ \.git$ ]]; then
        if ! command -v git >/dev/null 2>&1; then
            echo "Error: git is required" >&2
            return 1
        fi
        git clone "$source_url" "$target_dir" || return 1
    else
        echo "Error: Unsupported source format" >&2
        return 1
    fi

    if [[ ! -f "$target_dir/modulash.json" ]]; then
        echo "Error: Source does not contain modulash.json" >&2
        rm -rf "$target_dir"
        return 1
    fi

    source "$target_dir/bootstrap.sh" 2>/dev/null || true

    module_enable_module "$module_name"
    echo "Module '$module_name' installed successfully"
    return 0
}