#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' \
    'Usage:' \
    '  compose-clean-2x.sh --source PATH --donor PATH --region SPEC [--region SPEC ...] [--output PATH] [--overwrite]' \
    '' \
    'Region SPEC: x:y:width:height[:feather[:dx[:dy]]]' \
    '  feather defaults to 6; dx and dy default to 0.' \
    '  Positive dx moves donor content right; positive dy moves it down.'
}

source_path=''
donor_path=''
output_path=''
overwrite=0
regions=()

while (($#)); do
  case "$1" in
    --source)
      (($# >= 2)) || { usage >&2; exit 2; }
      source_path=$2
      shift 2
      ;;
    --donor)
      (($# >= 2)) || { usage >&2; exit 2; }
      donor_path=$2
      shift 2
      ;;
    --region)
      (($# >= 2)) || { usage >&2; exit 2; }
      regions+=("$2")
      shift 2
      ;;
    --output)
      (($# >= 2)) || { usage >&2; exit 2; }
      output_path=$2
      shift 2
      ;;
    --overwrite)
      overwrite=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$source_path" && -n "$donor_path" && ${#regions[@]} -gt 0 ]] || {
  usage >&2
  exit 2
}

[[ -f "$source_path" ]] || { printf 'Source not found: %s\n' "$source_path" >&2; exit 1; }
[[ -f "$donor_path" ]] || { printf 'Donor not found: %s\n' "$donor_path" >&2; exit 1; }
command -v ffmpeg >/dev/null || { printf 'ffmpeg is required.\n' >&2; exit 1; }
command -v ffprobe >/dev/null || { printf 'ffprobe is required.\n' >&2; exit 1; }

dimensions=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$source_path")
IFS=x read -r source_width source_height <<< "$dimensions"
[[ "$source_width" =~ ^[0-9]+$ && "$source_height" =~ ^[0-9]+$ ]] || {
  printf 'Could not read source dimensions.\n' >&2
  exit 1
}

source_dir=$(cd "$(dirname "$source_path")" && pwd)
source_name=$(basename "$source_path")
source_stem=${source_name%.*}
if [[ -z "$output_path" ]]; then
  output_dir="$source_dir/高清处理版本"
  output_path="$output_dir/${source_stem}_高清处理_2x.png"
else
  output_dir=$(dirname "$output_path")
fi

mkdir -p "$output_dir"
if [[ -e "$output_path" && "$overwrite" -ne 1 ]]; then
  printf 'Output already exists; pass --overwrite only after verifying it is the prior derivative: %s\n' "$output_path" >&2
  exit 1
fi

cleanup_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/faithful-image-cleanup.XXXXXX")
trap 'rm -rf "$cleanup_tmp_dir"' EXIT

current_path=$source_path
step_index=0

for region_spec in "${regions[@]}"; do
  IFS=: read -r region_x region_y region_width region_height region_feather donor_dx donor_dy extra <<< "$region_spec"
  region_feather=${region_feather:-6}
  donor_dx=${donor_dx:-0}
  donor_dy=${donor_dy:-0}

  [[ -z "${extra:-}" ]] || { printf 'Too many fields in region: %s\n' "$region_spec" >&2; exit 2; }
  for value in "$region_x" "$region_y" "$region_width" "$region_height" "$region_feather"; do
    [[ "$value" =~ ^[0-9]+$ ]] || { printf 'Region values must be non-negative integers: %s\n' "$region_spec" >&2; exit 2; }
  done
  [[ "$donor_dx" =~ ^-?[0-9]+$ && "$donor_dy" =~ ^-?[0-9]+$ ]] || {
    printf 'dx and dy must be integers: %s\n' "$region_spec" >&2
    exit 2
  }
  ((region_width > 0 && region_height > 0)) || { printf 'Region width and height must be positive.\n' >&2; exit 2; }
  ((region_x + region_width <= source_width && region_y + region_height <= source_height)) || {
    printf 'Region is outside the source canvas: %s\n' "$region_spec" >&2
    exit 2
  }
  ((region_feather <= 64)) || { printf 'Feather must be between 0 and 64.\n' >&2; exit 2; }

  if ((donor_dx >= 0)); then
    pad_x=$donor_dx
    crop_x=0
    padded_width=$((source_width + donor_dx))
  else
    pad_x=0
    crop_x=$((-donor_dx))
    padded_width=$((source_width - donor_dx))
  fi
  if ((donor_dy >= 0)); then
    pad_y=$donor_dy
    crop_y=0
    padded_height=$((source_height + donor_dy))
  else
    pad_y=0
    crop_y=$((-donor_dy))
    padded_height=$((source_height - donor_dy))
  fi

  region_x2=$((region_x + region_width - 1))
  region_y2=$((region_y + region_height - 1))
  next_path="$cleanup_tmp_dir/step-${step_index}.png"
  mask_filter="format=gray,geq=lum='if(between(X,${region_x},${region_x2})*between(Y,${region_y},${region_y2}),255,0)'"
  if ((region_feather > 0)); then
    mask_filter+=",boxblur=${region_feather}:1"
  fi

  ffmpeg -hide_banner -loglevel error -y \
    -i "$current_path" \
    -i "$donor_path" \
    -f lavfi -i "nullsrc=s=${source_width}x${source_height}:d=1" \
    -filter_complex "[1:v]scale=${source_width}:${source_height}:flags=lanczos,pad=${padded_width}:${padded_height}:${pad_x}:${pad_y}:black,crop=${source_width}:${source_height}:${crop_x}:${crop_y}[donor];[2:v]${mask_filter}[mask];[donor][mask]alphamerge[patch];[0:v][patch]overlay=0:0:format=auto[out]" \
    -map '[out]' -frames:v 1 "$next_path"

  current_path=$next_path
  step_index=$((step_index + 1))
done

output_width=$((source_width * 2))
output_height=$((source_height * 2))
ffmpeg -hide_banner -loglevel error -y \
  -i "$current_path" \
  -vf "scale=${output_width}:${output_height}:flags=lanczos,cas=strength=0.22" \
  -frames:v 1 "$output_path"

printf 'OUTPUT=%s\n' "$output_path"
printf 'SOURCE_SIZE=%sx%s\n' "$source_width" "$source_height"
printf 'OUTPUT_SIZE=%sx%s\n' "$output_width" "$output_height"
printf 'SHARPEN=cas:0.22\n'
