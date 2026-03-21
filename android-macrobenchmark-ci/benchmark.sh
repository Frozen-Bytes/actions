#!/usr/bin/env bash

set -euo pipefail

# Configuration & Defaults
NUMBER_OF_RUNS=1
PATH_APK_BASELINE=""
PATH_APK_CANDIDATE=""
PATH_APK_BENCHMARK=""
INSTRUMENT_PASSTHROUGH_ARGS=()
OUTPUT_DIR="./macrobenchmark_results"
TEST_RUNNER="androidx.test.runner.AndroidJUnitRunner"
EMULATOR_BENCHMARK_RESULT_DIR="/sdcard/Download"

# Logging
LOG_DIR=""  # Set after OUTPUT_DIR is finalized
MONITOR_PID=""

# Cleanup
TEMP_DIR="$(mktemp -d)"
trap 'cleanup' EXIT

cleanup() {
  stop_emulator_monitor
  rm -rf "${TEMP_DIR}"
}

die() {
  echo "err: $*" 1>&2
  exit 1
}

print_usage() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS] --baseline_apk <path> --candidate_apk <path> --benchmark_apk <path> [-- INSTRUMENT_ARGS]

Automated benchmark script for APKs.

Options:
  -o, --output-dir <path>      Directory where benchmark results will be saved. (Default: "${OUTPUT_DIR}")
  --baseline-apk <path>        Path to the baseline APK file.
  --candidate-apk <path>       Path to the candidate APK file.
  --benchmark-apk <path>       Path to the benchmark APK. Must contain instrumented tests.
  -n, --runs <number>          Set number of runs per benchmark. (Default: 1)
  -h, --help                   Display this help message and exit.

Additional Arguments:
  --                           Everything after '--' is passed directly to
                               the adb instrumentation command.

Example:
  $(basename "$0") -o ./macrobenchmark_results --baseline_apk base.apk --candidate_apk candidate.apk -- -e androidx.benchmark.profiling.mode none
EOF
}

# ─────────────────────────────────────────────
# LOGGING HELPERS
# ─────────────────────────────────────────────

init_log_dir() {
  LOG_DIR="${OUTPUT_DIR}/logs"
  mkdir -p "${LOG_DIR}"
}

log_section() {
  local label="$1"
  local file="$2"
  echo "" >> "${file}"
  echo "════════════════════════════════════════" >> "${file}"
  echo "  ${label}  —  $(date '+%Y-%m-%d %H:%M:%S')" >> "${file}"
  echo "════════════════════════════════════════" >> "${file}"
}

# ─────────────────────────────────────────────
# HOST ENVIRONMENT SNAPSHOT
# Captures static facts about the GH Actions runner
# that don't change during the run. Useful to correlate
# failures against runner specs across different CI jobs.
# ─────────────────────────────────────────────

log_host_environment() {
  local file="${LOG_DIR}/host_environment.txt"
  echo "Logging host environment → ${file}"

  log_section "OS & Kernel" "${file}"
  uname -a >> "${file}"
  cat /etc/os-release >> "${file}" 2>/dev/null || true

  log_section "CPU Info" "${file}"
  # Model name, architecture, core count, frequency
  lscpu >> "${file}" 2>/dev/null || true
  # Raw /proc/cpuinfo as fallback / supplement
  echo "--- /proc/cpuinfo (first 40 lines) ---" >> "${file}"
  head -40 /proc/cpuinfo >> "${file}" 2>/dev/null || true

  log_section "Memory Info" "${file}"
  # Total RAM, type info if available
  cat /proc/meminfo >> "${file}" 2>/dev/null || true
  # DMI/SMBIOS memory type (may require root — fine if it fails)
  sudo dmidecode --type memory 2>/dev/null | grep -E "Type|Speed|Size|Manufacturer" >> "${file}" || true

  log_section "Disk Info" "${file}"
  df -h >> "${file}" 2>/dev/null || true
  lsblk >> "${file}" 2>/dev/null || true

  log_section "Virtualization" "${file}"
  # Confirms whether we're on a VM and what hypervisor — relevant
  # because nested virtualization affects emulator performance significantly
  systemd-detect-virt 2>/dev/null >> "${file}" || echo "systemd-detect-virt not available" >> "${file}"
  cat /proc/cpuinfo | grep -E "hypervisor|vmx|svm" | head -5 >> "${file}" || true

  log_section "Running Processes (top 20 by memory)" "${file}"
  ps aux --sort=-%mem | head -20 >> "${file}" 2>/dev/null || true
}

