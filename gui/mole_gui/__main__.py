import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")

from .app import App  # noqa: E402

sys.exit(App().run(sys.argv[:1]))
