# 0583: App Store build bundles the LGPL ffmpeg

The Xcode project and gui/release.sh keep the GPL pair. The store script copies the LGPL pair over the bundled tools
after the archive, before re-signing. The bundled copies are checked by reading (`grep -a --enable-gpl`) because a
re-signed sandbox-inherit binary cannot be run standalone.
