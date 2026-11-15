#!/usr/bin/env bats

load helpers

# The window reads clean and optimize through their plain-text report; this
# pins the shapes it parses to what the commands print today.
gui_python() {
    /usr/bin/python3 -c 'import gi; gi.require_version("Gtk", "4.0")' 2> /dev/null || skip "PyGObject with GTK 4 is not installed"
    run /usr/bin/python3 -c "import sys; sys.path.insert(0, '$REPO/gui')
$1"
}

@test "the window parses clean's dry run into sections, sizes and skipped rules" {
    mkdir -p "$HOME/.cache/thumbnails/large"
    head -c 65536 /dev/zero > "$HOME/.cache/thumbnails/large/a.png"
    NO_COLOR=1 bash "$REPO/mole" clean --dry-run < /dev/null > "$TEST_ROOT/out.txt"
    gui_python "from mole_gui import cli
sections, summary = cli.parse_report(open('$TEST_ROOT/out.txt').read())
items = {i['label']: i for s in sections for i in s['items']}
t = items['Thumbnails']
assert t['kind'] == 'dry' and t['bytes'] > 0, t
assert any(s.startswith('Potential space') for s in summary), summary
print('ok')"
    [ "$status" -eq 0 ]
    [ "$output" == ok ]
}

@test "the window parses review lines, sub items and hints" {
    gui_python "from mole_gui import cli
text = '''➤ Failed Services
  ◎ 2 services failed
    ↳ a.service
    ↳ b.service
    Run systemctl status <unit>
➤ Browsers
  ○ Chrome cache · skipped while chrome is running
  ○ Firefox cache · 2 items, 1.5MB dry
'''
sections, _ = cli.parse_report(text)
failed = sections[0]['items'][0]
assert failed['kind'] == 'attention' and failed['subs'] == ['a.service', 'b.service'], failed
assert failed['hints'] == ['Run systemctl status <unit>'], failed
chrome, firefox = sections[1]['items']
assert chrome['kind'] == 'skipped', chrome
assert firefox['bytes'] == 1500000 and firefox['detail'] == '2 items, 1.5MB', firefox
print('ok')"
    [ "$status" -eq 0 ]
    [ "$output" == ok ]
}

@test "the whitelist check boxes refuse a broken link and write a linked file where it points" {
    mkdir -p "$HOME/.config/mole" "$HOME/dotfiles"
    ln -s "$HOME/dotfiles/whitelist" "$HOME/.config/mole/whitelist"
    # CleanPage.set_kept is what a check box calls; a stand-in window collects toasts.
    local toggle="import gi; gi.require_version('Gtk', '4.0'); gi.require_version('Adw', '1')
from types import SimpleNamespace
from mole_gui import pages
toasts = []
page = SimpleNamespace(whitelist='$HOME/.config/mole/whitelist', win=SimpleNamespace(toast=toasts.append))
pages.CleanPage.set_kept(page, 'npm cache', True)
print(toasts[-1])"
    gui_python "$toggle"
    [ "$status" -eq 0 ]
    [[ "$output" == "Cannot read the whitelist"* ]]
    [ -L "$HOME/.config/mole/whitelist" ]

    printf '# kept\nThumbnails\n' > "$HOME/dotfiles/whitelist"
    gui_python "$toggle"
    [ "$status" -eq 0 ]
    [ -L "$HOME/.config/mole/whitelist" ]
    [ "$(cat "$HOME/dotfiles/whitelist")" == $'# kept\nThumbnails\nnpm cache' ]
}

@test "the kept-items dialog keeps comments in place when entries change" {
    gui_python "from mole_gui import cli
lines = ['# caches', 'Thumbnails', '', '# my folders', '~/keep', 'npm cache']
out = cli.merge_entries(lines, ['~/keep', 'npm cache', 'Trash'])
assert out == ['# caches', '', '# my folders', '~/keep', 'npm cache', 'Trash'], out
print('ok')"
    [ "$status" -eq 0 ]
    [ "$output" == ok ]
}

@test "the uninstall dialog parses what goes, what stays and the notes of a plan" {
    gui_python "from mole_gui import cli
text = '''
➤ Code apt · 380MB
  ● ~/.cache/Code  12.0MB
  ○ ~/.config/Code  40.0MB (kept, holds settings)
  ○ ~/.vscode  1.0MB (kept)
  User services stopped and disabled first: code-sync.service
  ◎ apt also removes the packages that depend on these: code-insiders

======================================================================
Dry run complete - no changes made
Would remove: 1 app
======================================================================
'''
plan, summary = cli.parse_uninstall_plan(text)
assert plan['leftovers'] == [
    {'path': '~/.cache/Code', 'size': '12.0MB', 'goes': True, 'note': ''},
    {'path': '~/.config/Code', 'size': '40.0MB', 'goes': False, 'note': 'holds settings'},
    {'path': '~/.vscode', 'size': '1.0MB', 'goes': False, 'note': ''},
], plan['leftovers']
assert [n['warning'] for n in plan['notes']] == [False, True], plan['notes']
assert summary == ['Dry run complete - no changes made', 'Would remove: 1 app'], summary
print('ok')"
    [ "$status" -eq 0 ]
    [ "$output" == ok ]
}
