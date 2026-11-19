#include "desktop_integration.h"

#include <glib/gstdio.h>
#include <string.h>
#include <utime.h>

namespace {

constexpr char kIconName[] = "gundil-intercom";
constexpr int kSizes[] = {16, 24, 32, 48, 64, 128, 256, 512};
constexpr char kMarker[] = "X-Gundil-Intercom-Generated=true";

// <bundle>/data/icons: next to the executable (also inside the AppImage).
gchar* icons_dir() {
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe == nullptr) return nullptr;
  g_autofree gchar* dir = g_path_get_dirname(exe);
  return g_build_filename(dir, "data", "icons", nullptr);
}

gchar* icon_file(const gchar* dir, int size) {
  g_autofree gchar* name = g_strdup_printf("%s-%d.png", kIconName, size);
  return g_build_filename(dir, name, nullptr);
}

// Writes [contents] to [path] unless it already holds exactly that.
// Returns whether it wrote.
bool write_if_changed(const gchar* path, const gchar* contents, gsize length) {
  g_autofree gchar* old = nullptr;
  gsize old_length = 0;
  if (g_file_get_contents(path, &old, &old_length, nullptr) &&
      old_length == length && memcmp(old, contents, length) == 0) {
    return false;
  }
  g_autofree gchar* dir = g_path_get_dirname(path);
  g_mkdir_with_parents(dir, 0755);
  return g_file_set_contents(path, contents, length, nullptr);
}

// A value for Exec=: quoted, with the characters the spec reserves escaped.
gchar* exec_quote(const gchar* path) {
  GString* s = g_string_new("\"");
  for (const gchar* p = path; *p != '\0'; p++) {
    // Exec's own escape (a backslash), itself escaped as a string value:
    // a literal backslash becomes four.
    if (*p == '\\') {
      g_string_append(s, "\\\\\\\\");
      continue;
    }
    if (*p == '"' || *p == '`' || *p == '$') g_string_append(s, "\\\\");
    g_string_append_c(s, *p);
  }
  g_string_append_c(s, '"');
  return g_string_free(s, FALSE);
}

// Whether another menu entry in [apps_dir] (not [own_name]) already starts
// [exe], e.g. one made by AppImageLauncher, Gear Lever or appimaged when
// they integrated the AppImage. Such tools copy the AppImage's own entry,
// StartupWMClass included, so the taskbar icon works with theirs.
bool other_entry_runs(const gchar* apps_dir, const gchar* own_name,
                      const gchar* exe) {
  GDir* dir = g_dir_open(apps_dir, 0, nullptr);
  if (dir == nullptr) return false;
  bool found = false;
  const gchar* name;
  while (!found && (name = g_dir_read_name(dir)) != nullptr) {
    if (!g_str_has_suffix(name, ".desktop") || g_strcmp0(name, own_name) == 0) {
      continue;
    }
    g_autofree gchar* path = g_build_filename(apps_dir, name, nullptr);
    g_autoptr(GKeyFile) key_file = g_key_file_new();
    if (!g_key_file_load_from_file(key_file, path, G_KEY_FILE_NONE, nullptr)) {
      continue;
    }
    g_autofree gchar* exec = g_key_file_get_string(
        key_file, G_KEY_FILE_DESKTOP_GROUP, G_KEY_FILE_DESKTOP_KEY_EXEC,
        nullptr);
    if (exec == nullptr) continue;
    gchar** argv = nullptr;
    if (g_shell_parse_argv(exec, nullptr, &argv, nullptr)) {
      found = argv[0] != nullptr && g_strcmp0(argv[0], exe) == 0;
      g_strfreev(argv);
    }
  }
  g_dir_close(dir);
  return found;
}

}  // namespace

