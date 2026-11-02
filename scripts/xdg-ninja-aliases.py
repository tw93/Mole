#!/usr/bin/env python3
"""Propose uninstall leftover aliases from xdg-ninja's catalog (offline).

Not run by Mole. It reads xdg-ninja's programs/*.json (MIT, Copyright 2022
b3nj5m1n, https://github.com/b3nj5m1n/xdg-ninja) and package name lists, and
prints one TSV row per catalog path:

    verdict  reason  program  package  path  help

`verdict` is `candidate`, `listed` (already in Mole's alias tables) or
`reject`. A candidate is only a proposal: `name` is a display name, so every
candidate is reviewed by hand before it goes into mole_app_xdg_ninja_paths in
lib/uninstall/inventory.sh. The review also drops what this script cannot
judge: a package without a launcher (uninstall never lists it), a name that
is a different program, a path other programs share, user libraries and
credential stores.

Package lists come from an Arch machine; launchers.txt is optional and names
packages known to ship /usr/share/applications/*.desktop (from
archlinux.org/packages/<repo>/<arch>/<name>/files/json/ for repo packages):

    LC_ALL=C pacman -Slq | sort -u > repo.txt
    yay -Slq aur | sort -u > aur.txt

Usage: scripts/xdg-ninja-aliases.py XDG_NINJA_DIR repo.txt [aur.txt [launchers.txt]]
"""

import glob
import json
import os
import re
import sys

# Folders and files many programs share, or the login shell and session own.
SHARED = {
    ".profile", ".bashrc", ".bash_profile", ".bash_login", ".bash_logout",
    ".bash_history", ".zshrc", ".zshenv", ".zprofile", ".zlogin", ".zlogout",
    ".zsh_history", ".zcompdump", ".gitconfig", ".git-credentials", ".ssh",
    ".gnupg", ".pki", ".local", ".config", ".cache", ".xinitrc", ".xprofile",
    ".xsession", ".xsessionrc", ".xsession-errors", ".Xauthority",
    ".Xresources", ".Xdefaults", ".ICEauthority", ".inputrc", ".netrc",
    ".mime.types", ".mailcap", ".icons", ".fonts", ".fonts.conf", ".themes",
    ".dbus", ".terminfo", ".editorconfig", ".pam_environment", ".login",
    ".logout", ".cshrc", ".tcshrc", ".history", ".hushlogin", ".sh_history",
    ".lesshst", ".viminfo", ".wget-hsts", ".python_history", ".node_repl_history",
    ".sqlite_history", ".mysql_history", ".psql_history", ".rediscli_history",
}

# Names in Mole's own shared list (mole_shared_leftover_name), without the dot.
MOLE_SHARED = set(
    "applications autostart dbus-1 dconf environment.d flatpak fontconfig fonts "
    "gtk-2.0 gtk-3.0 gtk-4.0 gvfs-metadata icons keyrings libsecret mime "
    "pipewire pulse recently-used.xbel seahorse ssh gnupg steam systemd themes "
    "thumbnails trash wireplumber local config cache var pki cargo rustup npm "
    "java m2 gradle docker kube aws git bin omarchy hypr xdg-desktop-portal "
    "menus desktop-directories sounds".split()
)

# Words that mark a credential, wallet or keyring store: never offered.
SECRET = re.compile(
    r"pass(word)?|keyring|keychain|credential|secret|token|auth|wallet|"
    r"bitcoin|electrum|monero|\.pgpass|\.my\.cnf|vault|(^|[._-])(age|sops)([._-]|$)|"
    r"pki|cert|\.netrc",
    re.I,
)

# Display names whose package is not the lowercased name, checked by hand.
HAND_MAP = {
    "Dolphin Emulator": "dolphin-emu",
    "Citrix Workspace App": "icaclient",
    "Google Earth": "google-earth-pro",
    "vmware": "vmware-workstation",
    "ts3client": "teamspeak3",
    "logseq": "logseq-desktop-bin",
}

INVENTORY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib", "uninstall", "inventory.sh")

XDG_ROOTS = (".config/", ".cache/", ".local/share/", ".local/state/")


def load_names(path):
    with open(path, encoding="utf-8") as f:
        return {line.strip() for line in f if line.strip()}


def listed_pairs():
    """(package, home-relative path) pairs already in Mole's alias tables."""
    pairs = set()
    try:
        with open(INVENTORY, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return pairs
    for m in re.finditer(r"^\s+([a-z0-9@._+| -]+)\) printf (.*)$", text, re.M):
        pkgs = [x.strip() for x in m.group(1).split("|")]
        for path in re.findall(r'"\$(?:h|HOME)/([^"]+)"', m.group(2)):
            pairs.update((pkg, path) for pkg in pkgs)
    return pairs


def package_for(name, repo, aur):
    """Package id for a display name, by exact name only."""
    if name in HAND_MAP:
        return HAND_MAP[name], "hand"
    base = name.strip().lower().replace(" ", "-")
    if not re.fullmatch(r"[a-z0-9@._+-]+", base):
        return "", ""
    if base in repo:
        return base, "repo"
    for cand in (base, base + "-bin", base + "-git"):
        if cand in aur:
            return cand, "aur"
    return "", ""


def covered(rel, pkg):
    return rel in (
        "." + pkg,
        ".config/" + pkg,
        ".cache/" + pkg,
        ".local/share/" + pkg,
        ".local/state/" + pkg,
    ) or any(rel.startswith(p) for p in (
        "." + pkg + "/",
        ".config/" + pkg + "/",
        ".cache/" + pkg + "/",
        ".local/share/" + pkg + "/",
        ".local/state/" + pkg + "/",
    ))


def classify(rel, pkg):
    rel = rel.rstrip("/")
    if "*" in rel:
        return "reject", "wildcard"
    first = rel.split("/", 1)[0]
    if first in SHARED or rel in SHARED or first.lstrip(".").lower() in MOLE_SHARED:
        if not any(rel.startswith(r) for r in XDG_ROOTS):
            return "reject", "shared dotfile"
    leaf = rel
    for r in XDG_ROOTS:
        if rel.startswith(r):
            leaf = rel[len(r):]
            break
    if "/" in leaf:
        return "reject", "nested path"
    if leaf.lstrip(".").lower() in MOLE_SHARED or leaf in SHARED:
        return "reject", "shared dotfile"
    if SECRET.search(leaf):
        return "reject", "credential or keyring"
    if not pkg:
        return "reject", "no verified package"
    if covered(rel, pkg):
        return "reject", "covered by XDG rules"
    return "candidate", ""


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    repo = load_names(argv[2])
    aur = load_names(argv[3]) if len(argv) > 3 else set()
    launchers = load_names(argv[4]) if len(argv) > 4 else None
    listed = listed_pairs()
    for f in sorted(glob.glob(os.path.join(argv[1], "programs", "*.json"))):
        with open(f, encoding="utf-8") as fh:
            prog = json.load(fh)
        pkg, _ = package_for(prog["name"], repo, aur)
        for e in prog["files"]:
            path = e["path"]
            if not path.startswith("$HOME/"):
                verdict, reason = "reject", "outside home"
            else:
                rel = path[len("$HOME/"):].rstrip("/")
                verdict, reason = classify(rel, pkg)
                if verdict == "candidate" and (pkg, rel) in listed:
                    verdict, reason = "listed", ""
                elif verdict == "candidate" and launchers is not None and pkg not in launchers:
                    verdict, reason = "reject", "no launcher"
            help_line = " ".join(e.get("help", "").split())[:160]
            print("\t".join((verdict, reason, prog["name"], pkg, path, help_line)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
