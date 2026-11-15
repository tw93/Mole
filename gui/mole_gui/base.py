"""Building blocks every page shares: the page frame with its loading, empty
and error states, the run dialog that shows a command's output, and a few
row helpers."""

import os

from gi.repository import Adw, Gtk, GLib, Pango

from . import cli


class Page(Adw.NavigationPage):
    """A sidebar destination: header bar, scrolled clamp, optional bottom bar."""

    title = ""
    icon = ""
    section = ""

    def __init__(self, win):
        super().__init__(title=self.title, tag=type(self).__name__)
        self.win = win
        self.loaded = False
        self.header = Adw.HeaderBar()
        self.refresh_button = Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text="Refresh")
        self.refresh_button.connect("clicked", lambda *_: self.load())
        self.header.pack_end(self.refresh_button)

        self.box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24)
        self.box.set_margin_top(12)
        self.box.set_margin_bottom(24)
        self.box.set_margin_start(12)
        self.box.set_margin_end(12)
        clamp = Adw.Clamp(maximum_size=760, child=self.box)
        scrolled = Gtk.ScrolledWindow(child=clamp, vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER)

        self.status = Adw.StatusPage()
        self.spinner = Gtk.Spinner(width_request=32, height_request=32, halign=Gtk.Align.CENTER)
        loading = Adw.StatusPage(child=self.spinner)
        self.loading = loading
        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE)
        self.stack.add_named(scrolled, "content")
        self.stack.add_named(loading, "loading")
        self.stack.add_named(self.status, "status")

        self.toolbar = Adw.ToolbarView(content=self.stack)
        self.toolbar.add_top_bar(self.header)
        self.set_child(self.toolbar)

    # Called the first time the page is shown and by the refresh button.
    def load(self):
        self.loaded = True

    def ensure_loaded(self):
        if not self.loaded:
            self.load()

    def set_loading(self, text):
        self.loading.set_title(text)
        self.spinner.start()
        self.stack.set_visible_child_name("loading")

    def show_content(self):
        self.spinner.stop()
        self.stack.set_visible_child_name("content")

    def show_status(self, icon, title, description="", child=None):
        self.spinner.stop()
        self.status.set_icon_name(icon)
        self.status.set_title(title)
        self.status.set_description(description)
        self.status.set_child(child)
        self.stack.set_visible_child_name("status")

    def show_error(self, text):
        self.show_status("dialog-warning-symbolic", "Could Not Load", GLib.markup_escape_text(text))

    def clear(self):
        while child := self.box.get_first_child():
            self.box.remove(child)

    def add_group(self, title="", description=""):
        group = Adw.PreferencesGroup(title=GLib.markup_escape_text(title), description=GLib.markup_escape_text(description))
        self.box.append(group)
        return group

    def add_bottom_bar(self):
        """A bar under the list: a summary label on the left, buttons on the right."""
        bar = Gtk.Box(spacing=12, margin_top=12, margin_bottom=12, margin_start=18, margin_end=18)
        self.summary = Gtk.Label(xalign=0, hexpand=True, ellipsize=Pango.EllipsizeMode.END)
        bar.append(self.summary)
        self.toolbar.add_bottom_bar(bar)
        self.toolbar.set_bottom_bar_style(Adw.ToolbarStyle.RAISED)
        return bar


def row(title, subtitle="", suffix=None, icon=None, activatable_widget=None):
    r = Adw.ActionRow(title=GLib.markup_escape_text(title), subtitle=GLib.markup_escape_text(subtitle))
    r.set_subtitle_lines(2)
    if icon:
        r.add_prefix(Gtk.Image(icon_name=icon))
    if suffix is not None:
        r.add_suffix(suffix if isinstance(suffix, Gtk.Widget) else dim_label(suffix))
    if activatable_widget is not None:
        r.set_activatable_widget(activatable_widget)
    return r


def dim_label(text, numeric=True):
    label = Gtk.Label(label=text, valign=Gtk.Align.CENTER)
    label.add_css_class("dimmed")
    label.add_css_class("dim-label")
    if numeric:
        label.add_css_class("numeric")
    return label


def tag(text, kind=""):
    """A small pill: kind is warning, success, error or empty."""
    label = Gtk.Label(label=text, valign=Gtk.Align.CENTER)
    label.add_css_class("mole-tag")
    if kind:
        label.add_css_class(kind)
    return label


def flat_button(label, callback, style=""):
    button = Gtk.Button(label=label, valign=Gtk.Align.CENTER)
    if style:
        button.add_css_class(style)
    button.connect("clicked", lambda *_: callback())
    return button


def confirm(win, heading, body, action_label, on_confirm, destructive=True):
    """An alert whose buttons answer the heading; Escape and Return cancel."""
    dialog = Adw.AlertDialog(heading=heading, body=body)
    dialog.add_response("cancel", "Cancel")
    dialog.add_response("go", action_label)
    dialog.set_response_appearance(
        "go", Adw.ResponseAppearance.DESTRUCTIVE if destructive else Adw.ResponseAppearance.SUGGESTED
    )
    dialog.set_default_response("cancel")
    dialog.set_close_response("cancel")
    dialog.connect("response", lambda _d, response: response == "go" and on_confirm())
    dialog.present(win)


def output_view(buffer):
    """A read-only monospace view of a command's output."""
    return Gtk.TextView(buffer=buffer, editable=False, monospace=True, cursor_visible=False,
                        wrap_mode=Gtk.WrapMode.WORD_CHAR, top_margin=12, bottom_margin=12,
                        left_margin=12, right_margin=12)


