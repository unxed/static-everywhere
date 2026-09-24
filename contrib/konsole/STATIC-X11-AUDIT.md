# Static X11 backend ownership

Source inspected before changing the recipe: KWindowSystem v6.30.0,
commit 802629c63985e29f8288256b225e97419423c7a6 from
https://invent.kde.org/frameworks/kwindowsystem.git.

The top-level CMakeLists requires ECM 6.30 and Qt Gui >= 6.9 (GuiPrivate
with Qt >= 6.10). X11 enables X11 and XCB/XCB, KEYSYMS, RES and ICCCM.
QML and Wayland are separate optional branches, disabled by this recipe.
The framework target already links X11, Xfixes, XCB, RES, KEYSYMS and
GuiPrivate and compiles kxutils.cpp. The X11 MODULE adds effects, shadows,
window-system implementation and plugin.cpp, linking back to the framework.
Its generated moc_plugin.cpp carries the Qt plugin entry point and metadata.
The public X11 header installation is independent of the plugin binary.

The previous overlay added those four sources and Q_IMPORT_PLUGIN to the
framework while retaining the MODULE. Linking the MODULE pulled its own
plugin definitions back from libKF6WindowSystem.a and failed with duplicate
X11Plugin symbols. A configure-only mock without the MODULE missed this.

The pinned patch gives the backend exactly one owner: the static framework
with QT_STATICPLUGIN and Q_IMPORT_PLUGIN, or the upstream MODULE for shared
builds. Header installation remains common. kxutils.cpp retains one owner
in the static branch; the framework's existing link interface carries the
backend's dependencies to installed consumers. The patch was generated
directly by git diff from the pinned checkout, not edited as patch text.
The hook rejects a different checkout and tolerates reconfiguration.

CI preflight applies the patch to the exact clean source twice, executes the
patched backend CMakeLists in a small build/install fixture and links and
runs an external static consumer. It rejects a redundant MODULE or duplicated
helper source and checks that shared configuration still declares a MODULE.
The full CI checks the executable's static plugin symbol and metadata, then
requires the actual KWindowSystem `Loaded a static plugin for platform "xcb"`
message, a visible window and a child shell running on a PTY. It repeats
that smoke test after relocating the bundle and hiding build-time prefixes.

No builds or tests are run on the developer machine; all validation runs in
GitHub Actions.