# ─────────────────────────────────────────────
# POINT-IN-TIME SNAPSHOT
# Called before/after each baseline and candidate run.
# Captures the host + emulator state at that exact moment.
# ─────────────────────────────────────────────

log_snapshot() {
  local label="$1"     # e.g. "before_baseline_run_1"
  local file="${LOG_DIR}/snapshots.txt"

  log_section "${label}" "${file}"

  echo "--- Host: free memory ---" >> "${file}"
  free -h >> "${file}" 2>/dev/null || true

  echo "--- Host: CPU load average ---" >> "${file}"
  uptime >> "${file}" 2>/dev/null || true

  echo "--- Host: top 10 CPU consumers ---" >> "${file}"
  ps aux --sort=-%cpu | head -10 >> "${file}" 2>/dev/null || true

  echo "--- Emulator: /proc/meminfo ---" >> "${file}"
  adb shell cat /proc/meminfo 2>/dev/null >> "${file}" || echo "adb not available" >> "${file}"

  echo "--- Emulator: CPU load average ---" >> "${file}"
  adb shell cat /proc/loadavg 2>/dev/null >> "${file}" || true

  echo "--- Emulator: top processes (1 sample) ---" >> "${file}"
  adb shell top -n 1 -b 2>/dev/null | head -20 >> "${file}" || true

  echo "--- Emulator: available storage ---" >> "${file}"
  adb shell df /sdcard 2>/dev/null >> "${file}" || true
}

# ─────────────────────────────────────────────
# CONTINUOUS EMULATOR MONITOR
# Polls emulator memory + CPU every 3 seconds in the background.
# The timestamp lets you line up exactly which iteration was
# running when resources started degrading.
# ─────────────────────────────────────────────

start_emulator_monitor() {
  local file="${LOG_DIR}/emulator_monitor.csv"
  echo "timestamp,event,mem_total_kb,mem_available_kb,mem_used_kb,cpu_pct" > "${file}"

  (
    while true; do
      TS=$(date '+%Y-%m-%d %H:%M:%S')

      MEM_INFO=$(adb shell cat /proc/meminfo 2>/dev/null || true)
      MEM_TOTAL=$(echo "${MEM_INFO}"     | awk '/^MemTotal/{print $2}')
      MEM_AVAILABLE=$(echo "${MEM_INFO}" | awk '/^MemAvailable/{print $2}')
      MEM_USED=$(( ${MEM_TOTAL:-0} - ${MEM_AVAILABLE:-0} ))

      # CPU: two /proc/stat samples 1s apart → calculate usage %
      CPU1=$(adb shell cat /proc/stat 2>/dev/null | awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5+$6}')
      sleep 1
      CPU2=$(adb shell cat /proc/stat 2>/dev/null | awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5+$6}')
      TOTAL1=$(echo "${CPU1}" | cut -d' ' -f1)
      IDLE1=$(echo "${CPU1}"  | cut -d' ' -f2)
      TOTAL2=$(echo "${CPU2}" | cut -d' ' -f1)
      IDLE2=$(echo "${CPU2}"  | cut -d' ' -f2)
      DIFF_TOTAL=$(( ${TOTAL2:-0} - ${TOTAL1:-0} ))
      DIFF_IDLE=$(( ${IDLE2:-0}   - ${IDLE1:-0} ))
      if [ "${DIFF_TOTAL}" -gt 0 ]; then
        CPU_PCT=$(( (DIFF_TOTAL - DIFF_IDLE) * 100 / DIFF_TOTAL ))
      else
        CPU_PCT=0
      fi

      echo "${TS},poll,${MEM_TOTAL:-0},${MEM_AVAILABLE:-0},${MEM_USED},${CPU_PCT}" >> "${file}"

      sleep 2  # total ~3s per sample (1s for CPU diff + 2s sleep)
    done
  ) &
  MONITOR_PID=$!
}

stop_emulator_monitor() {
  if [[ -n "${MONITOR_PID}" ]]; then
    kill "${MONITOR_PID}" 2>/dev/null || true
    wait "${MONITOR_PID}" 2>/dev/null || true
    MONITOR_PID=""
  fi
}

