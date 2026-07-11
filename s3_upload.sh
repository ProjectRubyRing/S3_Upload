#!/usr/bin/env bash
#
# s3_upload.sh
#
# 指定した AWS アカウント内の Amazon S3 バケットへ、単一/複数のファイル・
# ディレクトリを柔軟かつ安全にアップロードする RHEL 9 対応スクリプト。
#
# 主な機能:
#   - バケットの直接指定 / 対話選択
#   - アップロード先プレフィックス指定・正規化
#   - ディレクトリの ZIP 化アップロード
#   - dry-run（S3 書き込みを一切行わない計画表示）
#   - 結果一覧の CSV/TSV/JSON 出力
#   - AWS 認証確認・アカウント一致確認
#   - 権限不足時のスイッチバック（warn/auto）
#
# 認証前提:
#   本スクリプトは事前に「aws login --remote」等で認証済みであることを前提とする。
#   認証コマンドは AUTH_HINT_COMMAND 定数として分離しており、環境に応じて変更可能。
#
# ------------------------------------------------------------------------------
set -Eeuo pipefail

# ==============================================================================
# 定数
# ==============================================================================
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 認証を促す際に表示するコマンド（環境依存。ここを差し替えれば表示文言が変わる）
readonly AUTH_HINT_COMMAND="aws login --remote"

# AWS CLI のページャーを無効化（処理停止防止）
export AWS_PAGER=""

# ------------------------------------------------------------------------------
# 終了コード定義
# ------------------------------------------------------------------------------
readonly EXIT_OK=0
readonly EXIT_USAGE=2              # 引数エラー
readonly EXIT_MISSING_COMMAND=3    # 必須コマンド不足
readonly EXIT_AWS_AUTH=4           # AWS 未認証/認証期限切れ
readonly EXIT_ACCOUNT_MISMATCH=5   # AWS アカウント不一致
readonly EXIT_PERMISSION=6         # AWS 権限不足
readonly EXIT_BUCKET=7             # バケット未存在/アクセス不可
readonly EXIT_LOCAL_FILE=11        # ローカルファイル未存在等
readonly EXIT_LOCAL_DIR=12         # ローカルディレクトリ未存在等
readonly EXIT_ZIP=13               # ZIP 作成失敗
readonly EXIT_UPLOAD=14            # アップロード失敗（1件以上）
readonly EXIT_RESULT_FILE=15       # 結果ファイル出力失敗
readonly EXIT_VERIFY=16            # アップロード検証失敗
readonly EXIT_SWITCHBACK=30        # スイッチバック失敗
readonly EXIT_INTERNAL=99          # 内部エラー

# ==============================================================================
# 既定値・グローバル変数
# ==============================================================================
ACCOUNT_ID=""
AWS_PROFILE_OPT=""      # common.sh の aws_cli が参照
AWS_REGION_OPT=""       # common.sh の aws_cli が参照
BUCKET=""
SELECT_BUCKET=false
DEST_ROOT=false
DEST_PREFIX=""
declare -a FILES=()
declare -a DIRECTORIES=()
ZIP_DIRECTORIES=false
DRY_RUN=false
RESULT_FILE=""
RESULT_FORMAT="csv"    # 既定は CSV
ALLOW_OVERWRITE=false
CONTINUE_ON_ERROR=false
VERIFY_UPLOAD=false
SWITCHBACK_MODE="warn" # 既定は warn（安全側）
SWITCHBACK_SCRIPT=""
declare -a SWITCHBACK_ARGS=()
COMMON_SCRIPT=""
LOG_LEVEL="INFO"
# 将来拡張用（既定は未設定＝付与しない）
STORAGE_CLASS=""
SSE=""
KMS_KEY_ID=""

# 実行時計算値
CURRENT_ACCOUNT_ID=""
SWITCHBACK_DONE=false

# アップロード計画/結果を保持する配列（1レコード=1行、フィールドは US(0x1f) 区切り）
declare -a PLAN_RECORDS=()
readonly FS=$'\x1f'   # レコード内フィールド区切り（内部用）

# 集計
COUNT_PLANNED=0
COUNT_SUCCESS=0
COUNT_FAILED=0
COUNT_SKIPPED=0

# ==============================================================================
# common.sh 読み込み
#   --common-script 指定があればそれを、なければスクリプトと同ディレクトリの
#   common.sh を探す。見つからない場合はフォールバック関数を定義する。
# ==============================================================================
load_common() {
  local candidate="${COMMON_SCRIPT}"
  if [[ -z "$candidate" && -f "${SCRIPT_DIR}/common.sh" ]]; then
    candidate="${SCRIPT_DIR}/common.sh"
  fi

  if [[ -n "$candidate" ]]; then
    # source 前検証（フォールバックの最小 die を使う）
    if [[ ! -e "$candidate" ]]; then
      _fallback_die "$EXIT_USAGE" "common.sh が存在しません: ${candidate}"
    fi
    if [[ ! -f "$candidate" ]]; then
      _fallback_die "$EXIT_USAGE" "common.sh が通常ファイルではありません: ${candidate}"
    fi
    if [[ ! -r "$candidate" ]]; then
      _fallback_die "$EXIT_USAGE" "common.sh に読み取り権限がありません: ${candidate}"
    fi
    # shellcheck source=/dev/null
    source "$candidate"
    return 0
  fi

  # common.sh が見つからない場合は最低限のフォールバックを使う
  _fallback_warn "common.sh が見つからないため、内蔵の最小共通関数を使用します。"
  _define_fallback_common
}

