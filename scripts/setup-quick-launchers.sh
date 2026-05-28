#!/bin/bash
# Create Raycast script commands and Alfred keywords for Roomy (clean + uninstall).

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

LAUNCHER_COMMAND_SPECS=(
    "clean|Roomy Clean|Deep system cleanup with Roomy|Run Roomy clean"
    "uninstall|Roomy Uninstall|Uninstall applications with Roomy|Uninstall apps via Roomy"
    "optimize|Roomy Optimize|System health checks and optimization|System health and optimization"
    "analyze|Roomy Analyze|Disk space analysis with Roomy|Disk space analysis"
    "status|Roomy Status|Live system status dashboard|Live system dashboard"
)

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
detect_roomy() {
    if [[ -n "${ROOMY_CLI_PATH:-}" && -x "${ROOMY_CLI_PATH:-}" ]]; then
        printf '%s\n' "$ROOMY_CLI_PATH"
    elif command -v roomy > /dev/null 2>&1; then
        command -v roomy
    elif command -v mo > /dev/null 2>&1; then
        command -v mo
    else
        log_error "Roomy not found. Install it first via Homebrew or ./install.sh."
        exit 1
    fi
}

shell_quote() {
    local value="$1"
    if [[ "$value" =~ [[:cntrl:]] ]]; then
        log_error "Refusing launcher value with control characters"
        return 1
    fi
    printf '%q\n' "$value"
}

applescript_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s\n' "$value"
}

xml_escape() {
    local value="$1"
    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    value="${value//\"/&quot;}"
    value="${value//\'/&apos;}"
    printf '%s\n' "$value"
}

write_generated_file_atomically() {
    local target="$1"
    local parent base temp_file

    parent="$(dirname "$target")"
    base="$(basename "$target")"
    launcher_require_regular_dir_path "$parent" "Launcher target directory" || return 1
    mkdir -p "$parent"
    temp_file="$(mktemp "$parent/.${base}.XXXXXX")" || return 1
    if ! cat > "$temp_file"; then
        rm -f "$temp_file" 2> /dev/null || true
        return 1
    fi
    if [[ -L "$target" ]]; then
        rm -f "$target" 2> /dev/null || {
            rm -f "$temp_file" 2> /dev/null || true
            return 1
        }
    elif [[ -e "$target" && ! -f "$target" ]]; then
        rm -f "$temp_file" 2> /dev/null || true
        return 1
    fi
    if ! mv -f "$temp_file" "$target"; then
        rm -f "$temp_file" 2> /dev/null || true
        return 1
    fi
}

launcher_require_regular_dir_path() {
    local dir="$1"
    local label="$2"
    local current="${dir%/}"

    if [[ -z "$current" ]]; then
        log_error "$label is empty"
        return 1
    fi
    if [[ "$current" =~ [[:cntrl:]] ]]; then
        log_error "$label contains control characters: $dir"
        return 1
    fi

    while [[ "$current" != "/" && "$current" != "." ]]; do
        if [[ -L "$current" ]]; then
            log_error "$label must not include symlinked directories: $current"
            return 1
        fi
        if [[ -e "$current" && ! -d "$current" ]]; then
            log_error "$label must not include non-directory paths: $current"
            return 1
        fi
        local parent
        parent="$(dirname "$current")"
        [[ "$parent" == "$current" ]] && break
        current="$parent"
    done
}

write_raycast_script() {
    local target="$1"
    local title="$2"
    local description="$3"
    local roomy_bin="$4"
    local subcommand="$5"

    local roomy_bin_shell
    local subcommand_shell
    local shell_command
    local shell_command_literal
    local cmd_for_applescript
    local cmd_for_applescript_literal
    roomy_bin_shell=$(shell_quote "$roomy_bin")
    subcommand_shell=$(shell_quote "$subcommand")
    shell_command="${roomy_bin_shell} ${subcommand_shell}"
    shell_command_literal=$(shell_quote "$shell_command")
    cmd_for_applescript=$(applescript_escape "$shell_command")
    cmd_for_applescript_literal=$(shell_quote "$cmd_for_applescript")

    write_generated_file_atomically "$target" << EOF
#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title ${title}
# @raycast.mode fullOutput
# @raycast.packageName Roomy
# @raycast.description ${description}

# Optional parameters:
# @raycast.icon 🐹

# ──────────────────────────────────────────────────────────
# Script execution begins below
# ──────────────────────────────────────────────────────────

set -euo pipefail

echo "🐹 Running ${title}..."
echo ""

ROOMY_BIN=${roomy_bin_shell}
ROOMY_SUBCOMMAND=${subcommand_shell}
ROOMY_COMMAND=${shell_command_literal}
ROOMY_COMMAND_APPLESCRIPT=${cmd_for_applescript_literal}

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
    if [[ -n "\${ROOMY_LAUNCHER_APP:-}" ]]; then
        echo "\${ROOMY_LAUNCHER_APP}"
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
set targetCommand to "\${ROOMY_COMMAND_APPLESCRIPT}"
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
set targetCommand to "\${ROOMY_COMMAND_APPLESCRIPT}"
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
                open -na "Alacritty" --args -e /bin/zsh -lc "\${ROOMY_COMMAND}"
                return \$?
            fi
            ;;
        Kitty)
            if has_bin "kitty"; then
                kitty --hold /bin/zsh -lc "\${ROOMY_COMMAND}"
                return \$?
            elif [[ -x "/Applications/kitty.app/Contents/MacOS/kitty" ]]; then
                "/Applications/kitty.app/Contents/MacOS/kitty" --hold /bin/zsh -lc "\${ROOMY_COMMAND}"
                return \$?
            fi
            ;;
        WezTerm)
            if has_bin "wezterm"; then
                wezterm start -- /bin/zsh -lc "\${ROOMY_COMMAND}"
                return \$?
            elif [[ -x "/Applications/WezTerm.app/Contents/MacOS/wezterm" ]]; then
                "/Applications/WezTerm.app/Contents/MacOS/wezterm" start -- /bin/zsh -lc "\${ROOMY_COMMAND}"
                return \$?
            fi
            ;;
        Ghostty)
            if launcher_available "Ghostty" && command -v open >/dev/null 2>&1; then
                open -na "Ghostty" --args -e /bin/zsh -lc "\${ROOMY_COMMAND}; exec /bin/zsh -l"
                return \$?
            fi
            ;;
        Hyper)
            if launcher_available "Hyper" && command -v open >/dev/null 2>&1; then
                open -na "Hyper" --args /bin/zsh -lc "\${ROOMY_COMMAND}"
                return \$?
            fi
            ;;
        WindTerm)
            if launcher_available "WindTerm" && command -v open >/dev/null 2>&1; then
                open -na "WindTerm" --args /bin/zsh -lc "\${ROOMY_COMMAND}"
                return \$?
            fi
            ;;
        Warp)
            if launcher_available "Warp" && command -v open >/dev/null 2>&1; then
                open -na "Warp" --args /bin/zsh -lc "\${ROOMY_COMMAND}"
                return \$?
            fi
            ;;
    esac
    return 1
}

