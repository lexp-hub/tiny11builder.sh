#!/usr/bin/env python3
"""
tiny11gui.py — Native GTK4 / Libadwaita graphical interface for Tiny11 Builder on Linux.
Enables configuring and building debloated, lightweight Windows 11 ISO images
without requiring a Windows installation or Microsoft DISM.
"""

import json
import os
import re
import signal
import subprocess
import sys
import threading
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("Gio", "2.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk

SCRIPT_DIR = Path(__file__).resolve().parent
BUILDER_SCRIPT = SCRIPT_DIR / "tiny11maker.sh"
RECIPES_DIR = SCRIPT_DIR / "recipes"


class Tiny11App(Adw.Application):
    def __init__(self):
        super().__init__(
            application_id="io.github.lexp_hub.tiny11builder",
            flags=Gio.ApplicationFlags.FLAGS_NONE,
        )

    def do_activate(self):
        display = Gdk.Display.get_default()
        if display:
            icon_theme = Gtk.IconTheme.get_for_display(display)
            icon_theme.add_search_path(str(SCRIPT_DIR / "data"))
        win = self.props.active_window
        if not win:
            win = Tiny11Window(self)
        win.present()


class Tiny11Window(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="Tiny11 Builder")
        self.set_default_size(880, 720)

        self.builder_proc = None
        self.build_thread = None
        self.recipe_data = {}
        self.source_iso_path = None
        self.final_iso_path = None

        # Toast overlay for alerts and feedback
        self.toast_overlay = Adw.ToastOverlay()
        self.set_content(self.toast_overlay)

        # Main Layout Box
        main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.toast_overlay.set_child(main_box)

        # HeaderBar
        self.header_bar = Adw.HeaderBar()
        self.header_title = Adw.WindowTitle(
            title="Tiny11 Builder",
            subtitle="Windows 11 Image Streamliner for Linux",
        )
        self.header_bar.set_title_widget(self.header_title)

        # Main Menu Button
        menu_btn = Gtk.MenuButton()
        menu_btn.set_icon_name("open-menu-symbolic")
        menu_btn.set_tooltip_text("Main menu")
        menu = Gio.Menu()
        menu.append("About Tiny11 Builder", "app.about")
        menu.append("GitHub Repository", "app.github")
        menu_btn.set_menu_model(menu)
        self.header_bar.pack_end(menu_btn)

        # Register menu actions
        about_act = Gio.SimpleAction.new("about", None)
        about_act.connect("activate", self.on_about_clicked)
        app.add_action(about_act)

        gh_act = Gio.SimpleAction.new("github", None)
        gh_act.connect(
            "activate",
            lambda *_: Gtk.show_uri(
                self,
                "https://github.com/lexp-hub/tiny11builder.sh",
                Gdk.CURRENT_TIME,
            ),
        )
        app.add_action(gh_act)

        main_box.append(self.header_bar)

        # View Stack for navigation between wizard steps
        self.stack = Adw.ViewStack()
        main_box.append(self.stack)

        # Setup pages
        self.setup_config_page()
        self.setup_building_page()
        self.setup_complete_page()

        self.stack.set_visible_child_name("config")

    # =========================================================================
    # PAGE 1: CONFIGURATION & OPTIONS
    # =========================================================================
    def setup_config_page(self):
        page = Adw.PreferencesPage()

        # Group 1: Source & Output paths
        grp_paths = Adw.PreferencesGroup(
            title="Files and Directories",
            description="Select the source Windows 11 ISO image, target destination, and workspace.",
        )
        page.add(grp_paths)

        # Source ISO Row
        self.row_source = Adw.ActionRow(
            title="Source Windows 11 ISO",
            subtitle="No ISO image selected",
            icon_name="drive-removable-media-symbolic",
        )
        btn_browse_source = Gtk.Button(label="Browse...")
        btn_browse_source.add_css_class("flat")
        btn_browse_source.set_valign(Gtk.Align.CENTER)
        btn_browse_source.connect("clicked", self.on_choose_source_iso)
        self.row_source.add_suffix(btn_browse_source)
        self.row_source.set_activatable_widget(btn_browse_source)
        grp_paths.add(self.row_source)

        # Output ISO Row
        default_out = str(Path.home() / "tiny11.iso")
        self.row_output = Adw.ActionRow(
            title="Target ISO Destination",
            subtitle=default_out,
            icon_name="media-optical-symbolic",
        )
        self.output_iso_path = default_out
        btn_browse_out = Gtk.Button(label="Change...")
        btn_browse_out.add_css_class("flat")
        btn_browse_out.set_valign(Gtk.Align.CENTER)
        btn_browse_out.connect("clicked", self.on_choose_output_iso)
        self.row_output.add_suffix(btn_browse_out)
        self.row_output.set_activatable_widget(btn_browse_out)
        grp_paths.add(self.row_output)

        # Temporary Workspace Row
        default_work = str(Path.home() / "tiny11-work")
        self.row_work = Adw.ActionRow(
            title="Temporary Workspace Directory",
            subtitle=default_work,
            icon_name="folder-symbolic",
        )
        self.work_dir_path = default_work
        btn_browse_work = Gtk.Button(label="Change...")
        btn_browse_work.add_css_class("flat")
        btn_browse_work.set_valign(Gtk.Align.CENTER)
        btn_browse_work.connect("clicked", self.on_choose_work_dir)
        self.row_work.add_suffix(btn_browse_work)
        self.row_work.set_activatable_widget(btn_browse_work)
        grp_paths.add(self.row_work)

        # Windows Edition Dropdown
        self.edition_model = Gtk.StringList.new([
            "Windows 11 Pro (Index 6 - Recommended)",
            "Windows 11 Home (Index 1)",
            "Windows 11 Pro N (Index 7)",
            "Windows 11 Home N (Index 2)",
            "Windows 11 Enterprise (Index 3)",
            "Windows 11 Education (Index 4)",
            "Custom / Manual Index...",
        ])
        self.row_edition = Adw.ComboRow(
            title="Windows 11 Edition",
            subtitle="SKU index inside install.wim",
            model=self.edition_model,
            icon_name="computer-symbolic",
        )
        self.row_edition.set_selected(0)
        grp_paths.add(self.row_edition)

        # Group 2: Presets & Recipes
        grp_presets = Adw.PreferencesGroup(
            title="Presets and Recipes",
            description="Quickly apply predefined templates or load a custom recipe JSON file.",
        )
        page.add(grp_presets)

        preset_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        preset_box.set_margin_top(4)
        preset_box.set_margin_bottom(4)
        preset_box.set_halign(Gtk.Align.CENTER)

        btn_preset_std = Gtk.Button(label="Tiny11 Standard")
        btn_preset_std.add_css_class("pill")
        btn_preset_std.connect("clicked", lambda *_: self.apply_preset("standard"))
        preset_box.append(btn_preset_std)

        btn_preset_min = Gtk.Button(label="Minimal / Core")
        btn_preset_min.add_css_class("pill")
        btn_preset_min.connect("clicked", lambda *_: self.apply_preset("minimal"))
        preset_box.append(btn_preset_min)

        btn_preset_cons = Gtk.Button(label="Conservative")
        btn_preset_cons.add_css_class("pill")
        btn_preset_cons.connect("clicked", lambda *_: self.apply_preset("conservative"))
        preset_box.append(btn_preset_cons)

        btn_load_recipe = Gtk.Button(label="Load JSON Recipe...")
        btn_load_recipe.add_css_class("pill")
        btn_load_recipe.connect("clicked", self.on_load_recipe_file)
        preset_box.append(btn_load_recipe)

        row_preset = Adw.ActionRow()
        row_preset.set_child(preset_box)
        grp_presets.add(row_preset)

        # Group 3: Components to remove
        grp_bloat = Adw.PreferencesGroup(
            title="Components to Remove",
            description="Choose which default packages and bundled apps should be stripped from the image.",
        )
        page.add(grp_bloat)

        self.sw_bloat = Adw.SwitchRow(
            title="Remove UWP Bloatware Apps",
            subtitle="Clipchamp, Solitaire, Bing News, Weather, Xbox, Teams, GetHelp, and sponsored apps",
            active=True,
            icon_name="user-trash-symbolic",
        )
        grp_bloat.add(self.sw_bloat)

        self.sw_edge = Adw.SwitchRow(
            title="Remove Microsoft Edge",
            subtitle="Remove Edge browser, EdgeUpdate, EdgeCore, and residual files",
            active=True,
            icon_name="web-browser-symbolic",
        )
        grp_bloat.add(self.sw_edge)

        self.sw_onedrive = Adw.SwitchRow(
            title="Remove OneDrive Setup",
            subtitle="Remove the automatic OneDrive installer executable from system files",
            active=True,
            icon_name="folder-remote-symbolic",
        )
        grp_bloat.add(self.sw_onedrive)

        self.sw_copilot = Adw.SwitchRow(
            title="Disable Microsoft Copilot",
            subtitle="Turn off system-wide Copilot integration and linked applications",
            active=True,
            icon_name="system-help-symbolic",
        )
        grp_bloat.add(self.sw_copilot)

        self.sw_telemetry = Adw.SwitchRow(
            title="Disable Telemetry and CEIP",
            subtitle="Remove diagnostic scheduled tasks and disable telemetry in registry hives",
            active=True,
            icon_name="security-high-symbolic",
        )
        grp_bloat.add(self.sw_telemetry)

        # Group 4: Hardware Requirements & OOBE Bypasses
        grp_bypass = Adw.PreferencesGroup(
            title="System Requirements and Setup Bypasses",
            description="Enable installation on older hardware, virtual machines, and with local accounts.",
        )
        page.add(grp_bypass)

        self.sw_bypass_hw = Adw.SwitchRow(
            title="Bypass Hardware Checks (TPM 2.0 / CPU / RAM / SecureBoot)",
            subtitle="Allows Windows 11 installation on non-compliant PCs and older systems",
            active=True,
            icon_name="emblem-system-symbolic",
        )
        grp_bypass.add(self.sw_bypass_hw)

        self.sw_bypass_nro = Adw.SwitchRow(
            title="Bypass Microsoft Account Requirement (BypassNRO)",
            subtitle="Enables setting up Windows using an offline local account during OOBE",
            active=True,
            icon_name="avatar-default-symbolic",
        )
        grp_bypass.add(self.sw_bypass_nro)

        self.sw_autounattend = Adw.SwitchRow(
            title="Inject autounattend.xml",
            subtitle="Automates bypassing hardware checks during the initial setup loader",
            active=True,
            icon_name="document-properties-symbolic",
        )
        grp_bypass.add(self.sw_autounattend)

        # Start Build Button Row
        btn_start_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        btn_start_box.set_margin_top(18)
        btn_start_box.set_margin_bottom(24)

        self.btn_start = Gtk.Button(label="Build Tiny11 ISO")
        self.btn_start.add_css_class("suggested-action")
        self.btn_start.add_css_class("pill")
        self.btn_start.set_halign(Gtk.Align.CENTER)
        self.btn_start.set_size_request(320, 50)
        self.btn_start.connect("clicked", self.on_start_build_clicked)
        btn_start_box.append(self.btn_start)

        page.add(Adw.PreferencesGroup())
        scrolled = Gtk.ScrolledWindow()
        scrolled.set_vexpand(True)
        scrolled.set_child(page)

        wrapper_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        wrapper_box.append(scrolled)
        wrapper_box.append(btn_start_box)

        self.stack.add_named(wrapper_box, "config")

    # =========================================================================
    # PAGE 2: BUILDING & LIVE LOGS
    # =========================================================================
    def setup_building_page(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        box.set_margin_top(24)
        box.set_margin_bottom(24)
        box.set_margin_start(24)
        box.set_margin_end(24)

        # Status Header Card
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        card.add_css_class("card")
        card.set_margin_bottom(8)
        card.set_margin_top(4)

        top_info = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        top_info.set_margin_top(14)
        top_info.set_margin_bottom(8)
        top_info.set_margin_start(16)
        top_info.set_margin_end(16)

        self.spinner = Gtk.Spinner()
        self.spinner.set_size_request(32, 32)
        top_info.append(self.spinner)

        lbl_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.lbl_build_title = Gtk.Label(label="Building Tiny11 ISO Image...")
        self.lbl_build_title.add_css_class("title-3")
        self.lbl_build_title.set_xalign(0)
        lbl_box.append(self.lbl_build_title)

        self.lbl_step = Gtk.Label(label="Initializing build process...")
        self.lbl_step.add_css_class("dim-label")
        self.lbl_step.set_xalign(0)
        lbl_box.append(self.lbl_step)
        top_info.append(lbl_box)
        card.append(top_info)

        # Progress bar
        self.prog_bar = Gtk.ProgressBar()
        self.prog_bar.set_margin_start(16)
        self.prog_bar.set_margin_end(16)
        self.prog_bar.set_margin_bottom(14)
        self.prog_bar.set_fraction(0.0)
        card.append(self.prog_bar)
        box.append(card)

        # Live Terminal Log View
        lbl_log = Gtk.Label(label="Build Output:")
        lbl_log.set_xalign(0)
        lbl_log.add_css_class("heading")
        box.append(lbl_log)

        scroll_log = Gtk.ScrolledWindow()
        scroll_log.set_vexpand(True)
        scroll_log.add_css_class("card")

        self.text_buffer = Gtk.TextBuffer()
        self.text_view = Gtk.TextView.new_with_buffer(self.text_buffer)
        self.text_view.set_editable(False)
        self.text_view.set_cursor_visible(False)
        self.text_view.set_monospace(True)
        self.text_view.set_left_margin(12)
        self.text_view.set_right_margin(12)
        self.text_view.set_top_margin(12)
        self.text_view.set_bottom_margin(12)
        scroll_log.set_child(self.text_view)
        box.append(scroll_log)

        # Bottom Buttons
        bottom_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        bottom_box.set_halign(Gtk.Align.END)
        self.btn_cancel = Gtk.Button(label="Cancel Build")
        self.btn_cancel.add_css_class("destructive-action")
        self.btn_cancel.connect("clicked", self.on_cancel_build_clicked)
        bottom_box.append(self.btn_cancel)
        box.append(bottom_box)

        self.stack.add_named(box, "building")

    # =========================================================================
    # PAGE 3: COMPLETION / SUCCESS
    # =========================================================================
    def setup_complete_page(self):
        self.status_page = Adw.StatusPage()
        self.status_page.set_icon_name("emblem-ok-symbolic")
        self.status_page.set_title("Tiny11 ISO Created Successfully")
        self.status_page.set_description(
            "The debloated Windows 11 image is ready.\n"
            "You can use it in a virtual machine or write it to a bootable USB drive."
        )

        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        card.add_css_class("card")
        card.set_margin_top(16)
        card.set_margin_bottom(24)
        card.set_margin_start(40)
        card.set_margin_end(40)

        self.lbl_iso_path = Gtk.Label()
        self.lbl_iso_path.set_margin_top(12)
        self.lbl_iso_path.set_selectable(True)
        self.lbl_iso_path.add_css_class("title-4")
        card.append(self.lbl_iso_path)

        self.lbl_iso_size = Gtk.Label()
        self.lbl_iso_size.set_margin_bottom(12)
        self.lbl_iso_size.add_css_class("dim-label")
        card.append(self.lbl_iso_size)

        btn_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        btn_box.set_halign(Gtk.Align.CENTER)
        btn_box.set_margin_bottom(12)

        btn_open = Gtk.Button(label="Open Containing Folder")
        btn_open.add_css_class("suggested-action")
        btn_open.add_css_class("pill")
        btn_open.connect("clicked", self.on_open_output_folder)
        btn_box.append(btn_open)

        btn_copy = Gtk.Button(label="Copy ISO Path")
        btn_copy.add_css_class("pill")
        btn_copy.connect("clicked", self.on_copy_iso_path)
        btn_box.append(btn_copy)

        btn_new = Gtk.Button(label="Build Another ISO")
        btn_new.add_css_class("pill")
        btn_new.connect("clicked", lambda *_: self.stack.set_visible_child_name("config"))
        btn_box.append(btn_new)

        card.append(btn_box)
        self.status_page.set_child(card)

        self.stack.add_named(self.status_page, "complete")

    # =========================================================================
    # EVENT HANDLERS & FILE CHOOSERS
    # =========================================================================
    def on_choose_source_iso(self, _btn):
        dialog = Gtk.FileDialog(title="Select Windows 11 Source ISO")
        f_filter = Gtk.FileFilter()
        f_filter.set_name("ISO Image Files (*.iso)")
        f_filter.add_pattern("*.iso")
        f_filter.add_pattern("*.ISO")
        filters = Gio.ListStore.new(Gtk.FileFilter)
        filters.append(f_filter)
        dialog.set_filters(filters)

        def cb(d, res):
            try:
                f = d.open_finish(res)
                p = f.get_path()
                if p:
                    self.row_source.set_subtitle(p)
                    self.source_iso_path = p
                    self.show_toast(f"Selected: {Path(p).name}")
            except Exception:
                pass

        dialog.open(self, None, cb)

    def on_choose_output_iso(self, _btn):
        dialog = Gtk.FileDialog(title="Destination Tiny11 ISO")
        dialog.set_initial_name("tiny11.iso")

        def cb(d, res):
            try:
                f = d.save_finish(res)
                p = f.get_path()
                if p:
                    if not p.endswith(".iso"):
                        p += ".iso"
                    self.row_output.set_subtitle(p)
                    self.output_iso_path = p
            except Exception:
                pass

        dialog.save(self, None, cb)

    def on_choose_work_dir(self, _btn):
        dialog = Gtk.FileDialog(title="Select Workspace Directory")

        def cb(d, res):
            try:
                f = d.select_folder_finish(res)
                p = f.get_path()
                if p:
                    self.row_work.set_subtitle(p)
                    self.work_dir_path = p
            except Exception:
                pass

        dialog.select_folder(self, None, cb)

    def on_load_recipe_file(self, _btn):
        dialog = Gtk.FileDialog(title="Load JSON Recipe")
        f_filter = Gtk.FileFilter()
        f_filter.set_name("JSON Recipe Files (*.json)")
        f_filter.add_pattern("*.json")
        filters = Gio.ListStore.new(Gtk.FileFilter)
        filters.append(f_filter)
        dialog.set_filters(filters)

        def cb(d, res):
            try:
                f = d.open_finish(res)
                p = f.get_path()
                if p:
                    self.load_recipe(p)
            except Exception:
                pass

        dialog.open(self, None, cb)

    def apply_preset(self, name):
        recipe_file = RECIPES_DIR / f"tiny11-{name}.json"
        if recipe_file.exists():
            self.load_recipe(str(recipe_file))
        else:
            if name == "standard":
                self.sw_bloat.set_active(True)
                self.sw_edge.set_active(True)
                self.sw_onedrive.set_active(True)
                self.sw_copilot.set_active(True)
                self.sw_telemetry.set_active(True)
                self.sw_bypass_hw.set_active(True)
                self.sw_bypass_nro.set_active(True)
                self.show_toast("Applied preset: Tiny11 Standard")
            elif name == "conservative":
                self.sw_bloat.set_active(True)
                self.sw_edge.set_active(False)
                self.sw_onedrive.set_active(False)
                self.sw_copilot.set_active(False)
                self.sw_telemetry.set_active(True)
                self.sw_bypass_hw.set_active(True)
                self.sw_bypass_nro.set_active(True)
                self.show_toast("Applied preset: Conservative")
            elif name == "minimal":
                self.sw_bloat.set_active(True)
                self.sw_edge.set_active(True)
                self.sw_onedrive.set_active(True)
                self.sw_copilot.set_active(True)
                self.sw_telemetry.set_active(True)
                self.sw_bypass_hw.set_active(True)
                self.sw_bypass_nro.set_active(True)
                self.show_toast("Applied preset: Minimal / Core")

    def load_recipe(self, path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)

            opts = data.get("SelectedOptions", [])
            if opts:
                self.sw_bloat.set_active(any(x in opts for x in ["solitaire", "xbox", "teams", "media"]))
                self.sw_edge.set_active("edge" in opts or "edge-files" in opts)
                self.sw_onedrive.set_active("onedrive" in opts or "onedrive-files" in opts)
                self.sw_copilot.set_active("copilot" in opts or "copilot-app" in opts)
                self.sw_telemetry.set_active("privacy" in opts or "ads" in opts)
                self.sw_bypass_hw.set_active("hardware-bypass" in opts)
                self.sw_bypass_nro.set_active("oobe" in opts or data.get("PreferLocalAccount", False))
            else:
                self.sw_bloat.set_active(data.get("remove_bloatware", True))
                self.sw_edge.set_active(data.get("remove_edge", True))
                self.sw_onedrive.set_active(data.get("remove_onedrive", True))
                self.sw_copilot.set_active(data.get("remove_copilot", True))
                self.sw_telemetry.set_active(data.get("remove_telemetry", True))
                self.sw_bypass_hw.set_active(data.get("bypass_hardware", True))
                self.sw_bypass_nro.set_active(data.get("bypass_nro", True))
                self.sw_autounattend.set_active(data.get("include_autounattend", True))

            name = data.get("name", Path(path).stem)
            self.show_toast(f"Recipe loaded: {name}")
        except Exception as e:
            self.show_toast(f"Error loading recipe: {e}")

    def show_toast(self, text):
        toast = Adw.Toast.new(text)
        self.toast_overlay.add_toast(toast)

    # =========================================================================
    # BUILD EXECUTION & PROGRESS
    # =========================================================================
    def get_selected_edition_index(self):
        sel = self.row_edition.get_selected()
        mapping = {
            0: 6,  # Pro
            1: 1,  # Home
            2: 7,  # Pro N
            3: 2,  # Home N
            4: 3,  # Enterprise
            5: 4,  # Education
        }
        return mapping.get(sel, 6)

    def on_start_build_clicked(self, _btn):
        source = getattr(self, "source_iso_path", None)
        if not source or not Path(source).exists():
            self.show_toast("Please select a valid Windows 11 ISO image first.")
            return

        out_iso = getattr(self, "output_iso_path", str(Path.home() / "tiny11.iso"))
        work_dir = getattr(self, "work_dir_path", str(Path.home() / "tiny11-work"))
        index = self.get_selected_edition_index()

        cmd = [
            str(BUILDER_SCRIPT),
            "-s", str(source),
            "-o", str(out_iso),
            "-i", str(index),
            "-w", str(work_dir),
            "-y",
        ]

        if not self.sw_bloat.get_active():
            cmd.append("--keep-bloat")
        if not self.sw_edge.get_active():
            cmd.append("--keep-edge")
        if not self.sw_onedrive.get_active():
            cmd.append("--keep-onedrive")
        if not self.sw_copilot.get_active():
            cmd.append("--keep-copilot")
        if not self.sw_telemetry.get_active():
            cmd.append("--keep-telemetry")
        if not self.sw_bypass_hw.get_active():
            cmd.append("--no-bypass-hw")
        if not self.sw_bypass_nro.get_active():
            cmd.append("--no-bypass-nro")
        if not self.sw_autounattend.get_active():
            cmd.append("--no-autounattend")

        # Reset UI on building page
        self.text_buffer.set_text("")
        self.prog_bar.set_fraction(0.0)
        self.spinner.start()
        self.lbl_step.set_text("Starting build process...")
        self.btn_cancel.set_sensitive(True)
        self.stack.set_visible_child_name("building")

        # Start thread
        self.build_thread = threading.Thread(
            target=self._run_build_process,
            args=(cmd, out_iso),
            daemon=True,
        )
        self.build_thread.start()

    def _run_build_process(self, cmd, out_iso):
        try:
            self.builder_proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                preexec_fn=os.setsid,
            )

            for line in iter(self.builder_proc.stdout.readline, ""):
                if not line:
                    break
                GLib.idle_add(self._handle_build_output, line)

            self.builder_proc.stdout.close()
            ret_code = self.builder_proc.wait()
            GLib.idle_add(self._handle_build_finished, ret_code, out_iso)

        except Exception as e:
            GLib.idle_add(self._handle_build_finished, -1, str(e))

    def _handle_build_output(self, line):
        clean_line = re.sub(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])", "", line)

        # Check for progress marker
        prog_match = re.match(r"^\[PROGRESS\]\s+(\d+)\s+(.+)$", clean_line.strip())
        if prog_match:
            pct = int(prog_match.group(1))
            step = prog_match.group(2)
            self.prog_bar.set_fraction(pct / 100.0)
            self.lbl_step.set_text(step)
            return False

        # Append to terminal log
        end_iter = self.text_buffer.get_end_iter()
        self.text_buffer.insert(end_iter, clean_line)

        # Scroll to bottom
        mark = self.text_buffer.create_mark(None, self.text_buffer.get_end_iter(), False)
        self.text_view.scroll_to_mark(mark, 0.05, True, 0.0, 1.0)
        return False

    def _handle_build_finished(self, ret_code, out_iso):
        self.spinner.stop()
        self.btn_cancel.set_sensitive(False)

        if ret_code == 0 and Path(out_iso).exists():
            size_gb = Path(out_iso).stat().st_size / (1024 * 1024 * 1024)
            self.lbl_iso_path.set_text(f"File: {out_iso}")
            self.lbl_iso_size.set_text(f"Final size: {size_gb:.2f} GB")
            self.final_iso_path = out_iso
            self.stack.set_visible_child_name("complete")
        else:
            self.lbl_step.set_text("Process stopped or completed with an error.")
            self.show_toast(f"Build failed with exit code {ret_code}")

    def on_cancel_build_clicked(self, _btn):
        if self.builder_proc and self.builder_proc.poll() is None:
            try:
                os.killpg(os.getpgid(self.builder_proc.pid), signal.SIGTERM)
                self.show_toast("Cancellation requested...")
                self.btn_cancel.set_sensitive(False)
            except Exception as e:
                self.show_toast(f"Error cancelling process: {e}")

    def on_open_output_folder(self, _btn):
        path = getattr(self, "final_iso_path", self.output_iso_path)
        folder = Path(path).parent
        try:
            Gio.AppInfo.launch_default_for_uri(folder.as_uri(), None)
        except Exception:
            subprocess.Popen(["xdg-open", str(folder)])

    def on_copy_iso_path(self, _btn):
        path = getattr(self, "final_iso_path", self.output_iso_path)
        display = Gdk.Display.get_default()
        if display:
            display.get_clipboard().set(path)
            self.show_toast("ISO path copied to clipboard.")

    def on_about_clicked(self, *_):
        about = Adw.AboutDialog()
        about.set_application_name("Tiny11 Builder")
        about.set_application_icon("io.github.lexp_hub.tiny11builder")
        about.set_version("0.2.0-linux")
        about.set_developer_name("lexp-hub and ntdevlabs")
        about.set_comments(
            "Open-source utility for creating debloated, lightweight Windows 11 images "
            "with removed telemetry and bypassed hardware requirements directly on Linux."
        )
        about.set_website("https://github.com/lexp-hub/tiny11builder.sh")
        about.set_issue_url("https://github.com/lexp-hub/tiny11builder.sh/issues")
        about.set_license_type(Gtk.License.MIT_X11)
        about.present(self)


def main():
    app = Tiny11App()
    return app.run(sys.argv)


if __name__ == "__main__":
    sys.exit(main())
