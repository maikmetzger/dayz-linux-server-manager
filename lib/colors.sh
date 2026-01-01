#!/usr/bin/env bash
# =============================================================================
# DayZ Server Scripts - Color & Terminal Definitions
# =============================================================================
# Shared ANSI color codes for DayZ TUI theme (Black/Blood Red #b20000)
# Source this file: source "${SCRIPT_DIR}/lib/colors.sh"
# =============================================================================

# Prevent double-sourcing
[[ -n "${_DAYZ_COLORS_LOADED:-}" ]] && return 0
_DAYZ_COLORS_LOADED=1

# -----------------------------------------------------------------------------
# ANSI Escape Codes
# -----------------------------------------------------------------------------
ESC=$'\033'
RESET="${ESC}[0m"
BOLD="${ESC}[1m"
DIM="${ESC}[2m"

# -----------------------------------------------------------------------------
# Foreground Colors (24-bit true color for #b20000 = RGB 178,0,0)
# -----------------------------------------------------------------------------
BLACK="${ESC}[30m"
RED="${ESC}[38;2;178;0;0m"          # #b20000 DayZ blood red
GREEN="${ESC}[32m"
YELLOW="${ESC}[33m"
WHITE="${ESC}[37m"
GRAY="${ESC}[90m"
DARKGRAY="${ESC}[38;2;55;55;55m"

# Legacy color aliases (used by installer)
CYN="${ESC}[36m"
CYAN="${CYN}"
BLU="${ESC}[34m"
YLW="${YELLOW}"
GRN="${GREEN}"
C0="${RESET}"

# -----------------------------------------------------------------------------
# Background Colors
# -----------------------------------------------------------------------------
BG_BLACK="${ESC}[40m"
BG_RED="${ESC}[48;2;178;0;0m"       # #b20000 DayZ blood red
BG_DARKGRAY="${ESC}[100m"
BG_WHITE="${ESC}[47m"

# -----------------------------------------------------------------------------
# Cursor Control
# -----------------------------------------------------------------------------
HIDE_CURSOR="${ESC}[?25l"
SHOW_CURSOR="${ESC}[?25h"
CLEAR_SCREEN="${ESC}[2J${ESC}[H"
CLEAR_LINE="${ESC}[2K"

# -----------------------------------------------------------------------------
# Cursor Movement Functions
# -----------------------------------------------------------------------------

# Move cursor to row, column (1-indexed)
move_to() { printf "${ESC}[%d;%dH" "$1" "$2"; }

# Move cursor up N lines
move_up() { printf "${ESC}[%dA" "${1:-1}"; }

# Move cursor down N lines
move_down() { printf "${ESC}[%dB" "${1:-1}"; }
