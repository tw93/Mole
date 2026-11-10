#!/usr/bin/env bats

load helpers

purge_run() {
    run bash -c 'SCRIPT_DIR="$MOLE_TEST_REPO"; source "$MOLE_TEST_REPO/bin/purge.sh"
'"$1"
}

# A node project whose node_modules npm can put back: package.json, a
# lockfile, npm's own install record, all older than a week.
make_node_project() {
    local p="$1"
    mkdir -p "$p/node_modules/left-pad"
    echo '{}' > "$p/package.json"
    echo '{}' > "$p/package-lock.json"
    echo '{}' > "$p/node_modules/.package-lock.json"
    head -c 65536 /dev/zero > "$p/node_modules/left-pad/index.js"
    age "$p"
}

age() { find "$1" -exec touch -h -d '30 days ago' {} +; }

@test "a folder needs the project file of the tool that made it" {
    p="$HOME/www/app"
    make_node_project "$p"
    git -C "$p" init -q
    git -C "$HOME/www/cs" init -q 2> /dev/null || { mkdir -p "$HOME/www/cs"; git -C "$HOME/www/cs" init -q; }
    mkdir -p "$p/build" "$p/vendor" "$p/bin" "$p/.venv" "$HOME/www/notes/build" "$HOME/www/cs/bin/Debug" "$HOME/www/py/.venv"
    echo x > "$HOME/www/cs/app.csproj"
    echo x > "$HOME/www/py/requirements.txt"
    touch "$HOME/www/py/.venv/pyvenv.cfg"
    purge_run 'for d in app/node_modules app/build app/vendor app/bin app/.venv notes/build cs/bin py/.venv; do
        r=$(mole_purge_refusal "$HOME/www/$d"); echo "$d=$r"; done'
    [[ "$output" == *"app/node_modules=ok"* ]]
    [[ "$output" == *"app/build=ok"* ]]
    [[ "$output" == *"app/vendor=no project file beside it"* ]]
    [[ "$output" == *"app/bin=no project file beside it"* ]]
    [[ "$output" == *"app/.venv=no project file beside it"* ]]
    [[ "$output" == *"notes/build=no project file beside it"* ]]
    [[ "$output" == *"cs/bin=ok"* ]]
    [[ "$output" == *"py/.venv=ok"* ]]
}

@test "a .venv without pyvenv.cfg and a bin without Debug or Release are not build output" {
    mkdir -p "$HOME/www/py/.venv" "$HOME/www/cs/bin/scripts"
    echo x > "$HOME/www/py/pyproject.toml"
    echo x > "$HOME/www/cs/app.csproj"
    git -C "$HOME/www/cs" init -q
    purge_run 'echo "venv=$(mole_purge_refusal "$HOME/www/py/.venv")"; echo "bin=$(mole_purge_refusal "$HOME/www/cs/bin")"'
    [[ "$output" == *"venv=not build output"* ]]
    [[ "$output" == *"bin=not build output"* ]]
}

@test "authored content keeps a folder: a repository, keypairs, files git tracks" {
    for n in a b c; do mkdir -p "$HOME/www/$n/target/x"; echo x > "$HOME/www/$n/Cargo.toml"; done
    mkdir -p "$HOME/www/a/target/x/.git"
    echo '[]' > "$HOME/www/b/target/deploy-keypair.json"
    git -C "$HOME/www/c" init -q
    echo src > "$HOME/www/c/target/x/main.rs"
    git -C "$HOME/www/c" add -f target/x/main.rs
    mkdir -p "$HOME/www/d/target/debug"
    echo x > "$HOME/www/d/Cargo.toml"
    git -C "$HOME/www/d" init -q
    echo '/target' > "$HOME/www/d/.gitignore"
    # A worktree whose main repository moved: git cannot answer, so it is kept.
    mkdir -p "$HOME/www/e/build/out"
    echo '{}' > "$HOME/www/e/package.json"
    echo "gitdir: $TEST_ROOT/gone/.git/worktrees/e" > "$HOME/www/e/.git"
    purge_run 'for n in a b c d; do r=$(mole_purge_refusal "$HOME/www/$n/target"); echo "$n=$r"; done
        echo "e=$(mole_purge_refusal "$HOME/www/e/build")"'
    [[ "$output" == *"e=could not be checked in time"* ]]
    [[ "$output" == *"a=holds tracked or authored files"* ]]
    [[ "$output" == *"b=holds tracked or authored files"* ]]
    [[ "$output" == *"c=holds tracked or authored files"* ]]
    [[ "$output" == *"d=ok"* ]]
}