class RunDialog(Adw.Dialog):
    """Show a command's output line by line while it runs."""

    def __init__(self, win, title, argv, on_done=None):
        super().__init__(title=title, content_width=640, content_height=460)
        self.on_done = on_done
        header = Adw.HeaderBar(show_end_title_buttons=False)
        self.spinner = Gtk.Spinner(spinning=True)
        header.pack_start(self.spinner)
        self.stop_button = Gtk.Button(label="Stop")
        self.stop_button.connect("clicked", lambda *_: self.proc and cli.stop(self.proc))
        header.pack_start(self.stop_button)
        self.close_button = Gtk.Button(label="Close", sensitive=False)
        self.close_button.add_css_class("suggested-action")
        self.close_button.connect("clicked", lambda *_: self.close())
        header.pack_end(self.close_button)
        self.buffer = Gtk.TextBuffer()
        view = output_view(self.buffer)
        self.view = view
        scrolled = Gtk.ScrolledWindow(child=view, vexpand=True)
        toolbar = Adw.ToolbarView(content=scrolled)
        toolbar.add_top_bar(header)
        self.set_child(toolbar)
        self.end_mark = self.buffer.create_mark(None, self.buffer.get_end_iter(), False)
        self.set_can_close(False)
        self.present(win)
        self.proc = cli.stream(argv, self.append, self.finish)

    def append(self, line):
        self.buffer.insert(self.buffer.get_end_iter(), line + "\n")
        self.view.scroll_mark_onscreen(self.end_mark)

    def finish(self, ok):
        self.spinner.set_spinning(False)
        self.spinner.set_visible(False)
        self.stop_button.set_visible(False)
        self.close_button.set_sensitive(True)
        self.set_can_close(True)
        self.ok = ok
        if self.on_done:
            self.on_done(ok)


class LineFileDialog(Adw.Dialog):
    """Edit a one-entry-per-line config file the CLI reads (purge_paths,
    whitelist). Comment lines are kept; the CLI still validates each entry."""

    def __init__(self, win, title, path, description, folders=True, typed_hint="", on_saved=None):
        super().__init__(title=title, content_width=560, content_height=520)
        self.win, self.path, self.on_saved = win, path, on_saved
        try:
            self.lines = cli.read_config(path)
        except OSError as e:
            # Saving over a file that could not be read would drop its entries.
            win.toast(f"Cannot read {os.path.basename(path)}: {e.strerror}")
            return
        entries = [ln.strip() for ln in self.lines if cli.is_entry(ln)]

        self.group = Adw.PreferencesGroup(description=GLib.markup_escape_text(description))
        self.rows = []
        for entry in entries:
            self.add_entry(entry)
        if folders:
            add = Gtk.Button(icon_name="folder-new-symbolic", tooltip_text="Add Folder", valign=Gtk.Align.CENTER)
            add.add_css_class("flat")
            add.connect("clicked", lambda *_: self.pick_folder())
            self.group.set_header_suffix(add)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18, margin_top=12, margin_bottom=24,
                      margin_start=12, margin_end=12)
        box.append(self.group)
        if typed_hint:
            typed = Adw.EntryRow(title=typed_hint, show_apply_button=True)
            typed.connect("apply", lambda r: (self.add_entry(r.get_text().strip()) if r.get_text().strip() else None, r.set_text("")))
            extra = Adw.PreferencesGroup()
            extra.add(typed)
            box.append(extra)
        header = Adw.HeaderBar(show_end_title_buttons=False, show_start_title_buttons=False)
        cancel = Gtk.Button(label="Cancel")
        cancel.connect("clicked", lambda *_: self.close())
        save = Gtk.Button(label="Save")
        save.add_css_class("suggested-action")
        save.connect("clicked", lambda *_: self.save())
        header.pack_start(cancel)
        header.pack_end(save)
        toolbar = Adw.ToolbarView(content=Gtk.ScrolledWindow(child=Adw.Clamp(child=box), vexpand=True))
        toolbar.add_top_bar(header)
        self.set_child(toolbar)
        self.present(win)

    def add_entry(self, entry):
        if any(r.entry == entry for r in self.rows):
            return
        r = Adw.ActionRow(title=GLib.markup_escape_text(entry))
        r.entry = entry
        remove = Gtk.Button(icon_name="list-remove-symbolic", tooltip_text="Remove", valign=Gtk.Align.CENTER)
        remove.add_css_class("flat")
        remove.connect("clicked", lambda *_: (self.group.remove(r), self.rows.remove(r)))
        r.add_suffix(remove)
        self.group.add(r)
        self.rows.append(r)

    def pick_folder(self):
        def done(d, result):
            try:
                folder = d.select_folder_finish(result)
            except GLib.Error:
                return
            path = folder.get_path() if folder else None
            if path:
                home = GLib.get_home_dir()
                self.add_entry("~" + path[len(home):] if path == home or path.startswith(home + "/") else path)

        Gtk.FileDialog(title="Choose a Folder").select_folder(self.win, None, done)

    def save(self):
        try:
            cli.write_config(self.path, cli.merge_entries(self.lines, [r.entry for r in self.rows]))
        except OSError as e:
            self.win.toast(f"Cannot save {os.path.basename(self.path)}: {e.strerror}")
            return
        self.close()
        if self.on_saved:
            self.on_saved()
