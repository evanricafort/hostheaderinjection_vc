#!/usr/bin/env bash
set -u
# Host Header Injection Kit
# Evan Ricafort - (X - @evanricafort | Web - https://evanricafort.com)
#
# Usage:
#  ./hhinjection.sh -f targets.txt -H "www.evanricafort.com" -B none -D -c 4 -v
#
# Options:
#  -t TARGET     Single target (URL or host:port). scheme auto-prepended (http://) if missing.
#  -f FILE       File with targets (one per line). skip blank and # comments.
#  -H HOST       Host header to inject (default: www.evanricafort.com).
#  -B BASELINE   Baseline Host header. Use "none" to send request without explicit -H. If omitted, no baseline run.
#  -D            Show diff (unified) between baseline and injected responses when baseline provided.
#  -c CONCURRENCY Number of parallel jobs (default 1 = sequential).
#  -T TIMEOUT    curl timeout seconds (default 10).
#  -o OUTDIR     Output directory (default: results_<timestamp>).
#  -u UA         User-Agent string.
#  -v            Verbose live output (prints full response).
#  -h            Help

# -------------------------
# Defaults
# -------------------------
HOST_HEADER="www.evanricafort.com"
BASELINE_HEADER=""
SHOW_DIFF=false
CONCURRENCY=1
TIMEOUT=10
OUTPUT_DIR=""
USER_AGENT="host-inject-script/1.0"
VERBOSE=false

timestamp(){ date +"%Y%m%d_%H%M%S"; }
iso_time(){ date --iso-8601=seconds 2>/dev/null || date -Iseconds; }

usage(){
  cat <<EOF
Usage: $0 [options]
Options:
  -t TARGET        Single target (URL or hostname). If no scheme provided, http:// is prepended.
  -f FILE          File with targets (one per line). Lines starting with # or blank are skipped.
  -H HOST          Host header value to inject. Default: ${HOST_HEADER}
  -B BASELINE      Baseline Host header. Use "none" to send request without explicit -H.
  -D               Show unified diff between baseline and injected responses when baseline is provided.
  -c CONCURRENCY   Number of parallel jobs. Default: ${CONCURRENCY}
  -T TIMEOUT       curl timeout seconds. Default: ${TIMEOUT}
  -o OUTDIR        Output directory. Default: results_<timestamp>
  -u UA            User-Agent string for curl.
  -v               Verbose live output (prints full response).
  -h               Show this help.

Examples:
  $0 -t example.com -H "www.evanricafort.com" -v
  $0 -f targets.txt -H "www.evanricafort.com" -B none -D -c 4 -v
EOF
  exit 1
}

# -------------------------
# Parse args
# -------------------------
TARGET=""
FILE=""
while getopts ":t:f:H:B:c:T:o:u:vDh" opt; do
  case $opt in
    t) TARGET="$OPTARG" ;;
    f) FILE="$OPTARG" ;;
    H) HOST_HEADER="$OPTARG" ;;
    B) BASELINE_HEADER="$OPTARG" ;;
    D) SHOW_DIFF=true ;;
    c) CONCURRENCY="$OPTARG" ;;
    T) TIMEOUT="$OPTARG" ;;
    o) OUTPUT_DIR="$OPTARG" ;;
    u) USER_AGENT="$OPTARG" ;;
    v) VERBOSE=true ;;
    h) usage ;;
    \?) echo "Invalid option -$OPTARG" >&2; usage ;;
  esac
done

if [[ -z "$TARGET" && -z "$FILE" ]]; then
  echo "Error: Provide -t TARGET or -f FILE." >&2
  usage
fi

# -------------------------
# Check required commands and detect diff colorizer
# -------------------------
required=(curl awk sed mktemp diff)
for c in "${required[@]}"; do
  command -v "$c" >/dev/null 2>&1 || { echo "Command '$c' not found. Please install it."; exit 2; }
done