@test "node_modules stays without a lockfile record or when changed after install" {
    make_node_project "$HOME/www/ok"
    make_node_project "$HOME/www/nolock"
    rm "$HOME/www/nolock/package-lock.json"
    make_node_project "$HOME/www/patched"
    echo patched > "$HOME/www/patched/node_modules/left-pad/index.js"
    purge_run 'for n in ok nolock patched; do r=$(mole_purge_refusal "$HOME/www/$n/node_modules"); echo "$n=$r"; done'
    [[ "$output" == *"ok=ok"* ]]
    [[ "$output" == *"nolock=no lockfile record, or changed after install"* ]]
    [[ "$output" == *"patched=no lockfile record, or changed after install"* ]]
}

@test "activity: one file changed this week makes the folder recent" {
    make_node_project "$HOME/www/old"
    make_node_project "$HOME/www/new"
    touch "$HOME/www/new/node_modules/left-pad/index.js"
    purge_run 'echo "old=$(mole_purge_activity "$HOME/www/old/node_modules")"; echo "new=$(mole_purge_activity "$HOME/www/new/node_modules")"'
    [[ "$output" == *"old=old"* ]]
    [[ "$output" == *"new=recent"* ]]
}

@test "a process working in the project marks it busy; Mole's own shells do not" {
    make_node_project "$HOME/www/busy"
    make_node_project "$HOME/www/idle"
    (cd "$HOME/www/busy" && exec sleep 30) &
    OWNER_PID=$!
    sleep 0.2
    mkdir -p "$HOME/www/mono/packages/web"
    echo '{}' > "$HOME/www/mono/package.json"
    make_node_project "$HOME/www/mono/packages/web"
    (cd "$HOME/www" && exec sleep 30) &
    SHELF_PID=$!
    (cd "$HOME/www/mono" && exec sleep 30) &
    MONO_PID=$!
    make_node_project "$HOME/www/py"
    (cd / && VIRTUAL_ENV="$HOME/www/py/.venv" exec sleep 30) &
    VENV_PID=$!
    sleep 0.2
    purge_run 'cd "$HOME/www/idle"; mole_purge_proc_snapshot
        for n in busy idle mono/packages/web py; do mole_purge_project_busy "$HOME/www/$n" "$HOME/www" && echo "$n=busy" || echo "$n=free"; done
        mole_purge_project_busy "$HOME/www/mono/packages/web" "$HOME/www/mono" && echo "mono-as-root=busy"
        MOLE_PURGE_PROC_OK=false; mole_purge_project_busy "$HOME/www/idle" "$HOME/www" && echo "noproc=busy"'
    kill "$MONO_PID" "$VENV_PID" "$SHELF_PID" 2> /dev/null || true
    [[ "$output" == *"mono-as-root=busy"* ]]
    [[ "$output" == *"busy=busy"* ]]
    [[ "$output" == *"idle=free"* ]]
    [[ "$output" == *"mono/packages/web=busy"* ]]
    [[ "$output" == *"py=busy"* ]]
    [[ "$output" == *"noproc=busy"* ]]
}

@test "a dev server in one workspace package keeps the other packages' node_modules" {
    mkdir -p "$HOME/www/ws/apps/docs" "$HOME/www/ws/packages/ui"
    echo 'packages: [apps/*, packages/*]' > "$HOME/www/ws/pnpm-workspace.yaml"
    make_node_project "$HOME/www/ws/packages/ui"
    make_node_project "$HOME/www/plain/a"
    mkdir -p "$HOME/www/plain/b"
    echo '{}' > "$HOME/www/plain/package.json"
    (cd "$HOME/www/ws/apps/docs" && exec sleep 30) &
    DOCS_PID=$!
    (cd "$HOME/www/plain/b" && exec sleep 30) &
    B_PID=$!
    sleep 0.2
    purge_run 'mole_purge_proc_snapshot
        mole_purge_project_busy "$HOME/www/ws/packages/ui" "$HOME/www" && echo ui=busy || echo ui=free
        mole_purge_project_busy "$HOME/www/plain/a" "$HOME/www" && echo a=busy || echo a=free'
    kill "$DOCS_PID" "$B_PID" 2> /dev/null || true
    [[ "$output" == *"ui=busy"* ]]
    [[ "$output" == *"a=free"* ]]
}

