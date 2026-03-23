#!/usr/bin/env bash
#
# Automated Macrobenchmark runner

set -euo pipefail

# Constants
readonly TEST_RUNNER="androidx.test.runner.AndroidJUnitRunner"
readonly EMULATOR_BENCHMARK_RESULT_DIR="/sdcard/Download/macrobenchmark"

# Config
NUMBER_OF_RUNS=1
PATH_APK_BASELINE=""
PATH_APK_CANDIDATE=""
PATH_APK_BENCHMARK=""
INSTRUMENT_PASSTHROUGH_ARGS=()

OUTPUT_DIR="./macrobenchmark_results"

# Temporary workspace (Cleaned up automatically on exit)
readonly TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

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
  -h, --help                   Display this help message and exit.

Additional Arguments:
  --                           Everything after '--' is passed directly to
                               the adb instrumentation command.

Example:
  $(basename "$0") -o ./macrobenchmark_results --baseline_apk base.apk --candidate_apk candidate.apk -- -e androidx.benchmark.profiling.mode none
EOF
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
  echo "Running benchmarks..."

  adb shell am instrument -w                                      \
    -e androidx.benchmark.suppressErrors EMULATOR                 \
    -e androidx.benchmark.profiling.mode none                     \
    -e no-isolated-storage true                                   \
    -e additionalTestOutputDir "${EMULATOR_BENCHMARK_RESULT_DIR}" \
    "${INSTRUMENT_PASSTHROUGH_ARGS[@]}"                           \
    "${BENCHMARK_PKG_NAME}/$TEST_RUNNER"
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

#############################################################################

main() {
  # State Validation
  [[ -n "${PATH_APK_BASELINE}"  ]] || { print_usage; exit 1; }
  [[ -n "${PATH_APK_CANDIDATE}" ]] || { print_usage; exit 1; }
  [[ -n "${PATH_APK_BENCHMARK}" ]] || { print_usage; exit 1; }

  [[ -f "${PATH_APK_BASELINE}"  ]] || die "Baseline APK not found: ${PATH_APK_BASELINE}"
  [[ -f "${PATH_APK_CANDIDATE}" ]] || die "Candidate APK not found: ${PATH_APK_CANDIDATE}"
  [[ -f "${PATH_APK_BENCHMARK}" ]] || die "Benchmark APK not found: ${PATH_APK_BENCHMARK}"

  APP_PKG_NAME=$(get_pkg_name_from_apk "${PATH_APK_BASELINE}")
  BENCHMARK_PKG_NAME=$(get_pkg_name_from_apk "${PATH_APK_BENCHMARK}")
  readonly APP_PKG_NAME BENCHMARK_PKG_NAME

  install_apk "${PATH_APK_BENCHMARK}"

  for ((i=1; i<=${NUMBER_OF_RUNS}; i++)); do
    echo "--- Starting benchmark run ($i / ${NUMBER_OF_RUNS}) ---"

    start_time=$SECONDS
    output_filename="${BENCHMARK_PKG_NAME}_$(date +"%Y-%m-%dT%H-%M-%S").json"

    # Baseline
    install_apk "${PATH_APK_BASELINE}"
    run_benchmark
    collect_benchmark_result "${OUTPUT_DIR}/baseline/${output_filename}"

    # Candidate
    install_apk "${PATH_APK_CANDIDATE}"
    run_benchmark
    collect_benchmark_result "${OUTPUT_DIR}/candidate/${output_filename}"

    duration=$((SECONDS - start_time))
    echo "--- Ending benchmark run ($i / ${NUMBER_OF_RUNS}) took ${duration}s ---"
  done

  echo "Benchmark completed. Results in \"$OUTPUT_DIR\""
}

main