# prefer diff-so-fancy, then colordiff, else plain diff
DIFF_TOOL="diff"
if command -v diff-so-fancy >/dev/null 2>&1; then
  DIFF_TOOL="diff-so-fancy"
elif command -v colordiff >/dev/null 2>&1; then
  DIFF_TOOL="colordiff"
else
  DIFF_TOOL="diff"
fi

# -------------------------
# Output directory
# -------------------------
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="results_$(timestamp)"
fi
mkdir -p "$OUTPUT_DIR" || { echo "Failed to create $OUTPUT_DIR"; exit 3; }

SUMMARY_CSV="$OUTPUT_DIR/summary.csv"
echo "target,host_header,baseline_header,http_status,server_header,response_file,baseline_file,scan_time,response_bytes" > "$SUMMARY_CSV"

# -------------------------
# Colors
# -------------------------
CLR_RESET=$'\033[0m'
CLR_BOLD=$'\033[1m'
CLR_GREEN=$'\033[1;32m'
CLR_RED=$'\033[1;31m'
CLR_YELLOW=$'\033[1;33m'
CLR_CYAN=$'\033[1;36m'
CLR_MAGENTA=$'\033[1;35m'
CLR_GREY=$'\033[0;37m'

color_for_status(){
  local s="$1"
  if [[ "$s" =~ ^2[0-9][0-9]$ ]]; then
    printf "%s" "$CLR_GREEN"
  elif [[ "$s" =~ ^3[0-9][0-9]$ ]]; then
    printf "%s" "$CLR_YELLOW"
  elif [[ "$s" =~ ^4|5[0-9][0-9]$ ]]; then
    printf "%s" "$CLR_RED"
  else
    printf "%s" "$CLR_CYAN"
  fi
}

