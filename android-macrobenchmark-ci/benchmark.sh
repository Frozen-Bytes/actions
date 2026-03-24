#!/usr/bin/env bash
#
# Automated Macrobenchmark runner

set -euo pipefail

# Constants
readonly TEST_RUNNER="androidx.test.runner.AndroidJUnitRunner"
readonly EMULATOR_BENCHMARK_RESULT_DIR="/sdcard/Download/macrobenchmark"

# Config
NUMBER_OF_RUNS=1
MAX_BENCHMARK_RETRIES=3

PATH_APK_BASELINE=""
PATH_APK_CANDIDATE=""
PATH_APK_BENCHMARK=""
INSTRUMENT_PASSTHROUGH_ARGS=()

OUTPUT_DIR="./macrobenchmark_results"

# Spinner
SPINNER_PID=-1

# Temporary workspace (Cleaned up automatically on exit)
readonly TEMP_DIR="$(mktemp -d)"
trap cleanup EXIT

cleanup() {
  rm -rf "${TEMP_DIR}" || true
  stop_spinner || true
}

#############################################################################
# Helpers
#############################################################################

die() {
  echo "err: $*" >&2
  exit 1
}

warn() {
  echo "warn: $*" >&2
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
  -n, --runs <number>          Set number of runs per benchmark. (Default: ${NUMBER_OF_RUNS})
  --retry <number>             Number of times to retry the benchmark on failure (Default: ${MAX_BENCHMARK_RETRIES}).
  -h, --help                   Display this help message and exit.

Additional Arguments:
  --                           Everything after '--' is passed directly to
                               the adb instrumentation command.

Example:
  $(basename "$0") -o ./macrobenchmark_results --baseline_apk base.apk --candidate_apk candidate.apk -- -e androidx.benchmark.profiling.mode none
EOF
}

print_usage_and_exit() {
  print_usage
  exit 1
}

_start_spinner() {
  local text="$1"
  local do_display_elapsed_time="$2"
  local start_time=$SECONDS

  while true; do
    local elapsed=""
    if [[ "$do_display_elapsed_time" = true ]]; then
      elapsed=" $(( SECONDS - start_time ))s"
    fi

    echo "${text}${elapsed}"
    sleep 60
  done
}

start_spinner() {
  _start_spinner "$@" &
  SPINNER_PID=$!
}

stop_spinner() {
  if (( SPINNER_PID < 0 )); then
    return
  fi

  kill "${SPINNER_PID}" &>/dev/null || true
  wait "${SPINNER_PID}" &>/dev/null || true

  SPINNER_PID=-1
}

get_pkg_name_from_apk() {
  local apk_path="$1"
  apkanalyzer manifest application-id "${apk_path}"
}

install_apk() {
  local apk_path="$1"

  echo "Installing APK: ${apk_path}"

  # -d allows version downgrade
  adb install -d "${apk_path}" >/dev/null || die "failed to install apk \"${apk_path}\""

  # Clear any state left by a previous run
  adb shell pm clear "${APP_PKG_NAME}"                    &>/dev/null || true
  adb shell pm clear "${BENCHMARK_PKG_NAME}"              &>/dev/null || true
  adb shell "rm -rf \"${EMULATOR_BENCHMARK_RESULT_DIR}\"" &>/dev/null || true

  # Create any necessary directories
  adb shell "mkdir -p \"${EMULATOR_BENCHMARK_RESULT_DIR}\"" &>/dev/null || true
}

#############################################################################

#############################################################################
# Benchmark
#############################################################################

run_benchmark() {
  start_spinner "Running benchmarks..." true

  local output=$(
    adb shell am instrument -w                                    \
    -e androidx.benchmark.suppressErrors EMULATOR                 \
    -e androidx.benchmark.profiling.mode none                     \
    -e no-isolated-storage true                                   \
    -e additionalTestOutputDir "${EMULATOR_BENCHMARK_RESULT_DIR}" \
    "${INSTRUMENT_PASSTHROUGH_ARGS[@]}"                           \
    "${BENCHMARK_PKG_NAME}/$TEST_RUNNER"
  )

  stop_spinner

  echo "${output}"

  if [[ "${output}" =~ "FAILURES" ]]; then
      return 1
  fi

  return 0
}

