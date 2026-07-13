#!/usr/bin/env bash
#
# upload_helper.sh
#
# s3_upload.sh のラッパー（ヘルパー）スクリプト。
#
# 目的:
#   - 毎回多数のパラメータをコンソール入力する手間を減らす。
#   - よく使う値を「設定セクション」に既定値として持たせ、
#     実行時に指定するのは最小限（原則ペイロード=--file/--directory のみ）にする。
#   - どうしても外から指定が必要なパラメータは引数チェックし、usage を表示する。
#
# スイッチバック（source によるスイッチロール制御）に関する重要事項:
#   - スイッチバックは s3_upload.sh 自身のプロセス内で「source」される設計。
#   - よって本ヘルパーは s3_upload.sh を「source せず、子プロセスとして実行」する。
#     こうすることで、s3_upload.sh 内の source は s3_upload.sh のプロセスに反映され、
#     その後の AWS CLI 呼び出し（アップロード等）に正しく効く。
#   - 本ヘルパーが別ディレクトリにあっても壊れないよう:
#       * s3_upload.sh のパスは「本ヘルパーの位置(BASH_SOURCE)」を基準に解決する。
#         （CWD には依存しない）
#       * s3_upload.sh 側も common.sh を自分の BASH_SOURCE 基準で探すため、
#         配置ディレクトリが別でも common.sh 解決は壊れない。
#       * switchback / common / file / directory / result-file のパスは
#         すべて絶対パス化して渡す（CWD が変わっても source 対象を取り違えない）。
#
# ------------------------------------------------------------------------------
set -Eeuo pipefail

# 本ヘルパー自身の設置ディレクトリ（CWD 非依存で解決）
readonly HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HELPER_NAME="$(basename "${BASH_SOURCE[0]}")"

# ==============================================================================
# 設定セクション（ここを自由に編集・追加してください）
#   ここに既定値を入れておくほど、実行時の指定を減らせます。
#   「外から必ず指定させたい」項目は、既定値を空にして REQUIRED_VARS に列挙します。
# ==============================================================================

# --- 主要な既定値 -------------------------------------------------------------
DEFAULT_ACCOUNT_ID="123456789012"                 # 対象 AWS アカウントID（12桁）
DEFAULT_PROFILE=""                                # AWS CLI プロファイル（空=既定）
DEFAULT_REGION="ap-northeast-1"                   # リージョン
DEFAULT_BUCKET="example-bucket"                   # 既定バケット
DEFAULT_PREFIX="incoming"                         # 既定プレフィックス（空=ルート）

# --- バックアップ既定値 ---------------------------------------------------------
#   アップロード先に既存ファイルがある場合、s3_upload.sh が事前にその S3 ディレクトリ
#   配下を ZIP に固めて出力するディレクトリ。空なら --backup-dir を渡さない（無効）。
DEFAULT_BACKUP_DIR=""

# --- スイッチバック（スイッチロール）既定値 ----------------------------------
DEFAULT_SWITCHBACK_MODE="auto"                    # warn | auto
DEFAULT_SWITCHBACK_SCRIPT="/opt/company/aws/switchback.sh"  # auto 時に source される
DEFAULT_SWITCHBACK_ARGS=()                        # 例: ("arn:aws:iam::123456789012:role/Upload")

# --- その他既定値 -------------------------------------------------------------
DEFAULT_COMMON_SCRIPT=""                          # 空なら s3_upload.sh が自動解決
DEFAULT_LOG_LEVEL="INFO"                          # ERROR|WARN|INFO|DEBUG
DEFAULT_RESULT_FORMAT="csv"                       # csv|tsv|json
DEFAULT_RESULT_FILE=""                            # 空なら結果ファイルを出力しない
#   result ファイル名に処理日時(YYYYMMDD_HHMMSS)を付与するか。
#   true なら例: result.csv → result_20260713_153045.csv
DEFAULT_RESULT_TIMESTAMP=true