# common.sh 読み込み前でも使える最小 die/warn
_fallback_die() {
  local code="$1"; shift
  printf '%s [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
  exit "$code"
}
_fallback_warn() {
  printf '%s [WARN] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

# common.sh が無い場合の内蔵フォールバック定義（機能は簡易版）
_define_fallback_common() {
  declare -gA __LOG_LEVELS=([ERROR]=1 [WARN]=2 [INFO]=3 [DEBUG]=4)
  __log_now() { date '+%Y-%m-%d %H:%M:%S'; }
  __log_threshold() { echo "${__LOG_LEVELS[${LOG_LEVEL:-INFO}]:-3}"; }
  __log_enabled() { [[ "${__LOG_LEVELS[$1]:-3}" -le "$(__log_threshold)" ]]; }
  log() { local l="$1"; shift; __log_enabled "$l" || return 0
    local ln; ln="$(__log_now) [${l}] $*"
    if [[ "$l" == ERROR || "$l" == WARN ]]; then printf '%s\n' "$ln" >&2; else printf '%s\n' "$ln"; fi; }
  log_error() { log ERROR "$@"; }; log_warn() { log WARN "$@"; }
  log_info() { log INFO "$@"; }; log_debug() { log DEBUG "$@"; }
  die() { local c="$1"; shift; log_error "$*"; exit "$c"; }
  require_commands() { local m=() c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || m+=("$c"); done
    [[ ${#m[@]} -eq 0 ]] || die "$EXIT_MISSING_COMMAND" "必須コマンドが見つかりません: ${m[*]}"; }
  require_value() { [[ -n "$2" ]] || die "$EXIT_USAGE" "オプション $1 に値がありません。"; }
  assert_readable_file() { [[ -f "$1" && -r "$1" ]] || die "$EXIT_LOCAL_FILE" "読み取り可能な通常ファイルではありません: $1"; }
  assert_readable_dir() { [[ -d "$1" && -r "$1" && -x "$1" ]] || die "$EXIT_LOCAL_DIR" "読み取り可能なディレクトリではありません: $1"; }
  assert_sourceable_file() { [[ -f "$1" && -r "$1" ]] || die "$EXIT_USAGE" "source 不可: $1"; }
  declare -ga __TEMP_PATHS=()
  register_temp_path() { __TEMP_PATHS+=("$1"); }
  make_temp_file() { local t; t="$(mktemp "${TMPDIR:-/tmp}/s3upload.XXXXXX")"; register_temp_path "$t"; printf '%s' "$t"; }
  make_temp_dir() { local t; t="$(mktemp -d "${TMPDIR:-/tmp}/s3upload.XXXXXX")"; register_temp_path "$t"; printf '%s' "$t"; }
  cleanup_temp_files() { local p; for p in "${__TEMP_PATHS[@]:-}"; do [[ -n "$p" && -e "$p" ]] && rm -rf -- "$p" 2>/dev/null || true; done; __TEMP_PATHS=(); }
  mask_sensitive() { sed -E 's/(secret_access_key|session_token|access_key_id)[[:space:]=:]+[^[:space:]]+/\1 ********/Ig'; }
  AWS_CLI_LAST_STDERR=""
  aws_cli() { local -a a=(); [[ -n "${AWS_PROFILE_OPT:-}" ]] && a+=(--profile "$AWS_PROFILE_OPT")
    [[ -n "${AWS_REGION_OPT:-}" ]] && a+=(--region "$AWS_REGION_OPT"); a+=("$@")
    local ef o rc; ef="$(mktemp "${TMPDIR:-/tmp}/s3upload.awserr.XXXXXX")"
    set +e; o="$(AWS_PAGER="" aws "${a[@]}" 2>"$ef")"; rc=$?; set -e
    AWS_CLI_LAST_STDERR="$(cat "$ef" 2>/dev/null || true)"; rm -f -- "$ef" 2>/dev/null || true
    printf '%s' "$o"; return $rc; }
  classify_aws_error() { local m="${AWS_CLI_LAST_STDERR:-}"
    if grep -qiE 'ExpiredToken|InvalidClientTokenId|expired' <<<"$m"; then echo EXPIRED
    elif grep -qiE 'AccessDenied|UnauthorizedOperation|not authorized|Forbidden' <<<"$m"; then echo PERMISSION
    elif grep -qiE 'Unable to locate credentials|NoCredentials|SignatureDoesNotMatch|AuthFailure' <<<"$m"; then echo AUTH
    else echo OTHER; fi; }
  aws_get_caller_account() { local ac; if ac="$(aws_cli sts get-caller-identity --query Account --output text)"; then
    [[ "$ac" =~ ^[0-9]{12}$ ]] && { printf '%s' "$ac"; return 0; }; fi; return 1; }
  validate_switchback_script() { assert_sourceable_file "$1"; }
  csv_escape() { local f="$1"; if [[ "$f" == *[,\"$'\n']* ]]; then f="${f//\"/\"\"}"; printf '"%s"' "$f"; else printf '%s' "$f"; fi; }
  tsv_escape() { local f="$1"; f="${f//$'\t'/ }"; f="${f//$'\n'/ }"; printf '%s' "$f"; }
  json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"; printf '%s' "$s"; }
}

# ==============================================================================
# trap: エラー・終了時処理
# ==============================================================================
# log 関数が未ロード（common.sh 読み込み前）でも安全に出力するヘルパ
_safe_err() {
  if declare -F log_error >/dev/null 2>&1; then
    log_error "$@"
  else
    printf '%s [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
  fi
}
_safe_debug() {
  if declare -F log_debug >/dev/null 2>&1; then
    log_debug "$@"
  fi
}

on_error() {
  local rc=$?
  local line="${BASH_LINENO[0]:-?}"
  # ERR トラップ。set -e で落ちた場合の情報を残す。
  _safe_err "予期しないエラーが発生しました (行: ${line}, 終了コード: ${rc})"
}

on_exit() {
  local rc=$?
  # 一時ファイル削除は常に実施（cleanup_temp_files 未定義でも無視）
  if declare -F cleanup_temp_files >/dev/null 2>&1; then
    cleanup_temp_files 2>/dev/null || true
  fi
  _safe_debug "終了処理を実行しました (終了コード: ${rc})"
}

on_interrupt() {
  if declare -F log_warn >/dev/null 2>&1; then
    log_warn "割り込みを受信しました。一時ファイルを削除して終了します。"
  else
    printf '%s [WARN] 割り込みを受信しました。\n' "$(date '+%Y-%m-%d %H:%M:%S')" >&2
  fi
  if declare -F cleanup_temp_files >/dev/null 2>&1; then
    cleanup_temp_files 2>/dev/null || true
  fi
  exit 130
}

# ==============================================================================
# 使い方表示
# ==============================================================================
usage() {
  cat <<EOF
使い方: ${SCRIPT_NAME} [オプション]

指定した AWS アカウント内の S3 バケットへファイル/ディレクトリをアップロードします。

AWS/認証:
  --account-id ACCOUNT_ID     対象 AWS アカウントID（12桁数字・必須）
  --profile PROFILE           AWS CLI プロファイル名
  --region REGION             AWS リージョン（例: ap-northeast-1）

バケット指定（排他）:
  --bucket BUCKET_NAME        バケット名を直接指定
  --select-bucket             バケット一覧から番号選択（対話端末のみ）

アップロード先（排他。既定はバケットルート）:
  --destination-root          バケットルート直下へ
  --destination-prefix PREFIX S3 キーのプレフィックス配下へ

アップロード元（いずれか1つ以上必須。複数指定可）:
  --file FILE_PATH            アップロードするファイル
  --directory DIRECTORY_PATH アップロードするディレクトリ

動作:
  --zip-directories          各ディレクトリを個別 ZIP にしてアップロード
  --dry-run                  実アップロードせず計画のみ表示
  --allow-overwrite          既存オブジェクトの上書きを許可
  --continue-on-error        1件失敗しても残りを継続
  --verify-upload            アップロード後に head-object で検証

結果出力:
  --result-file FILE_PATH    結果一覧の出力先
  --result-format FORMAT     csv|tsv|json（既定: csv）

スイッチバック:
  --switchback-mode MODE     warn|auto（既定: warn）
  --switchback-script PATH   auto 時に source するスクリプト（auto では必須）
  --switchback-arg VALUE     スイッチバックスクリプトへ渡す引数（複数指定可）

その他:
  --common-script FILE_PATH  共通処理 common.sh のパス
  --log-level LEVEL          ERROR|WARN|INFO|DEBUG（既定: INFO）
  --help                     このヘルプを表示

事前に「${AUTH_HINT_COMMAND}」で認証しておく必要があります。
EOF
}

# ==============================================================================
# 引数解析（長オプション対応の手動パーサ）
# ==============================================================================
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --account-id)      require_value_early "$1" "${2:-}"; ACCOUNT_ID="$2"; shift 2 ;;
      --account-id=*)    ACCOUNT_ID="${1#*=}"; shift ;;
      --profile)         require_value_early "$1" "${2:-}"; AWS_PROFILE_OPT="$2"; shift 2 ;;
      --profile=*)       AWS_PROFILE_OPT="${1#*=}"; shift ;;
      --region)          require_value_early "$1" "${2:-}"; AWS_REGION_OPT="$2"; shift 2 ;;
      --region=*)        AWS_REGION_OPT="${1#*=}"; shift ;;
      --bucket)          require_value_early "$1" "${2:-}"; BUCKET="$2"; shift 2 ;;
      --bucket=*)        BUCKET="${1#*=}"; shift ;;
      --select-bucket)   SELECT_BUCKET=true; shift ;;
      --destination-root) DEST_ROOT=true; shift ;;
      --destination-prefix)   require_value_early "$1" "${2:-}"; DEST_PREFIX="$2"; shift 2 ;;
      --destination-prefix=*) DEST_PREFIX="${1#*=}"; shift ;;
      --file)            require_value_early "$1" "${2:-}"; FILES+=("$2"); shift 2 ;;
      --file=*)          FILES+=("${1#*=}"); shift ;;
      --directory)       require_value_early "$1" "${2:-}"; DIRECTORIES+=("$2"); shift 2 ;;
      --directory=*)     DIRECTORIES+=("${1#*=}"); shift ;;
      --zip-directories) ZIP_DIRECTORIES=true; shift ;;
      --dry-run)         DRY_RUN=true; shift ;;
      --result-file)     require_value_early "$1" "${2:-}"; RESULT_FILE="$2"; shift 2 ;;
      --result-file=*)   RESULT_FILE="${1#*=}"; shift ;;
      --result-format)   require_value_early "$1" "${2:-}"; RESULT_FORMAT="$2"; shift 2 ;;
      --result-format=*) RESULT_FORMAT="${1#*=}"; shift ;;
      --allow-overwrite) ALLOW_OVERWRITE=true; shift ;;
      --continue-on-error) CONTINUE_ON_ERROR=true; shift ;;
      --verify-upload)   VERIFY_UPLOAD=true; shift ;;
      --switchback-mode)   require_value_early "$1" "${2:-}"; SWITCHBACK_MODE="$2"; shift 2 ;;
      --switchback-mode=*) SWITCHBACK_MODE="${1#*=}"; shift ;;
      --switchback-script)   require_value_early "$1" "${2:-}"; SWITCHBACK_SCRIPT="$2"; shift 2 ;;
      --switchback-script=*) SWITCHBACK_SCRIPT="${1#*=}"; shift ;;
      --switchback-arg)   require_value_early "$1" "${2:-}"; SWITCHBACK_ARGS+=("$2"); shift 2 ;;
      --switchback-arg=*) SWITCHBACK_ARGS+=("${1#*=}"); shift ;;
      --common-script)   require_value_early "$1" "${2:-}"; COMMON_SCRIPT="$2"; shift 2 ;;
      --common-script=*) COMMON_SCRIPT="${1#*=}"; shift ;;
      --storage-class)   require_value_early "$1" "${2:-}"; STORAGE_CLASS="$2"; shift 2 ;;
      --storage-class=*) STORAGE_CLASS="${1#*=}"; shift ;;
      --sse)             require_value_early "$1" "${2:-}"; SSE="$2"; shift 2 ;;
      --sse=*)           SSE="${1#*=}"; shift ;;
      --kms-key-id)      require_value_early "$1" "${2:-}"; KMS_KEY_ID="$2"; shift 2 ;;
      --kms-key-id=*)    KMS_KEY_ID="${1#*=}"; shift ;;
      --log-level)       require_value_early "$1" "${2:-}"; LOG_LEVEL="$2"; shift 2 ;;
      --log-level=*)     LOG_LEVEL="${1#*=}"; shift ;;
      --help|-h)         usage; exit "$EXIT_OK" ;;
      --)                shift; break ;;
      -*)                _fallback_die "$EXIT_USAGE" "未知のオプションです: $1（--help を参照）" ;;
      *)                 _fallback_die "$EXIT_USAGE" "余分な引数です: $1（--help を参照）" ;;
    esac
  done
}

