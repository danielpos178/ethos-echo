#!/bin/bash
# Xorg session setup script for Lemurs
# This script is called by lemurs after authentication to start the X11 session

# Set up environment variables
export XDG_SESSION_TYPE=x11
export XDG_SESSION_DESKTOP=dwm

# Disable screen blanking and power management
xset s off
xset s noblank
xset -dpms

# Start dwm via startx
cd ~
exec startx