run_benchmark_with_retry() {
  local apk_path="$1"
  local success=false
  local attempts=$(( MAX_BENCHMARK_RETRIES + 1 ))

  local attempt
  for (( attempt=1; attempt <= attempts; attempt++ )); do
    # Reinstall before retrying to restore a clean device state.
    install_apk "${apk_path}"

    if run_benchmark; then
      success=true
      break
    fi

    if (( attempt <= MAX_BENCHMARK_RETRIES )); then
      warn "benchmark attempt ${attempt} failed. Retrying (${attempt} / ${MAX_BENCHMARK_RETRIES})"
    fi
  done

  if ! ${success}; then
    die "benchmark failed after ${attempts} attempt(s)"
  fi
}

collect_benchmark_result() {
  local dest_json="${1}"
  local staging_dir="${TEMP_DIR}/pull_$(date +%s)"

  adb pull "${EMULATOR_BENCHMARK_RESULT_DIR}/." "${staging_dir}" &>/dev/null || true

  mkdir -p "$(dirname "${dest_json}")" &>/dev/null || true

  # There should be exactly 1 json file
  mv "${staging_dir}/"*.json "${dest_json}" &>/dev/null || warn "failed to collect Macrobenchmark report, skipping"
}

#############################################################################

#############################################################################
# Commandline Arguments Parsing
#############################################################################

parse_commandline_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        print_usage
        exit 0
        ;;

      # Required
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

      # Optional
      -o|--output-dir)
        OUTPUT_DIR="$2"
        shift 2
        ;;
      -n|--runs)
        NUMBER_OF_RUNS="$2"
        [[ "${NUMBER_OF_RUNS}" =~ ^[0-9]+$ ]] || print_usage_and_exit
        shift 2
        ;;
      --retry)
        MAX_BENCHMARK_RETRIES="$2"
        [[ "${MAX_BENCHMARK_RETRIES}" =~ ^[0-9]+$ ]] || print_usage_and_exit
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
}

#############################################################################

main() {
  parse_commandline_args "$@"

  # State Validation
  [[ -n "${PATH_APK_BASELINE}"  ]] || print_usage_and_exit
  [[ -n "${PATH_APK_CANDIDATE}" ]] || print_usage_and_exit
  [[ -n "${PATH_APK_BENCHMARK}" ]] || print_usage_and_exit

  [[ -f "${PATH_APK_BASELINE}"  ]] || die "Baseline APK not found: ${PATH_APK_BASELINE}"
  [[ -f "${PATH_APK_CANDIDATE}" ]] || die "Candidate APK not found: ${PATH_APK_CANDIDATE}"
  [[ -f "${PATH_APK_BENCHMARK}" ]] || die "Benchmark APK not found: ${PATH_APK_BENCHMARK}"

  APP_PKG_NAME=$(get_pkg_name_from_apk "${PATH_APK_BASELINE}")
  BENCHMARK_PKG_NAME=$(get_pkg_name_from_apk "${PATH_APK_BENCHMARK}")
  readonly APP_PKG_NAME BENCHMARK_PKG_NAME

  install_apk "${PATH_APK_BENCHMARK}"

  local run
  for (( run=1; run <= NUMBER_OF_RUNS; run++ )); do
    echo "--- Starting benchmark run (${run} / ${NUMBER_OF_RUNS}) ---"

    start_time=$SECONDS
    output_filename="${BENCHMARK_PKG_NAME}_$(date +"%Y-%m-%dT%H-%M-%S").json"

    # Baseline
    run_benchmark_with_retry "${PATH_APK_BASELINE}"
    collect_benchmark_result "${OUTPUT_DIR}/baseline/${output_filename}"

    # Candidate
    run_benchmark_with_retry "${PATH_APK_CANDIDATE}"
    collect_benchmark_result "${OUTPUT_DIR}/candidate/${output_filename}"

    duration=$((SECONDS - start_time))
    echo "--- Ending benchmark run (${run} / ${NUMBER_OF_RUNS}) took ${duration}s ---"
  done

  echo "Benchmark completed. Results in \"$OUTPUT_DIR\""
}

main "$@"
