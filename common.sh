#!/usr/bin/env bash
#
# common.sh
#
# S3 アップロードスクリプト（s3_upload.sh）用の共通処理ライブラリ。
#
# 想定利用:
#   本ファイルは単体実行ではなく、メインスクリプトから source して利用する。
#     source /path/to/common.sh
#
# 提供する主な機能:
#   - 日時付き・レベル制御付きログ出力（ERROR/WARN/INFO/DEBUG）
#   - 必須コマンド存在確認
#   - 引数必須チェック
#   - ファイル/ディレクトリ存在・種別・権限確認
#   - AWS CLI 実行ラッパー（プロファイル/リージョン注入・機密マスク）
#   - AWS 認証状態確認 / アカウントID取得 / 権限の簡易確認
#   - スイッチバック処理（source 方式）
#   - 一時ファイル管理と確実な削除
#   - 異常終了処理（die）
#
# 注意:
#   本ファイルは "set -Eeuo pipefail" 前提のメインスクリプトから読み込まれることを
#   想定している。ここでは set は変更しない（呼び出し元の設定を尊重する）。
#
# ------------------------------------------------------------------------------

# 二重読み込み防止
if [[ -n "${__COMMON_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
__COMMON_SH_LOADED=1

# ------------------------------------------------------------------------------
# ログレベル定義
# 数値が大きいほど詳細（ERROR=1 < WARN=2 < INFO=3 < DEBUG=4）
# 注意: 本ファイルは関数内から source される可能性があるため、グローバル配列
#       として定義するために declare -g を用いる（-g が無いと関数ローカルになり、
#       source した関数を抜けた後に未定義となってしまう）。
# ------------------------------------------------------------------------------
declare -gA __LOG_LEVELS=(
  [ERROR]=1
  [WARN]=2
  [INFO]=3
  [DEBUG]=4
)

# 既定のログレベル（メインスクリプトが上書き可能）
: "${LOG_LEVEL:=INFO}"

# 現在時刻文字列
__log_now() {
  date '+%Y-%m-%d %H:%M:%S'
}

# 現在のログレベル閾値（数値）を返す
__log_threshold() {
  local lvl="${LOG_LEVEL:-INFO}"
  echo "${__LOG_LEVELS[$lvl]:-3}"
}

# 内部: 指定レベルで出力するか判定
__log_enabled() {
  local msg_level="$1"
  local msg_num="${__LOG_LEVELS[$msg_level]:-3}"
  local threshold
  threshold="$(__log_threshold)"
  [[ "$msg_num" -le "$threshold" ]]
}

# 汎用ログ関数
# 使い方: log LEVEL "メッセージ"
log() {
  local level="$1"; shift
  local message="$*"
  __log_enabled "$level" || return 0
  local line
  line="$(__log_now) [${level}] ${message}"
  if [[ "$level" == "ERROR" || "$level" == "WARN" ]]; then
    # エラー・警告は標準エラー出力へ
    printf '%s\n' "$line" >&2
  else
    printf '%s\n' "$line"
  fi
}

log_error() { log ERROR "$@"; }
log_warn()  { log WARN  "$@"; }
log_info()  { log INFO  "$@"; }
log_debug() { log DEBUG "$@"; }

# ------------------------------------------------------------------------------
# 異常終了処理
# 使い方: die EXIT_CODE "メッセージ"
# ------------------------------------------------------------------------------
die() {
  local code="$1"; shift
  log_error "$*"
  exit "$code"
}

# ------------------------------------------------------------------------------
# 必須コマンド存在確認
# 使い方: require_commands aws zip date ...
# 見つからないコマンドがあれば die する（EXIT_MISSING_COMMAND を利用）
# ------------------------------------------------------------------------------
require_commands() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    die "${EXIT_MISSING_COMMAND:-3}" "必須コマンドが見つかりません: ${missing[*]}"
  fi
  log_debug "必須コマンド確認 OK: $*"
}

# ------------------------------------------------------------------------------
# 引数必須チェック
# 使い方: require_value "オプション名" "$値"
# ------------------------------------------------------------------------------
require_value() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    die "${EXIT_USAGE:-2}" "オプション ${name} に値が指定されていません。"
  fi
}

# ------------------------------------------------------------------------------
# ファイル/ディレクトリ確認
# ------------------------------------------------------------------------------

# 通常ファイルで読み取り可能か
assert_readable_file() {
  local path="$1"
  [[ -e "$path" ]] || die "${EXIT_LOCAL_FILE:-11}" "ファイルが存在しません: ${path}"
  [[ -f "$path" ]] || die "${EXIT_LOCAL_FILE:-11}" "通常ファイルではありません: ${path}"
  [[ -r "$path" ]] || die "${EXIT_LOCAL_FILE:-11}" "ファイルに読み取り権限がありません: ${path}"
}

