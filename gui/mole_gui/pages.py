"""One class per sidebar destination. Each reads the CLI's report and hands
every change back to the CLI; nothing here decides what is safe to remove."""

import math
import os
import time
from datetime import datetime

from gi.repository import Adw, Gio, GLib, Graphene, Gsk, Gtk, Pango

from . import cli
from .base import LineFileDialog, Page, RunDialog, confirm, dim_label, flat_button, plan_dialog, row, tag

HOME = GLib.get_home_dir()


def display_path(path):
    return "~" + path[len(HOME):] if path == HOME or path.startswith(HOME + "/") else path


def ago(epoch):
    if not epoch:
        return ""
    days = int((time.time() - epoch) // 86400)
    if days < 1:
        return "today"
    if days < 30:
        return f"{days} days ago" if days > 1 else "yesterday"
    if days < 365:
        return f"{days // 30} months ago" if days >= 60 else "a month ago"
    return f"{days // 365} years ago" if days >= 730 else "a year ago"


class Ring(Gtk.Widget):
    """A usage ring: the share of a whole, with the figure in its middle.
    Drawn with Gsk paths, so it needs no cairo bindings."""

    def __init__(self, size=132):
        super().__init__(width_request=size, height_request=size, valign=Gtk.Align.CENTER)
        self.fraction = 0.0

    def set_fraction(self, fraction):
        self.fraction = max(0.0, min(1.0, fraction))
        self.queue_draw()

    def do_snapshot(self, snapshot):
        w, h = self.get_width(), self.get_height()
        lw = 12
        r = min(w, h) / 2 - lw / 2
        cx, cy = w / 2, h / 2
        track = self.get_color()
        track.alpha = 0.12
        # The accent, or the warning color once the disk is nearly full.
        found, fill = self.get_style_context().lookup_color("warning_bg_color" if self.fraction >= 0.9 else "accent_bg_color")
        if not found:
            fill = self.get_color()
        stroke = Gsk.Stroke.new(lw)
        builder = Gsk.PathBuilder.new()
        builder.add_circle(Graphene.Point().init(cx, cy), r)
        snapshot.append_stroke(builder.to_path(), stroke, track)
        if self.fraction <= 0:
            return
        stroke.set_line_cap(Gsk.LineCap.ROUND)
        builder = Gsk.PathBuilder.new()
        if self.fraction >= 0.999:
            builder.add_circle(Graphene.Point().init(cx, cy), r)
        else:
            angle = 2 * math.pi * self.fraction
            builder.move_to(cx, cy - r)
            builder.svg_arc_to(r, r, 0, angle > math.pi, True, cx + r * math.sin(angle), cy - r * math.cos(angle))
        snapshot.append_stroke(builder.to_path(), stroke, fill)


def usage_bar(fraction=0.0, warn=True, **props):
    """A level bar in the accent color; with warn, past 90% it turns to the
    warning color. Adwaita's default offsets read a low value as a warning."""
    bar = Gtk.LevelBar(min_value=0, max_value=1, value=fraction, **props)
    for name in ("low", "high", "full"):
        bar.remove_offset_value(name)
    if warn:
        bar.add_offset_value("mole-ok", 0.9)
        bar.add_offset_value("mole-warn", 1.0)
    else:
        bar.add_offset_value("mole-ok", 1.0)
    return bar


class Tile(Gtk.Box):
    """A dashboard figure: name, value, and a bar or a note under it."""

    def __init__(self, name, warn=True):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=4, hexpand=True)
        self.add_css_class("card")
        self.add_css_class("mole-tile")
        self.name = Gtk.Label(label=name, xalign=0)
        self.name.add_css_class("dimmed")
        self.name.add_css_class("dim-label")
        self.name.add_css_class("caption")
        self.value = Gtk.Label(label="—", xalign=0)
        self.value.add_css_class("title-2")
        self.value.add_css_class("numeric")
        self.bar = usage_bar(margin_top=4, warn=warn)
        self.note = Gtk.Label(xalign=0, ellipsize=Pango.EllipsizeMode.END, max_width_chars=12)
        self.note.add_css_class("dimmed")
        self.note.add_css_class("dim-label")
        self.note.add_css_class("caption")
        for w in (self.name, self.value, self.bar, self.note):
            self.append(w)

    def set(self, value, fraction=None, note=""):
        self.value.set_label(value)
        self.bar.set_visible(fraction is not None)
        if fraction is not None:
            self.bar.set_value(max(0.0, min(1.0, fraction)))
        self.note.set_label(note)
        self.note.set_visible(bool(note))


