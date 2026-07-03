#!/usr/bin/env bash
# health_check.sh - Simple VM health check script
# Usage: ./health_check.sh [explain]

EXPLAIN=0
if [ "${1:-}" = "explain" ]; then
  EXPLAIN=1
fi

# Thresholds (adjust as needed)
CPU_WARN=0.70
CPU_CRIT=1.00
MEM_WARN=75.0
MEM_CRIT=90.0
DISK_WARN=80
DISK_CRIT=90

status_code=0 # 0=OK,1=WARN,2=CRIT

# Helpers
set_status() {
  local new=$1
  if [ "$new" -gt "$status_code" ]; then
    status_code=$new
  fi
}

# CPU: compare 1-min load per CPU
get_cpu() {
  local cores load1 load_per_cpu
  cores=$(nproc 2>/dev/null || echo 1)
  if [ -r /proc/loadavg ]; then
    load1=$(cut -d' ' -f1 /proc/loadavg)
  else
    load1=$(uptime | awk -F'load average:' '{print $2}' | awk -F, '{print $1}')
  fi
  load_per_cpu=$(awk -v l="$load1" -v c="$cores" 'BEGIN{printf "%.2f", (l/c)}')
  echo "$load_per_cpu|$load1|$cores"
}

# Memory: use /proc/meminfo if available
get_mem() {
  local total avail used_pct
  if [ -r /proc/meminfo ]; then
    total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    if [ -z "$avail" ]; then
      # Fallback: estimate available as free+cached
      avail=$(( $(awk '/MemFree/ {print $2}' /proc/meminfo) + $(awk '/^Cached:/ {print $2}' /proc/meminfo) ))
    fi
    used_pct=$(awk -v t="$total" -v a="$avail" 'BEGIN{printf "%.1f", (1 - a/t) * 100}')
    echo "$used_pct|$total|$avail"
  else
    # Fallback to free
    if command -v free >/dev/null 2>&1; then
      used_pct=$(free -m | awk 'NR==2{printf "%.1f", $3/$2*100}')
      echo "$used_pct|0|0"
    else
      echo "0|0|0"
    fi
  fi
}

# Disk: check filesystems (exclude tmpfs and devtmpfs)
get_disk() {
  # Output: mount percent_for_worst
  local worst_pct=0
  local worst_mount=""
  # Use POSIX df -P; ignore tmpfs/devtmpfs
  df -P -x tmpfs -x devtmpfs 2>/dev/null | awk 'NR>1{print $6" "$5}' | while read -r mount pcent; do
    pnum=${pcent%%%}
    # In some systems pcent may be like "90%"; strip
    pnum=${pnum%%%}
    if [ -n "$pnum" ] 2>/dev/null; then
      if [ "$pnum" -gt "$worst_pct" ]; then
        worst_pct=$pnum
        worst_mount=$mount
      fi
    fi
  done
  # awk in a subshell loses variables; compute again in bash for portability
  worst_pct=0
  worst_mount=""
  while read -r fs blocks used avail pcent mount; do
    pnum=${pcent%%%}
    if [ -n "$pnum" ] && [ "$pnum" -gt "$worst_pct" ]; then
      worst_pct=$pnum
      worst_mount=$mount
    fi
  done < <(df -P -x tmpfs -x devtmpfs 2>/dev/null | sed 1d)
  echo "$worst_pct|$worst_mount"
}

# Run checks
cpu_raw=$(get_cpu)
cpu_per_cpu=$(echo "$cpu_raw" | cut -d'|' -f1)
cpu_load=$(echo "$cpu_raw" | cut -d'|' -f2)
cpu_cores=$(echo "$cpu_raw" | cut -d'|' -f3)

mem_raw=$(get_mem)
mem_used_pct=$(echo "$mem_raw" | cut -d'|' -f1)

disk_raw=$(get_disk)
disk_pct=$(echo "$disk_raw" | cut -d'|' -f1)
disk_mount=$(echo "$disk_raw" | cut -d'|' -f2)

# Evaluate CPU
cpu_sev=0
cpu_cmp=$(awk -v v="$cpu_per_cpu" -v w="$CPU_WARN" 'BEGIN{print (v>=w)?1:0}')
cpu_cmp2=$(awk -v v="$cpu_per_cpu" -v c="$CPU_CRIT" 'BEGIN{print (v>=c)?1:0}')
if [ "$cpu_cmp2" -eq 1 ]; then
  cpu_sev=2
elif [ "$cpu_cmp" -eq 1 ]; then
  cpu_sev=1
fi
set_status $cpu_sev

# Evaluate Memory
mem_sev=0
if awk -v v="$mem_used_pct" -v c="$MEM_CRIT" 'BEGIN{exit !(v>=c)}'; then
  mem_sev=2
elif awk -v v="$mem_used_pct" -v w="$MEM_WARN" 'BEGIN{exit !(v>=w)}'; then
  mem_sev=1
fi
set_status $mem_sev

# Evaluate Disk
disk_sev=0
if [ -n "$disk_pct" ]; then
  if [ "$disk_pct" -ge "$DISK_CRIT" ]; then
    disk_sev=2
  elif [ "$disk_pct" -ge "$DISK_WARN" ]; then
    disk_sev=1
  fi
fi
set_status $disk_sev

# Summary output
overall_text="OK"
if [ "$status_code" -eq 2 ]; then
  overall_text="CRITICAL"
elif [ "$status_code" -eq 1 ]; then
  overall_text="WARNING"
fi

if [ "$EXPLAIN" -eq 1 ]; then
  cat <<EOF
Health check: $overall_text

CPU:
  1-min load: $cpu_load
  CPUs: $cpu_cores
  Load per CPU: $cpu_per_cpu
  Thresholds: WARN=$CPU_WARN, CRIT=$CPU_CRIT
  Status: $( [ $cpu_sev -eq 2 ] && echo CRITICAL || ( [ $cpu_sev -eq 1 ] && echo WARNING || echo OK) )

Memory:
  Used: ${mem_used_pct}%
  Thresholds: WARN=${MEM_WARN}%, CRIT=${MEM_CRIT}%
  Status: $( [ $mem_sev -eq 2 ] && echo CRITICAL || ( [ $mem_sev -eq 1 ] && echo WARNING || echo OK) )

Disk (worst):
  Mount: ${disk_mount:-N/A}
  Percent used: ${disk_pct:-N/A}%
  Thresholds: WARN=${DISK_WARN}%, CRIT=${DISK_CRIT}%
  Status: $( [ $disk_sev -eq 2 ] && echo CRITICAL || ( [ $disk_sev -eq 1 ] && echo WARNING || echo OK) )

Exit code: $status_code (0=OK,1=WARNING,2=CRITICAL)
EOF
else
  echo "Health: $overall_text"
fi

# Exit with code representing worst status
exit $status_code