# --- 将来拡張オプション既定値（空なら渡さない） --------------------------------
DEFAULT_STORAGE_CLASS=""                          # 例: STANDARD_IA / GLACIER
DEFAULT_SSE=""                                    # 例: AES256 / aws:kms
DEFAULT_KMS_KEY_ID=""                             # SSE=aws:kms 時の KMS キーID

# --- パススルーする既定フラグ -------------------------------------------------
#   ここを true にした場合でも、実行時に --no-<フラグ名>（例: --no-allow-overwrite）
#   で打ち消せる。
DEFAULT_ZIP=false
DEFAULT_DRY_RUN=false
DEFAULT_ALLOW_OVERWRITE=false
DEFAULT_CONTINUE_ON_ERROR=false
DEFAULT_VERIFY_UPLOAD=false

# --- 呼び出し先スクリプトの場所 ----------------------------------------------
#   空の場合は以下の順で自動探索する:
#     1) 環境変数 S3_UPLOAD_MAIN
#     2) HELPER_DIR/../s3_upload.sh
#     3) HELPER_DIR/s3_upload.sh
DEFAULT_MAIN_SCRIPT=""

# --- 必須チェック設定 ---------------------------------------------------------
#   REQUIRE_PAYLOAD=true の場合、--file か --directory を最低1つ必須にする。
REQUIRE_PAYLOAD=true
#   最終的に空だとエラーにする論理パラメータ名を列挙する。
#   例: 既定バケットを持たせず毎回指定させたいなら DEFAULT_BUCKET="" にして
#       REQUIRED_VARS=("BUCKET") とする。
#   指定可能な名前: ACCOUNT_ID PROFILE REGION BUCKET PREFIX BACKUP_DIR SWITCHBACK_SCRIPT ...
REQUIRED_VARS=("ACCOUNT_ID" "BUCKET")

# ==============================================================================
# 設定セクションここまで
# ==============================================================================