class OverviewPage(Page):
    title = "Overview"
    icon = "speedometer-symbolic"

    def __init__(self, win):
        super().__init__(win)
        self.timer = 0
        self.polling = False
        self.attention_rows = []

        hero = Gtk.Box(spacing=28, margin_top=12)
        self.ring = Ring()
        overlay = Gtk.Overlay(child=self.ring)
        ring_label = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER)
        self.ring_value = Gtk.Label(label="—")
        self.ring_value.add_css_class("title-2")
        self.ring_value.add_css_class("numeric")
        self.ring_note = Gtk.Label(label="used")
        self.ring_note.add_css_class("dimmed")
        self.ring_note.add_css_class("dim-label")
        self.ring_note.add_css_class("caption")
        ring_label.append(self.ring_value)
        ring_label.append(self.ring_note)
        overlay.add_overlay(ring_label)
        hero.append(overlay)
        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, valign=Gtk.Align.CENTER, hexpand=True)
        self.headline = Gtk.Label(xalign=0, wrap=True)
        self.headline.add_css_class("title-1")
        self.subline = Gtk.Label(xalign=0, wrap=True)
        self.subline.add_css_class("dimmed")
        self.subline.add_css_class("dim-label")
        buttons = Gtk.Box(spacing=12, margin_top=8)
        review = Gtk.Button(label="Review Cleanup")
        review.add_css_class("pill")
        review.add_css_class("suggested-action")
        review.connect("clicked", lambda *_: win.show_page("CleanPage"))
        analyze = Gtk.Button(label="Explore Disk")
        analyze.add_css_class("pill")
        analyze.connect("clicked", lambda *_: win.show_page("AnalyzePage"))
        buttons.append(review)
        buttons.append(analyze)
        for w in (self.headline, self.subline, buttons):
            text.append(w)
        hero.append(text)
        self.box.append(hero)

        # A high health score is good news, so it never turns to the warning color.
        self.tiles = {name: Tile(name, warn=name != "Health") for name in ("Health", "CPU", "Memory", "Temperature")}
        grid = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, homogeneous=True, column_spacing=12,
                           row_spacing=12, min_children_per_line=2, max_children_per_line=4)
        for tile in self.tiles.values():
            grid.append(tile)
        self.box.append(grid)

        self.attention = Adw.PreferencesGroup(title="Attention")
        self.box.append(self.attention)
        self.disks = Adw.PreferencesGroup(title="Disks")
        self.box.append(self.disks)
        self.apps = Adw.PreferencesGroup(title="Busiest Apps")
        self.box.append(self.apps)
        self.disk_rows = []
        self.app_rows = []
        self.connect("shown", lambda *_: self.start())
        self.connect("hidden", lambda *_: self.stop())

    def load(self):
        super().load()
        if not self.polling:
            self.set_loading("Reading system status…")
        self.poll()
        cli.run_json(["system", "--json"], self.show_system)

    def start(self):
        self.ensure_loaded()
        if not self.timer:
            self.timer = GLib.timeout_add_seconds(2, self.poll)

    def stop(self):
        if self.timer:
            GLib.source_remove(self.timer)
            self.timer = 0

    def poll(self):
        if not self.polling:
            self.polling = True
            cli.run_json(["status", "--json"], self.show_status_data)
        return True

    def show_status_data(self, data, err):
        self.polling = False
        if data is None:
            self.show_error(err)
            return
        self.show_content()
        root = next((d for d in data.get("disks") or [] if d.get("mount") == "/"), None)
        if root:
            free = root["total"] - root["used"]
            self.ring.set_fraction(root["used"] / root["total"])
            self.ring_value.set_label(f"{100 * root['used'] / root['total']:.0f}%")
            self.ring_note.set_label(f"of {cli.human(root['total'])}")
            self.headline.set_label(f"{cli.human(free)} free")
        hw = data.get("hardware") or {}
        self.subline.set_label(" · ".join(x for x in (hw.get("os_version"), f"up {data.get('uptime', '')}") if x))

        score = data.get("health_score")
        self.tiles["Health"].set(str(score) if score is not None else "—", (score or 0) / 100, data.get("health_score_msg", ""))
        cpu = data.get("cpu") or {}
        self.tiles["CPU"].set(f"{cpu.get('usage', 0):.0f}%", cpu.get("usage", 0) / 100,
                              f"Load {cpu.get('load1', 0):.2f} · {cpu.get('logical_cpu', '')} threads")
        mem = data.get("memory") or {}
        self.tiles["Memory"].set(cli.human(mem.get("used", 0)), mem.get("used_percent", 0) / 100,
                                 f"of {cli.human(mem.get('total', 0))}" + ("" if mem.get("pressure") in (None, "normal") else f" · {mem['pressure']} pressure"))
        temp = (data.get("thermal") or {}).get("cpu_temp") or 0
        batteries = data.get("batteries") or []
        if batteries:
            b = batteries[0]
            self.tiles["Temperature"].name.set_label("Battery")
            self.tiles["Temperature"].set(f"{b.get('percent', 0):.0f}%", b.get("percent", 0) / 100, b.get("status", ""))
        else:
            self.tiles["Temperature"].set(f"{temp:.0f} °C" if temp else "—", None, "CPU package")

        for r in self.disk_rows:
            self.disks.remove(r)
        self.disk_rows = []
        for d in data.get("disks") or []:
            bar = usage_bar(d["used_percent"] / 100, valign=Gtk.Align.CENTER, width_request=120)
            r = row(d["mount"], f"{d.get('device', '')} · {d.get('fstype', '')}",
                    suffix=bar, icon="drive-harddisk-symbolic")
            r.add_suffix(dim_label(f"{cli.human(d['total'] - d['used'])} free"))
            r.add_suffix(Gtk.Image(icon_name="go-next-symbolic"))
            r.set_activatable(True)
            r.connect("activated", lambda _r, m=d["mount"]: self.explore(m))
            self.disks.add(r)
            self.disk_rows.append(r)

        for r in self.app_rows:
            self.apps.remove(r)
        self.app_rows = []
        for a in (data.get("top_apps") or [])[:5]:
            r = row(a.get("name", ""), f"{a.get('processes', 1)} processes" if a.get("processes", 1) > 1 else "",
                    suffix=f"{a.get('cpu', 0):.0f}% CPU · {cli.human(a.get('memory_bytes', 0))}")
            self.apps.add(r)
            self.app_rows.append(r)

    def explore(self, mount):
        self.win.show_page("AnalyzePage")
        self.win.pages["AnalyzePage"].open(mount)

    def show_system(self, data, err):
        for r in self.attention_rows:
            self.attention.remove(r)
        self.attention_rows = []
        checks = [c for c in (data or {}).get("checks", []) if c["state"] == "attention"]
        for c in checks:
            r = row(c["title"], c["summary"], icon="dialog-warning-symbolic")
            r.set_activatable(True)
            r.connect("activated", lambda *_: self.win.show_page("SystemPage"))
            r.add_suffix(Gtk.Image(icon_name="go-next-symbolic"))
            self.attention.add(r)
            self.attention_rows.append(r)
        self.attention.set_visible(bool(checks))