# 値が無い/次が別オプションの場合に早期エラー（common 読み込み前でも動く）
require_value_early() {
  local name="$1" val="$2"
  if [[ -z "$val" || "$val" == --* ]]; then
    _fallback_die "$EXIT_USAGE" "オプション ${name} に値が指定されていません。"
  fi
}

# ==============================================================================
# 引数間の整合性チェック
# ==============================================================================
validate_args() {
  # ログレベル
  case "$LOG_LEVEL" in
    ERROR|WARN|INFO|DEBUG) ;;
    *) die "$EXIT_USAGE" "不正な --log-level です: ${LOG_LEVEL}（ERROR|WARN|INFO|DEBUG）" ;;
  esac

  # アカウントID
  [[ -n "$ACCOUNT_ID" ]] || die "$EXIT_USAGE" "--account-id は必須です。"
  [[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || die "$EXIT_USAGE" "--account-id は12桁の数字で指定してください: ${ACCOUNT_ID}"

  # バケット指定の排他
  if [[ -n "$BUCKET" && "$SELECT_BUCKET" == true ]]; then
    die "$EXIT_USAGE" "--bucket と --select-bucket は同時指定できません。"
  fi

  # 宛先の排他
  if [[ "$DEST_ROOT" == true && -n "$DEST_PREFIX" ]]; then
    die "$EXIT_USAGE" "--destination-root と --destination-prefix は同時指定できません。"
  fi

  # プレフィックスに '..' を含めない（パストラバーサル対策）
  if [[ -n "$DEST_PREFIX" && "$DEST_PREFIX" == *".."* ]]; then
    die "$EXIT_USAGE" "プレフィックスに '..' を含めることはできません: ${DEST_PREFIX}"
  fi

  # アップロード元必須
  if [[ "${#FILES[@]}" -eq 0 && "${#DIRECTORIES[@]}" -eq 0 ]]; then
    die "$EXIT_USAGE" "--file または --directory を1つ以上指定してください。"
  fi

  # 結果フォーマット
  case "$RESULT_FORMAT" in
    csv|tsv|json) ;;
    *) die "$EXIT_USAGE" "不正な --result-format です: ${RESULT_FORMAT}（csv|tsv|json）" ;;
  esac

  # スイッチバックモード
  case "$SWITCHBACK_MODE" in
    warn|auto) ;;
    *) die "$EXIT_USAGE" "不正な --switchback-mode です: ${SWITCHBACK_MODE}（warn|auto）" ;;
  esac
  if [[ "$SWITCHBACK_MODE" == "auto" && -z "$SWITCHBACK_SCRIPT" ]]; then
    die "$EXIT_USAGE" "--switchback-mode auto では --switchback-script が必須です。"
  fi

  # バケット未指定時の扱い（対話端末なら選択へ、非対話ならエラー）
  if [[ -z "$BUCKET" && "$SELECT_BUCKET" != true ]]; then
    if [[ -t 0 ]]; then
      log_info "バケット未指定のため、対話端末として一覧選択を開始します。"
      SELECT_BUCKET=true
    else
      die "$EXIT_USAGE" "非対話環境では --bucket か --select-bucket のいずれかを指定してください。"
    fi
  fi

  # 非対話で --select-bucket は不可
  if [[ "$SELECT_BUCKET" == true && ! -t 0 ]]; then
    die "$EXIT_USAGE" "非対話環境では --select-bucket は使用できません。--bucket を指定してください。"
  fi

  log_debug "引数整合性チェック OK"
}

