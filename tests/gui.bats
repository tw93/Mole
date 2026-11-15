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