def app_icons():
    """Launcher icons by lowercase app name and desktop id, for the app list.
    Only a picture: which app is removed is decided by the CLI's name."""
    icons = {}
    for info in Gio.AppInfo.get_all():
        icon = info.get_icon()
        if icon is None:
            continue
        icons.setdefault(info.get_name().lower(), icon)
        app_id = (info.get_id() or "").removesuffix(".desktop").lower()
        icons.setdefault(app_id, icon)
    return icons


class ReportPage(Page):
    """A page built from a dry run's sections (clean, optimize)."""

    command = ""
    loading_text = ""
    run_label = ""
    run_title = ""

    def __init__(self, win):
        super().__init__(win)
        bar = self.add_bottom_bar()
        self.terminal_button = flat_button("Open in Terminal", self.open_terminal)
        self.terminal_button.set_tooltip_text("Run in a terminal, where Mole can ask for your password")
        self.run_button = flat_button(self.run_label, self.ask_run, "suggested-action")
        bar.append(self.terminal_button)
        bar.append(self.run_button)

    def load(self):
        super().load()
        self.set_loading(self.loading_text)
        self.run_button.set_sensitive(False)
        cli.run([self.command, "--dry-run"], self.show_report)

    def show_report(self, ok, out, err):
        sections, summary = cli.parse_report(out)
        if not sections:
            self.show_error(err or out or "No report")
            return
        self.clear()
        for section in sections:
            group = self.add_group(section["title"])
            if not section["items"]:
                group.add(row("Nothing to do", icon="object-select-symbolic"))
            for item in section["items"]:
                group.add(self.item_row(item))
        # The summary block's headline restates "dry run"; the figures are what matter.
        lines = [s.replace(" | ", " · ") for s in summary if not s.lower().startswith(("dry run", "run without"))]
        self.summary.set_label("  ·  ".join(lines))
        self.run_button.set_sensitive(True)
        self.show_content()

    def item_row(self, item):
        icons = {
            "ok": "object-select-symbolic",
            "skipped": "media-playback-pause-symbolic",
            "review": "dialog-information-symbolic",
            "attention": "dialog-warning-symbolic",
            "error": "dialog-error-symbolic",
        }
        subtitle = item["detail"]
        if item["hints"]:
            subtitle = "\n".join(filter(None, [subtitle, *item["hints"]]))
        if item["subs"]:
            r = Adw.ExpanderRow(title=GLib.markup_escape_text(item["label"]), subtitle=GLib.markup_escape_text(subtitle))
            r.add_prefix(Gtk.Image(icon_name=icons.get(item["kind"], "")))
            for sub in item["subs"]:
                child = Adw.ActionRow(title=GLib.markup_escape_text(sub))
                child.add_css_class("monospace")
                r.add_row(child)
            return r
        return row(item["label"], subtitle, icon=icons.get(item["kind"]))

    def ask_run(self):
        confirm(self.win, f"{self.run_title}?", self.run_body(), self.run_label, self.run, destructive=False)

    def run_body(self):
        return "Steps that need your password are skipped here; use Open in Terminal for them."

    def run(self):
        RunDialog(self.win, self.run_title, [cli.MOLE, self.command], lambda ok: self.load())

    def open_terminal(self):
        if not cli.in_terminal(cli.mo_command(self.command)):
            self.win.toast("No terminal app found")


