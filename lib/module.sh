#!/bin/bash
# ============================================
# Modulash Module Management Library
# ============================================

export MODULE_VENDOR_DIR="${MODULE_VENDOR_DIR:-$PWD/vendor}"
export MODULE_COMMANDS_DIR="${MODULE_COMMANDS_DIR:-$PWD/bin/commands}"

# ------------------------------------------------------------
# Scripts (hooks)
# ------------------------------------------------------------
module_run_scripts() {
    local event="$1"
    local config_file="$PWD/modulash.json"
    [[ ! -f "$config_file" ]] && return 0

    local scripts
    scripts=$(jq -r --arg event "$event" '.scripts[$event] // [] | .[]' "$config_file" 2>/dev/null)
    [[ -z "$scripts" ]] && return 0

    clish_console_core_log_info "Running scripts for event: $event"
    local failed=0
    while IFS= read -r cmd; do
        echo "[RUN] $cmd"
        if ! bash -c "$cmd"; then
            clish_console_core_log_error "Script failed: $cmd" >&2
            ((failed++))
        fi
    done <<< "$scripts"

    if [[ $failed -gt 0 ]]; then
        clish_console_core_log_error "$failed script(s) failed for event '$event'" >&2
        return 1
    fi
    return 0
}

# ------------------------------------------------------------
# Registry & version matching
# ------------------------------------------------------------
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

# ------------------------------------------------------------
# Lock file helpers (fixed with error checking)
# ------------------------------------------------------------
_read_lock_dep_version() {
    local dep="$1"
    local lock_file="$PWD/modulash.lock"
    if [[ -f "$lock_file" ]]; then
        jq -r ".dependencies.\"$dep\" // \"\"" "$lock_file" 2>/dev/null
    else
        echo ""
    fi
}

_write_lock_dep_version() {
    local dep="$1"
    local version="$2"
    local lock_file="$PWD/modulash.lock"
    local tmp_lock="${lock_file}.tmp"

    clish_console_core_log_debug "Writing lock: dep=$dep, version=$version, lock_file=$lock_file" >&2

    if [[ -f "$lock_file" ]]; then
        if ! jq --arg dep "$dep" --arg ver "$version" '.dependencies[$dep] = $ver' "$lock_file" > "$tmp_lock" 2>/dev/null; then
            clish_console_core_log_error "jq failed to update lock file" >&2
            return 1
        fi
    else
        echo "{\"dependencies\":{\"$dep\":\"$version\"}}" > "$tmp_lock"
    fi

    if [[ -s "$tmp_lock" ]]; then
        mv "$tmp_lock" "$lock_file"
        clish_console_core_log_debug "Lock file written successfully" >&2
        return 0
    else
        clish_console_core_log_error "Temporary lock file is empty" >&2
        rm -f "$tmp_lock"
        return 1
    fi
}

