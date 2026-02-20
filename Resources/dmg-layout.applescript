on run argv
    set volName to item 1 of argv
    tell application "Finder"
        tell disk volName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set bounds of container window to {200, 120, 760, 430}
            set opts to icon view options of container window
            set arrangement of opts to not arranged
            set icon size of opts to 128
            set background color of opts to {56797, 56797, 56797}
            delay 1
            set position of item "Switcher.app" of container window to {155, 155}
            set position of item "Applications" of container window to {405, 155}
            close
            open
            update without registering applications
            delay 1
        end tell
    end tell
end run