# ==============================================================================
# プレフィックス正規化
#   - 先頭 / を除去
#   - 連続 / を単一化
#   - 末尾 / を除去
#   - .. を含む場合は拒否
# ==============================================================================
# 注意: 本関数はコマンド置換 $(...) の中で呼ばれるため die しない（純粋関数）。
# '..' の拒否など致命的検証は validate_args 側で行う。
normalize_prefix() {
  local p="$1"
  [[ -z "$p" ]] && { printf ''; return 0; }
  # 連続スラッシュを単一化
  while [[ "$p" == *"//"* ]]; do p="${p//\/\//\/}"; done
  # 先頭スラッシュ除去
  p="${p#/}"
  # 末尾スラッシュ除去
  p="${p%/}"
  printf '%s' "$p"
}

# ==============================================================================
# AWS 認証確認
# ==============================================================================
check_aws_auth() {
  log_info "AWS 認証状態を確認しています。"
  local acct
  if acct="$(aws_get_caller_account)"; then
    CURRENT_ACCOUNT_ID="$acct"
    log_info "現在の AWS アカウントID: ${CURRENT_ACCOUNT_ID}"
    return 0
  fi

  local kind
  kind="$(classify_aws_error)"
  log_debug "認証確認 stderr: ${AWS_CLI_LAST_STDERR}"
  case "$kind" in
    EXPIRED|AUTH)
      log_error "AWSの認証状態を確認できませんでした。"
      log_error "事前に「${AUTH_HINT_COMMAND}」を実行して認証を完了してから、再度スクリプトを実行してください。"
      exit "$EXIT_AWS_AUTH"
      ;;
    PERMISSION)
      # sts:GetCallerIdentity すら拒否されるのは稀だが権限扱い
      log_warn "認証は取得できましたが権限が不足している可能性があります。"
      return 1
      ;;
    *)
      log_error "AWSの認証状態を確認できませんでした。"
      log_error "事前に「${AUTH_HINT_COMMAND}」を実行して認証を完了してから、再度スクリプトを実行してください。"
      exit "$EXIT_AWS_AUTH"
      ;;
  esac
}

# ==============================================================================
# アカウント一致確認 + 必要ならスイッチバック
# ==============================================================================
ensure_account_and_permissions() {
  # まず認証
  check_aws_auth || true

  # アカウント一致確認
  if [[ "$CURRENT_ACCOUNT_ID" != "$ACCOUNT_ID" ]]; then
    log_warn "現在のアカウント(${CURRENT_ACCOUNT_ID})が指定アカウント(${ACCOUNT_ID})と一致しません。"
    handle_switchback "アカウント不一致"
  fi

  # 権限の簡易事前確認（ListAllMyBuckets 相当を軽く試す）
  if ! preflight_permission_check; then
    handle_switchback "S3 操作権限不足の可能性"
  fi
}

# 権限の簡易事前確認（完全判定は不可能なため代表操作のみ）
preflight_permission_check() {
  # バケット直接指定時は list-buckets 権限が無くても良いので head-bucket を試す
  if [[ -n "$BUCKET" ]]; then
    if aws_cli s3api head-bucket --bucket "$BUCKET" >/dev/null; then
      return 0
    fi
    local kind; kind="$(classify_aws_error)"
    log_debug "head-bucket stderr: ${AWS_CLI_LAST_STDERR}"
    case "$kind" in
      PERMISSION) return 1 ;;
      EXPIRED|AUTH)
        log_error "認証情報の期限切れ等を検出しました。「${AUTH_HINT_COMMAND}」で再認証してください。"
        exit "$EXIT_AWS_AUTH" ;;
      *) return 1 ;;  # 存在しない等も後段で詳細判定
    esac
  else
    # 選択方式では list-buckets を試す
    if aws_cli s3api list-buckets --query 'Owner.ID' --output text >/dev/null; then
      return 0
    fi
    local kind; kind="$(classify_aws_error)"
    case "$kind" in
      EXPIRED|AUTH)
        log_error "認証情報の期限切れ等を検出しました。「${AUTH_HINT_COMMAND}」で再認証してください。"
        exit "$EXIT_AWS_AUTH" ;;
      *) return 1 ;;
    esac
  fi
}

# ==============================================================================
# スイッチバック処理
# ==============================================================================
handle_switchback() {
  local reason="$1"

  if [[ "$SWITCHBACK_MODE" == "warn" ]]; then
    log_error "現在のAWS認証情報または操作権限では、指定されたAWSアカウントのS3操作を実行できません。（理由: ${reason}）"
    log_error "必要なスイッチバックを実施してから、再度スクリプトを実行してください。"
    exit "$EXIT_SWITCHBACK"
  fi

  # auto モード
  if [[ "$SWITCHBACK_DONE" == true ]]; then
    die "$EXIT_SWITCHBACK" "スイッチバックは既に1回実行済みですが、依然として操作できません。処理を中止します。"
  fi

  [[ -n "$SWITCHBACK_SCRIPT" ]] || die "$EXIT_SWITCHBACK" "--switchback-script が指定されていません。"
  validate_switchback_script "$SWITCHBACK_SCRIPT"

  log_info "スイッチバックを自動実行します（source: ${SWITCHBACK_SCRIPT}）。理由: ${reason}"
  SWITCHBACK_DONE=true

  # 位置パラメータを退避してから source（メイン自身のパラメータを破壊しない）
  local -a _saved=( "$@" )  # ここでは reason のみだが形式として退避
  set --
  if [[ "${#SWITCHBACK_ARGS[@]}" -gt 0 ]]; then
    set -- "${SWITCHBACK_ARGS[@]}"
  fi

  # source 実行（失敗しても set -e で即死しないよう制御）
  set +e
  # shellcheck source=/dev/null
  source "$SWITCHBACK_SCRIPT"
  local sb_rc=$?
  set -e

  # 位置パラメータ復元
  set --
  if [[ "${#_saved[@]}" -gt 0 ]]; then
    set -- "${_saved[@]}"
  fi

  if [[ "$sb_rc" -ne 0 ]]; then
    die "$EXIT_SWITCHBACK" "スイッチバックスクリプトが非0で終了しました（終了コード: ${sb_rc}）。"
  fi

  # 再確認: 認証・アカウント・権限
  log_info "スイッチバック後の再確認を行います。"
  CURRENT_ACCOUNT_ID=""
  check_aws_auth || die "$EXIT_SWITCHBACK" "スイッチバック後も認証を確認できませんでした。"

  if [[ "$CURRENT_ACCOUNT_ID" != "$ACCOUNT_ID" ]]; then
    die "$EXIT_ACCOUNT_MISMATCH" "スイッチバック後もアカウントが一致しません（現在: ${CURRENT_ACCOUNT_ID}, 指定: ${ACCOUNT_ID}）。"
  fi

  if ! preflight_permission_check; then
    die "$EXIT_PERMISSION" "スイッチバック後も必要な S3 権限を確認できませんでした。"
  fi

  log_info "スイッチバックに成功しました。処理を続行します。"
}