@test "roots: config paths with ~, never / or the home itself, nested roots folded, unreadable file refused" {
    mkdir -p "$HOME/www/inner" "$HOME/work" "$HOME/.config/mole"
    printf '%s\n' '# comment' '~/www' '~/www/inner' "$HOME/work" '/' '~' '~/missing' "$(dirname "$HOME")" > "$HOME/.config/mole/purge_paths"
    purge_run 'mole_purge_load_roots; printf "root=%s\n" "${MOLE_PURGE_ROOTS[@]}"; echo "config=$MOLE_PURGE_ROOTS_FROM_CONFIG"'
    [ "$status" -eq 0 ]
    [ "$(grep -c '^root=' <<< "$output")" -eq 2 ]
    [[ "$output" == *"root=$HOME/www"* ]]
    [[ "$output" == *"root=$HOME/work"* ]]
    [[ "$output" == *"config=true"* ]]
    chmod 000 "$HOME/.config/mole/purge_paths"
    purge_run 'rc=0; mole_purge_load_roots || rc=$?; echo "rc=$rc"'
    [[ "$output" == *"rc=2"* ]]
}

@test "roots: discovery finds project folders in home and skips media, GOPATH and dot folders" {
    mkdir -p "$HOME/stuff/app" "$HOME/go/pkg/mod/x" "$HOME/Music/band" "$HOME/.hidden/app"
    echo '{}' > "$HOME/stuff/app/package.json"
    echo x > "$HOME/go/pkg/mod/x/go.mod"
    echo '{}' > "$HOME/Music/band/package.json"
    echo '{}' > "$HOME/.hidden/app/package.json"
    purge_run 'mole_purge_load_roots; printf "root=%s\n" "${MOLE_PURGE_ROOTS[@]}"'
    [[ "$output" == *"root=$HOME/stuff"* ]]
    [[ "$output" != *"root=$HOME/go"* ]]
    [[ "$output" != *"root=$HOME/Music"* ]]
    [[ "$output" != *".hidden"* ]]
}

@test "walk: stops at matched folders and skips dot folders that are not targets" {
    make_node_project "$HOME/www/app"
    mkdir -p "$HOME/www/app/node_modules/pkg/node_modules" "$HOME/www/app/.github/build" "$HOME/www/app/.next"
    purge_run 'mole_purge_walk "$HOME/www" | sort'
    [[ "$output" == *"$HOME/www/app/node_modules"* ]]
    [[ "$output" == *"$HOME/www/app/.next"* ]]
    [[ "$output" != *"pkg/node_modules"* ]]
    [[ "$output" != *".github"* ]]
}

@test "a hand-named folder outside a git repository is never offered" {
    mkdir -p "$HOME/tools/cli/dist" "$HOME/tools/cli/node_modules"
    echo '{}' > "$HOME/tools/cli/package.json"
    # Dotfiles kept as a repository at the home itself do not count.
    git -C "$HOME" init -q
    purge_run 'echo "dist=$(mole_purge_refusal "$HOME/tools/cli/dist")"'
    [[ "$output" == *"dist=not in a git repository"* ]]
}

@test "the removal sink checks identity, root, links and ownership again" {
    make_node_project "$HOME/www/app"
    root="$HOME/www"
    mkdir -p "$TEST_ROOT/elsewhere/app"
    make_node_project "$TEST_ROOT/elsewhere/app"
    ln -s "$TEST_ROOT/elsewhere" "$HOME/www/link"
    purge_run 'p="$HOME/www/app/node_modules"; id=$(mole_purge_identity "$p")
        mole_artifact_path_ok "$p" "$HOME/www" "1:1" && echo wrong-id=ok || echo wrong-id=refused
        mole_artifact_path_ok "$p" "$HOME/other" "$id" && echo wrong-root=ok || echo wrong-root=refused
        l="$HOME/www/link/app/node_modules"; lid=$(mole_purge_identity "$l")
        mole_artifact_path_ok "$l" "$HOME/www" "$lid" && echo link=ok || echo link=refused
        mole_artifact_path_ok "$p" "$HOME/www" "$id" && echo right=ok || echo right=refused'
    [[ "$output" == *"wrong-id=refused"* ]]
    [[ "$output" == *"wrong-root=refused"* ]]
    [[ "$output" == *"link=refused"* ]]
    [[ "$output" == *"right=ok"* ]]
    [ -d "$TEST_ROOT/elsewhere/app/node_modules" ]
}

@test "mo purge: outside a terminal it needs --yes or --dry-run" {
    make_node_project "$HOME/www/app"
    run bash "$REPO/mole" purge < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs a terminal"* ]]
    [ -d "$HOME/www/app/node_modules" ]
}