class CleanPage(ReportPage):
    title = "Clean"
    icon = "user-trash-symbolic"
    section = "Free Space"
    command = "clean"
    loading_text = "Looking for caches…"
    run_label = "Clean"
    run_title = "Clean Caches"

    def __init__(self, win):
        super().__init__(win)
        self.whitelist = cli.config_path("whitelist")
        keep = Gtk.Button(icon_name="security-high-symbolic", tooltip_text="Kept Items")
        keep.connect("clicked", lambda *_: LineFileDialog(
            win, "Kept Items", self.whitelist,
            "Clean skips these rules and folders.",
            typed_hint="Rule name, path or glob", on_saved=self.load))
        self.header.pack_end(keep)

    def run_body(self):
        return ("Caches are removed for good; apps rebuild them. Files in the Trash are deleted. "
                "Steps that need your password are skipped here; use Open in Terminal for them.")

    def item_row(self, item):
        r = super().item_row(item)
        whitelisted = "whitelist" in item["detail"]
        if item["kind"] in ("dry", "skipped") and (item["bytes"] or whitelisted) and not isinstance(r, Adw.ExpanderRow):
            check = Gtk.CheckButton(active=not whitelisted, valign=Gtk.Align.CENTER,
                                    tooltip_text="Clean this; uncheck to keep it (whitelist)")
            check.connect("toggled", lambda c, label=item["label"]: self.set_kept(label, not c.get_active()))
            r.add_prefix(check)
            r.set_activatable_widget(check)
            if item["bytes"]:
                r.add_suffix(dim_label(cli.human(item["bytes"])))
        return r

    def set_kept(self, label, keep):
        """Add or drop a rule label in the whitelist clean reads."""
        try:
            lines = cli.read_config(self.whitelist)
        except OSError as e:
            self.win.toast(f"Cannot read the whitelist: {e.strerror}")
            return
        lines = [ln for ln in lines if ln.strip() != label]
        if keep:
            lines.append(label)
        try:
            cli.write_config(self.whitelist, lines)
        except OSError as e:
            self.win.toast(f"Cannot save the whitelist: {e.strerror}")
            return
        self.win.toast(f"{label} {'kept' if keep else 'cleaned again'}")


class OptimizePage(ReportPage):
    title = "Optimize"
    icon = "applications-engineering-symbolic"
    section = "Maintain"
    command = "optimize"
    loading_text = "Checking the system…"
    run_label = "Optimize"
    run_title = "Optimize"

    def run_body(self):
        return "Rebuilds caches and indexes. Items marked for attention are only reported."

    def show_report(self, ok, out, err):
        sections, summary = cli.parse_report(out)
        if not sections:
            self.show_error(err or out or "No report")
            return
        self.clear()
        attention = self.add_group("Needs Attention")
        tasks = self.add_group("Tasks")
        for section in sections:
            for item in section["items"] or [{"kind": "ok", "label": "Nothing to do", "detail": "", "subs": [], "hints": []}]:
                shown = dict(item, label=section["title"], detail=" · ".join(x for x in (item["label"], item["detail"]) if x))
                r = self.item_row(shown)
                (attention if item["kind"] in ("attention", "error", "review") else tasks).add(r)
        attention.set_visible(any(i["kind"] in ("attention", "error", "review") for s in sections for i in s["items"]))
        lines = [s.replace(" | ", " · ") for s in summary if not s.lower().startswith(("dry run", "run without"))]
        self.summary.set_label("  ·  ".join(lines))
        self.run_button.set_sensitive(True)
        self.show_content()


