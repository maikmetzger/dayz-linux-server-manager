#!/bin/bash
# =============================================================================
# DayZ Ban Expiry Timer Setup
# =============================================================================
# Sets up a systemd user timer to run the ban expiry checker every minute.
#
# Usage: ./setup_ban_expiry_timer.sh <instance_dir>
# Example: ./setup_ban_expiry_timer.sh ~/servers/dayz-server1
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <instance_dir>"
    echo "Example: $0 ~/servers/dayz-server1"
    exit 1
fi

INSTANCE_DIR="$(realpath "$1")"
CHECK_SCRIPT="${SCRIPT_DIR}/check_ban_expiry.sh"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SERVICE_NAME="dayz-ban-expiry"

# Validate
if [[ ! -d "$INSTANCE_DIR" ]]; then
    echo "Error: Instance directory not found: $INSTANCE_DIR"
    exit 1
fi

if [[ ! -f "$CHECK_SCRIPT" ]]; then
    echo "Error: check_ban_expiry.sh not found at: $CHECK_SCRIPT"
    exit 1
fi

echo "Setting up ban expiry timer for: $INSTANCE_DIR"
echo ""

# Create systemd user directory
mkdir -p "$SYSTEMD_USER_DIR"

# Create service file
cat > "${SYSTEMD_USER_DIR}/${SERVICE_NAME}.service" << EOF
[Unit]
Description=DayZ Ban Expiry Checker
After=network.target

[Service]
Type=oneshot
ExecStart=${CHECK_SCRIPT} ${INSTANCE_DIR}
StandardOutput=journal
StandardError=journal
EOF

echo "Created: ${SYSTEMD_USER_DIR}/${SERVICE_NAME}.service"

# Create timer file
cat > "${SYSTEMD_USER_DIR}/${SERVICE_NAME}.timer" << EOF
[Unit]
Description=Run DayZ Ban Expiry Checker every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF

echo "Created: ${SYSTEMD_USER_DIR}/${SERVICE_NAME}.timer"

# Reload systemd
echo ""
echo "Reloading systemd..."
systemctl --user daemon-reload

# Enable and start timer
echo "Enabling and starting timer..."
systemctl --user enable "${SERVICE_NAME}.timer"
systemctl --user start "${SERVICE_NAME}.timer"

echo ""
echo "✓ Ban expiry timer is now running!"
echo ""
echo "Useful commands:"
echo "  Check status:  systemctl --user status ${SERVICE_NAME}.timer"
echo "  View logs:     journalctl --user -u ${SERVICE_NAME}.service -f"
echo "  Disable:       systemctl --user disable ${SERVICE_NAME}.timer"
echo "  Stop:          systemctl --user stop ${SERVICE_NAME}.timer"
