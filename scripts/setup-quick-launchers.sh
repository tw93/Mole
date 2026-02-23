#!/bin/bash
# Create Raycast script commands and Alfred keywords for Mole (clean + uninstall).

set -euo pipefail

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ICON_STEP="➜"
ICON_SUCCESS="✓"
ICON_WARN="!"
ICON_ERR="✗"

log_step() { echo -e "${BLUE}${ICON_STEP}${NC} $1"; }
log_success() { echo -e "${GREEN}${ICON_SUCCESS}${NC} $1"; }
log_warn() { echo -e "${YELLOW}${ICON_WARN}${NC} $1"; }
log_error() { echo -e "${RED}${ICON_ERR}${NC} $1"; }
log_header() { echo -e "\n${BLUE}==== $1 ====${NC}\n"; }
is_interactive() { [[ -t 1 && -r /dev/tty ]]; }
prompt_enter() {
    local prompt="$1"
    if is_interactive; then
        read -r -p "$prompt" < /dev/tty || true
    else
        echo "$prompt"
    fi
}
detect_mo() {
    if command -v mo > /dev/null 2>&1; then
        command -v mo
    elif command -v mole > /dev/null 2>&1; then
        command -v mole
    else
        log_error "Mole not found. Install it first via Homebrew or ./install.sh."
        exit 1
    fi
}

write_raycast_script() {
    local target="$1"
    local title="$2"
    local description="$3"
    local mo_bin="$4"
    local subcommand="$5"

    local cmd_for_applescript="${mo_bin//\\/\\\\}"
    cmd_for_applescript="${cmd_for_applescript//\"/\\\"}"

    cat > "$target" << EOF
#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title ${title}
# @raycast.mode fullOutput
# @raycast.packageName Mole
# @raycast.description ${description}

# Optional parameters:
# @raycast.icon 🐹

# ──────────────────────────────────────────────────────────
# Script execution begins below
# ──────────────────────────────────────────────────────────

set -euo pipefail

echo "🐹 Running ${title}..."
echo ""

MO_BIN="${mo_bin}"
MO_SUBCOMMAND="${subcommand}"
MO_BIN_ESCAPED="${cmd_for_applescript}"

has_app() {
    local name="\$1"
    [[ -d "/Applications/\${name}.app" || -d "\$HOME/Applications/\${name}.app" ]]
}

has_bin() {
    command -v "\$1" >/dev/null 2>&1
}

launcher_available() {
    local app="\$1"
    case "\$app" in
        Terminal) return 0 ;;
        iTerm|iTerm2) has_app "iTerm" || has_app "iTerm2" ;;
        Alacritty) has_app "Alacritty" ;;
        Kitty) has_bin "kitty" || has_app "kitty" ;;
        WezTerm) has_bin "wezterm" || has_app "WezTerm" ;;
        Ghostty) has_bin "ghostty" || has_app "Ghostty" ;;
        Hyper) has_app "Hyper" ;;
        WindTerm) has_app "WindTerm" ;;
        Warp) has_app "Warp" ;;
        *)
            return 1 ;;
    esac
}

detect_launcher_app() {
    if [[ -n "\${MO_LAUNCHER_APP:-}" ]]; then
        echo "\${MO_LAUNCHER_APP}"
        return
    fi
    local candidates=(Warp Ghostty Alacritty Kitty WezTerm WindTerm Hyper iTerm2 iTerm Terminal)
    local app
    for app in "\${candidates[@]}"; do
        if launcher_available "\$app"; then
            echo "\$app"
            return
        fi
    done
    echo "Terminal"
}

launch_with_app() {
    local app="\$1"
    case "\$app" in
        Terminal)
            if command -v osascript >/dev/null 2>&1; then
                osascript <<APPLESCRIPT
set targetCommand to "\${MO_BIN_ESCAPED} \${MO_SUBCOMMAND}"
tell application "Terminal"
    activate
    do script targetCommand
end tell
APPLESCRIPT
                return 0
            fi
            ;;
        iTerm|iTerm2)
            if command -v osascript >/dev/null 2>&1; then
                osascript <<APPLESCRIPT
set targetCommand to "\${MO_BIN_ESCAPED} \${MO_SUBCOMMAND}"
tell application "iTerm2"
    activate
    try
        tell current window
            tell current session
                write text targetCommand
            end tell
        end tell
    on error
        create window with default profile
        tell current window
            tell current session
                write text targetCommand
            end tell
        end tell
    end try
