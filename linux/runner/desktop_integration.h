#ifndef RUNNER_DESKTOP_INTEGRATION_H_
#define RUNNER_DESKTOP_INTEGRATION_H_

#include <gtk/gtk.h>

// Puts the app in the desktop's menu with its icon, for the AppImage and
// the tar.gz (which aren't installed by a package): writes
// ~/.local/share/applications/<APPLICATION_ID>.desktop and the icons in
// ~/.local/share/icons/hicolor. Docks and taskbars (GNOME, KDE on Wayland)
// show a window's icon only through such an entry. Does nothing when a
// package already installed one, or with GUNDIL_NO_DESKTOP_ENTRY=1. When
// another entry (AppImageLauncher, Gear Lever) already starts the same
// file, removes its own instead, so the menu doesn't list the app twice.
void desktop_integration_install();

// Gives [window] the app's icon in every size there is (X11 taskbars use
// it directly).
void desktop_integration_set_window_icon(GtkWindow* window);

#endif  // RUNNER_DESKTOP_INTEGRATION_H_