class UninstallPage(Page):
    title = "Uninstall"
    icon = "application-x-addon-symbolic"
    section = "Free Space"
    # Kinds Mole removes without sudo or a package manager's prompt.
    LOCAL_KINDS = {"appimage", "webapp", "tui", "orphan"}

    def __init__(self, win):
        super().__init__(win)
        self.search = Gtk.SearchEntry(placeholder_text="Search apps", hexpand=True)
        self.search.connect("search-changed", lambda *_: self.listbox.invalidate_filter())
        self.listbox = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        self.listbox.add_css_class("boxed-list")
        self.listbox.set_filter_func(self.matches)
        self.count = Gtk.Label(xalign=0)
        self.count.add_css_class("heading")

    def load(self):
        super().load()
        self.set_loading("Reading installed apps…")
        cli.run_json(["uninstall", "--list"], self.show_apps)

    def matches(self, r):
        q = self.search.get_text().lower()
        return not q or q in r.search_text

    def show_apps(self, data, err):
        if data is None:
            self.show_error(err)
            return
        self.clear()
        self.listbox.remove_all()
        self.box.append(self.search)
        self.count.set_label(f"{len(data)} apps · largest first")
        self.box.append(self.count)
        self.box.set_spacing(12)
        icons = app_icons()
        for app in sorted(data, key=lambda a: -int(a.get("size_kb") or 0)):
            subtitle = " · ".join(x for x in (app["uninstall_name"], app["source"], f"used {app['last_used'].lower()}" if app.get("last_used") else "") if x)
            r = row(app["name"], subtitle, suffix=app.get("size", ""))
            icon = icons.get(app["uninstall_name"].lower()) or icons.get(app["name"].lower())
            image = Gtk.Image(pixel_size=32)
            if icon:
                image.set_from_gicon(icon)
            else:
                image.set_from_icon_name("application-x-executable")
            r.add_prefix(image)
            r.search_text = f"{app['name']} {app['uninstall_name']} {app['source']}".lower()
            r.add_suffix(Gtk.Image(icon_name="go-next-symbolic"))
            r.set_activatable(True)
            r.set_tooltip_text("Uninstall…")
            r.connect("activated", lambda _r, a=app: self.plan(a))
            self.listbox.append(r)
        self.box.append(self.listbox)
        self.show_content()

    def plan(self, app):
        name = app["uninstall_name"]
        if app["kind"] in self.LOCAL_KINDS:
            actions = [("Uninstall", "destructive-action", lambda: self.remove_here(app))]
        else:
            actions = [("Continue in Terminal", "suggested-action", lambda: self.remove_in_terminal(app))]
        plan_dialog(self.win, f"Uninstall {app['name']}", ["uninstall", "--dry-run", name], actions)

    def remove_here(self, app):
        RunDialog(self.win, f"Uninstall {app['name']}", [cli.MOLE, "uninstall", "--yes", app["uninstall_name"]],
                  lambda ok: self.load())

    def remove_in_terminal(self, app):
        # The package manager asks for the password and confirms its own plan.
        if not cli.in_terminal(cli.mo_command("uninstall", app["uninstall_name"])):
            self.win.toast("No terminal app found")


