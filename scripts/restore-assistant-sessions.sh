#!/usr/bin/env bash
# tmux-resurrect restore hook — safely re-launch assistants from the manifest
# cryptographically paired with the exact layout selected by `last`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-detect.sh
source "$SCRIPT_DIR/lib-detect.sh"

RESURRECT_DIR="$(tmux show-option -gqv @resurrect-dir 2>/dev/null || true)"
RESURRECT_DIR="${RESURRECT_DIR:-${HOME}/.tmux/resurrect}"
RESURRECT_DIR="${RESURRECT_DIR/#\~/$HOME}"
STATE_DIR="${TMUX_ASSISTANT_RESURRECT_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-assistant-resurrect}"
LOG_FILE="${RESURRECT_DIR}/assistant-restore.log"
REPORT_FILE="${RESURRECT_DIR}/assistant-restore-report-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
RESULTS_FILE=$(mktemp)
TMP_SESSIONS=$(mktemp)
trap 'rm -f "$RESULTS_FILE" "$TMP_SESSIONS"' EXIT INT TERM

mkdir -p "$RESURRECT_DIR"
if [ -f "$LOG_FILE" ]; then
	tail -n 500 "$LOG_FILE" >"${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE" || true
fi

log() {
	local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
	echo "$msg" >&2
	echo "$msg" >>"$LOG_FILE"
}

sha256_file() {
	local path="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$path" | awk '{print $1}'
	else
		shasum -a 256 "$path" | awk '{print $1}'
	fi
}

record_result() {
	local pane="$1" tool="$2" session_id="$3" status="$4" detail="$5"
	jq -nc --arg pane "$pane" --arg tool "$tool" --arg sid "$session_id" \
		--arg status "$status" --arg detail "$detail" \
		'{pane:$pane, tool:$tool, session_id:$sid, status:$status, detail:$detail}' >>"$RESULTS_FILE"
}

write_report() {
	local layout="$1" manifest="$2" expected="$3"
	jq -s --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--arg layout "$layout" --arg manifest "$manifest" --argjson expected "$expected" '
		{
		  schema_version:1,
		  generated_at:$generated,
		  layout:$layout,
		  manifest:$manifest,
		  expected:$expected,
		  summary:{
		    attempted:([.[] | select(.status == "verified" or .status == "awaiting_confirmation" or .status == "failed")] | length),
		    verified:([.[] | select(.status == "verified")] | length),
		    awaiting_confirmation:([.[] | select(.status == "awaiting_confirmation")] | length),
		    failed:([.[] | select(.status == "failed")] | length),
		    skipped:([.[] | select(.status == "skipped")] | length)
		  },
		  results:.
		}' "$RESULTS_FILE" >"${REPORT_FILE}.tmp"
	mv -f "${REPORT_FILE}.tmp" "$REPORT_FILE"
}

finish() {
	local layout="$1" manifest="$2" expected="$3"
	write_report "$layout" "$manifest" "$expected"
	local verified waiting failed skipped
	verified=$(jq '.summary.verified' "$REPORT_FILE")
	waiting=$(jq '.summary.awaiting_confirmation' "$REPORT_FILE")
	failed=$(jq '.summary.failed' "$REPORT_FILE")
	skipped=$(jq '.summary.skipped' "$REPORT_FILE")
	log "restore complete: verified=$verified awaiting_confirmation=$waiting failed=$failed skipped=$skipped report=$REPORT_FILE"
	if [ "$failed" -gt 0 ] || [ "$waiting" -gt 0 ]; then
		tmux display-message "Assistant restore: $verified verified, $waiting awaiting confirmation, $failed failed (see $(basename "$REPORT_FILE"))" 2>/dev/null || true
	fi
}

validate_manifest() {
	local layout="$1" manifest="$2"
	[ -s "$layout" ] && [ -s "$manifest" ] || return 1
	[ "$(jq -r '.schema_version // 0' "$manifest" 2>/dev/null)" = "2" ] || return 1
	[ "$(jq -r '.layout.file // empty' "$manifest")" = "$(basename "$layout")" ] || return 1
	local expected actual
	expected=$(jq -r '.layout.sha256 // empty' "$manifest")
	actual=$(sha256_file "$layout")
	[ -n "$expected" ] && [ "$expected" = "$actual" ]
}

validate_cli_args() {
	local tool="$1" args="$2"
	[ "$tool" != "codex" ] && return 0
	case " $args " in
	*" codex-supervisor "* | *" --real-codex "* | *" resume "*) return 1 ;;
	esac
	return 0
}