# ディレクトリで読み取り・検索可能か
assert_readable_dir() {
  local path="$1"
  [[ -e "$path" ]] || die "${EXIT_LOCAL_DIR:-12}" "ディレクトリが存在しません: ${path}"
  [[ -d "$path" ]] || die "${EXIT_LOCAL_DIR:-12}" "ディレクトリではありません: ${path}"
  [[ -r "$path" && -x "$path" ]] || die "${EXIT_LOCAL_DIR:-12}" "ディレクトリに読み取り/検索権限がありません: ${path}"
}

# source 対象として安全なファイルか（存在・通常ファイル・読み取り可能）
assert_sourceable_file() {
  local path="$1"
  [[ -n "$path" ]] || die "${EXIT_USAGE:-2}" "source 対象のパスが指定されていません。"
  [[ -e "$path" ]] || die "${EXIT_USAGE:-2}" "source 対象ファイルが存在しません: ${path}"
  [[ -f "$path" ]] || die "${EXIT_USAGE:-2}" "source 対象が通常ファイルではありません: ${path}"
  [[ -r "$path" ]] || die "${EXIT_USAGE:-2}" "source 対象ファイルに読み取り権限がありません: ${path}"
}

# ------------------------------------------------------------------------------
# 一時ファイル管理
# 生成した一時パスを配列に記録し、cleanup_temp_files で一括削除する。
# ------------------------------------------------------------------------------
declare -ga __TEMP_PATHS=()

register_temp_path() {
  __TEMP_PATHS+=("$1")
}

make_temp_file() {
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/s3upload.XXXXXX")"
  register_temp_path "$tmp"
  printf '%s' "$tmp"
}

make_temp_dir() {
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/s3upload.XXXXXX")"
  register_temp_path "$tmp"
  printf '%s' "$tmp"
}

cleanup_temp_files() {
  local p
  for p in "${__TEMP_PATHS[@]:-}"; do
    [[ -n "$p" ]] || continue
    if [[ -e "$p" ]]; then
      rm -rf -- "$p" 2>/dev/null || log_warn "一時パスの削除に失敗しました: ${p}"
      log_debug "一時パスを削除しました: ${p}"
    fi
  done
  __TEMP_PATHS=()
}

# ------------------------------------------------------------------------------
# 機密値マスク
# AWS CLI コマンドをログ表示する際に、値部分をできる範囲でマスクする。
# ------------------------------------------------------------------------------
mask_sensitive() {
  # 標準入力の文字列中の機密キーワードに続く値をマスクする
  sed -E \
    -e 's/(aws_access_key_id[[:space:]=:]+)[A-Za-z0-9/+]+/\1********/Ig' \
    -e 's/(aws_secret_access_key[[:space:]=:]+)[A-Za-z0-9/+]+/\1********/Ig' \
    -e 's/(aws_session_token[[:space:]=:]+)[A-Za-z0-9/+=]+/\1********/Ig' \
    -e 's/(--sse-kms-key-id[[:space:]=]+)[^[:space:]]+/\1********/Ig'
}

# ------------------------------------------------------------------------------
# AWS CLI 実行ラッパー
#   - AWS_PAGER="" でページャー停止
#   - グローバルの AWS_PROFILE / AWS_REGION（設定されていれば）を引数として注入
#   - 実行コマンドは DEBUG でマスクして表示
#   - set -e 下でも呼び出し元が終了コードを評価できるよう、失敗しても return する
#
# 使い方:
#   if out="$(aws_cli s3api list-buckets --output json)"; then ... ; fi
#   戻り値: aws の終了コード。標準出力に aws の stdout。stderr は AWS_CLI_LAST_STDERR に格納。
# ------------------------------------------------------------------------------
AWS_CLI_LAST_STDERR=""

