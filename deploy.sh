#!/bin/bash

cp archive-to-s3.sh /usr/local/bin/archive-to-s3.sh
chmod +x /usr/local/bin/archive-to-s3.sh
echo "archive-to-s3.sh has been copied to /usr/local/bin and made executable."

launchctl unload ~/Library/LaunchAgents/com.gregkopp.archive-to-s3.plist
echo "com.gregkopp.archive-to-s3.plist has been unloaded."

cp com.gregkopp.archive-to-s3.plist ~/Library/LaunchAgents/com.gregkopp.archive-to-s3.plist
echo "com.gregkopp.archive-to-s3.plist has been copied to ~/Library/LaunchAgents."

launchctl load ~/Library/LaunchAgents/com.gregkopp.archive-to-s3.plist
echo "com.gregkopp.archive-to-s3.plist has been loaded."