void desktop_integration_install() {
  const gchar* off = g_getenv("GUNDIL_NO_DESKTOP_ENTRY");
  if (off != nullptr && *off != '\0' && g_strcmp0(off, "0") != 0) return;

  g_autofree gchar* entry_name = g_strdup_printf("%s.desktop", APPLICATION_ID);
  // Installed by a package (e.g. /usr/share/applications): that one counts.
  for (const gchar* const* d = g_get_system_data_dirs(); *d != nullptr; d++) {
    g_autofree gchar* p = g_build_filename(*d, "applications", entry_name,
                                           nullptr);
    if (g_file_test(p, G_FILE_TEST_EXISTS)) return;
  }

  const gchar* data = g_get_user_data_dir();
  g_autofree gchar* entry_path =
      g_build_filename(data, "applications", entry_name, nullptr);
  // One the user made (or another tool): leave it alone.
  g_autofree gchar* existing = nullptr;
  if (g_file_get_contents(entry_path, &existing, nullptr, nullptr) &&
      strstr(existing, kMarker) == nullptr) {
    return;
  }

  // The AppImage runs from a temporary mount: $APPIMAGE is the real file.
  const gchar* appimage = g_getenv("APPIMAGE");
  g_autofree gchar* self = g_file_read_link("/proc/self/exe", nullptr);
  const gchar* exe = (appimage != nullptr && *appimage != '\0')
                         ? appimage
                         : self;
  if (exe == nullptr) return;

  // Already in the menu through another tool's entry: one is enough, so
  // remove ours (an earlier start may have written it).
  g_autofree gchar* apps_dir = g_build_filename(data, "applications", nullptr);
  if (other_entry_runs(apps_dir, entry_name, exe)) {
    if (existing != nullptr && g_unlink(entry_path) == 0) {
      g_message("Desktop entry removed (another one starts this app): %s",
                entry_path);
    }
    return;
  }

  bool icons_changed = false;
  g_autofree gchar* src_dir = icons_dir();
  g_autofree gchar* hicolor = g_build_filename(data, "icons", "hicolor",
                                               nullptr);
  if (src_dir != nullptr) {
    for (int size : kSizes) {
      g_autofree gchar* src = icon_file(src_dir, size);
      g_autofree gchar* bytes = nullptr;
      gsize length = 0;
      if (!g_file_get_contents(src, &bytes, &length, nullptr)) continue;
      g_autofree gchar* dims = g_strdup_printf("%dx%d", size, size);
      g_autofree gchar* png = g_strdup_printf("%s.png", kIconName);
      g_autofree gchar* dst =
          g_build_filename(hicolor, dims, "apps", png, nullptr);
      if (write_if_changed(dst, bytes, length)) icons_changed = true;
    }
  }
  if (icons_changed) {
    // Tells icon caches (GTK, the shell) to look again.
    utime(hicolor, nullptr);
  }

  g_autofree gchar* quoted = exec_quote(exe);
  g_autofree gchar* entry = g_strdup_printf(
      "[Desktop Entry]\n"
      "Type=Application\n"
      "Name=Gundil Intercom\n"
      "GenericName=LAN Intercom\n"
      "Comment=Two-way peer-to-peer audio intercom for your local network\n"
      "Exec=%s %%U\n"
      "TryExec=%s\n"
      "Icon=%s\n"
      "Terminal=false\n"
      "Categories=Network;Telephony;\n"
      "Keywords=intercom;voice;talk;LAN;\n"
      "StartupWMClass=%s\n"
      "StartupNotify=true\n"
      "%s\n",
      quoted, exe, kIconName, APPLICATION_ID, kMarker);
  if (write_if_changed(entry_path, entry, strlen(entry))) {
    g_message("Desktop entry written: %s", entry_path);
  }
}

void desktop_integration_set_window_icon(GtkWindow* window) {
  g_autofree gchar* dir = icons_dir();
  GList* icons = nullptr;
  if (dir != nullptr) {
    for (int size : kSizes) {
      g_autofree gchar* path = icon_file(dir, size);
      GdkPixbuf* pixbuf = gdk_pixbuf_new_from_file(path, nullptr);
      if (pixbuf != nullptr) icons = g_list_append(icons, pixbuf);
    }
  }
  if (icons == nullptr) {
    // No icon files: the theme's (installed by desktop_integration_install).
    gtk_window_set_default_icon_name(kIconName);
    gtk_window_set_icon_name(window, kIconName);
    return;
  }
  gtk_window_set_icon_list(window, icons);
  gtk_window_set_default_icon_list(icons);
  g_list_free_full(icons, g_object_unref);
}