# ------------------------------------------------------------------------------
# ログ（ヘルパー用の最小ログ。日時付き）
# ------------------------------------------------------------------------------
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
info() { printf '%s [INFO] %s\n' "$(_ts)" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(_ts)" "$*" >&2; }
err()  { printf '%s [ERROR] %s\n' "$(_ts)" "$*" >&2; }
die()  { err "$*"; exit 2; }

# ------------------------------------------------------------------------------
# パス絶対化（存在しなくても正規化する。CWD 基準で相対解決）
# ------------------------------------------------------------------------------
to_abs() {
  local p="$1"
  [[ -z "$p" ]] && { printf ''; return 0; }
  if command -v realpath >/dev/null 2>&1; then
    realpath -m -- "$p" 2>/dev/null || printf '%s' "$p"
  else
    # realpath 不在時のフォールバック
    case "$p" in
      /*) printf '%s' "$p" ;;
      *)  printf '%s/%s' "$(pwd)" "$p" ;;
    esac
  fi
}

# ------------------------------------------------------------------------------
# usage
# ------------------------------------------------------------------------------
usage() {
  cat <<EOF
使い方: ${HELPER_NAME} [オプション] [-- s3_upload.sh へのパススルー引数...]

s3_upload.sh を最小限の指定で呼び出すヘルパーです。
よく使う値は本スクリプト上部の「設定セクション」に既定値として保持しています。
既定値を上書きしたい場合のみ、対応するオプションを指定してください。

ペイロード（いずれか1つ以上必須）:
  --file PATH            アップロードするファイル（複数指定可）
  --directory PATH       アップロードするディレクトリ（複数指定可）

宛先の上書き:
  --bucket NAME          バケット（既定: ${DEFAULT_BUCKET:-（未設定）}）
  --select-bucket        バケット一覧から番号選択（対話端末のみ。既定バケットを無視）
  --prefix PREFIX        プレフィックス（既定: ${DEFAULT_PREFIX:-（ルート）}）
  --root                 ルート直下へ（既定プレフィックスを無視）

AWS の上書き:
  --account-id ID        アカウントID（既定: ${DEFAULT_ACCOUNT_ID:-（未設定）}）
  --profile NAME         プロファイル（既定: ${DEFAULT_PROFILE:-（既定）}）
  --region NAME          リージョン（既定: ${DEFAULT_REGION:-（既定）}）

バックアップ:
  --backup-dir PATH      アップロード先に既存ファイルがある場合、事前にその S3
                         ディレクトリ配下を処理日時付き ZIP に固めて出力する先
                         （既定: ${DEFAULT_BACKUP_DIR:-なし}）
  --no-backup            既定のバックアップ先を無効化（--backup-dir を渡さない）

動作フラグ（パススルー。既定値 true を打ち消すには --no-... を使用）:
  --zip / --no-zip                     ディレクトリを個別ZIP化（--zip-directories）
  --dry-run / --no-dry-run             計画のみ（書き込みなし）
  --allow-overwrite / --no-allow-overwrite   上書き許可
  --continue-on-error / --no-continue-on-error  失敗しても継続
  --verify-upload / --no-verify-upload アップロード後に検証

結果出力:
  --result-file PATH     結果出力先（既定: ${DEFAULT_RESULT_FILE:-なし}）
  --result-format FMT    csv|tsv|json（既定: ${DEFAULT_RESULT_FORMAT}）
  --result-timestamp / --no-result-timestamp
                         結果ファイル名へ処理日時(YYYYMMDD_HHMMSS)を付与
                         （既定: ${DEFAULT_RESULT_TIMESTAMP}。例: result.csv → result_20260101_120000.csv）

オブジェクト属性（空なら渡さない）:
  --storage-class CLASS  ストレージクラス（既定: ${DEFAULT_STORAGE_CLASS:-なし}）
  --sse MODE             サーバサイド暗号化 AES256|aws:kms（既定: ${DEFAULT_SSE:-なし}）
  --kms-key-id ID        SSE=aws:kms 時の KMS キーID（既定: ${DEFAULT_KMS_KEY_ID:-なし}）

スイッチバック（スイッチロール）:
  --switchback-mode M    warn|auto（既定: ${DEFAULT_SWITCHBACK_MODE}）
  --switchback-script P  auto 時に source するスクリプト（既定: ${DEFAULT_SWITCHBACK_SCRIPT:-なし}）
  --switchback-arg V     スイッチバックへ渡す引数（複数指定可）

その他:
  --main-script PATH     s3_upload.sh のパスを明示指定（既定: 自動探索）
  --common-script PATH   common.sh のパスを明示指定
  --config FILE          既定値を上書きする設定ファイルを source
  --log-level LEVEL      ERROR|WARN|INFO|DEBUG（既定: ${DEFAULT_LOG_LEVEL}）
  --print-command        実行せず、組み立てた s3_upload.sh コマンドを表示して終了
  --help                 このヘルプ

例:
  # 最小指定（既定値のバケット/アカウント/スイッチバックを使用）
  ${HELPER_NAME} --file /work/sample.txt

  # 宛先だけ変えて複数ファイル
  ${HELPER_NAME} --prefix release/v1 --file /work/a.txt --file "/work/b 2.csv"

  # ディレクトリをZIP化してdry-run、結果CSV出力（ファイル名に処理日時が付与される）
  ${HELPER_NAME} --zip --dry-run --result-file /work/plan.csv --directory /work/proj

  # 既存ファイルをバックアップしてから上書きアップロード
  ${HELPER_NAME} --backup-dir /work/backup --allow-overwrite --file /work/a.txt

  # 組み立てられるコマンドの確認のみ
  ${HELPER_NAME} --file /work/a.txt --print-command
EOF
}

# ==============================================================================
# 事前パス: --config / --help / --main-script を先に拾う
#   （--config を先に source して既定値へ反映するため）
# ==============================================================================
CONFIG_FILE="${UPLOAD_HELPER_CONFIG:-}"
PRE_MAIN_SCRIPT=""
_scan_pre_args() {
  local a
  local -a argv=("$@")
  local i=0
  while [[ $i -lt ${#argv[@]} ]]; do
    a="${argv[$i]}"
    case "$a" in
      --help|-h) usage; exit 0 ;;
      --config)  CONFIG_FILE="${argv[$((i+1))]:-}"; i=$((i+2)); continue ;;
      --config=*) CONFIG_FILE="${a#*=}"; i=$((i+1)); continue ;;
      --) break ;;
    esac
    i=$((i+1))
  done
}
_scan_pre_args "$@"

# 設定ファイルの読み込み（信頼済みファイル前提。DEFAULT_* を上書き可能）
if [[ -n "$CONFIG_FILE" ]]; then
  CONFIG_FILE="$(to_abs "$CONFIG_FILE")"
  [[ -f "$CONFIG_FILE" && -r "$CONFIG_FILE" ]] || die "設定ファイルを読み込めません: ${CONFIG_FILE}"
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  info "設定ファイルを読み込みました: ${CONFIG_FILE}"
fi

# ==============================================================================
# 作業変数を既定値で初期化
# ==============================================================================
ACCOUNT_ID="$DEFAULT_ACCOUNT_ID"
PROFILE="$DEFAULT_PROFILE"
REGION="$DEFAULT_REGION"
BUCKET="$DEFAULT_BUCKET"
BUCKET_EXPLICIT=false
SELECT_BUCKET=false
PREFIX="$DEFAULT_PREFIX"
ROOT=false
BACKUP_DIR="$DEFAULT_BACKUP_DIR"
SWITCHBACK_MODE="$DEFAULT_SWITCHBACK_MODE"
SWITCHBACK_SCRIPT="$DEFAULT_SWITCHBACK_SCRIPT"
declare -a SWITCHBACK_ARGS=("${DEFAULT_SWITCHBACK_ARGS[@]:-}")
COMMON_SCRIPT="$DEFAULT_COMMON_SCRIPT"
LOG_LEVEL="$DEFAULT_LOG_LEVEL"
RESULT_FILE="$DEFAULT_RESULT_FILE"
RESULT_FORMAT="$DEFAULT_RESULT_FORMAT"
RESULT_TIMESTAMP="$DEFAULT_RESULT_TIMESTAMP"
STORAGE_CLASS="$DEFAULT_STORAGE_CLASS"
SSE="$DEFAULT_SSE"
KMS_KEY_ID="$DEFAULT_KMS_KEY_ID"
ZIP="$DEFAULT_ZIP"
DRY_RUN="$DEFAULT_DRY_RUN"
ALLOW_OVERWRITE="$DEFAULT_ALLOW_OVERWRITE"
CONTINUE_ON_ERROR="$DEFAULT_CONTINUE_ON_ERROR"
VERIFY_UPLOAD="$DEFAULT_VERIFY_UPLOAD"
MAIN_SCRIPT="$DEFAULT_MAIN_SCRIPT"
PRINT_ONLY=false

declare -a FILES=()
declare -a DIRECTORIES=()
declare -a EXTRA_ARGS=()   # -- 以降のパススルー

# SWITCHBACK_ARGS の空要素（初期化由来）を除去
if [[ "${#SWITCHBACK_ARGS[@]}" -eq 1 && -z "${SWITCHBACK_ARGS[0]}" ]]; then
  SWITCHBACK_ARGS=()
fi

# ==============================================================================
# 引数解析（本パース）
# ==============================================================================
_need() { [[ -n "${2:-}" && "${2:-}" != --* ]] || die "オプション $1 に値が必要です。"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file)              _need "$1" "${2:-}"; FILES+=("$2"); shift 2 ;;
      --file=*)            FILES+=("${1#*=}"); shift ;;
      --directory)         _need "$1" "${2:-}"; DIRECTORIES+=("$2"); shift 2 ;;
      --directory=*)       DIRECTORIES+=("${1#*=}"); shift ;;
      --bucket)            _need "$1" "${2:-}"; BUCKET="$2"; BUCKET_EXPLICIT=true; shift 2 ;;
      --bucket=*)          BUCKET="${1#*=}"; BUCKET_EXPLICIT=true; shift ;;
      --select-bucket)     SELECT_BUCKET=true; shift ;;
      --prefix)            _need "$1" "${2:-}"; PREFIX="$2"; shift 2 ;;
      --prefix=*)          PREFIX="${1#*=}"; shift ;;
      --root)              ROOT=true; shift ;;
      --backup-dir)        _need "$1" "${2:-}"; BACKUP_DIR="$2"; shift 2 ;;
      --backup-dir=*)      BACKUP_DIR="${1#*=}"; shift ;;
      --no-backup)         BACKUP_DIR=""; shift ;;
      --account-id)        _need "$1" "${2:-}"; ACCOUNT_ID="$2"; shift 2 ;;
      --account-id=*)      ACCOUNT_ID="${1#*=}"; shift ;;
      --profile)           _need "$1" "${2:-}"; PROFILE="$2"; shift 2 ;;
      --profile=*)         PROFILE="${1#*=}"; shift ;;
      --region)            _need "$1" "${2:-}"; REGION="$2"; shift 2 ;;
      --region=*)          REGION="${1#*=}"; shift ;;
      --zip)               ZIP=true; shift ;;
      --no-zip)            ZIP=false; shift ;;
      --dry-run)           DRY_RUN=true; shift ;;
      --no-dry-run)        DRY_RUN=false; shift ;;
      --allow-overwrite)   ALLOW_OVERWRITE=true; shift ;;
      --no-allow-overwrite) ALLOW_OVERWRITE=false; shift ;;
      --continue-on-error) CONTINUE_ON_ERROR=true; shift ;;
      --no-continue-on-error) CONTINUE_ON_ERROR=false; shift ;;
      --verify-upload)     VERIFY_UPLOAD=true; shift ;;
      --no-verify-upload)  VERIFY_UPLOAD=false; shift ;;
      --result-file)       _need "$1" "${2:-}"; RESULT_FILE="$2"; shift 2 ;;
      --result-file=*)     RESULT_FILE="${1#*=}"; shift ;;
      --result-format)     _need "$1" "${2:-}"; RESULT_FORMAT="$2"; shift 2 ;;
      --result-format=*)   RESULT_FORMAT="${1#*=}"; shift ;;
      --result-timestamp)  RESULT_TIMESTAMP=true; shift ;;
      --no-result-timestamp) RESULT_TIMESTAMP=false; shift ;;
      --storage-class)     _need "$1" "${2:-}"; STORAGE_CLASS="$2"; shift 2 ;;
      --storage-class=*)   STORAGE_CLASS="${1#*=}"; shift ;;
      --sse)               _need "$1" "${2:-}"; SSE="$2"; shift 2 ;;
      --sse=*)             SSE="${1#*=}"; shift ;;
      --kms-key-id)        _need "$1" "${2:-}"; KMS_KEY_ID="$2"; shift 2 ;;
      --kms-key-id=*)      KMS_KEY_ID="${1#*=}"; shift ;;
      --switchback-mode)   _need "$1" "${2:-}"; SWITCHBACK_MODE="$2"; shift 2 ;;
      --switchback-mode=*) SWITCHBACK_MODE="${1#*=}"; shift ;;
      --switchback-script) _need "$1" "${2:-}"; SWITCHBACK_SCRIPT="$2"; shift 2 ;;
      --switchback-script=*) SWITCHBACK_SCRIPT="${1#*=}"; shift ;;
      --switchback-arg)    _need "$1" "${2:-}"; SWITCHBACK_ARGS+=("$2"); shift 2 ;;
      --switchback-arg=*)  SWITCHBACK_ARGS+=("${1#*=}"); shift ;;
      --main-script)       _need "$1" "${2:-}"; MAIN_SCRIPT="$2"; shift 2 ;;
      --main-script=*)     MAIN_SCRIPT="${1#*=}"; shift ;;
      --common-script)     _need "$1" "${2:-}"; COMMON_SCRIPT="$2"; shift 2 ;;
      --common-script=*)   COMMON_SCRIPT="${1#*=}"; shift ;;
      --config|--config=*) shift ;;   # 事前パスで処理済み（値付きは shift 1 で足りる=次で再評価）
      --log-level)         _need "$1" "${2:-}"; LOG_LEVEL="$2"; shift 2 ;;
      --log-level=*)       LOG_LEVEL="${1#*=}"; shift ;;
      --print-command)     PRINT_ONLY=true; shift ;;
      --help|-h)           usage; exit 0 ;;
      --)                  shift; EXTRA_ARGS+=("$@"); break ;;
      -*)                  die "未知のオプションです: $1（--help を参照）" ;;
      *)                   die "余分な引数です: $1（--help を参照）" ;;
    esac
  done
}

# --config が「値あり形式（--config X）」の場合、本パースで先頭に来ると
# X を余分な引数として誤検知しないよう、事前に取り除いておく。
_strip_config() {
  local -a out=()
  local skip=false a
  for a in "$@"; do
    if [[ "$skip" == true ]]; then skip=false; continue; fi
    case "$a" in
      --config)   skip=true; continue ;;
      --config=*) continue ;;
    esac
    out+=("$a")
  done
  # 呼び出し元へ配列を返す（グローバルに格納）
  STRIPPED_ARGS=("${out[@]}")
}
declare -a STRIPPED_ARGS=()
_strip_config "$@"
parse_args "${STRIPPED_ARGS[@]}"

# ==============================================================================
# s3_upload.sh（呼び出し先）の解決
#   ヘルパー位置(BASH_SOURCE)基準で解決し、CWD/配置ディレクトリに依存しない。
# ==============================================================================
resolve_main_script() {
  local candidate="$MAIN_SCRIPT"
  if [[ -z "$candidate" ]]; then
    if [[ -n "${S3_UPLOAD_MAIN:-}" ]]; then
      candidate="${S3_UPLOAD_MAIN}"
    elif [[ -f "${HELPER_DIR}/../s3_upload.sh" ]]; then
      candidate="${HELPER_DIR}/../s3_upload.sh"
    elif [[ -f "${HELPER_DIR}/s3_upload.sh" ]]; then
      candidate="${HELPER_DIR}/s3_upload.sh"
    else
      die "s3_upload.sh が見つかりません。--main-script で明示指定してください。"
    fi
  fi
  candidate="$(to_abs "$candidate")"
  [[ -e "$candidate" ]] || die "呼び出し先スクリプトが存在しません: ${candidate}"
  [[ -f "$candidate" ]] || die "呼び出し先が通常ファイルではありません: ${candidate}"
  [[ -r "$candidate" ]] || die "呼び出し先スクリプトに読み取り権限がありません: ${candidate}"
  MAIN_SCRIPT="$candidate"
}
resolve_main_script

# ==============================================================================
# 引数チェック（外から必ず指定させたいもの）
# ==============================================================================
validate_required() {
  # ペイロード必須
  if [[ "$REQUIRE_PAYLOAD" == true ]]; then
    if [[ "${#FILES[@]}" -eq 0 && "${#DIRECTORIES[@]}" -eq 0 ]]; then
      err "アップロード対象がありません。--file または --directory を1つ以上指定してください。"
      echo >&2
      usage >&2
      exit 2
    fi
  fi

  # バケット直接指定と一覧選択の排他（本体側の制約に合わせる）
  if [[ "$SELECT_BUCKET" == true ]]; then
    if [[ "$BUCKET_EXPLICIT" == true ]]; then
      die "--bucket と --select-bucket は同時指定できません。"
    fi
    # 既定バケットは無視して一覧選択に委ねる
    if [[ -n "$BUCKET" ]]; then
      info "--select-bucket 指定のため、既定バケット（${BUCKET}）は無視します。"
      BUCKET=""
    fi
  fi

  # REQUIRED_VARS に列挙された論理パラメータが空でないこと
  local name val missing=()
  for name in "${REQUIRED_VARS[@]:-}"; do
    [[ -n "$name" ]] || continue
    # --select-bucket 時はバケット名不要（対話選択に委ねる）
    if [[ "$name" == "BUCKET" && "$SELECT_BUCKET" == true ]]; then
      continue
    fi
    val="${!name:-}"
    if [[ -z "$val" ]]; then
      missing+=("$name")
    fi
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    err "必須パラメータが未指定です: ${missing[*]}"
    err "設定セクションの既定値を設定するか、対応するオプションで指定してください。"
    echo >&2
    usage >&2
    exit 2
  fi

  # auto スイッチバック時はスクリプトが必須
  if [[ "$SWITCHBACK_MODE" == "auto" && -z "$SWITCHBACK_SCRIPT" ]]; then
    die "--switchback-mode auto では --switchback-script（または既定値）が必須です。"
  fi
}
validate_required

# ==============================================================================
# 呼び出し引数の組み立て
#   ・パスは絶対化して渡す（CWD 非依存 / source 対象の取り違え防止）
#   ・配列で安全に構築（eval・文字列連結を使わない）
# ==============================================================================
# 結果ファイル名へ処理日時(YYYYMMDD_HHMMSS)を付与する。
#   例: /work/result.csv → /work/result_20260101_120000.csv
#       /work/result     → /work/result_20260101_120000
append_run_timestamp() {
  local p="$1" ts dir name base ext
  ts="$(date '+%Y%m%d_%H%M%S')"
  dir="$(dirname -- "$p")"
  name="$(basename -- "$p")"
  if [[ "$name" == *.* && "$name" != .* ]]; then
    base="${name%.*}"
    ext=".${name##*.}"
  else
    base="$name"
    ext=""
  fi
  printf '%s/%s_%s%s' "$dir" "$base" "$ts" "$ext"
}

build_main_args() {
  MAIN_ARGS=()

  [[ -n "$ACCOUNT_ID" ]] && MAIN_ARGS+=(--account-id "$ACCOUNT_ID")
  [[ -n "$PROFILE" ]]    && MAIN_ARGS+=(--profile "$PROFILE")
  [[ -n "$REGION" ]]     && MAIN_ARGS+=(--region "$REGION")

  # バケット: 直接指定 or 一覧選択（排他は validate_required で確認済み）
  if [[ "$SELECT_BUCKET" == true ]]; then
    MAIN_ARGS+=(--select-bucket)
  elif [[ -n "$BUCKET" ]]; then
    MAIN_ARGS+=(--bucket "$BUCKET")
  fi

  # 宛先: --root 指定 or PREFIX 空 ならルート、そうでなければプレフィックス
  if [[ "$ROOT" == true || -z "$PREFIX" ]]; then
    MAIN_ARGS+=(--destination-root)
  else
    MAIN_ARGS+=(--destination-prefix "$PREFIX")
  fi

  # バックアップ出力先（絶対化して渡す）
  if [[ -n "$BACKUP_DIR" ]]; then
    MAIN_ARGS+=(--backup-dir "$(to_abs "$BACKUP_DIR")")
  fi

  # ペイロード（絶対化）
  local f d
  for f in "${FILES[@]:-}"; do
    [[ -n "$f" ]] || continue
    MAIN_ARGS+=(--file "$(to_abs "$f")")
  done
  for d in "${DIRECTORIES[@]:-}"; do
    [[ -n "$d" ]] || continue
    MAIN_ARGS+=(--directory "$(to_abs "$d")")
  done

  # フラグ
  [[ "$ZIP" == true ]]                && MAIN_ARGS+=(--zip-directories)
  [[ "$DRY_RUN" == true ]]            && MAIN_ARGS+=(--dry-run)
  [[ "$ALLOW_OVERWRITE" == true ]]    && MAIN_ARGS+=(--allow-overwrite)
  [[ "$CONTINUE_ON_ERROR" == true ]]  && MAIN_ARGS+=(--continue-on-error)
  [[ "$VERIFY_UPLOAD" == true ]]      && MAIN_ARGS+=(--verify-upload)

  # 結果ファイル（絶対化。既定で処理日時をファイル名に付与する）
  if [[ -n "$RESULT_FILE" ]]; then
    local result_path
    result_path="$(to_abs "$RESULT_FILE")"
    if [[ "$RESULT_TIMESTAMP" == true ]]; then
      result_path="$(append_run_timestamp "$result_path")"
      info "結果ファイル名に処理日時を付与します: ${result_path}"
    fi
    MAIN_ARGS+=(--result-file "$result_path" --result-format "$RESULT_FORMAT")
  fi

  # オブジェクト属性（指定時のみ渡す）
  [[ -n "$STORAGE_CLASS" ]] && MAIN_ARGS+=(--storage-class "$STORAGE_CLASS")
  [[ -n "$SSE" ]]           && MAIN_ARGS+=(--sse "$SSE")
  [[ -n "$KMS_KEY_ID" ]]    && MAIN_ARGS+=(--kms-key-id "$KMS_KEY_ID")

  # スイッチバック（source 対象は必ず絶対パスで渡す）
  [[ -n "$SWITCHBACK_MODE" ]] && MAIN_ARGS+=(--switchback-mode "$SWITCHBACK_MODE")
  if [[ -n "$SWITCHBACK_SCRIPT" ]]; then
    MAIN_ARGS+=(--switchback-script "$(to_abs "$SWITCHBACK_SCRIPT")")
  fi
  local a
  for a in "${SWITCHBACK_ARGS[@]:-}"; do
    [[ -n "$a" ]] || continue
    MAIN_ARGS+=(--switchback-arg "$a")
  done

  # common.sh（指定時のみ絶対化して渡す。未指定なら main が自動解決）
  if [[ -n "$COMMON_SCRIPT" ]]; then
    MAIN_ARGS+=(--common-script "$(to_abs "$COMMON_SCRIPT")")
  fi

  [[ -n "$LOG_LEVEL" ]] && MAIN_ARGS+=(--log-level "$LOG_LEVEL")

  # -- 以降のパススルー引数
  if [[ "${#EXTRA_ARGS[@]}" -gt 0 ]]; then
    MAIN_ARGS+=("${EXTRA_ARGS[@]}")
  fi
}
declare -a MAIN_ARGS=()
build_main_args

# ==============================================================================
# 実行（重要: source ではなく子プロセスとして実行する）
#   → s3_upload.sh 内部の switchback source は s3_upload.sh のプロセスに反映され、
#     後続の AWS CLI 呼び出しに正しく効く。
# ==============================================================================
print_command() {
  # 表示用に安全にクォート（実行はしない）
  local out="bash ${MAIN_SCRIPT}"
  local x
  for x in "${MAIN_ARGS[@]}"; do
    printf -v x '%q' "$x"
    out+=" $x"
  done
  printf '%s\n' "$out"
}

if [[ "$PRINT_ONLY" == true ]]; then
  info "組み立てた s3_upload.sh 実行コマンド:"
  print_command
  exit 0
fi

info "s3_upload.sh を実行します（子プロセス実行。switchback は呼び出し先内部で source されます）。"
info "呼び出し先: ${MAIN_SCRIPT}"

# stdin/stdout/stderr はそのまま継承する（--select-bucket の対話や TTY 判定を壊さない）。
# bash 明示実行にすることで実行権限(+x)有無に依存しない。
bash "$MAIN_SCRIPT" "${MAIN_ARGS[@]}"
rc=$?

exit "$rc"
