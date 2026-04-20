#!/usr/bin/env bash

SLEEP=1
TALL=0
IFACE=""

for arg in "$@"; do
  if [[ "$arg" == "--tall" ]]; then
    TALL=1
  elif [[ -n "$arg" ]]; then
    IFACE="$arg"
  fi
done
[ -z "$IFACE" ] && IFACE="$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')"
[ -z "$IFACE" ] && IFACE="eth0"

tput civis 2>/dev/null
trap 'tput cnorm 2>/dev/null; exit' INT TERM EXIT

GREEN=$'\033[32m'
YELLOW=$'\033[33m'
ORANGE=$'\033[38;5;208m'
RED=$'\033[31m'
RESET=$'\033[0m'

ticks=(" " "▁" "▂" "▃" "▄" "▅" "▆" "▇" "█")

declare -a CPU_HIST MEM_HIST SWAP_HIST NET_HIST
declare -A CORE_HIST

get_dims() {
  WIDTH=$(( $(tput cols 2>/dev/null || echo 80) - 6 ))
  TERM_LINES=$(tput lines 2>/dev/null || echo 24)
  ((WIDTH < 5)) && WIDTH=5
}

push() {
  local -n ref=$1
  ref+=("$2")
  ((${#ref[@]} > WIDTH)) && ref=("${ref[@]:1}")
}

get_color() {
  local v=$1
  if ((v < 40)); then COLOR=$GREEN
  elif ((v < 60)); then COLOR=$YELLOW
  elif ((v < 80)); then COLOR=$ORANGE
  else COLOR=$RED
  fi
}

render() {
  local -n ref=$1
  local out=""
  local pad=$(( WIDTH - ${#ref[@]} ))
  for ((i=0; i<pad; i++)); do out+=" "; done
  for v in "${ref[@]}"; do
    local idx=$((v/12))
    ((idx>8)) && idx=8
    get_color "$v"
    out+="${COLOR}${ticks[$idx]}${RESET}"
  done
  RENDERED="$out"
}

render_rows() {
  local -n ref=$1
  local n=$2
  local max_units=$(( n * 8 ))
  local rows=()
  local padding=""
  local pad=$(( WIDTH - ${#ref[@]} ))
  for ((i=0; i<pad; i++)); do padding+=" "; done
  for ((r=0; r<n; r++)); do rows[$r]="$padding"; done
  for v in "${ref[@]}"; do
    local units=$(( v * max_units / 100 ))
    ((units > max_units)) && units=$max_units
    get_color "$v"
    for ((r=0; r<n; r++)); do
      local rem=$(( units - r * 8 ))
      local idx
      if ((rem <= 0)); then idx=0
      elif ((rem >= 8)); then idx=8
      else idx=$rem
      fi
      rows[$r]+="${COLOR}${ticks[$idx]}${RESET}"
    done
  done
  ROWS=()
  for ((r=n-1; r>=0; r--)); do ROWS+=("${rows[$r]}"); done
}

print_row() {
  local label="$1"
  local hist_name="$2"
  local line
  if ((ROW_HEIGHT > 1)); then
    render_rows "$hist_name" $ROW_HEIGHT
    for ((r=0; r<ROW_HEIGHT-1; r++)); do buf+="    ${ROWS[$r]}"$'\n'; done
    printf -v line "%-4s%s\n" "$label" "${ROWS[$((ROW_HEIGHT-1))]}"
    buf+="$line"
  else
    render "$hist_name"
    printf -v line "%-4s%s\n" "$label" "$RENDERED"
    buf+="$line"
  fi
}

get_cpu_line() { grep '^cpu ' /proc/stat; }
get_core_lines() { grep '^cpu[0-9]' /proc/stat; }

calc_cpu_pair() {
  local -a p=($1) n=($2)
  local idle_p=$((p[4]+p[5]))
  local idle_n=$((n[4]+n[5]))
  local tp=0 tn=0
  for v in "${p[@]:1:8}"; do tp=$((tp+v)); done
  for v in "${n[@]:1:8}"; do tn=$((tn+v)); done
  local dt=$((tn-tp))
  local di=$((idle_n-idle_p))
  echo $(( dt>0 ? 100*(dt-di)/dt : 0 ))
}

get_mem_pct()  { free | awk '/Mem:/ {print int($3*100/$2)}'; }
get_swap_pct() { free | awk '/Swap:/ {if($2==0)print 0; else print int($3*100/$2)}'; }
get_net_rx()   { awk -v iface="$IFACE" '$0 ~ iface {print $2}' /proc/net/dev; }

PREV_CPU=($(get_cpu_line))
mapfile -t PREV_CORES < <(get_core_lines)
PREV_NET=$(get_net_rx)
PREV_TIME=$(date +%s)

clear

while true; do
  get_dims
  buf=""

  mapfile -t CUR_CORES < <(get_core_lines)
  num_resources=$(( 4 + ${#CUR_CORES[@]} ))
  if ((TALL)); then
    ROW_HEIGHT=$(( TERM_LINES / num_resources ))
    ((ROW_HEIGHT < 1)) && ROW_HEIGHT=1
  else
    ROW_HEIGHT=1
  fi

  # CPU total
  CUR_CPU=($(get_cpu_line))
  cpu=$(calc_cpu_pair "${PREV_CPU[*]}" "${CUR_CPU[*]}")
  PREV_CPU=("${CUR_CPU[@]}")
  push CPU_HIST $cpu
  print_row "CPU" "CPU_HIST"

  # per-core
  for i in "${!CUR_CORES[@]}"; do
    val=$(calc_cpu_pair "${PREV_CORES[$i]}" "${CUR_CORES[$i]}")
    CORE_HIST[$i]="${CORE_HIST[$i]} $val"
    core_arr=(${CORE_HIST[$i]})
    ((${#core_arr[@]} > WIDTH)) && core_arr=("${core_arr[@]:1}")
    CORE_HIST[$i]="${core_arr[*]}"

    label=$(printf "C%-2d" "$i")
    if ((ROW_HEIGHT > 1)); then
      render_rows core_arr $ROW_HEIGHT
      for ((r=0; r<ROW_HEIGHT-1; r++)); do buf+="    ${ROWS[$r]}"$'\n'; done
      printf -v line "%-4s%s\n" "$label" "${ROWS[$((ROW_HEIGHT-1))]}"
      buf+="$line"
    else
      render core_arr
      printf -v line "%-4s%s\n" "$label" "$RENDERED"
      buf+="$line"
    fi
  done
  PREV_CORES=("${CUR_CORES[@]}")

  # MEM
  mem=$(get_mem_pct)
  push MEM_HIST $mem
  print_row "MEM" "MEM_HIST"

  # SWAP
  swap=$(get_swap_pct)
  push SWAP_HIST $swap
  print_row "SWP" "SWAP_HIST"

  # NET
  CUR_NET=$(get_net_rx)
  NOW=$(date +%s)
  DT=$((NOW - PREV_TIME))
  ((DT == 0)) && DT=1
  rate=$(( (CUR_NET - PREV_NET) / DT ))
  PREV_NET=$CUR_NET
  PREV_TIME=$NOW
  net_pct=$((rate/1000))
  ((net_pct>100)) && net_pct=100
  push NET_HIST $net_pct
  print_row "NET" "NET_HIST"

  printf '\033[H%s\033[J' "$buf"
  sleep $SLEEP
done