class CheckListPage(Page):
    """Rows with check boxes, a total, and one action on what is checked."""

    action_label = ""

    def __init__(self, win):
        super().__init__(win)
        self.bar = self.add_bottom_bar()
        self.action = flat_button(self.action_label, self.ask, "destructive-action")
        self.bar.append(self.action)
        self.checks = []

    def reset(self):
        self.clear()
        self.checks = []
        self.toolbar.set_reveal_bottom_bars(True)

    def show_status(self, *args, **kwargs):
        self.toolbar.set_reveal_bottom_bars(False)
        super().show_status(*args, **kwargs)

    def add_check(self, group, title, subtitle, size_bytes, value, active, suffix=None):
        check = Gtk.CheckButton(active=active, valign=Gtk.Align.CENTER)
        check.connect("toggled", lambda *_: self.update_total())
        r = row(title, subtitle)
        r.add_prefix(check)
        r.set_activatable_widget(check)
        if suffix is not None:
            r.add_suffix(suffix)
        r.add_suffix(dim_label(cli.human(size_bytes) if size_bytes is not None else "?"))
        group.add(r)
        self.checks.append((check, value, size_bytes or 0))

    def add_kept(self, group, title, subtitle, size_bytes, reason):
        r = row(title, subtitle, suffix=tag(reason))
        r.add_suffix(dim_label(cli.human(size_bytes)))
        group.add(r)

    def selected(self):
        return [(value, size) for check, value, size in self.checks if check.get_active()]

    def update_total(self):
        picked = self.selected()
        total = sum(size for _, size in picked)
        self.summary.set_label(f"{cli.human(total)} selected in {len(picked)} items" if picked else "Nothing selected")
        self.action.set_sensitive(bool(picked))


class PurgePage(CheckListPage):
    title = "Project Purge"
    icon = "folder-symbolic"
    section = "Free Space"
    action_label = "Remove"

    def __init__(self, win):
        super().__init__(win)
        paths = Gtk.Button(icon_name="folder-new-symbolic", tooltip_text="Scan Folders")
        paths.connect("clicked", lambda *_: LineFileDialog(
            win, "Scan Folders", cli.config_path("purge_paths"),
            "Purge looks only in these folders. With none listed, it finds project folders in your home.",
            on_saved=self.load))
        self.header.pack_end(paths)

    def load(self):
        super().load()
        self.set_loading("Scanning projects…")
        cli.run_json(["purge", "--json"], self.show_items)

    def show_items(self, data, err):
        if data is None:
            self.show_error(err)
            return
        self.reset()
        roots = ", ".join(display_path(r) for r in data["roots"])
        if not data["items"]:
            self.show_status("folder-symbolic", "No Build Output",
                             f"Nothing to remove in {roots}" if roots else "No project folders found")
            self.update_total()
            return
        group = self.add_group("Build Output", f"In {roots}. Folders changed this week start unchecked.")
        states = {"old": None, "recent": "changed this week", "busy": "in use"}
        for item in sorted(data["items"], key=lambda i: -(i["size_kb"] or 0)):
            size = item["size_kb"] * 1024 if item["size_kb"] is not None else None
            subtitle = f"{item['name']} · {ago(item['mtime'])}"
            title = display_path(item["project"])
            if item["state"] == "busy":
                self.add_kept(group, title, subtitle, size or 0, "In use")
            else:
                note = states.get(item["state"])
                self.add_check(group, title, subtitle, size, item["path"], item["state"] == "old",
                               tag(note) if note else None)
        self.update_total()
        self.show_content()

    def ask(self):
        picked = self.selected()
        confirm(self.win, f"Remove {len(picked)} Folders?",
                "Build output is deleted, not moved to the Trash. Package managers and build tools make it again.",
                "Remove", lambda: RunDialog(self.win, "Project Purge", [cli.MOLE, "purge", "--yes", *[p for p, _ in picked]],
                                            lambda ok: self.load()))


class InstallerPage(CheckListPage):
    title = "Installers"
    icon = "folder-download-symbolic"
    section = "Free Space"
    action_label = "Move to Trash"

    def load(self):
        super().load()
        self.set_loading("Looking for installers…")
        cli.run_json(["installer", "--json"], self.show_items)

    def show_items(self, data, err):
        if data is None:
            self.show_error(err)
            return
        self.reset()
        if not data:
            self.show_status("folder-download-symbolic", "No Installers", "Downloads and Desktop hold no installer files")
            self.update_total()
            return
        group = self.add_group("In Downloads and Desktop")
        for item in data:
            subtitle = " · ".join(x for x in (display_path(os.path.dirname(item["path"])), item["kind"],
                                              ago(time.time() - item["age_days"] * 86400)) if x)
            size = item["size_kb"] * 1024
            if item["state"] != "ok":
                self.add_kept(group, item["name"], subtitle, size, item["note"].capitalize())
            else:
                self.add_check(group, item["name"], subtitle, size, item["path"], True,
                               tag("Installed", "success") if item["note"] == "installed" else None)
        self.update_total()
        self.show_content()
        self.action.remove_css_class("destructive-action")
        self.action.add_css_class("suggested-action")

    def ask(self):
        paths = [p for p, _ in self.selected()]

        def done(ok, out, err):
            # The CLI checks each file again before the move; one opened since stays.
            moved = sum(1 for ln in cli.strip(out).splitlines() if ln.strip().startswith("✓"))
            if ok:
                self.win.toast(f"{moved} of {len(paths)} files moved to the Trash" if moved < len(paths)
                               else f"{moved} {'file' if moved == 1 else 'files'} moved to the Trash")
            else:
                self.win.toast((cli.strip(err or out).strip().splitlines() or ["Could not move them"])[-1])
            self.load()

        cli.run(["installer", "--yes", *paths], done)


