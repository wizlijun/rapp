#!/bin/bash
# Remove what rapp-<version>.pkg installed: the LaunchAgent and /Applications/rapp.app.
# Keeps ~/rapp (the data dir: ID, password, saved hosts, shared files) and
# ~/Library/Application Support/rapp (old config, data-root pointer);
# delete those by hand for a clean slate. Run as yourself; asks for sudo once.
set -u
LABEL=com.rapp.service
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
pkill -x rapp 2>/dev/null || true
sudo rm -rf /Applications/rapp.app
sudo pkgutil --forget com.rapp.pkg >/dev/null 2>&1 || true
echo "rapp removed (kept $HOME/rapp and $HOME/Library/Application Support/rapp)"