if [[ -n "\${TERM:-}" && "\${TERM}" != "dumb" ]]; then
    "\${ROOMY_BIN}" "\${ROOMY_SUBCOMMAND}"
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
echo "    \${ROOMY_COMMAND}"
exit 1
EOF
    chmod +x "$target"
}

create_raycast_commands() {
    local roomy_bin="$1"
    local default_dir="$HOME/Library/Application Support/Raycast/script-commands"
    local dir="$default_dir"
    local entry
    local subcommand
    local title
    local description
    local alfred_subtitle

    log_step "Installing Raycast commands..."
    launcher_require_regular_dir_path "$dir" "Launcher target directory" || return 1
    mkdir -p "$dir"
    for entry in "${LAUNCHER_COMMAND_SPECS[@]}"; do
        IFS="|" read -r subcommand title description alfred_subtitle <<< "$entry"
        write_raycast_script "$dir/roomy-${subcommand}.sh" "$title" "$description" "$roomy_bin" "$subcommand"
    done
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
    local roomy_bin="$1"
    local prefs_dir="${ALFRED_PREFS_DIR:-$HOME/Library/Application Support/Alfred/Alfred.alfredpreferences}"
    local workflows_dir="$prefs_dir/workflows"
    local entry
    local subcommand
    local title
    local subtitle
    local bundle
    local keyword
    local command

    if [[ ! -d "$workflows_dir" ]]; then
        return
    fi

    log_step "Installing Alfred workflows..."
    launcher_require_regular_dir_path "$workflows_dir" "Launcher target directory" || return 1
    for entry in "${LAUNCHER_COMMAND_SPECS[@]}"; do
        IFS="|" read -r subcommand title _ subtitle <<< "$entry"
        bundle="fun.tw93.roomy.${subcommand}"
        keyword="${subcommand}"
        local roomy_bin_shell
        local subcommand_shell
        local command_xml
        roomy_bin_shell=$(shell_quote "$roomy_bin")
        subcommand_shell=$(shell_quote "$subcommand")
        command="${roomy_bin_shell} ${subcommand_shell}"
        command_xml=$(xml_escape "$command")
        local workflow_uid="user.workflow.$(uuid | LC_ALL=C tr '[:upper:]' '[:lower:]')"
        local input_uid
        local action_uid
        input_uid="$(uuid)"
        action_uid="$(uuid)"
        local dir="$workflows_dir/$workflow_uid"
        launcher_require_regular_dir_path "$dir" "Launcher target directory" || return 1
        mkdir -p "$dir"

        write_generated_file_atomically "$dir/info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>bundleid</key>
    <string>${bundle}</string>
    <key>createdby</key>
    <string>Roomy</string>
    <key>name</key>
    <string>${title}</string>
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
                <string>${title}</string>
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
${command_xml}
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
        log_success "Workflow ready: ${title}, keyword: ${keyword}"
    done

    log_step "Open Alfred preferences → Workflows if you need to adjust keywords."
}

main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Roomy Quick Launchers"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local roomy_bin
    roomy_bin="$(detect_roomy)"
    log_step "Detected Roomy binary at: ${roomy_bin}"

    create_raycast_commands "$roomy_bin"
    create_alfred_workflow "$roomy_bin"

    echo ""
    log_success "Done! Raycast and Alfred are ready with 5 commands:"
    local entry
    local subcommand
    local title
    for entry in "${LAUNCHER_COMMAND_SPECS[@]}"; do
        IFS="|" read -r subcommand title _ _ <<< "$entry"
        echo "  • Raycast: ${title} | Alfred keyword: ${subcommand}"
    done
    echo ""
}

main "$@"