@test "mo purge --dry-run lists what would go and keeps everything" {
    make_node_project "$HOME/www/old"
    make_node_project "$HOME/www/new"
    touch "$HOME/www/new/node_modules"
    run bash "$REPO/mole" purge --dry-run < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"~/www/old"*"node_modules"*"dry"* ]]
    [[ "$output" == *"~/www/new"*"changed this week, kept unless picked"* ]]
    [[ "$output" == *"Would free:"*"1 folder"* ]]
    [ -d "$HOME/www/old/node_modules" ]
    [ ! -s "$HOME/.local/state/mole/operations.log" ]
}

@test "a refusal probe that prints nothing keeps the folder" {
    make_node_project "$HOME/www/app"
    purge_run 'mole_purge_refusal() { return 0; }; P_PATH=("$HOME/www/app/node_modules"); P_ROOT=("$HOME/www"); P_STATE=(old)
        mole_purge_proc_snapshot; r=$(recheck 0) || echo "kept=$r"'
    [[ "$output" == *"kept=could not be checked"* ]]
}

@test "mo purge --yes removes old build output, keeps recent and busy projects, logs each" {
    make_node_project "$HOME/www/old"
    make_node_project "$HOME/www/new"
    make_node_project "$HOME/www/busy"
    touch "$HOME/www/new/node_modules/left-pad/index.js" "$HOME/www/new/node_modules/.package-lock.json"
    (cd "$HOME/www/busy" && exec sleep 30) &
    OWNER_PID=$!
    sleep 0.2
    run bash "$REPO/mole" purge --yes < /dev/null
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/www/old/node_modules" ]
    [ -f "$HOME/www/old/package.json" ]
    [ -d "$HOME/www/new/node_modules" ]
    [ -d "$HOME/www/busy/node_modules" ]
    [[ "$output" == *"Purge complete"* ]]
    grep -q "\[purge run=[0-9-]*\] REMOVED $HOME/www/old/node_modules (" "$HOME/.local/state/mole/operations.log"
    run bash "$REPO/mole" history --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"command": "purge"'*'"removed": 1'* ]]
}

@test "mo purge --yes: a folder that changed after the scan is kept" {
    make_node_project "$HOME/www/app"
    purge_run 'DRY_RUN=false; ASSUME_YES=true; scan; P_STATE[0]=old
        touch "$HOME/www/app/node_modules/.package-lock.json" "$HOME/www/app/node_modules/left-pad/index.js"
        mole_purge_proc_snapshot; r=$(recheck 0) || echo "kept=$r"'
    [[ "$output" == *"kept=changed since the scan"* ]]
    [ -d "$HOME/www/app/node_modules" ]
}

@test "a process elsewhere holding one file of a project keeps the project busy" {
    mkdir -p "$HOME/www/held/dist" "$HOME/www/idle/dist" "$HOME/elsewhere"
    : > "$HOME/www/held/dist/server.log"
    (cd "$HOME/elsewhere" && exec 3< "$HOME/www/held/dist/server.log" && exec sleep 30) &
    local holder=$!
    sleep 0.2
    purge_run 'mole_purge_proc_snapshot
        for n in held idle; do mole_purge_project_busy "$HOME/www/$n" "$HOME/www" && echo "busy $n"; done; true'
    kill "$holder" 2> /dev/null || true
    wait "$holder" 2> /dev/null || true
    [ "$status" -eq 0 ]
    [[ "$output" == *"busy held"* ]]
    [[ "$output" != *"busy idle"* ]]
}

@test "a library mapped from a project keeps the project busy after its handle closed" {
    command -v python3 > /dev/null 2>&1 || skip "python3 not available"
    mkdir -p "$HOME/www/mapped/target" "$HOME/www/idle/target" "$HOME/elsewhere"
    head -c 4096 /dev/zero > "$HOME/www/mapped/target/libheld.so"
    # The executable sits outside the project, the path is in no argument and the
    # file handle is closed, so only the mapping shows it.
    # Python's own mmap keeps a duplicate descriptor, so this calls libc directly.
    (cd "$HOME/elsewhere" && HELD_LIBRARY="$HOME/www/mapped/target/libheld.so" exec python3 -c 'import ctypes,os,time
libc=ctypes.CDLL(None); libc.mmap.restype=ctypes.c_void_p
libc.mmap.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_long]
fd=os.open(os.environ["HELD_LIBRARY"],os.O_RDONLY); libc.mmap(None,4096,1,2,fd,0); os.close(fd); time.sleep(30)') &
    local holder=$!
    sleep 0.5
    grep -q libheld "/proc/$holder/maps"
    run bash -c "find /proc/$holder/fd -mindepth 1 -maxdepth 1 -type l -printf '%l\n' | grep libheld"
    [ "$status" -ne 0 ]
    purge_run 'mole_purge_proc_snapshot; echo "ok=$MOLE_PURGE_PROC_OK"
        for n in mapped idle; do mole_purge_project_busy "$HOME/www/$n" "$HOME/www" && echo "busy $n"; done; true'
    kill "$holder" 2> /dev/null || true
    wait "$holder" 2> /dev/null || true
    [[ "$output" == *"ok=true"* ]]
    [[ "$output" == *"busy mapped"* ]]
    [[ "$output" != *"busy idle"* ]]
}