class AnalyzePage(Page):
    title = "Disk Usage"
    icon = "drive-harddisk-symbolic"
    section = "Free Space"

    def __init__(self, win):
        super().__init__(win)
        self.path = HOME
        self.history = []
        self.back = Gtk.Button(icon_name="go-up-symbolic", tooltip_text="Parent Folder", sensitive=False)
        self.back.connect("clicked", lambda *_: self.go_up())
        self.header.pack_start(self.back)
        choose = Gtk.Button(icon_name="folder-open-symbolic", tooltip_text="Choose Folder")
        choose.connect("clicked", lambda *_: self.choose())
        self.header.pack_end(choose)
        self.cancellable = None

    def load(self):
        super().load()
        self.set_title(os.path.basename(self.path) or self.path)
        self.set_loading(f"Measuring {display_path(self.path)}…")
        self.back.set_sensitive(self.path != "/")
        if self.cancellable:
            self.cancellable.cancel()
        self.cancellable = cancellable = Gio.Cancellable()
        # A replaced scan's reply ("cancelled") must not cover the new one.
        cli.run_json(["analyze", "--json", self.path],
                     lambda data, err: cancellable.is_cancelled() or self.show_tree(data, err), cancellable)

    def open(self, path):
        self.path = path
        self.load()

    def go_up(self):
        self.open(os.path.dirname(self.path.rstrip("/")) or "/")

    def choose(self):
        dialog = Gtk.FileDialog(title="Choose a Folder to Measure")

        def done(d, result):
            try:
                folder = d.select_folder_finish(result)
            except GLib.Error:
                return
            if folder and folder.get_path():
                self.open(folder.get_path())

        dialog.select_folder(self.win, None, done)

    def show_tree(self, data, err):
        if data is None:
            if err:
                self.show_error(err)
            return
        self.clear()
        entries = sorted(data.get("entries") or [], key=lambda e: -e.get("size", 0))
        total = sum(e.get("size", 0) for e in entries) or 1
        group = self.add_group(description=f"{display_path(data.get('path', self.path))} · {cli.human(total)} in {len(entries)} items")
        for e in entries[:200]:
            fraction = e.get("size", 0) / total
            subtitle = f"{fraction * 100:.1f}%"
            if e.get("last_access"):
                try:
                    when = datetime.fromisoformat(e["last_access"].replace("Z", "+00:00")).timestamp()
                    subtitle += f" · opened {ago(when)}"
                except ValueError:
                    pass
            r = row(e["name"], subtitle, icon="folder-symbolic" if e.get("is_dir") else "text-x-generic-symbolic")
            r.add_css_class(f"mole-fill-{round(fraction * 100)}")
            r.add_suffix(dim_label(cli.human(e.get("size", 0))))
            menu = Gio.Menu()
            menu.append("Open", f"win.open-path::{e['path']}")
            menu.append("Move to Trash", f"win.trash-path::{e['path']}")
            r.add_suffix(Gtk.MenuButton(icon_name="view-more-symbolic", menu_model=menu, valign=Gtk.Align.CENTER,
                                        css_classes=["flat"]))
            if e.get("is_dir"):
                r.add_suffix(Gtk.Image(icon_name="go-next-symbolic"))
                r.set_activatable(True)
                r.connect("activated", lambda _r, p=e["path"]: self.open(p))
            group.add(r)
        self.show_content()

    def trash(self, path):
        def go():
            def done(ok, msg):
                self.win.toast(f"{os.path.basename(path)} moved to the Trash" if ok else (msg or "Could not move to the Trash"))
                if ok:
                    self.load()

            cli.trash([path], done)

        confirm(self.win, f"Move {os.path.basename(path)} to the Trash?",
                "It can be restored from the Trash in Files.", "Move to Trash", go)


