#!/bin/bash
set -euo pipefail
[[ $# == 8 ]] || exit 0
mouse_x=$1 mouse_y=$2 cursor_x=$3 cursor_y=$4 pane_width=$5 pane_id=$6 in_mode=$7 alternate=$8
for number in "$mouse_x" "$mouse_y" "$cursor_x" "$cursor_y" "$pane_width"; do
  [[ $number =~ ^[0-9]{1,5}$ ]] || exit 0
done
[[ $pane_id =~ ^%[0-9]+$ && $in_mode == 0 && $alternate == 0 ]] || exit 0
command_name=$(tmux display-message -p -t "$pane_id" '#{pane_current_command}')
case "$command_name" in zsh|bash|sh|fish) ;; *) exit 0 ;; esac
distance=$((10#$mouse_x - 10#$cursor_x + (10#$mouse_y - 10#$cursor_y) * 10#$pane_width))
(( distance != 0 && distance > -4096 && distance < 4096 )) || exit 0
direction=Right
if (( distance < 0 )); then direction=Left; distance=$((-distance)); fi
tmux send-keys -t "$pane_id" -N "$distance" "$direction"