aws_cli() {
  local -a args=()
  # プロファイル/リージョンはグローバル変数 AWS_PROFILE_OPT / AWS_REGION_OPT から注入
  if [[ -n "${AWS_PROFILE_OPT:-}" ]]; then
    args+=(--profile "${AWS_PROFILE_OPT}")
  fi
  if [[ -n "${AWS_REGION_OPT:-}" ]]; then
    args+=(--region "${AWS_REGION_OPT}")
  fi
  args+=("$@")

  # DEBUG 表示（機密マスク）
  if __log_enabled DEBUG; then
    local shown
    shown="$(printf 'aws %s' "${args[*]}" | mask_sensitive)"
    log_debug "AWS CLI 実行: ${shown}"
  fi

  local stderr_file rc stdout
  stderr_file="$(mktemp "${TMPDIR:-/tmp}/s3upload.awserr.XXXXXX")"

  # set -e 下でも失敗を捕捉するため一時的に無効化
  set +e
  stdout="$(AWS_PAGER="" aws "${args[@]}" 2>"$stderr_file")"
  rc=$?
  set -e

  AWS_CLI_LAST_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
  rm -f -- "$stderr_file" 2>/dev/null || true

  # stdout をそのまま返す
  printf '%s' "$stdout"
  return "$rc"
}

# AWS エラー分類（AWS_CLI_LAST_STDERR を解析して種別文字列を返す）
#   出力: AUTH / PERMISSION / EXPIRED / NETWORK / OTHER
classify_aws_error() {
  local msg="${AWS_CLI_LAST_STDERR:-}"
  if grep -qiE 'ExpiredToken|token.*expired|InvalidClientTokenId|credentials.*expired' <<<"$msg"; then
    echo "EXPIRED"
  elif grep -qiE 'AccessDenied|UnauthorizedOperation|not authorized|AccessDeniedException|Forbidden' <<<"$msg"; then
    echo "PERMISSION"
  elif grep -qiE 'Unable to locate credentials|NoCredentialsError|Unable to parse|SignatureDoesNotMatch|AuthFailure' <<<"$msg"; then
    echo "AUTH"
  elif grep -qiE 'Could not connect|Connection.*refused|EndpointConnectionError|timed out|Network' <<<"$msg"; then
    echo "NETWORK"
  else
    echo "OTHER"
  fi
}

# ------------------------------------------------------------------------------
# AWS 認証状態確認
#   成功で 0、失敗で非0。失敗時は AWS_CLI_LAST_STDERR に理由が入る。
#   現在のアカウントIDを標準出力へ返す（成功時）。
# ------------------------------------------------------------------------------
aws_get_caller_account() {
  local acct
  if acct="$(aws_cli sts get-caller-identity --query 'Account' --output text)"; then
    # 期待は 12桁数字
    if [[ "$acct" =~ ^[0-9]{12}$ ]]; then
      printf '%s' "$acct"
      return 0
    fi
    AWS_CLI_LAST_STDERR="想定外のアカウントID応答: ${acct}"
    return 1
  fi
  return 1
}

# ------------------------------------------------------------------------------
# スイッチバック処理（source 方式）
#   引数: スクリプトパス、以降は渡す引数
#   注意:
#     - 現在のシェル環境へ環境変数/認証情報を反映するため source する。
#     - メイン自身の位置パラメータを破壊しないよう、サブシェルではなく
#       set -- で退避・復元しつつ source する呼び出し元設計を想定。
#   ここでは source 自体は呼び出し元（main）が実施し、本関数は検証のみ提供する。
# ------------------------------------------------------------------------------
validate_switchback_script() {
  local path="$1"
  assert_sourceable_file "$path"
  # 追加のセキュリティ検証: 所有者・パーミッション
  # 他者書き込み可能なファイルは source を拒否する
  local perm owner
  if perm="$(stat -c '%a' "$path" 2>/dev/null)"; then
    # 末尾桁（other 権限）が 2/3/6/7 = 他者書き込み可能
    local other="${perm: -1}"
    case "$other" in
      2|3|6|7)
        die "${EXIT_SWITCHBACK:-30}" "スイッチバックスクリプトが他者書き込み可能です（危険）: ${path} (perm=${perm})"
        ;;
    esac
  fi
  if owner="$(stat -c '%U' "$path" 2>/dev/null)"; then
    log_debug "スイッチバックスクリプト所有者: ${owner}, パーミッション: ${perm:-unknown}"
  fi
  return 0
}

# ------------------------------------------------------------------------------
# CSV フィールドエスケープ
#   カンマ・ダブルクォート・改行を含む場合はダブルクォートで囲み、内部の " を "" にする。
# ------------------------------------------------------------------------------
csv_escape() {
  local field="$1"
  if [[ "$field" == *[,\"$'\n'$'\r']* ]]; then
    field="${field//\"/\"\"}"
    printf '"%s"' "$field"
  else
    printf '%s' "$field"
  fi
}

# TSV フィールドエスケープ（タブ・改行を空白へ）
tsv_escape() {
  local field="$1"
  field="${field//$'\t'/ }"
  field="${field//$'\n'/ }"
  field="${field//$'\r'/ }"
  printf '%s' "$field"
}

# JSON 文字列エスケープ
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}