class SystemPage(Page):
    title = "System"
    icon = "computer-symbolic"
    section = "Maintain"

    def load(self):
        super().load()
        self.set_loading("Checking the system…")
        cli.run_json(["system", "--json"], self.show_checks)

    def show_checks(self, data, err):
        if data is None:
            self.show_error(err)
            return
        self.clear()
        icons = {"attention": "dialog-warning-symbolic", "ok": "object-select-symbolic",
                 "info": "dialog-information-symbolic", "unknown": "dialog-question-symbolic"}
        group = self.add_group()
        for c in data["checks"]:
            if c["items"]:
                r = Adw.ExpanderRow(title=GLib.markup_escape_text(c["title"]), subtitle=GLib.markup_escape_text(c["summary"]))
                r.add_prefix(Gtk.Image(icon_name=icons.get(c["state"], "")))
                for item in c["items"][:50]:
                    r.add_row(Adw.ActionRow(title=GLib.markup_escape_text(item)))
            else:
                r = row(c["title"], c["summary"], icon=icons.get(c["state"]))
            if c["command"] and c["state"] == "attention":
                button = flat_button("Run…", lambda cmd=c["command"]: self.run_command(cmd))
                button.set_tooltip_text(c["command"])
                r.add_suffix(button)
            group.add(r)
        self.show_content()

    def run_command(self, command):
        def go():
            if not cli.in_terminal(command):
                self.win.toast("No terminal app found")

        confirm(self.win, "Run in a Terminal?", command, "Run", go)


class StartupPage(Page):
    title = "Startup Apps"
    icon = "system-run-symbolic"
    section = "Maintain"

    def load(self):
        super().load()
        self.set_loading("Reading startup items…")
        cli.run_json(["startup", "--json"], self.show_items)

    def show_items(self, data, err):
        if data is None:
            self.show_error(err)
            return
        self.clear()
        groups = {
            "autostart": self.add_group(),
            "service": self.add_group("User Services"),
        }
        counts = {"autostart": 0, "service": 0}
        for item in data:
            switch = Gtk.Switch(active=item["enabled"], valign=Gtk.Align.CENTER)
            switch.connect("state-set", lambda s, state, i=item: self.toggle(s, state, i))
            source = {"system": "System default", "override": "System default, changed", "user": "Added by you"}[item["source"]]
            r = row(item["name"], f"{source} · {item['id']}", suffix=switch, activatable_widget=switch)
            groups[item["kind"]].add(r)
            counts[item["kind"]] += 1
        for kind, group in groups.items():
            group.set_visible(counts[kind] > 0)
        if not data:
            self.show_status("system-run-symbolic", "Nothing Starts at Login")
            return
        self.show_content()

    def toggle(self, switch, state, item):
        if getattr(switch, "reverting", False):
            return False

        def done(ok, out, err):
            if ok:
                switch.set_state(state)
                return
            switch.reverting = True
            switch.set_active(not state)
            switch.reverting = False
            self.win.toast((cli.strip(err or out).strip().splitlines() or ["Could not change it"])[-1])

        cli.run(["startup", "enable" if state else "disable", item["id"]], done)
        return True


class HistoryPage(Page):
    title = "History"
    icon = "document-open-recent-symbolic"
    section = "Maintain"

    def load(self):
        super().load()
        self.set_loading("Reading history…")
        cli.run_json(["history", "--json", "--limit", "200"], self.show_history)

    def show_history(self, data, err):
        if data is None:
            self.show_error(err)
            return
        self.clear()
        sessions = list(reversed(data.get("sessions") or []))
        if not sessions:
            self.show_status("document-open-recent-symbolic", "No Activity")
            return
        ops = {}
        for op in data.get("operations") or []:
            ops.setdefault((op["command"], op["run_id"]), []).append(op)
        day, group = None, None
        for s in sessions:
            date, _, clock = s["started_at"].partition(" ")
            if date != day:
                day = date
                group = self.add_group(date)
            a = s["actions"]
            parts = [f"{a[k]} {k}" for k in ("removed", "trashed", "skipped", "failed", "other") if a[k]]
            r = Adw.ExpanderRow(title=s["command"].capitalize(), subtitle=f"{clock[:5]} · {', '.join(parts)}")
            for op in ops.get((s["command"], s["run_id"]), [])[:100]:
                child = Adw.ActionRow(title=GLib.markup_escape_text(display_path(op["path"])),
                                      subtitle=GLib.markup_escape_text(" · ".join(x for x in (op["action"], op["detail"]) if x)))
                child.set_title_lines(1)
                r.add_row(child)
            group.add(r)
        self.show_content()


PAGES = [OverviewPage, CleanPage, UninstallPage, PurgePage, InstallerPage, AnalyzePage,
         OptimizePage, SystemPage, StartupPage, HistoryPage]