end tell
APPLESCRIPT
                return 0
            fi
            ;;
        Alacritty)
            if launcher_available "Alacritty" && command -v open >/dev/null 2>&1; then
                open -na "Alacritty" --args -e /bin/zsh -lc "\"\${MO_BIN}\" \${MO_SUBCOMMAND}"
                return \$?
            fi
            ;;
        Kitty)
            if has_bin "kitty"; then
                kitty --hold /bin/zsh -lc "\"\${MO_BIN}\" \${MO_SUBCOMMAND}"
                return \$?
            elif [[ -x "/Applications/kitty.app/Contents/MacOS/kitty" ]]; then
                "/Applications/kitty.app/Contents/MacOS/kitty" --hold /bin/zsh -lc "\"\${MO_BIN}\" \${MO_SUBCOMMAND}"
                return \$?
            fi
            ;;
        WezTerm)
            if has_bin "wezterm"; then
                wezterm start -- /bin/zsh -lc "\"\${MO_BIN}\" \${MO_SUBCOMMAND}"
                return \$?
            elif [[ -x "/Applications/WezTerm.app/Contents/MacOS/wezterm" ]]; then
                "/Applications/WezTerm.app/Contents/MacOS/wezterm" start -- /bin/zsh -lc "\"\${MO_BIN}\" \${MO_SUBCOMMAND}"
                return \$?
            fi
            ;;
        Ghostty)
            if launcher_available "Ghostty" && command -v open >/dev/null 2>&1; then
                open -na "Ghostty" --args -e /bin/zsh -lc "\"\${MO_BIN}\" \${MO_SUBCOMMAND}; exec /bin/zsh -l"
                return \$?
            fi
            ;;
        Hyper)
            if launcher_available "Hyper" && command -v open >/dev/null 2>&1; then
                open -na "Hyper" --args /bin/zsh -lc "\"\${MO_BIN}\" \${MO_SUBCOMMAND}"
                return \$?
            fi
            ;;
        WindTerm)
            if launcher_available "WindTerm" && command -v open >/dev/null 2>&1; then
                open -na "WindTerm" --args /bin/zsh -lc "\"\${MO_BIN}\" \${MO_SUBCOMMAND}"
                return \$?
            fi
            ;;
        Warp)
            if launcher_available "Warp" && command -v open >/dev/null 2>&1; then
                open -na "Warp" --args /bin/zsh -lc "\"\${MO_BIN}\" \${MO_SUBCOMMAND}"
                return \$?
            fi
            ;;
    esac
    return 1
}

if [[ -n "\${TERM:-}" && "\${TERM}" != "dumb" ]]; then
    "\${MO_BIN}" \${MO_SUBCOMMAND}
    exit \$?
fi

TERM_APP="\$(detect_launcher_app)"

if launch_with_app "\$TERM_APP"; then
    exit 0
fi

if [[ "\$TERM_APP" != "Terminal" ]]; then
    echo "Could not control \$TERM_APP, falling back to Terminal..."
    if launch_with_app "Terminal"; then
        exit 0
    fi
fi

echo "TERM environment variable not set and no launcher succeeded."
echo "Run this manually:"
echo "    \"\${MO_BIN}\" \${MO_SUBCOMMAND}"
exit 1
EOF
    chmod +x "$target"
}

create_raycast_commands() {
    local mo_bin="$1"
    local default_dir="$HOME/Library/Application Support/Raycast/script-commands"
    local dir="$default_dir"

    log_step "Installing Raycast commands..."
    mkdir -p "$dir"
    write_raycast_script "$dir/mole-clean.sh" "Mole Clean" "Deep system cleanup with Mole" "$mo_bin" "clean"
    write_raycast_script "$dir/mole-uninstall.sh" "Mole Uninstall" "Uninstall applications with Mole" "$mo_bin" "uninstall"
    write_raycast_script "$dir/mole-optimize.sh" "Mole Optimize" "System health checks and optimization" "$mo_bin" "optimize"
    write_raycast_script "$dir/mole-analyze.sh" "Mole Analyze" "Disk space analysis with Mole" "$mo_bin" "analyze"
    write_raycast_script "$dir/mole-status.sh" "Mole Status" "Live system status dashboard" "$mo_bin" "status"
    log_success "Scripts ready in: $dir"

    log_header "Raycast Configuration"
    log_step "Open Raycast → Settings → Extensions → Script Commands."
    echo "1. Click \"+\" → Add Script Directory."
    echo "2. Choose: $dir"
    echo "3. Click \"Reload Script Directories\"."

    if is_interactive; then
        log_header "Finalizing Setup"
        log_warn "Please complete the Raycast steps above before continuing."
        prompt_enter "Press [Enter] to continue..."
        log_success "Raycast setup complete!"
    else
        log_warn "Non-interactive mode; skip Raycast reload. Please run 'Reload Script Directories' in Raycast."
    fi
}

