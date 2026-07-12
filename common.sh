#!/usr/bin/env bash
#
# common.sh - 複数のスクリプトで共有するユーティリティ関数群
#
# 使い方:
#   このファイルを source して各関数を利用する。
#     source "$(dirname "$0")/common.sh"
#
#   DRY_RUN=true を設定すると run() は実コマンドを実行せず表示のみ行う。
#
# 注意: このファイル自体は単体実行を想定していない（source 専用）。

# 既に読み込み済みなら何もしない（多重 source 対策）
if [[ -n "${COMMON_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
COMMON_SH_LOADED=1

# ---------------------------------------------------------------------------
# 色定義（端末が対応している場合のみ色を付ける）
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET="$(printf '\033[0m')"
  C_RED="$(printf '\033[31m')"
  C_GREEN="$(printf '\033[32m')"
  C_YELLOW="$(printf '\033[33m')"
  C_BLUE="$(printf '\033[34m')"
else
  C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE=""
fi

# ---------------------------------------------------------------------------
# ログ関数
# ---------------------------------------------------------------------------
log_info()    { printf '%s[INFO]%s  %s\n'  "$C_BLUE"   "$C_RESET" "$*"; }
log_success() { printf '%s[OK]%s    %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
log_warn()    { printf '%s[WARN]%s  %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error()   { printf '%s[ERROR]%s %s\n'  "$C_RED"    "$C_RESET" "$*" >&2; }

# エラーメッセージを出して終了する
# usage: die "メッセージ" [終了コード]
die() {
  local msg="$1"
  local code="${2:-1}"
  log_error "$msg"
  exit "$code"
}

# ---------------------------------------------------------------------------
# コマンド実行ヘルパー
#   DRY_RUN=true のときは実行内容を表示するだけで実行しない。
#   それ以外のときは表示してから実行する。
#
# usage: run git push origin --delete feature/foo
# ---------------------------------------------------------------------------
run() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    printf '%s[DRY-RUN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"
    return 0
  fi
  printf '%s[RUN]%s %s\n' "$C_BLUE" "$C_RESET" "$*"
  "$@"
}

# ---------------------------------------------------------------------------
# 確認プロンプト
#   ASSUME_YES=true（--yes 相当）のときは確認せず yes とみなす。
#   DRY_RUN=true のときも確認をスキップする（破壊的操作は実行されないため）。
#
# usage: if confirm "本当に削除しますか?"; then ... ; fi
# 戻り値: yes -> 0, no -> 1
# ---------------------------------------------------------------------------
confirm() {
  local prompt="${1:-続行しますか?}"

  if [[ "${ASSUME_YES:-false}" == "true" ]]; then
    return 0
  fi
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "(dry-run のため確認をスキップ)"
    return 0
  fi

  local reply
  read -r -p "$prompt [y/N]: " reply
  case "$reply" in
    [yY] | [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 必須コマンドの存在確認
# usage: require_command git
# ---------------------------------------------------------------------------
require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "コマンドが見つかりません: $cmd"
}

# ---------------------------------------------------------------------------
# AWS の認証が済んでいるか（aws login --remote 済みか）を確認する。
#   sts get-caller-identity が成功すれば「認証済み」とみなす。
#
# usage: aws_is_authenticated [aws共通引数...]
#        例: aws_is_authenticated --region ap-northeast-1 --profile foo
# 戻り値: 認証済み -> 0, 未認証 -> 1
# ---------------------------------------------------------------------------
aws_is_authenticated() {
  aws "$@" sts get-caller-identity >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 指定した CodeCommit リポジトリから git pull できる権限があるかを確認する。
#   本スクリプトが実際に必要とするのは管理 API 権限（get-repository 等）ではなく、
#   git 通信に使う codecommit:GitPull 権限である。GitPull は AWS CLI に対応コマンドが
#   無いため、clone と同じ取得経路である git ls-remote を試して判定する。
#     成功                       -> 権限あり (0)
#     認可エラー(403/AccessDenied)-> 権限なし (1)
#     それ以外のエラー(接続不可等) -> 判定不能 (2)。内容を AWS_LAST_ERROR に格納する。
#   GIT_TERMINAL_PROMPT=0 で資格情報の対話入力待ち（ハング）を防ぐ。
#
# usage: aws_can_access_codecommit <clone-url>
# 戻り値: 権限あり -> 0, 権限なし -> 1, その他エラー -> 2
# ---------------------------------------------------------------------------
AWS_LAST_ERROR=""
aws_can_access_codecommit() {
  local url="$1"
  local err
  if err="$(GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$url" 2>&1)"; then
    return 0
  fi
  if printf '%s' "$err" \
       | grep -qiE 'AccessDenied|not authorized|UnauthorizedOperation|\b403\b|Forbidden|Authentication failed|permission|denied'; then
    return 1
  fi
  AWS_LAST_ERROR="$err"
  return 2
}