# ------------------------------------------------------------
# Install a dependency (forced version)
# ------------------------------------------------------------
module_install_dependency_forced() {
    local dep_name="$1"
    local version="$2"
    local registry_url
    registry_url="$(module_get_registry_url)"
    [[ -z "$registry_url" ]] && return 1

    module_run_scripts "pre-package-install" || true

    local api_url="$registry_url/$dep_name"
    local package_info
    if ! package_info=$(curl -s "$api_url"); then
        clish_console_core_log_error "Failed to fetch package info" >&2
        return 1
    fi
    if ! echo "$package_info" | jq -e . >/dev/null 2>&1; then
        clish_console_core_log_error "Invalid JSON" >&2
        return 1
    fi

    if ! echo "$package_info" | jq -e --arg ver "$version" '.versions[] | select(.version == $ver)' >/dev/null 2>&1; then
        clish_console_core_log_error "Version $version not found for $dep_name" >&2
        return 1
    fi

    local tarball_url
    tarball_url=$(echo "$package_info" | jq -r --arg ver "$version" '.versions[] | select(.version == $ver) | .download_url // ""')
    [[ -z "$tarball_url" || "$tarball_url" == "null" ]] && tarball_url="$registry_url/$dep_name/download/$version"

    local target_dir="$PWD/vendor/$dep_name"
    mkdir -p "$PWD/vendor"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local tarball="$tmp_dir/package.tar.gz"
    clish_console_core_log_info "Downloading $tarball_url ..." >&2
    if ! curl -L -o "$tarball" "$tarball_url"; then
        clish_console_core_log_error "Download failed" >&2
        return 1
    fi
    if ! tar -xzf "$tarball" -C "$tmp_dir"; then
        clish_console_core_log_error "Extraction failed" >&2
        return 1
    fi

    local pkg_dir
    pkg_dir="$(_find_pkg_dir "$tmp_dir")"
    [[ -z "$pkg_dir" ]] && { clish_console_core_log_error "No modulash.json" >&2; return 1; }

    mkdir -p "$target_dir"
    cp -r "$pkg_dir"/* "$target_dir"/
    # shellcheck disable=SC1091
    source "$target_dir/bootstrap.sh" 2>/dev/null || true

    if ! _write_lock_dep_version "$dep_name" "$version"; then
        clish_console_core_log_warning "Failed to write lock file, but installation succeeded" >&2
    fi

    clish_console_core_log_success "Installed $dep_name $version" >&2
    module_run_scripts "post-package-install" || true
    return 0
}

# ------------------------------------------------------------
# Install dependency with constraint (uses lock if exists)
# ------------------------------------------------------------
module_install_dependency() {
    local dep_name="$1"
    local constraint="$2"
    local locked
    locked="$(_read_lock_dep_version "$dep_name")"
    if [[ -n "$locked" ]]; then
        module_install_dependency_forced "$dep_name" "$locked"
        return $?
    fi

    local registry_url
    registry_url="$(module_get_registry_url)"
    [[ -z "$registry_url" ]] && return 1
    local api_url="$registry_url/$dep_name"
    local package_info
    if ! package_info=$(curl -s "$api_url"); then
        clish_console_core_log_error "Failed to fetch package info" >&2
        return 1
    fi
    if ! echo "$package_info" | jq -e . >/dev/null 2>&1; then
        clish_console_core_log_error "Invalid JSON" >&2
        return 1
    fi
    # shellcheck disable=SC2207
    versions=($(echo "$package_info" | jq -r '.versions[].version' | sort -V))
    [[ ${#versions[@]} -eq 0 ]] && return 1
    local matched_version
    matched_version="$(module_match_version "$constraint" "${versions[@]}")"
    [[ -z "$matched_version" ]] && return 1
    module_install_dependency_forced "$dep_name" "$matched_version"
    return $?
}

# ------------------------------------------------------------
# Helper: find package directory
# ------------------------------------------------------------
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

# ------------------------------------------------------------
# Sync (install missing)
# ------------------------------------------------------------
module_sync_modules() {
    if ! command -v jq >/dev/null 2>&1; then
        clish_console_core_log_error "jq required" >&2
        return 1
    fi
    local config_file="$PWD/modulash.json"
    [[ ! -f "$config_file" ]] && { clish_console_core_log_error "modulash.json not found" >&2; return 1; }

    module_run_scripts "pre-install" || true

    local deps_json
    deps_json="$(jq -r '.dependencies // {}' "$config_file")"
    local modules
    modules="$(jq -r 'keys[]' <<< "$deps_json")"
    if [[ -z "$modules" ]]; then
        clish_console_core_log_info "No dependencies found"
        return 0
    fi

    clish_console_core_log_info "Installing dependencies..."
    local failed=0
    for mod in $modules; do
        local constraint
        constraint="$(jq -r ".\"$mod\"" <<< "$deps_json")"
        if [[ -d "$PWD/vendor/$mod" ]]; then
            clish_console_core_log_info "$mod already installed"
            continue
        fi
        clish_console_core_log_info "Installing $mod ($constraint)"
        if ! module_install_dependency "$mod" "$constraint"; then
            clish_console_core_log_error "Failed to install $mod" >&2
            ((failed++))
        fi
    done

    module_run_scripts "post-install" || true
    if [[ $failed -gt 0 ]]; then
        clish_console_core_log_error "Some installs failed" >&2
        return 1
    fi
    clish_console_core_log_success "All dependencies installed"
    return 0
}

# ------------------------------------------------------------
# Update (with lock)
# ------------------------------------------------------------
module_update_dependency() {
    local dep_name="$1"
    local constraint="$2"
    local force="${3:-false}"
    local registry_url
    registry_url="$(module_get_registry_url)"
    [[ -z "$registry_url" ]] && { clish_console_core_log_error "No registry URL" >&2; return 1; }

    module_run_scripts "pre-package-install" || true

    local api_url="$registry_url/$dep_name"
    local package_info
    if ! package_info=$(curl -s "$api_url"); then
        clish_console_core_log_error "Failed to fetch package info" >&2
        return 1
    fi
    if ! echo "$package_info" | jq -e . >/dev/null 2>&1; then
        clish_console_core_log_error "Invalid JSON" >&2
        return 1
    fi

    # shellcheck disable=SC2207
    versions=($(echo "$package_info" | jq -r '.versions[].version' | sort -V))
    [[ ${#versions[@]} -eq 0 ]] && { clish_console_core_log_error "No versions" >&2; return 1; }

    local matched_version
    matched_version="$(module_match_version "$constraint" "${versions[@]}")"
    [[ -z "$matched_version" ]] && { clish_console_core_log_error "No matching version" >&2; return 1; }

    local locked_version
    locked_version="$(_read_lock_dep_version "$dep_name")"

    if [[ "$force" != "true" && -n "$locked_version" && "$locked_version" == "$matched_version" ]]; then
        clish_console_core_log_info "$dep_name locked at $locked_version (already up-to-date)"
        module_run_scripts "post-package-install" || true
        return 0
    fi

    # Download and install
    local target_dir="$PWD/vendor/$dep_name"
    local tarball_url
    tarball_url=$(echo "$package_info" | jq -r --arg ver "$matched_version" '.versions[] | select(.version == $ver) | .download_url // ""')
    [[ -z "$tarball_url" || "$tarball_url" == "null" ]] && tarball_url="$registry_url/$dep_name/download/$matched_version"

    rm -rf "$target_dir"
    mkdir -p "$PWD/vendor"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local tarball="$tmp_dir/package.tar.gz"
    clish_console_core_log_info "Downloading $tarball_url ..." >&2
    if ! curl -L -o "$tarball" "$tarball_url"; then
        clish_console_core_log_error "Download failed" >&2
        return 1
    fi
    if ! tar -xzf "$tarball" -C "$tmp_dir"; then
        clish_console_core_log_error "Extraction failed" >&2
        return 1
    fi

    local pkg_dir
    pkg_dir="$(_find_pkg_dir "$tmp_dir")"
    [[ -z "$pkg_dir" ]] && { clish_console_core_log_error "No modulash.json" >&2; return 1; }

    mkdir -p "$target_dir"
    cp -r "$pkg_dir"/* "$target_dir"/
    # shellcheck disable=SC1091
    source "$target_dir/bootstrap.sh" 2>/dev/null || true

    if ! _write_lock_dep_version "$dep_name" "$matched_version"; then
        clish_console_core_log_warning "Failed to write lock file, but update succeeded" >&2
    fi

    clish_console_core_log_success "Updated $dep_name to $matched_version" >&2
    module_run_scripts "post-package-install" || true
    return 0
}

module_update_all() {
    local force="${1:-false}"
    if ! command -v jq >/dev/null 2>&1; then
        clish_console_core_log_error "jq required" >&2
        return 1
    fi
    local config_file="$PWD/modulash.json"
    [[ ! -f "$config_file" ]] && { clish_console_core_log_error "modulash.json not found" >&2; return 1; }

    module_run_scripts "pre-update" || true

    local deps_json
    deps_json="$(jq -r '.dependencies // {}' "$config_file")"
    local modules
    modules="$(jq -r 'keys[]' <<< "$deps_json")"
    if [[ -z "$modules" ]]; then
        clish_console_core_log_info "No dependencies found" >&2
        return 0
    fi

    clish_console_core_log_info "Updating all dependencies..." >&2
    local failed=0
    for mod in $modules; do
        local constraint
        constraint="$(jq -r ".\"$mod\"" <<< "$deps_json")"
        if ! module_update_dependency "$mod" "$constraint" "$force"; then
            clish_console_core_log_error "Failed to update $mod" >&2
            ((failed++))
        fi
    done

    module_run_scripts "post-update" || true
    if [[ $failed -gt 0 ]]; then
        clish_console_core_log_error "Some updates failed" >&2
        return 1
    fi
    clish_console_core_log_success "All dependencies updated" >&2
    return 0
}

# ------------------------------------------------------------
# Install from Git/local path (compatibility)
# ------------------------------------------------------------
module_install_module() {
    local source_url="$1"
    local module_name="$2"
    local target_dir="$PWD/vendor/$module_name"

    if [[ -d "$target_dir" ]]; then
        clish_console_core_log_error "Module '$module_name' already exists" >&2
        return 1
    fi

    mkdir -p "$PWD/vendor"

    if [[ -d "$source_url" ]]; then
        cp -r "$source_url" "$target_dir"
    elif [[ "$source_url" =~ ^https?:// ]] || [[ "$source_url" =~ \.git$ ]]; then
        if ! command -v git >/dev/null 2>&1; then
            clish_console_core_log_error "git is required" >&2
            return 1
        fi
        git clone "$source_url" "$target_dir" || return 1
    else
        clish_console_core_log_error "Unsupported source format" >&2
        return 1
    fi

    if [[ ! -f "$target_dir/modulash.json" ]]; then
        clish_console_core_log_error "Source does not contain modulash.json" >&2
        rm -rf "$target_dir"
        return 1
    fi

    # shellcheck disable=SC1091
    source "$target_dir/bootstrap.sh" 2>/dev/null || true

    clish_console_core_log_success "Module '$module_name' installed successfully"
    return 0
}