# ==============================================================================
# バケット選択（対話）
# ==============================================================================
select_bucket_interactive() {
  log_info "バケット一覧を取得しています。"
  local out
  if ! out="$(aws_cli s3api list-buckets --query 'Buckets[].Name' --output text)"; then
    local kind; kind="$(classify_aws_error)"
    if [[ "$kind" == "PERMISSION" ]]; then
      die "$EXIT_PERMISSION" "バケット一覧の取得権限(s3:ListAllMyBuckets)がありません。"
    fi
    die "$EXIT_BUCKET" "バケット一覧の取得に失敗しました: ${AWS_CLI_LAST_STDERR}"
  fi

  # タブ区切り→配列
  local -a names=()
  # shellcheck disable=SC2206
  IFS=$'\t' read -r -a names <<<"$out"

  if [[ "${#names[@]}" -eq 0 || ( "${#names[@]}" -eq 1 && -z "${names[0]}" ) ]]; then
    die "$EXIT_BUCKET" "アクセス可能なバケットが0件です。"
  fi

  echo "利用可能なバケット:" >&2
  local i
  for i in "${!names[@]}"; do
    printf '  %d) %s\n' "$((i+1))" "${names[$i]}" >&2
  done

  local choice
  while true; do
    printf 'アップロード先バケットの番号を入力してください [1-%d]: ' "${#names[@]}" >&2
    if ! read -r choice; then
      die "$EXIT_USAGE" "入力を取得できませんでした。"
    fi
    if [[ -z "$choice" ]]; then
      log_warn "空入力です。番号を入力してください。"
      continue
    fi
    if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
      log_warn "数値を入力してください: ${choice}"
      continue
    fi
    if (( choice < 1 || choice > ${#names[@]} )); then
      log_warn "範囲外です（1-${#names[@]}）: ${choice}"
      continue
    fi
    break
  done

  BUCKET="${names[$((choice-1))]}"
  log_info "選択されたバケット: ${BUCKET}"
}

# ==============================================================================
# バケット名の基本形式チェック
# ==============================================================================
validate_bucket_name() {
  local b="$1"
  if [[ ! "$b" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
    die "$EXIT_USAGE" "バケット名がS3命名規則に反しています: ${b}"
  fi
  if [[ "$b" == *".."* ]]; then
    die "$EXIT_USAGE" "バケット名に連続ドットは使用できません: ${b}"
  fi
  if [[ "$b" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "$EXIT_USAGE" "バケット名にIPアドレス形式は使用できません: ${b}"
  fi
}

# ==============================================================================
# バケットアクセス確認
# ==============================================================================
verify_bucket_access() {
  log_info "バケット '${BUCKET}' の存在とアクセス可否を確認しています。"
  if aws_cli s3api head-bucket --bucket "$BUCKET" >/dev/null; then
    log_info "バケットにアクセスできます。"
  else
    local kind; kind="$(classify_aws_error)"
    log_debug "head-bucket stderr: ${AWS_CLI_LAST_STDERR}"
    case "$kind" in
      PERMISSION) die "$EXIT_PERMISSION" "バケット '${BUCKET}' へのアクセス権限がありません。" ;;
      EXPIRED|AUTH) die "$EXIT_AWS_AUTH" "認証情報の期限切れ等を検出しました。「${AUTH_HINT_COMMAND}」で再認証してください。" ;;
      *) die "$EXIT_BUCKET" "バケット '${BUCKET}' が存在しないかアクセスできません。" ;;
    esac
  fi

  # バケット所有者アカウントの確認（可能な範囲）
  # 注意: get-bucket-acl は権限やバケット設定によっては失敗する。失敗しても致命的にはしない。
  local owner
  if owner="$(aws_cli s3api list-buckets --query "Buckets[?Name=='${BUCKET}'].Name" --output text 2>/dev/null)"; then
    if [[ "$owner" == "$BUCKET" ]]; then
      log_debug "バケットは現在の認証主体のアカウントに属していると推定されます。"
    else
      log_warn "バケット所有アカウントの厳密確認はできませんでした（S3 API の制約）。指定アカウントに属している前提で続行します。"
    fi
  else
    log_warn "バケット所有アカウントの厳密確認はできませんでした（list-buckets 不可）。指定アカウントに属している前提で続行します。"
  fi
}

# ==============================================================================
# アップロード計画の作成
#   各レコード: TYPE FS LOCALPATH FS ZIPPED FS ZIPNAME FS S3URI FS SIZE FS STATUS FS ERRMSG
# ==============================================================================

# 最終 S3 URI を組み立てる（プレフィックス正規化済み前提。二重スラッシュ防止）
build_s3_uri() {
  local key_suffix="$1"   # プレフィックス配下の相対キー
  local prefix="$DEST_PREFIX"
  local key
  if [[ -n "$prefix" ]]; then
    key="${prefix}/${key_suffix}"
  else
    key="${key_suffix}"
  fi
  # 念のため連続スラッシュ除去
  while [[ "$key" == *"//"* ]]; do key="${key//\/\//\/}"; done
  key="${key#/}"
  printf 's3://%s/%s' "$BUCKET" "$key"
}

# 計画レコード追加
add_plan_record() {
  local type="$1" local_path="$2" zipped="$3" zipname="$4" s3uri="$5" size="$6" status="$7" errmsg="$8"
  PLAN_RECORDS+=("${type}${FS}${local_path}${FS}${zipped}${FS}${zipname}${FS}${s3uri}${FS}${size}${FS}${status}${FS}${errmsg}")
}

# 重複パス正規化用
canonical_path() {
  # realpath -m は存在しないパスでも正規化する。ファイルは存在前提なので -e でも良いが -m で統一。
  realpath -m -- "$1" 2>/dev/null || printf '%s' "$1"
}

build_plan() {
  log_info "アップロード計画を作成しています。"

  local -A seen_local=()   # 重複ローカルパス検出
  local -A seen_s3key=()   # S3 キー衝突検出

  # ---- ファイル ----
  local f canon base s3uri size
  for f in "${FILES[@]:-}"; do
    [[ -n "$f" ]] || continue
    assert_readable_file "$f"
    canon="$(canonical_path "$f")"
    if [[ -n "${seen_local[$canon]:-}" ]]; then
      log_warn "重複指定されたファイルをスキップします: ${f}"
      continue
    fi
    seen_local[$canon]=1

    base="$(basename -- "$f")"
    s3uri="$(build_s3_uri "$base")"
    size="$(stat -c '%s' -- "$f" 2>/dev/null || echo 0)"

    check_s3key_collision "$s3uri" "$f" seen_s3key || continue
    add_plan_record "file" "$f" "no" "" "$s3uri" "$size" "PLANNED" ""
    COUNT_PLANNED=$((COUNT_PLANNED+1))
  done

  # ---- ディレクトリ ----
  local d
  for d in "${DIRECTORIES[@]:-}"; do
    [[ -n "$d" ]] || continue
    assert_readable_dir "$d"
    canon="$(canonical_path "$d")"
    if [[ -n "${seen_local[$canon]:-}" ]]; then
      log_warn "重複指定されたディレクトリをスキップします: ${d}"
      continue
    fi
    seen_local[$canon]=1

    if [[ "$ZIP_DIRECTORIES" == true ]]; then
      build_plan_dir_zip "$d" seen_s3key
    else
      build_plan_dir_recursive "$d" seen_s3key
    fi
  done

  if [[ "$COUNT_PLANNED" -eq 0 ]]; then
    die "$EXIT_LOCAL_FILE" "アップロード対象が0件です。指定内容を確認してください。"
  fi
  log_info "計画件数: ${COUNT_PLANNED}"
}

# ディレクトリを ZIP としてアップロードする計画
build_plan_dir_zip() {
  local d="$1"
  local -n _seen="$2"
  local dirname zipname s3uri
  dirname="$(basename -- "$d")"
  # 衝突しない ZIP 名: ディレクトリ名 + 親パスのハッシュ短縮
  local hash
  hash="$(printf '%s' "$(canonical_path "$d")" | cksum | awk '{print $1}')"
  zipname="${dirname}.zip"
  # 同名 ZIP が既に計画にある場合はハッシュを付与
  local rec exists=false
  for rec in "${PLAN_RECORDS[@]:-}"; do
    IFS="$FS" read -r _t _l _z zn _rest <<<"$rec"
    if [[ "$zn" == "$zipname" ]]; then exists=true; break; fi
  done
  if [[ "$exists" == true ]]; then
    zipname="${dirname}.${hash}.zip"
  fi

  s3uri="$(build_s3_uri "$zipname")"
  check_s3key_collision "$s3uri" "$d" _seen || return 0
  # dry-run では ZIP を作らないためサイズは未知
  add_plan_record "dir-zip" "$d" "yes" "$zipname" "$s3uri" "-" "PLANNED" ""
  COUNT_PLANNED=$((COUNT_PLANNED+1))
}

# ディレクトリを階層維持で再帰アップロードする計画
build_plan_dir_recursive() {
  local d="$1"
  local -n _seen="$2"
  local dirname base_rel s3uri size file rel
  dirname="$(basename -- "$d")"

  local found=false
  # 隠しファイルも含めて全ファイルを列挙（NUL 区切りで安全に）
  while IFS= read -r -d '' file; do
    found=true
    # d からの相対パス
    rel="${file#"$d"/}"
    # S3 キーは <ディレクトリ名>/<相対パス> として親ディレクトリ名を維持
    base_rel="${dirname}/${rel}"
    s3uri="$(build_s3_uri "$base_rel")"
    size="$(stat -c '%s' -- "$file" 2>/dev/null || echo 0)"
    check_s3key_collision "$s3uri" "$file" _seen || continue
    add_plan_record "dir-file" "$file" "no" "" "$s3uri" "$size" "PLANNED" ""
    COUNT_PLANNED=$((COUNT_PLANNED+1))
  done < <(find "$d" -type f -print0 2>/dev/null)

  if [[ "$found" != true ]]; then
    log_warn "空ディレクトリのためアップロード対象がありません: ${d}"
    add_plan_record "dir-empty" "$d" "no" "" "-" "0" "SKIPPED" "空ディレクトリ"
    COUNT_SKIPPED=$((COUNT_SKIPPED+1))
  fi
}

# S3 キー衝突・上書き検出
#   同一実行内の衝突と、既存オブジェクトの上書きの両方を確認する。
check_s3key_collision() {
  local s3uri="$1" src="$2"
  local -n _seen="$3"

  # 同一実行内の衝突
  if [[ -n "${_seen[$s3uri]:-}" ]]; then
    if [[ "$ALLOW_OVERWRITE" == true ]]; then
      log_warn "同一 S3 キーが実行内で重複していますが上書き許可のため続行します: ${s3uri} (元: ${src})"
    else
      die "$EXIT_USAGE" "同一 S3 キーが実行内で衝突しています: ${s3uri}（元: ${src}）。--allow-overwrite を検討してください。"
    fi
  fi
  _seen[$s3uri]=1

  # 既存オブジェクトの上書き検出（dry-run でも読み取りは可）
  if [[ "$ALLOW_OVERWRITE" != true ]]; then
    local key="${s3uri#s3://"$BUCKET"/}"
    if aws_cli s3api head-object --bucket "$BUCKET" --key "$key" >/dev/null 2>&1; then
      die "$EXIT_USAGE" "既存オブジェクトの上書きになります: ${s3uri}。--allow-overwrite を指定するか宛先を変更してください。"
    fi
  fi
  return 0
}

# ==============================================================================
# dry-run / 計画表示
# ==============================================================================
show_plan() {
  local mode
  if [[ "$DRY_RUN" == true ]]; then mode="dry-run（実アップロードなし）"; else mode="実アップロード"; fi

  cat <<EOF >&2
================ アップロード計画 ================
実行モード         : ${mode}
対象アカウントID   : ${ACCOUNT_ID}
AWS プロファイル   : ${AWS_PROFILE_OPT:-（既定）}
AWS リージョン     : ${AWS_REGION_OPT:-（既定）}
対象バケット       : ${BUCKET}
宛先プレフィックス : ${DEST_PREFIX:-（ルート）}
上書き許可         : ${ALLOW_OVERWRITE}
ZIP 化             : ${ZIP_DIRECTORIES}
計画件数           : ${COUNT_PLANNED}
=================================================
EOF

  local rec type local_path zipped zipname s3uri size status errmsg n=0
  for rec in "${PLAN_RECORDS[@]:-}"; do
    [[ -n "$rec" ]] || continue
    IFS="$FS" read -r type local_path zipped zipname s3uri size status errmsg <<<"$rec"
    n=$((n+1))
    printf '[%d] %-9s %s\n     -> %s (zip=%s%s, size=%s, status=%s)\n' \
      "$n" "$type" "$local_path" "$s3uri" "$zipped" \
      "$( [[ -n "$zipname" ]] && printf ':%s' "$zipname" )" "$size" "$status" >&2
  done
}

# ==============================================================================
# ZIP 作成
#   ディレクトリを親ディレクトリ名を含む ZIP にする。
#   出力: 作成した ZIP のパスを標準出力へ。失敗時は非0。
# ==============================================================================
create_zip_for_dir() {
  local dir="$1" zipname="$2"
  local tmpdir zippath parent base
  tmpdir="$(make_temp_dir)"
  zippath="${tmpdir}/${zipname}"

  parent="$(dirname -- "$dir")"
  base="$(basename -- "$dir")"

  # 親ディレクトリ名を含めるため、親へ cd して base を対象にする（サブシェルで実行）
  if ( cd "$parent" && zip -r -q -- "$zippath" "$base" ); then
    printf '%s' "$zippath"
    return 0
  fi
  return 1
}

# ==============================================================================
# 実アップロード
# ==============================================================================

# 1オブジェクトをアップロードする共通処理。成功で0。
do_s3_cp() {
  local src="$1" s3uri="$2"
  local -a args=(s3 cp -- "$src" "$s3uri")
  # 追加オプション（配列で安全に）
  if [[ -n "$STORAGE_CLASS" ]]; then args+=(--storage-class "$STORAGE_CLASS"); fi
  if [[ -n "$SSE" ]]; then args+=(--sse "$SSE"); fi
  if [[ -n "$KMS_KEY_ID" ]]; then args+=(--sse-kms-key-id "$KMS_KEY_ID"); fi

  # aws_cli は先頭に --profile/--region を注入するため、s3 サブコマンドの前に来る
  # よって args の先頭 "s3 cp ..." をそのまま渡す
  if aws_cli "${args[@]}" >/dev/null; then
    return 0
  fi
  return 1
}

# head-object による検証
verify_object() {
  local s3uri="$1"
  local key="${s3uri#s3://"$BUCKET"/}"
  if aws_cli s3api head-object --bucket "$BUCKET" --key "$key" >/dev/null; then
    return 0
  fi
  return 1
}

execute_uploads() {
  if [[ "$DRY_RUN" == true ]]; then
    log_info "dry-run のため実アップロードは行いません。"
    return 0
  fi

  log_info "アップロードを開始します。"
  local -a new_records=()
  local rec type local_path zipped zipname s3uri size status errmsg
  local zippath

  for rec in "${PLAN_RECORDS[@]:-}"; do
    [[ -n "$rec" ]] || continue
    IFS="$FS" read -r type local_path zipped zipname s3uri size status errmsg <<<"$rec"

    # 既に SKIPPED のレコードはそのまま
    if [[ "$status" == "SKIPPED" ]]; then
      new_records+=("$rec")
      continue
    fi

    case "$type" in
      file|dir-file)
        if do_s3_cp "$local_path" "$s3uri"; then
          status="SUCCESS"; errmsg=""
          COUNT_SUCCESS=$((COUNT_SUCCESS+1))
          log_info "アップロード成功: ${s3uri}"
          if [[ "$VERIFY_UPLOAD" == true ]]; then
            if ! verify_object "$s3uri"; then
              status="FAILED"; errmsg="検証失敗(head-object)"
              COUNT_SUCCESS=$((COUNT_SUCCESS-1)); COUNT_FAILED=$((COUNT_FAILED+1))
              log_error "アップロード検証に失敗しました: ${s3uri}"
              handle_upload_failure || { new_records+=("${type}${FS}${local_path}${FS}${zipped}${FS}${zipname}${FS}${s3uri}${FS}${size}${FS}${status}${FS}${errmsg}"); finalize_partial "$rec" new_records; return 1; }
            fi
          fi
        else
          local kind; kind="$(classify_aws_error)"
          status="FAILED"; errmsg="$(printf '%s' "${AWS_CLI_LAST_STDERR}" | head -c 200 | tr '\n' ' ')"
          COUNT_FAILED=$((COUNT_FAILED+1))
          log_error "アップロード失敗(${kind}): ${s3uri}"
          if [[ "$kind" == "EXPIRED" || "$kind" == "AUTH" ]]; then
            new_records+=("${type}${FS}${local_path}${FS}${zipped}${FS}${zipname}${FS}${s3uri}${FS}${size}${FS}${status}${FS}${errmsg}")
            PLAN_RECORDS=("${new_records[@]}")
            die "$EXIT_AWS_AUTH" "認証エラーによりアップロードを中断しました。「${AUTH_HINT_COMMAND}」で再認証してください。"
          fi
          if ! handle_upload_failure; then
            new_records+=("${type}${FS}${local_path}${FS}${zipped}${FS}${zipname}${FS}${s3uri}${FS}${size}${FS}${status}${FS}${errmsg}")
            PLAN_RECORDS=("${new_records[@]}")
            return 1
          fi
        fi
        new_records+=("${type}${FS}${local_path}${FS}${zipped}${FS}${zipname}${FS}${s3uri}${FS}${size}${FS}${status}${FS}${errmsg}")
        ;;

      dir-zip)
        # ZIP を作成してからアップロード
        if ! zippath="$(create_zip_for_dir "$local_path" "$zipname")"; then
          status="FAILED"; errmsg="ZIP作成失敗"
          COUNT_FAILED=$((COUNT_FAILED+1))
          log_error "ZIP 作成に失敗しました: ${local_path}"
          new_records+=("${type}${FS}${local_path}${FS}${zipped}${FS}${zipname}${FS}${s3uri}${FS}${size}${FS}${status}${FS}${errmsg}")
          if ! handle_upload_failure; then PLAN_RECORDS=("${new_records[@]}"); return 1; fi
          continue
        fi
        size="$(stat -c '%s' -- "$zippath" 2>/dev/null || echo 0)"
        if do_s3_cp "$zippath" "$s3uri"; then
          status="SUCCESS"; errmsg=""
          COUNT_SUCCESS=$((COUNT_SUCCESS+1))
          log_info "ZIP アップロード成功: ${s3uri}"
          if [[ "$VERIFY_UPLOAD" == true ]] && ! verify_object "$s3uri"; then
            status="FAILED"; errmsg="検証失敗(head-object)"
            COUNT_SUCCESS=$((COUNT_SUCCESS-1)); COUNT_FAILED=$((COUNT_FAILED+1))
            log_error "ZIP アップロード検証に失敗しました: ${s3uri}"
          fi
        else
          status="FAILED"; errmsg="$(printf '%s' "${AWS_CLI_LAST_STDERR}" | head -c 200 | tr '\n' ' ')"
          COUNT_FAILED=$((COUNT_FAILED+1))
          log_error "ZIP アップロード失敗: ${s3uri}"
        fi
        new_records+=("${type}${FS}${local_path}${FS}${zipped}${FS}${zipname}${FS}${s3uri}${FS}${size}${FS}${status}${FS}${errmsg}")
        if [[ "$status" == "FAILED" ]] && ! handle_upload_failure; then
          PLAN_RECORDS=("${new_records[@]}"); return 1
        fi
        ;;

      *)
        new_records+=("$rec")
        ;;
    esac
  done

  PLAN_RECORDS=("${new_records[@]}")
  return 0
}

# 失敗時の継続判定。継続するなら0、中断するなら非0。
handle_upload_failure() {
  if [[ "$CONTINUE_ON_ERROR" == true ]]; then
    return 0
  fi
  log_error "エラーが発生したため処理を中断します（--continue-on-error 未指定）。"
  return 1
}

# 中断時に残りレコードを結果へ反映する補助（未処理は PLANNED のまま残す）
finalize_partial() {
  : # PLAN_RECORDS は呼び出し側で更新済み。プレースホルダ。
}

# ==============================================================================
# 結果出力
# ==============================================================================
write_results() {
  local now
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  local dryflag
  if [[ "$DRY_RUN" == true ]]; then dryflag="dry-run"; else dryflag="real"; fi

  # 結果ファイル出力
  if [[ -n "$RESULT_FILE" ]]; then
    local parent
    parent="$(dirname -- "$RESULT_FILE")"
    if [[ ! -d "$parent" ]]; then
      # 既定は作成せずエラー（安全側）。作成したい場合はここを mkdir -p に変更可能。
      die "$EXIT_RESULT_FILE" "結果ファイルの親ディレクトリが存在しません: ${parent}"
    fi
    # 安全な権限で作成
    ( umask 077; : >"$RESULT_FILE" ) || die "$EXIT_RESULT_FILE" "結果ファイルを作成できません: ${RESULT_FILE}"

    case "$RESULT_FORMAT" in
      csv)  write_results_csv "$now" "$dryflag" >"$RESULT_FILE" ;;
      tsv)  write_results_tsv "$now" "$dryflag" >"$RESULT_FILE" ;;
      json) write_results_json "$now" "$dryflag" >"$RESULT_FILE" ;;
    esac
    log_info "結果を出力しました: ${RESULT_FILE} (${RESULT_FORMAT})"
  fi
}