session_matches() {
	local tool="$1" pid="$2" sid="$3" args="$4"
	case "$tool" in
	claude)
		[ "$(jq -r '.session_id // empty' "$STATE_DIR/claude-${pid}.json" 2>/dev/null || true)" = "$sid" ] && return 0
		;;
	codex)
		local instance
		for instance in "${XDG_STATE_HOME:-$HOME/.local/state}/codex-supervisor/instances"/*.json; do
			[ -f "$instance" ] || continue
			jq -e --arg sid "$sid" --argjson pid "$pid" \
				'.session_id == $sid and .status == "running" and (.child_pid == $pid or .pid == $pid)' \
				"$instance" >/dev/null 2>&1 && return 0
		done
		;;
	opencode) ;;
	esac
	case " $args " in
	*" $sid "* | *" $sid") return 0 ;;
	esac
	return 1
}

verify_launch() {
	local pane="$1" tool="$2" sid="$3"
	local pane_pid found args observed i
	pane_pid=$(tmux display-message -t "$pane" -p '#{pane_pid}' 2>/dev/null || true)
	for ((i = 0; i < 20; i++)); do
		found=$(pane_has_assistant "$pane_pid" || true)
		if [ -n "$found" ]; then
			args=$(ps -o args= -p "$found" 2>/dev/null || true)
			observed=$(detect_tool "$args")
			if [ "$observed" = "$tool" ] && session_matches "$tool" "$found" "$sid" "$args"; then
				return 0
			fi
		fi
		sleep 0.5
	done
	return 1
}

LAST_LINK="$RESURRECT_DIR/last"
if [ ! -L "$LAST_LINK" ]; then
	record_result "" "manifest" "" "failed" "missing resurrect last symlink"
	finish "" "" 0
	exit 0
fi

LAYOUT_TARGET=$(readlink "$LAST_LINK")
case "$LAYOUT_TARGET" in
/*) LAYOUT_FILE="$LAYOUT_TARGET" ;;
*) LAYOUT_FILE="$RESURRECT_DIR/$LAYOUT_TARGET" ;;
esac
INPUT_FILE="${LAYOUT_FILE%.*}.assistants.json"
if ! validate_manifest "$LAYOUT_FILE" "$INPUT_FILE"; then
	log "refusing assistant restore: layout and manifest are missing or do not match"
	record_result "" "manifest" "" "failed" "layout/manifest validation failed; no commands injected"
	finish "$LAYOUT_FILE" "$INPUT_FILE" 0
	exit 0
fi

sessions=$(jq -c '.sessions // []' "$INPUT_FILE")
count=$(echo "$sessions" | jq 'length')
if [ "$count" -eq 0 ]; then
	log "no assistant sessions to restore"
	finish "$LAYOUT_FILE" "$INPUT_FILE" 0
	exit 0
fi

sleep 2
log "restoring $count assistant session(s) from paired manifest $(basename "$INPUT_FILE")..."
echo "$sessions" | jq -c '.[]' >"$TMP_SESSIONS"

WAITED_SESSIONS="|"
while read -r entry; do
	pane=$(echo "$entry" | jq -r '.pane')
	tool=$(echo "$entry" | jq -r '.tool')
	session_id=$(echo "$entry" | jq -r '.session_id')
	cwd=$(echo "$entry" | jq -r '.cwd')
	cli_args=$(echo "$entry" | jq -r '.cli_args // empty')
	model=$(echo "$entry" | jq -r '.model // empty')
	env_json=$(echo "$entry" | jq -c '.env // {}')
	tmux_session="${pane%%:*}"

	if ! tmux has-session -t "$tmux_session" 2>/dev/null; then
		log "session '$tmux_session' does not exist, skipping pane $pane"
		record_result "$pane" "$tool" "$session_id" "skipped" "tmux session does not exist"
		continue
	fi
	if ! tmux list-panes -t "$pane" >/dev/null 2>&1; then
		log "pane $pane does not exist, skipping"
		record_result "$pane" "$tool" "$session_id" "skipped" "pane does not exist"
		continue
	fi

	case "$WAITED_SESSIONS" in
	*"|$tmux_session|"*) ;;
	*)
		client_wait=0
		while [ "$(tmux list-clients -t "$tmux_session" 2>/dev/null | wc -l)" -eq 0 ] && [ "$client_wait" -lt 50 ]; do
			sleep 0.1
			client_wait=$((client_wait + 1))
		done
		if [ "$client_wait" -ge 50 ]; then
			log "no client attached to session '$tmux_session' after 5s; replaying anyway"
		fi
		WAITED_SESSIONS="${WAITED_SESSIONS}${tmux_session}|"
		;;
	esac

	pane_cmd=$(tmux display-message -t "$pane" -p '#{pane_current_command}' 2>/dev/null || true)
	pane_cmd="${pane_cmd#-}"
	case "$pane_cmd" in
	bash | zsh | fish | sh | dash | ksh | tcsh | csh | nu) ;;
	*)
		log "pane $pane is running '$pane_cmd' (not a shell), skipping"
		record_result "$pane" "$tool" "$session_id" "skipped" "pane is not a shell: $pane_cmd"
		continue
		;;
	esac

	pane_shell_pid=$(tmux display-message -t "$pane" -p '#{pane_pid}' 2>/dev/null || true)
	existing=$(pane_has_assistant "$pane_shell_pid" || true)
	if [ -n "$existing" ]; then
		log "pane $pane already has a running assistant (pid $existing), skipping"
		record_result "$pane" "$tool" "$session_id" "skipped" "assistant already running: pid $existing"
		continue
	fi

	if ! validate_cli_args "$tool" "$cli_args"; then
		log "refusing unsafe $tool CLI args in $pane: $cli_args"
		record_result "$pane" "$tool" "$session_id" "failed" "unsafe saved CLI args"
		continue
	fi

	env_prefix=""
	if [ -n "$env_json" ] && [ "$env_json" != "null" ] && [ "$env_json" != "{}" ]; then
		capture_env=$(tmux show-option -gqv @assistant-resurrect-capture-env 2>/dev/null || true)
		for var in $capture_env; do
			if ! [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
				log "skipping invalid env var name: $var"
				continue
			fi
			val=$(echo "$env_json" | jq -r --arg k "$var" '.[$k] // empty')
			[ -n "$val" ] && env_prefix="${env_prefix}${var}=$(posix_quote "$val") "
		done
	fi

	safe_sid=$(posix_quote "$session_id")
	safe_cli_args=""
	if [ -n "$cli_args" ]; then
		set -f
		for _arg in $cli_args; do safe_cli_args="${safe_cli_args} $(posix_quote "$_arg")"; done
		set +f
	fi
	safe_model_arg=""
	if [ -n "$model" ] && [ "$tool" = "claude" ]; then
		case "$cli_args" in *--model*) ;; *) safe_model_arg=" --model $(posix_quote "$model")" ;; esac
	fi

	case "$tool" in
	claude) resume_cmd="command claude${safe_cli_args}${safe_model_arg} --resume ${safe_sid}" ;;
	opencode) resume_cmd="command opencode${safe_cli_args} -s ${safe_sid}" ;;
	codex) resume_cmd="command codex${safe_cli_args} resume ${safe_sid}" ;;
	*)
		log "unknown tool '$tool' in $pane, skipping"
		record_result "$pane" "$tool" "$session_id" "skipped" "unknown tool"
		continue
		;;
	esac
	[ -n "$env_prefix" ] && resume_cmd="${env_prefix}${resume_cmd}"
	log "restoring $tool in $pane (session: $session_id, cmd: $resume_cmd)"

	tmux send-keys -t "$pane" "clear" Enter
	tmux clear-history -t "$pane"
	sleep 0.3
	if [ -n "$cwd" ] && [ "$cwd" != "null" ]; then
		tmux send-keys -t "$pane" "cd $(posix_quote "$cwd") 2>/dev/null; ${resume_cmd}" Enter
	else
		tmux send-keys -t "$pane" "${resume_cmd}" Enter
	fi

	if verify_launch "$pane" "$tool" "$session_id"; then
		if tmux capture-pane -pJ -t "$pane" -S -80 2>/dev/null | grep -qi 'resume from summary\|recommend resuming from a summary'; then
			record_result "$pane" "$tool" "$session_id" "awaiting_confirmation" "assistant is running and awaits resume choice"
		else
			record_result "$pane" "$tool" "$session_id" "verified" "assistant and session identity verified"
		fi
	else
		log "verification failed for $tool in $pane (session: $session_id)"
		record_result "$pane" "$tool" "$session_id" "failed" "assistant/session identity not observed within 10 seconds"
	fi
	sleep 1
done <"$TMP_SESSIONS"

finish "$LAYOUT_FILE" "$INPUT_FILE" "$count"