# Write a named marker into the monitor CSV so you can see
# exactly when baseline ended, candidate started, etc.
log_monitor_event() {
  local event="$1"
  local file="${LOG_DIR}/emulator_monitor.csv"
  echo "$(date '+%Y-%m-%d %H:%M:%S'),${event},,,," >> "${file}"
}

# ─────────────────────────────────────────────
# FAILURE SNAPSHOT
# Called automatically via trap ERR — captures the system
# state at the exact moment of failure, which is the most
# valuable data for diagnosing flakiness.
# ─────────────────────────────────────────────

log_failure_snapshot() {
  local file="${LOG_DIR}/failure_snapshot.txt"
  log_section "FAILURE at $(date '+%Y-%m-%d %H:%M:%S')" "${file}"

  echo "--- Host: free memory ---" >> "${file}"
  free -h >> "${file}" 2>/dev/null || true

  echo "--- Host: load average ---" >> "${file}"
  uptime >> "${file}" 2>/dev/null || true

  echo "--- Host: top 15 memory consumers ---" >> "${file}"
  ps aux --sort=-%mem | head -15 >> "${file}" 2>/dev/null || true

  echo "--- Host: top 15 CPU consumers ---" >> "${file}"
  ps aux --sort=-%cpu | head -15 >> "${file}" 2>/dev/null || true

  echo "--- Emulator: /proc/meminfo ---" >> "${file}"
  adb shell cat /proc/meminfo 2>/dev/null >> "${file}" || true

  echo "--- Emulator: /proc/loadavg ---" >> "${file}"
  adb shell cat /proc/loadavg 2>/dev/null >> "${file}" || true

  echo "--- Emulator: top processes ---" >> "${file}"
  adb shell top -n 1 -b 2>/dev/null >> "${file}" || true

  echo "--- Emulator: logcat (last 200 lines) ---" >> "${file}"
  adb logcat -d -t 200 2>/dev/null >> "${file}" || true

  echo "--- Emulator: UI hierarchy dump ---" >> "${file}"
  adb shell uiautomator dump /sdcard/ui_dump.xml 2>/dev/null && \
    adb pull /sdcard/ui_dump.xml "${LOG_DIR}/failure_ui_dump.xml" 2>/dev/null || \
    echo "UI dump failed" >> "${file}"
}

trap 'log_failure_snapshot' ERR

# ─────────────────────────────────────────────
# LOGCAT CAPTURE
# Captures benchmark-related logcat lines continuously.
# The BENCH_TIMING tag picks up any timing logs you add
# to forYouWaitForContent(); the AndroidRuntime tag catches
# crashes; Benchmark catches the framework's own output.
# ─────────────────────────────────────────────

start_logcat_capture() {
  local label="$1"   # e.g. "baseline_run_1"
  adb logcat -c 2>/dev/null || true   # clear buffer before each run
  adb logcat -s "BENCH_TIMING:*" "AndroidRuntime:E" "Benchmark:*" "MacrobenchmarkScope:*" \
    >> "${LOG_DIR}/logcat_${label}.txt" 2>/dev/null &
  echo $! >> "${TEMP_DIR}/logcat_pids.txt"
}

stop_logcat_capture() {
  if [[ -f "${TEMP_DIR}/logcat_pids.txt" ]]; then
    while read -r pid; do
      kill "${pid}" 2>/dev/null || true
    done < "${TEMP_DIR}/logcat_pids.txt"
    rm -f "${TEMP_DIR}/logcat_pids.txt"
  fi
}

# ─────────────────────────────────────────────
# ORIGINAL FUNCTIONS (unchanged logic, logging added)
# ─────────────────────────────────────────────

get_pkg_name() {
  local apk="${1}"
  apkanalyzer manifest application-id "${apk}"
}

install_apk() {
  local apk="${1}"
  echo "Installing APK: ${apk}"
  adb install -d "${apk}" > /dev/null || die "failed to install apk '${apk}'"
  adb shell pm clear "${APP_PKG_NAME}" > /dev/null 2>&1 || true
  adb shell pm clear "${BENCHMARK_PKG_NAME}" > /dev/null 2>&1 || true
  adb shell "rm -rf ${EMULATOR_BENCHMARK_RESULT_DIR} && mkdir -p ${EMULATOR_BENCHMARK_RESULT_DIR}" > /dev/null || true
}