# -------------------------
# Helpers
# -------------------------
normalize_url(){
  local t="$1"
  if [[ "$t" =~ ^https?:// ]]; then
    printf "%s" "$t"
  else
    printf "http://%s" "$t"
  fi
}

safe_name(){
  local t="$1"
  t="${t#http://}"
  t="${t#https://}"
  echo "$t" | sed -E 's/[^A-Za-z0-9._-]/_/g'
}

job_tempfile(){ mktemp "$OUTPUT_DIR/job_XXXXXX.tmp"; }

perform_request(){
  local url="$1"; local outfile="$2"; local hosthdr="$3"
  if [[ -n "$hosthdr" ]]; then
    curl -A "$USER_AGENT" -is --max-time "$TIMEOUT" -H "Host: $hosthdr" "$url" > "$outfile" 2>/dev/null || true
  else
    # omit -H entirely
    curl -A "$USER_AGENT" -is --max-time "$TIMEOUT" "$url" > "$outfile" 2>/dev/null || true
  fi
}

parse_meta(){
  local f="$1"
  local status
  status=$(awk 'BEGIN{RS="\r\n"} /^HTTP\// {print $0; exit}' "$f" 2>/dev/null | awk '{print $2}' 2>/dev/null || true)
  [[ -z "$status" ]] && status="N/A"
  local server
  server=$(awk 'BEGIN{IGNORECASE=1} /^Server:/ {sub(/^Server:[ \t]*/,""); print; exit}' "$f" 2>/dev/null || true)
  [[ -z "$server" ]] && server="N/A"
  printf "%s|%s" "$status" "$server"
}

# nicely formatted box header
boxed_header(){
  local title="$1"
  local width=78
  local pad
  pad=$(( (width - ${#title}) / 2 ))
  printf "%s\n" "$CLR_MAGENTA$(printf '=%.0s' $(seq 1 $width))$CLR_RESET"
  printf "%s\n" "$(printf ' %*s%s%*s ' "$pad" '' "$CLR_BOLD$title$CLR_RESET" "$pad" '')"
  printf "%s\n" "$CLR_MAGENTA$(printf '=%.0s' $(seq 1 $width))$CLR_RESET"
}

# build verbose output into a temp file (atomically printed later)
# args: raw_target inj_file base_file status server bytes start_time inj_host base_host out_temp
build_verbose(){
  local raw_target="$1"; local inj_file="$2"; local base_file="$3"
  local status="$4"; local server="$5"; local bytes="$6"; local start_time="$7"
  local inj_host="$8"; local base_host="$9"; local out_temp="${10}"

  {
    # Big readable header
    boxed_header "SCAN RESULT: $raw_target"

    # metadata row
    printf "%s\n" ""
    printf "%s%-14s%s : %s\n" "$CLR_BOLD" "Target" "$CLR_RESET" "$raw_target"
    printf "%s%-14s%s : %s\n" "$CLR_BOLD" "Injected Host" "$CLR_RESET" "$inj_host"
    if [[ -n "$base_host" ]]; then
      printf "%s%-14s%s : %s\n" "$CLR_BOLD" "Baseline Host" "$CLR_RESET" "$base_host"
    fi
    printf "%s%-14s%s : %s%s%s\n" "$CLR_BOLD" "Status" "$CLR_RESET" "$(color_for_status "$status")" "$status" "$CLR_RESET"
    printf "%s%-14s%s : %s\n" "$CLR_BOLD" "Server" "$CLR_RESET" "$server"
    printf "%s%-14s%s : %s bytes\n" "$CLR_BOLD" "Bytes" "$CLR_RESET" "$bytes"
    printf "%s%-14s%s : %s\n" "$CLR_BOLD" "Time" "$CLR_RESET" "$start_time"
    printf "%s\n" ""

    # injected response section
    printf "%s\n" ">>> FULL INJECTED RESPONSE ($inj_file) >>>"
    printf "%s\n" "------------------------------------------------------------"
    cat "$inj_file" 2>/dev/null || printf "<no injected response>\n"
    printf "%s\n" "------------------------------------------------------------"
    printf "\n"

    # baseline section (if present)
    if [[ -n "$base_file" && -s "$base_file" ]]; then
      printf "%s\n" ">>> FULL BASELINE RESPONSE ($base_file) >>>"
      printf "%s\n" "------------------------------------------------------------"
      cat "$base_file" 2>/dev/null || printf "<no baseline response>\n"
      printf "%s\n" "------------------------------------------------------------"
      printf "\n"

      # diff (colorized if possible)
      if $SHOW_DIFF; then
        printf "%s\n" ">>> DIFF (baseline -> injected) using: $DIFF_TOOL >>>"
        printf "%s\n" "------------------------------------------------------------"
        # produce unified diff and pipe through chosen colorizer if available
        if [[ "$DIFF_TOOL" == "diff-so-fancy" ]]; then
          diff -u --label "baseline" --label "injected" "$base_file" "$inj_file" 2>/dev/null | diff-so-fancy || printf "<no diff or diff-so-fancy returned non-zero>\n"
        elif [[ "$DIFF_TOOL" == "colordiff" ]]; then
          colordiff -u "$base_file" "$inj_file" 2>/dev/null || printf "<no diff or colordiff returned non-zero>\n"
        else
          diff -u "$base_file" "$inj_file" 2>/dev/null || printf "<no diff or diff returned non-zero>\n"
        fi
        printf "%s\n" "------------------------------------------------------------"
        printf "\n"
      fi
    fi

    # footer spacing
    printf "%s\n" ""
    printf "%s\n" "$(printf ' %s\n' "$(printf '%.0s-' $(seq 1 78))")"
    printf "\n\n"
  } > "$out_temp"
}

# -------------------------
# do_scan for a single target
# -------------------------
do_scan(){
  local raw_target="$1"
  local vtemp="$2"
  local url; url=$(normalize_url "$raw_target")
  local name; name=$(safe_name "$raw_target")
  local start_time; start_time="$(iso_time)"

  # baseline
  local baseline_file=""
  if [[ -n "$BASELINE_HEADER" ]]; then
    baseline_file="$OUTPUT_DIR/${name}_baseline_$(timestamp).resp"
    if [[ "$BASELINE_HEADER" == "none" ]]; then
      perform_request "$url" "$baseline_file" ""
    else
      perform_request "$url" "$baseline_file" "$BASELINE_HEADER"
    fi
  fi

  # injected
  local inj_file="$OUTPUT_DIR/${name}_inject_$(timestamp).resp"
  perform_request "$url" "$inj_file" "$HOST_HEADER"

  # meta
  local meta; meta=$(parse_meta "$inj_file")
  local status="${meta%%|*}"
  local server="${meta##*|}"
  local bytes; bytes=$(wc -c < "$inj_file" 2>/dev/null || echo 0)

  # CSV append (race-safe)
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "\"$raw_target\"" "\"$HOST_HEADER\"" "\"${BASELINE_HEADER:-}\"" "\"$status\"" \
    "\"$server\"" "\"$inj_file\"" "\"${baseline_file:-}\"" "\"$start_time\",\"$bytes\"" >> "$SUMMARY_CSV"

  # build verbose content into vtemp
  if $VERBOSE; then
    build_verbose "$raw_target" "$inj_file" "${baseline_file:-}" "$status" "$server" "$bytes" "$start_time" "$HOST_HEADER" "${BASELINE_HEADER:-}" "$vtemp"
  else
    printf "Target: %s | Status: %s | File: %s\n" "$raw_target" "$status" "$inj_file" > "$vtemp"
  fi
}

# -------------------------
# Job control
# -------------------------
current_jobs=0
start_job(){
  local target="$1"
  local vtemp; vtemp=$(job_tempfile)

  ((current_jobs++))
  (
    do_scan "$target" "$vtemp"
  ) &
  local pid=$!

  # watcher prints vtemp atomically and cleans up
  (
    wait "$pid"
    if [[ -f "$vtemp" ]]; then
      # print with a separating newline to keep spacing between results
      printf "\n"
      cat "$vtemp"
      rm -f "$vtemp"
    fi
    ((current_jobs--))
  ) &
}

wait_for_slot(){
  while true; do
    if (( current_jobs < CONCURRENCY )); then
      break
    fi
    sleep 0.05
  done
}

# -------------------------
# Main scanning loops
# -------------------------
if (( CONCURRENCY <= 1 )); then
  if [[ -n "$TARGET" ]]; then
    echo "[*] Scanning single target: $TARGET with Host: $HOST_HEADER"
    vtemp=$(job_tempfile)
    do_scan "$TARGET" "$vtemp"
    printf "\n"
    cat "$vtemp" && rm -f "$vtemp"
  fi

  if [[ -n "$FILE" ]]; then
    echo "[*] Scanning targets from file: $FILE (sequential)"
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="$(echo -e "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [[ -z "$line" ]] && continue
      echo "[*] -> $line"
      vtemp=$(job_tempfile)
      do_scan "$line" "$vtemp"
      printf "\n"
      cat "$vtemp" && rm -f "$vtemp"
    done < "$FILE"
  fi
else
  if [[ -n "$TARGET" ]]; then
    echo "[*] Scanning single target (background): $TARGET (concurrency=$CONCURRENCY)"
    start_job "$TARGET"
  fi

  if [[ -n "$FILE" ]]; then
    echo "[*] Scanning targets from file: $FILE (concurrency=$CONCURRENCY)"
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="$(echo -e "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [[ -z "$line" ]] && continue
      wait_for_slot
      echo "[*] -> $line"
      start_job "$line"
    done < "$FILE"
  fi

  echo "[*] Waiting for background jobs to finish..."
  # wait until current_jobs reaches 0
  while (( current_jobs > 0 )); do
    sleep 0.1
  done
fi

echo ""
echo "[*] Scans finished. Results in: $OUTPUT_DIR"
echo "[*] Summary CSV: $SUMMARY_CSV"
if $VERBOSE; then
  echo "[*] Verbose full responses were printed to stdout with enhanced spacing and colorized diffs (if -D used)."
  echo "[*] Diff colorizer: $DIFF_TOOL"
fi

exit 0