write_results_csv() {
  local now="$1" dryflag="$2"
  printf '%s\n' "連番,実行日時,種別,AWSアカウントID,バケット,アップロード元種別,ローカルパス,ZIP化,ZIPファイル名,S3 URI,ファイルサイズ,ステータス,エラーメッセージ"
  local rec type local_path zipped zipname s3uri size status errmsg n=0
  for rec in "${PLAN_RECORDS[@]:-}"; do
    [[ -n "$rec" ]] || continue
    IFS="$FS" read -r type local_path zipped zipname s3uri size status errmsg <<<"$rec"
    n=$((n+1))
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$n" "$(csv_escape "$now")" "$(csv_escape "$dryflag")" "$(csv_escape "$ACCOUNT_ID")" \
      "$(csv_escape "$BUCKET")" "$(csv_escape "$type")" "$(csv_escape "$local_path")" \
      "$(csv_escape "$zipped")" "$(csv_escape "$zipname")" "$(csv_escape "$s3uri")" \
      "$(csv_escape "$size")" "$(csv_escape "$status")" "$(csv_escape "$errmsg")"
  done
}

write_results_tsv() {
  local now="$1" dryflag="$2"
  printf '%s\n' "連番	実行日時	種別	AWSアカウントID	バケット	アップロード元種別	ローカルパス	ZIP化	ZIPファイル名	S3 URI	ファイルサイズ	ステータス	エラーメッセージ"
  local rec type local_path zipped zipname s3uri size status errmsg n=0
  for rec in "${PLAN_RECORDS[@]:-}"; do
    [[ -n "$rec" ]] || continue
    IFS="$FS" read -r type local_path zipped zipname s3uri size status errmsg <<<"$rec"
    n=$((n+1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$n" "$(tsv_escape "$now")" "$(tsv_escape "$dryflag")" "$(tsv_escape "$ACCOUNT_ID")" \
      "$(tsv_escape "$BUCKET")" "$(tsv_escape "$type")" "$(tsv_escape "$local_path")" \
      "$(tsv_escape "$zipped")" "$(tsv_escape "$zipname")" "$(tsv_escape "$s3uri")" \
      "$(tsv_escape "$size")" "$(tsv_escape "$status")" "$(tsv_escape "$errmsg")"
  done
}

write_results_json() {
  local now="$1" dryflag="$2"
  local rec type local_path zipped zipname s3uri size status errmsg n=0 first=true
  printf '[\n'
  for rec in "${PLAN_RECORDS[@]:-}"; do
    [[ -n "$rec" ]] || continue
    IFS="$FS" read -r type local_path zipped zipname s3uri size status errmsg <<<"$rec"
    n=$((n+1))
    if [[ "$first" == true ]]; then first=false; else printf ',\n'; fi
    printf '  {"seq":%d,"datetime":"%s","mode":"%s","account_id":"%s","bucket":"%s","source_type":"%s","local_path":"%s","zipped":"%s","zip_name":"%s","s3_uri":"%s","size":"%s","status":"%s","error":"%s"}' \
      "$n" "$(json_escape "$now")" "$(json_escape "$dryflag")" "$(json_escape "$ACCOUNT_ID")" \
      "$(json_escape "$BUCKET")" "$(json_escape "$type")" "$(json_escape "$local_path")" \
      "$(json_escape "$zipped")" "$(json_escape "$zipname")" "$(json_escape "$s3uri")" \
      "$(json_escape "$size")" "$(json_escape "$status")" "$(json_escape "$errmsg")"
  done
  printf '\n]\n'
}

# ==============================================================================
# サマリー表示
# ==============================================================================
show_summary() {
  cat <<EOF >&2
================ 実行サマリー ================
計画件数 : ${COUNT_PLANNED}
成功件数 : ${COUNT_SUCCESS}
失敗件数 : ${COUNT_FAILED}
スキップ : ${COUNT_SKIPPED}
============================================
EOF
}

# ==============================================================================
# メイン
# ==============================================================================
main() {
  # 1. 初期設定
  umask 077
  trap on_error ERR
  trap on_exit EXIT
  trap on_interrupt INT TERM

  # 2. 引数解析（common 読み込み前でも動く手動パーサ）
  parse_args "$@"

  # 4. 共通スクリプト読み込み（3.--help は parse_args 内で処理済み）
  load_common

  # 5. 必須コマンド確認
  local -a req=(aws date stat find mktemp realpath basename dirname)
  if [[ "$ZIP_DIRECTORIES" == true ]]; then req+=(zip); fi
  require_commands "${req[@]}"

  # 6. 引数整合性 + 正規化
  validate_args
  DEST_PREFIX="$(normalize_prefix "$DEST_PREFIX")"
  if [[ -n "$BUCKET" ]]; then validate_bucket_name "$BUCKET"; fi

  # 7-11. 認証・アカウント一致・権限・スイッチバック
  ensure_account_and_permissions

  # 12. バケット確定
  if [[ "$SELECT_BUCKET" == true ]]; then
    select_bucket_interactive
    validate_bucket_name "$BUCKET"
  fi

  # 13. バケットアクセス確認
  verify_bucket_access

  # 14-16. アップロード元検証・計画作成・衝突確認
  build_plan

  # 17. 計画表示
  show_plan

  # 18-20. ZIP 作成 + 実アップロード + 検証
  local upload_rc=0
  execute_uploads || upload_rc=$?

  # 21. 結果出力
  write_results

  # 22. サマリー
  show_summary

  # 24. 最終終了コード
  if [[ "$COUNT_FAILED" -gt 0 || "$upload_rc" -ne 0 ]]; then
    log_error "1件以上の失敗があります。"
    exit "$EXIT_UPLOAD"
  fi
  log_info "すべての処理が完了しました。"
  exit "$EXIT_OK"
}

main "$@"