run_benchmark() {
  echo "Running benchmarks..."
  adb shell am instrument -w \
    -e androidx.benchmark.suppressErrors EMULATOR \
    -e androidx.benchmark.profiling.mode none \
    -e no-isolated-storage true \
    -e additionalTestOutputDir "${EMULATOR_BENCHMARK_RESULT_DIR}" \
    "${INSTRUMENT_PASSTHROUGH_ARGS[@]}" \
    "${BENCHMARK_PKG_NAME}/$TEST_RUNNER"
}

write_benchmark_result() {
  local dest_path="${1}"
  local pull_temp="${TEMP_DIR}/pull_$(date +%s)"
  adb pull "${EMULATOR_BENCHMARK_RESULT_DIR}/." "${pull_temp}" > /dev/null
  mkdir -p $(dirname "${dest_path}") && mv "${pull_temp}/"*.json "${dest_path}"
}

# ─────────────────────────────────────────────
# ARG PARSING
# ─────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_usage
      exit 0
      ;;
    -o|--output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --baseline-apk)
      PATH_APK_BASELINE="$2"
      shift 2
      ;;
    --candidate-apk)
      PATH_APK_CANDIDATE="$2"
      shift 2
      ;;
    --benchmark-apk)
      PATH_APK_BENCHMARK="$2"
      shift 2
      ;;
    -n|--runs)
      NUMBER_OF_RUNS="$2"
      if ! [[ "$NUMBER_OF_RUNS" -eq "$NUMBER_OF_RUNS" ]] 2> /dev/null; then
          print_usage
          exit 1
      fi
      shift 2
      ;;
    --)
      shift
      INSTRUMENT_PASSTHROUGH_ARGS+=("$@")
      break
      ;;
    *)
      echo "$(basename "$0"): invalid option -- '$1'"
      echo "Try '$(basename "$0") --help' for more information"
      exit 1
      ;;
  esac
done

if [[ -z "${PATH_APK_BASELINE}" || -z "${PATH_APK_CANDIDATE}" || -z "${PATH_APK_BENCHMARK}" ]]; then
    print_usage
    exit 1
fi

# ─────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────

APP_PKG_NAME=$(get_pkg_name "${PATH_APK_BASELINE}")
BENCHMARK_PKG_NAME=$(get_pkg_name "${PATH_APK_BENCHMARK}")

init_log_dir

# One-time: snapshot static host facts before anything runs
log_host_environment

# Start continuous emulator resource monitor (runs for entire script duration)
start_emulator_monitor

install_apk "${PATH_APK_BENCHMARK}"

for ((i=1; i<=${NUMBER_OF_RUNS}; i++)); do
  echo "--- Starting benchmark run (${i} / ${NUMBER_OF_RUNS}) ---"
  start_time=$SECONDS
  output_filename="${BENCHMARK_PKG_NAME}_$(date +"%Y-%m-%dT%H-%M-%S").json"

  # Baseline
  log_monitor_event "baseline_run_${i}_start"
  log_snapshot "before_baseline_run_${i}"
  start_logcat_capture "baseline_run_${i}"

  install_apk "${PATH_APK_BASELINE}"
  run_benchmark
  write_benchmark_result "${OUTPUT_DIR}/baseline/${output_filename}"

  stop_logcat_capture
  log_snapshot "after_baseline_run_${i}"
  log_monitor_event "baseline_run_${i}_end"

  # Candidate
  log_monitor_event "candidate_run_${i}_start"
  log_snapshot "before_candidate_run_${i}"
  start_logcat_capture "candidate_run_${i}"

  install_apk "${PATH_APK_CANDIDATE}"
  run_benchmark
  write_benchmark_result "${OUTPUT_DIR}/candidate/${output_filename}"

  stop_logcat_capture
  log_snapshot "after_candidate_run_${i}"
  log_monitor_event "candidate_run_${i}_end"

  duration=$((SECONDS - start_time))
  echo "--- Ending benchmark run (${i} / ${NUMBER_OF_RUNS}) took ${duration}s ---"
done

stop_emulator_monitor

echo "Benchmark completed. Results in '${OUTPUT_DIR}'"
echo "Logs saved in '${LOG_DIR}'"
