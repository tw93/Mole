"""The Mole window: a sidebar of tools beside the open page."""

import os

from gi.repository import Adw, Gdk, Gio, GLib, Gtk

from . import cli
from .pages import PAGES

CSS = """
.mole-tile { padding: 12px 14px; }
.mole-tag { font-size: smaller; font-weight: bold; padding: 2px 8px; border-radius: 99px;
            background: alpha(currentColor, .1); }
.mole-tag.warning { color: @warning_color; background: alpha(@warning_bg_color, .18); }
.mole-tag.success { color: @success_color; background: alpha(@success_bg_color, .18); }
levelbar block.mole-ok { background-color: @accent_bg_color; }
levelbar block.mole-warn { background-color: @warning_bg_color; }
""" + "".join(
    # A Disk Usage row's background fills to its share of the folder, one rule per whole percent.
    f".mole-fill-{p} {{ background-image: linear-gradient(to right, alpha(@accent_bg_color, .2) {p}%, transparent {p}%); }}\n"
    for p in range(101))


def version():
    try:
        with open(os.path.join(cli.ROOT, "VERSION"), encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return "unknown"


def main_menu():
    """The header bar's main menu."""
    menu = Gio.Menu()
    menu.append_section(None, mole_section())
    menu.append("About Mole", "win.about")
    return menu


def mole_section():
    section = Gio.Menu()
    section.append("Open Terminal Menu", "win.terminal")
    section.append("Update Mole", "win.update")
    section.append("Remove Mole…", "win.remove")
    return section


def menu_bar():
    """Exported over D-Bus for global menu bars (GNOME Shell extensions, KDE);
    Adwaita windows do not draw it themselves. No menu is named Mole: the
    global menu shows the app's name next to these already."""
    file_menu = Gio.Menu()
    file_menu.append_section(None, mole_section())
    quit_section = Gio.Menu()
    quit_section.append("Quit", "app.quit")
    file_menu.append_section(None, quit_section)
    view = Gio.Menu()
    sections = {}
    for cls in PAGES:
        if cls.section not in sections:
            sections[cls.section] = Gio.Menu()
            view.append_section(None, sections[cls.section])
        sections[cls.section].append(cls.title, f"win.page::{cls.__name__}")
    refresh = Gio.Menu()
    refresh.append("Refresh", "win.refresh")
    view.append_section(None, refresh)
    help_menu = Gio.Menu()
    help_menu.append("About Mole", "win.about")
    bar = Gio.Menu()
    bar.append_submenu("File", file_menu)
    bar.append_submenu("View", view)
    bar.append_submenu("Help", help_menu)
    return bar


class Window(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="Mole", default_width=1100, default_height=760)
        self.set_size_request(360, 400)
        self.pages = {cls.__name__: cls(self) for cls in PAGES}

        self.sidebar = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self.sidebar.add_css_class("navigation-sidebar")
        self.sidebar.set_header_func(self.sidebar_header)
        for page in self.pages.values():
            box = Gtk.Box(spacing=12, margin_top=2, margin_bottom=2)
            box.append(Gtk.Image(icon_name=page.icon))
            box.append(Gtk.Label(label=page.title, xalign=0, hexpand=True))
            item = Gtk.ListBoxRow(child=box)
            item.page = page
            self.sidebar.append(item)
        self.sidebar.connect("row-activated", lambda _l, r: self.open(r.page))

        side_header = Adw.HeaderBar()
        side_header.pack_end(Gtk.MenuButton(icon_name="open-menu-symbolic", menu_model=main_menu(), tooltip_text="Main Menu"))
        side_toolbar = Adw.ToolbarView(content=Gtk.ScrolledWindow(child=self.sidebar, hscrollbar_policy=Gtk.PolicyType.NEVER))
        side_toolbar.add_top_bar(side_header)
        sidebar_page = Adw.NavigationPage(title="Mole", child=side_toolbar)

        first = next(iter(self.pages.values()))
        self.split = Adw.NavigationSplitView(sidebar=sidebar_page, content=first, min_sidebar_width=220,
                                             max_sidebar_width=280)
        self.toasts = Adw.ToastOverlay(child=self.split)
        self.set_content(self.toasts)

        breakpoint = Adw.Breakpoint.new(Adw.BreakpointCondition.parse("max-width: 640sp"))
        breakpoint.add_setter(self.split, "collapsed", True)
        self.add_breakpoint(breakpoint)

        for name, callback, kind in (
            ("about", lambda *_: self.about(), None),
            ("terminal", lambda *_: self.in_terminal(), None),
            ("update", lambda *_: self.in_terminal("update"), None),
            # mo remove asks for its own confirmation in the terminal.
            ("remove", lambda *_: self.in_terminal("remove"), None),
            ("open-path", lambda _a, p: Gio.AppInfo.launch_default_for_uri(Gio.File.new_for_path(p.get_string()).get_uri(), None), "s"),
            ("trash-path", lambda _a, p: self.pages["AnalyzePage"].trash(p.get_string()), "s"),
            ("page", lambda _a, p: self.show_page(p.get_string()), "s"),
            ("refresh", lambda *_: self.split.get_content().load(), None),
        ):
            action = Gio.SimpleAction.new(name, GLib.VariantType.new(kind) if kind else None)
            action.connect("activate", callback)
            self.add_action(action)

        self.sidebar.select_row(self.sidebar.get_row_at_index(0))
        first.ensure_loaded()

    def sidebar_header(self, item, before):
        section = item.page.section
        if section and (before is None or before.page.section != section):
            label = Gtk.Label(label=section, xalign=0, margin_start=12, margin_top=12, margin_bottom=4)
            label.add_css_class("heading")
            label.add_css_class("dimmed")
            label.add_css_class("dim-label")
            item.set_header(label)
        else:
            item.set_header(None)

    def open(self, page):
        self.split.set_content(page)
        self.split.set_show_content(True)
        page.ensure_loaded()

    def show_page(self, name):
        page = self.pages[name]
        for i, item in enumerate(self.pages.values()):
            if item is page:
                self.sidebar.select_row(self.sidebar.get_row_at_index(i))
        self.open(page)

    def in_terminal(self, *args):
        if not cli.in_terminal(cli.mo_command(*args)):
            self.toast("No terminal app found")

    def toast(self, text):
        self.toasts.add_toast(Adw.Toast(title=GLib.markup_escape_text(text), timeout=4))

    def about(self):
        Adw.AboutDialog(
            application_name="Mole", application_icon="fit.mole.Mole", version=version(),
            developer_name="Mole contributors", website="https://mole.fit", issue_url="https://github.com/tw93/Mole/issues",
            license_type=Gtk.License.GPL_3_0, comments="Deep clean and maintain your Linux desktop.",
        ).present(self)


class App(Adw.Application):
    def __init__(self):
        super().__init__(application_id="fit.mole.Mole", flags=Gio.ApplicationFlags.DEFAULT_FLAGS)

    def do_startup(self):
        Adw.Application.do_startup(self)
        provider = Gtk.CssProvider()
        provider.load_from_string(CSS)
        display = Gdk.Display.get_default()
        Gtk.StyleContext.add_provider_for_display(display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        # gui/fit.mole.Mole.png, found by the app id as an unthemed icon.
        Gtk.IconTheme.get_for_display(display).add_search_path(os.path.join(cli.ROOT, "gui"))
        Gtk.Window.set_default_icon_name(self.get_application_id())
        quit_action = Gio.SimpleAction.new("quit", None)
        quit_action.connect("activate", lambda *_: self.quit())
        self.add_action(quit_action)
        self.set_accels_for_action("app.quit", ["<Control>q"])
        self.set_accels_for_action("win.refresh", ["<Control>r", "F5"])
        for i, cls in enumerate(PAGES[:10]):
            self.set_accels_for_action(f"win.page::{cls.__name__}", [f"<Control>{(i + 1) % 10}"])
        self.set_menubar(menu_bar())

    def do_activate(self):
        (self.get_active_window() or Window(self)).present()
