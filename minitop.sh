#!/usr/bin/env bash

SLEEP=1

IFACE="${1:-$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')}"
[ -z "$IFACE" ] && IFACE="eth0"

# ANSI colors (correct way)
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
ORANGE=$'\033[38;5;208m'
RED=$'\033[31m'
RESET=$'\033[0m'

ticks=(" " "▁" "▂" "▃" "▄" "▅" "▆" "▇" "█")

declare -a CPU_HIST MEM_HIST SWAP_HIST NET_HIST
declare -A CORE_HIST

get_width() {
  cols=$(tput cols 2>/dev/null || echo 80)
  WIDTH=$((cols - 6))
  ((WIDTH < 5)) && WIDTH=5
}

push() {
  local -n ref=$1
  ref+=("$2")
  ((${#ref[@]} > WIDTH)) && ref=("${ref[@]:1}")
}

render() {
  local -n ref=$1
  local out=""

  for v in "${ref[@]}"; do
    idx=$((v/12))
    ((idx>8)) && idx=8

    if ((v < 40)); then
      color=$GREEN
    elif ((v < 60)); then
      color=$YELLOW
    elif ((v < 80)); then
      color=$ORANGE
    else
      color=$RED
    fi

    out+="${color}${ticks[$idx]}${RESET}"
  done

  printf "%s" "$out"
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

get_mem_pct() {
  free | awk '/Mem:/ {print int($3*100/$2)}'
}

get_swap_pct() {
  free | awk '/Swap:/ {if($2==0)print 0; else print int($3*100/$2)}'
}

get_net_rx() {
  awk -v iface="$IFACE" '$0 ~ iface {print $2}' /proc/net/dev
}

PREV_CPU=($(get_cpu_line))
mapfile -t PREV_CORES < <(get_core_lines)
PREV_NET=$(get_net_rx)
PREV_TIME=$(date +%s)

while true; do
  get_width
  clear

  # CPU total
  CUR_CPU=($(get_cpu_line))
  cpu=$(calc_cpu_pair "${PREV_CPU[*]}" "${CUR_CPU[*]}")
  PREV_CPU=("${CUR_CPU[@]}")
  push CPU_HIST $cpu
  printf "CPU %s\n" "$(render CPU_HIST)"

  # per-core
  mapfile -t CUR_CORES < <(get_core_lines)
  for i in "${!CUR_CORES[@]}"; do
    val=$(calc_cpu_pair "${PREV_CORES[$i]}" "${CUR_CORES[$i]}")

    CORE_HIST[$i]="${CORE_HIST[$i]} $val"
    core_arr=(${CORE_HIST[$i]})
    ((${#core_arr[@]} > WIDTH)) && core_arr=("${core_arr[@]:1}")
    CORE_HIST[$i]="${core_arr[*]}"

    printf "C%-2d %s\n" "$i" "$(render core_arr)"
  done
  PREV_CORES=("${CUR_CORES[@]}")

  # MEM
  mem=$(get_mem_pct)
  push MEM_HIST $mem
  printf "MEM %s\n" "$(render MEM_HIST)"

  # SWAP
  swap=$(get_swap_pct)
  push SWAP_HIST $swap
  printf "SWP %s\n" "$(render SWAP_HIST)"

  # NET (rx only)
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
  printf "NET %s\n" "$(render NET_HIST)"

  sleep $SLEEP
done