@test "a process that vanished does not lose what the others hold" {
    mkdir -p "$HOME/www/held/dist" "$HOME/elsewhere"
    : > "$HOME/www/held/dist/server.log"
    (cd "$HOME/elsewhere" && exec 3< "$HOME/www/held/dist/server.log" && exec sleep 30) &
    local holder=$!
    sleep 0.2
    purge_run 'mole_purge_other_pids() { printf "%s\n" 4194000 "'"$holder"'" done; }
        mole_purge_proc_snapshot; echo "rc=$? ok=$MOLE_PURGE_PROC_OK"
        mole_purge_project_busy "$HOME/www/held" "$HOME/www" && echo busy; true'
    kill "$holder" 2> /dev/null || true
    wait "$holder" 2> /dev/null || true
    [[ "$output" == *"rc=0 ok=true"* ]]
    [[ "$output" == *busy* ]]
}

@test "an unfinished holder scan fails the snapshot, so every project reads busy" {
    mkdir -p "$HOME/www/idle/dist"
    for tool in xargs timeout sort find cat; do
        printf '#!/bin/sh\nexit 127\n' > "$TEST_ROOT/bin/$tool"
        chmod +x "$TEST_ROOT/bin/$tool"
        purge_run 'set +e; mole_purge_proc_snapshot; echo "rc=$? ok=$MOLE_PURGE_PROC_OK"
            mole_purge_project_busy "$HOME/www/idle" "$HOME/www" && echo busy'
        [[ "$output" == *"rc=2 ok=false"* ]] || { echo "$tool: $output"; return 1; }
        [[ "$output" == *busy* ]]
        rm -f "$TEST_ROOT/bin/$tool"
    done
}

@test "a process whose owner cannot be read, or a cut pid list, fails the snapshot" {
    local proc="$TEST_ROOT/proc"
    mkdir -p "$proc/self" "$proc/4100"
    printf 'Name:\tsecret\nUid:\t%s\t%s\n' "$(id -u)" "$(id -u)" > "$proc/4100/status"
    chmod 000 "$proc/4100/status"
    purge_run '_MOLE_PROC_ROOT="'"$proc"'"; set +e
        mole_purge_pid_mine "'"$proc"'/4100"; echo "unreadable=$?"
        mole_purge_pid_mine "'"$proc"'/4199"; echo "gone=$?"
        mole_purge_proc_snapshot; echo "rc=$? ok=$MOLE_PURGE_PROC_OK"
        mole_purge_other_pids() { printf "%s\n" 4100; }
        mole_purge_proc_snapshot; echo "cut rc=$? ok=$MOLE_PURGE_PROC_OK"'
    chmod 644 "$proc/4100/status"
    [[ "$output" == *"unreadable=2"* ]]
    [[ "$output" == *"gone=1"* ]]
    [[ "$output" == *"
rc=2 ok=false"* ]]
    [[ "$output" == *"cut rc=2 ok=false"* ]]
}

@test "only an exited or refused process may fail a listing" {
    purge_run 'errors="$HOME/errors"; check() { printf "%s\n" "$1" > "$errors"; mole_purge_listing_finished "$2" "$errors" && echo finished || echo failed; }
        : > "$errors"; mole_purge_listing_finished 123 "$errors" && echo finished || echo failed
        check "find: /proc/9/fd: Permission denied" 123
        check "cat: /proc/9/maps: No such process" 123
        check "find: /proc/9/fd: Too many open files" 123
        check "sh: 1: exec: find: not found" 123
        check "" 0
        check "cat: /proc/9/maps: No such process" 124'
    [ "${lines[0]}" = failed ]
    [ "${lines[1]}" = finished ]
    [ "${lines[2]}" = finished ]
    [ "${lines[3]}" = failed ]
    [ "${lines[4]}" = failed ]
    [ "${lines[5]}" = finished ]
    [ "${lines[6]}" = failed ]
}

@test "menu search matches every word in any order" {
    run python3 "$MOLE_TEST_REPO/tests/menu_search_pty.py"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