uuid() {
    if command -v uuidgen > /dev/null 2>&1; then
        uuidgen
    else
        # Fallback pseudo UUID in format: 8-4-4-4-12
        local hex=$(openssl rand -hex 16)
        echo "${hex:0:8}-${hex:8:4}-${hex:12:4}-${hex:16:4}-${hex:20:12}"
    fi
}

create_alfred_workflow() {
    local mo_bin="$1"
    local prefs_dir="${ALFRED_PREFS_DIR:-$HOME/Library/Application Support/Alfred/Alfred.alfredpreferences}"
    local workflows_dir="$prefs_dir/workflows"

    if [[ ! -d "$workflows_dir" ]]; then
        return
    fi

    log_step "Installing Alfred workflows..."
    local workflows=(
        "fun.tw93.mole.clean|Mole clean|clean|Run Mole clean|\"${mo_bin}\" clean"
        "fun.tw93.mole.uninstall|Mole uninstall|uninstall|Uninstall apps via Mole|\"${mo_bin}\" uninstall"
        "fun.tw93.mole.optimize|Mole optimize|optimize|System health & optimization|\"${mo_bin}\" optimize"
        "fun.tw93.mole.analyze|Mole analyze|analyze|Disk space analysis|\"${mo_bin}\" analyze"
        "fun.tw93.mole.status|Mole status|status|Live system dashboard|\"${mo_bin}\" status"
    )

    for entry in "${workflows[@]}"; do
        IFS="|" read -r bundle name keyword subtitle command <<< "$entry"
        local workflow_uid="user.workflow.$(uuid | LC_ALL=C tr '[:upper:]' '[:lower:]')"
        local input_uid
        local action_uid
        input_uid="$(uuid)"
        action_uid="$(uuid)"
        local dir="$workflows_dir/$workflow_uid"
        mkdir -p "$dir"

        cat > "$dir/info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>bundleid</key>
    <string>${bundle}</string>
    <key>createdby</key>
    <string>Mole</string>
    <key>name</key>
    <string>${name}</string>
    <key>objects</key>
    <array>
        <dict>
            <key>config</key>
            <dict>
                <key>argumenttype</key>
                <integer>2</integer>
                <key>keyword</key>
                <string>${keyword}</string>
                <key>subtext</key>
                <string>${subtitle}</string>
                <key>text</key>
                <string>${name}</string>
                <key>withspace</key>
                <true/>
            </dict>
            <key>type</key>
            <string>alfred.workflow.input.keyword</string>
            <key>uid</key>
            <string>${input_uid}</string>
            <key>version</key>
            <integer>1</integer>
        </dict>
        <dict>
            <key>config</key>
            <dict>
                <key>concurrently</key>
                <true/>
                <key>escaping</key>
                <integer>102</integer>
                <key>script</key>
                <string>#!/bin/bash
PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
${command}
</string>
                <key>scriptargtype</key>
                <integer>1</integer>
                <key>scriptfile</key>
                <string></string>
                <key>type</key>
                <integer>0</integer>
            </dict>
            <key>type</key>
            <string>alfred.workflow.action.script</string>
            <key>uid</key>
            <string>${action_uid}</string>
            <key>version</key>
            <integer>2</integer>
        </dict>
    </array>
    <key>connections</key>
    <dict>
        <key>${input_uid}</key>
        <array>
            <dict>
                <key>destinationuid</key>
                <string>${action_uid}</string>
                <key>modifiers</key>
                <integer>0</integer>
                <key>modifiersubtext</key>
                <string></string>
            </dict>
        </array>
    </dict>
    <key>uid</key>
    <string>${workflow_uid}</string>
    <key>version</key>
    <integer>1</integer>
</dict>
</plist>
EOF
        log_success "Workflow ready: ${name}, keyword: ${keyword}"
    done

    log_step "Open Alfred preferences → Workflows if you need to adjust keywords."
}

main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Mole Quick Launchers"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local mo_bin
    mo_bin="$(detect_mo)"
    log_step "Detected Mole binary at: ${mo_bin}"

    create_raycast_commands "$mo_bin"
    create_alfred_workflow "$mo_bin"

    echo ""
    log_success "Done! Raycast and Alfred are ready with 5 commands:"
    echo "  • Mole Clean, Deep system cleanup"
    echo "  • Mole Uninstall, Remove applications"
    echo "  • Mole Optimize, System health & tuning"
    echo "  • Mole Analyze, Disk space explorer"
    echo "  • Mole Status, Live system monitor"
    echo ""
}

main "$@"
