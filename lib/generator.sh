#!/bin/bash
# Generate vendor/autoload.sh
generate_autoload() {
    local target_dir="$1"
    local sour="sour"

    cat > "$target_dir/autoload.sh" <<EOF
#!/bin/bash
# ============================================
# Module loader (compatible with bash 3.2)
# ============================================
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
${sour}ce "\$SCRIPT_DIR/modulash/modulash.sh"
EOF

    chmod +x "$target_dir/autoload.sh"
}

# Generate vendor/modulash/modulash.sh
generate_modulash() {
    local target_dir="$1"   # vendor/modulash/
    cat > "$target_dir/modulash.sh" <<'EOF'
#!/bin/bash
# Modulash Autoload - DO NOT EDIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/aliases.sh"

_modulash_resolve() {
    local spec="$1"
    # Remove quotes
    spec="${spec#\"}"; spec="${spec%\"}"
    spec="${spec#\'}"; spec="${spec%\'}"
    
    if [[ "$spec" == @* ]]; then
        # Try longest matching alias
        local best_alias=""
        local best_path=""
        local rest=""
        for i in "${!__MODULASH_ALIASES[@]}"; do
            local alias="${__MODULASH_ALIASES[$i]}"
            # If spec starts with alias (and alias is followed by '/' or end)
            if [[ "$spec" == "$alias"/* ]] || [[ "$spec" == "$alias" ]]; then
                # Choose the longest alias
                if [[ ${#alias} -gt ${#best_alias} ]]; then
                    best_alias="$alias"
                    best_path="${__MODULASH_PATHS[$i]}"
                fi
            fi
        done
        if [[ -n "$best_alias" ]]; then
            # Extract remaining part
            if [[ "$spec" == "$best_alias" ]]; then
                rest=""
            else
                # shellcheck disable=SC2295
                rest="${spec#"$best_alias"/}"
            fi
            # Ensure path ends with /
            [[ "$best_path" != */ ]] && best_path="$best_path/"
            echo "${best_path}${rest}"
            return 0
        else
            echo "Error: unknown alias (${spec%%/*})" >&2
            return 1
        fi
    else
        # Relative path, based on caller's directory
        local caller_dir
        caller_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
        echo "$caller_dir/$spec"
        return 0
    fi
}

import() {
    local file
    file="$(_modulash_resolve "$1")" || return $?
    if [[ ! -f "$file" ]]; then
        echo "Module not found: $1 -> $file" >&2
        return 1
    fi
    # shellcheck source=/dev/null
    source "$file"
}

export -f import _modulash_resolve 2>/dev/null || true
EOF
    chmod +x "$target_dir/modulash.sh"
}

# Generate vendor/modulash/aliases.sh
generate_aliases() {
    local target_dir="$1"
    cat > "$target_dir/aliases.sh" <<'EOF'
#!/bin/bash
# Modulash Aliases - DO NOT EDIT

__MODULASH_ALIASES=(
)

__MODULASH_PATHS=(
)
EOF
    chmod +x "$target_dir/aliases.sh"
}

# Generate vendor/modulash/facades.sh
generate_facades() {
    local target_dir="$1"
    cat > "$target_dir/facades.sh" <<'EOF'
#!/bin/bash
# ============================================
# Auto-generated Facades - DO NOT EDIT MANUALLY
# ============================================
#
# Edit modulash.json to customize facades, then run dump-autoload again.
# Example:
#   "facade": {
#     "info": "clish_console_log_info"      # auto-pass all arguments
#   }
# ============================================
EOF
    chmod +x "$target_dir/facades.sh"
}

# Main entry: generate all core bootstrap files
generate_core() {
    local project_dir="$1"
    local vendor_dir="$project_dir/vendor"
    local modulash_dir="$vendor_dir/modulash"

    mkdir -p "$vendor_dir" "$modulash_dir"

    generate_autoload "$vendor_dir"
    generate_modulash "$modulash_dir"
    generate_aliases "$modulash_dir"
    generate_facades "$modulash_dir"

    echo "Core bootstrap files generated in $vendor_dir"
}