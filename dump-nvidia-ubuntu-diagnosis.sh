#!/usr/bin/env bash
# dump-nvidia-ubuntu-diagnosis.sh — Ubuntu の NVIDIA ドライバ / Linux カーネル周りの不調を診断する
#
# 情報を集めて判定するだけで、システムには何も変更を加えない
# (パッケージ導入・設定変更・モジュール読み込み・再起動はしない)。
#
# 使い方 (デスクトップのターミナルから一般ユーザーで実行):
#   ./dump-nvidia-ubuntu-diagnosis.sh                 診断して判定を表示し、レポートを保存する
#   ./dump-nvidia-ubuntu-diagnosis.sh --sudo          MOK 鍵の登録状況など、権限が要る確認も行う (読み取りのみ)
#   ./dump-nvidia-ubuntu-diagnosis.sh --redact        レポート中のホスト名・ユーザー名・GPU シリアル等を伏せる
#   ./dump-nvidia-ubuntu-diagnosis.sh --attach FILE   任意のファイル (chrome://gpu のコピーなど) をレポートに添付
#   ./dump-nvidia-ubuntu-diagnosis.sh -o FILE         レポートの保存先 (既定: ./nvidia-ubuntu-report-日時.txt)
#   ./dump-nvidia-ubuntu-diagnosis.sh --no-color      色を付けない
#
# 終了コード: 0 = 問題なし / 1 = 注意 (WARN) あり / 2 = 異常 (FAIL) あり

# shellcheck disable=SC2016  # dpkg-query の書式や awk のプログラムは意図的に単一引用符で渡す

set -u

# ================================================================ 共通

have() { command -v "$1" >/dev/null 2>&1; }
die() { printf 'nvidia-ubuntu: %s\n' "$*" >&2; exit 64; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
upstream() { local v=${1#*:}; printf '%s' "${v%%-*}"; }   # 1:595.99.02-0ubuntu1 → 595.99.02
nlines() { grep -c . <<<"$1"; }

F_LEVEL=() F_TITLE=() F_BODY=()
finding() { F_LEVEL+=("$1"); F_TITLE+=("$2"); F_BODY+=("${3:-}"); }

sec()  { printf '\n######## %s ########\n' "$1" >>"$RAW"; }
note() { printf '%s\n' "$@" >>"$RAW"; }

# 標準入力を「先頭 h 行 + 末尾 t 行」に詰める
headtail() {
  awk -v h="$1" -v t="$2" '{ a[NR] = $0 }
    END {
      if (NR <= h + t) { for (i = 1; i <= NR; i++) print a[i] }
      else {
        for (i = 1; i <= h; i++) print a[i]
        printf "... (%d 行省略) ...\n", NR - h - t
        for (i = NR - t + 1; i <= NR; i++) print a[i]
      }
    }'
}

# コマンドを実行し、コマンド行と出力を生データに記録する
run() {
  local cmd=$1 limit=${2:-200} t="$WORK/run.out" rc
  printf '$ %s\n' "$cmd" >>"$RAW"
  timeout 40 bash -c "$cmd" >"$t" 2>&1; rc=$?
  headtail "$limit" 0 <"$t" >>"$RAW"
  if (( rc == 124 )); then note '[timeout]'; elif (( rc != 0 )); then note "[exit $rc]"; fi
  note ''
}

# ================================================================ 準備

parse_args() {
  OUT="" REDACT=0 COLOR=auto USE_SUDO=0 ATTACH=()
  while (( $# )); do
    case $1 in
      -o|--output) (( $# >= 2 )) || die "-o にはファイル名が必要"; OUT=$2; shift 2 ;;
      --attach)    (( $# >= 2 )) || die "--attach にはファイル名が必要"; ATTACH+=("$2"); shift 2 ;;
      --redact)    REDACT=1; shift ;;
      --sudo)      USE_SUDO=1; shift ;;
      --no-color)  COLOR=never; shift ;;
      -h|--help)   usage; exit 0 ;;
      *)           usage >&2; die "不明なオプション: $1" ;;
    esac
  done
}

setup() {
  export LC_ALL=C
  export PATH="$PATH:/usr/sbin:/sbin"
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/nvidia-ubuntu-report.XXXXXX") || die "一時ディレクトリを作れない"
  trap 'rm -rf "$WORK"' EXIT
  RAW="$WORK/raw.txt"; : >"$RAW"
  SUDO=""
  if (( USE_SUDO && EUID != 0 )); then
    echo "権限が必要な確認に sudo を使います (読み取りのみ)。" >&2
    if sudo -v; then SUDO="sudo -n"; else echo "sudo を使えないため、その確認は省略します。" >&2; fi
  fi
  if [[ $COLOR == auto && -t 1 ]]; then
    C_FAIL=$'\e[1;31m' C_WARN=$'\e[1;33m' C_INFO=$'\e[36m' C_OK=$'\e[32m' C_B=$'\e[1m' C_0=$'\e[0m'
  else
    C_FAIL="" C_WARN="" C_INFO="" C_OK="" C_B="" C_0=""
  fi
}

# ================================================================ 事実の収集

# 使用中のライブラリの版に合う候補を優先し、一意に決まらなければ選ばない。
select_driver_packages() {
  local candidates matches p v target=${USER_VER:-${DISK_VER:-$LOADED_VER}}
  DRV_PKG="" DRV_BRANCH="" DRV_VARIANT="" PKG_VER="" DKMS_PKG="" DKMS_VER=""
  candidates=$(awk -F'\t' '$1 ~ /^nvidia-(driver|headless(-no-dkms)?)-[0-9]+(-open|-server|-server-open)?$/ { print }' <<<"$PKG_NV_INST")
  matches=""
  while IFS=$'\t' read -r p v; do
    [[ -n $p ]] || continue
    [[ -n $target && $(upstream "$v") == "$target" ]] && matches+="$p"$'\t'"$v"$'\n'
  done <<<"$candidates"
  [[ -n $matches ]] && candidates=$matches
  if (( $(nlines "$candidates") == 1 )); then
    IFS=$'\t' read -r DRV_PKG v <<<"$candidates"
    PKG_VER=$(upstream "$v")
    DRV_BRANCH=$(grep -oE '[0-9]+' <<<"$DRV_PKG" | head -n1)
    DRV_VARIANT=$(sed -E 's/^nvidia-(driver|headless(-no-dkms)?)-[0-9]+//' <<<"$DRV_PKG")
  else
    candidates=$(awk -F'\t' -v t="$target" '
      $1 ~ /^libnvidia-gl-[0-9]+(-server)?$/ {
        v=$2; sub(/^[0-9]+:/, "", v); sub(/-.*/, "", v)
        if (v == t) print $1 "\t" v
      }' <<<"$PKG_NV_INST")
    if (( $(nlines "$candidates") == 1 )); then
      IFS=$'\t' read -r p PKG_VER <<<"$candidates"
      DRV_BRANCH=$(grep -oE '[0-9]+' <<<"$p" | head -n1)
      [[ $p == *-server ]] && DRV_VARIANT=-server
      # open / proprietary の違いはディスク上のモジュールから取得する。
      [[ $(modinfo -F license nvidia 2>/dev/null) == *MIT* ]] && DRV_VARIANT+=-open
    fi
  fi
  if [[ -n $DRV_BRANCH ]]; then
    p="nvidia-dkms-${DRV_BRANCH}${DRV_VARIANT}"
    v=$(awk -F'\t' -v p="$p" '$1 == p { print $2 }' <<<"$PKG_NV_INST")
    if [[ -n $v ]]; then DKMS_PKG=$p; DKMS_VER=$(upstream "$v"); fi
  fi
}

collect_facts() {
  local f v d k l

  KREL=$(uname -r)
  HOST=$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)
  NOW=$(date '+%F %T')
  local btime; btime=$(awk '/^btime/ { print $2 }' /proc/stat 2>/dev/null)
  BOOT_TIME=$(date -d "@${btime:-0}" '+%F %T')
  OS_NAME=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"')
  SESSION_TYPE=${XDG_SESSION_TYPE:-}
  HAS_DISPLAY=0; [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]] && HAS_DISPLAY=1

  # --- GPU
  NV_GPUS=""
  have lspci && NV_GPUS=$(lspci -d 10de: -nn 2>/dev/null | grep -E 'VGA|3D|Display')
  if [[ -z $NV_GPUS ]]; then
    for d in /sys/bus/pci/devices/*; do
      [[ $(cat "$d/vendor" 2>/dev/null) == 0x10de && $(cat "$d/class" 2>/dev/null) == 0x03* ]] || continue
      NV_GPUS+="${d##*/} NVIDIA GPU"$'\n'
    done
    NV_GPUS=${NV_GPUS%$'\n'}
  fi

  # --- パッケージ (状態は ${db:Status-Abbrev}: 1 文字目 = 希望, 2 文字目 = 状態, 3 文字目 = エラー)
  PKG_ALL=$(dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Version}\n' 2>/dev/null)
  PKG_NV=$(awk -F'\t' '$2 ~ /nvidia/ && substr($1, 2, 1) != "n"' <<<"$PKG_ALL")
  PKG_NV_INST=$(awk -F'\t' 'substr($1, 2, 1) == "i" { print $2 "\t" $3 }' <<<"$PKG_NV")
  PKG_BROKEN=$(awk -F'\t' '$2 ~ /nvidia|^linux-(image|headers|modules)/ && (substr($1, 2, 1) ~ /[HUFWt]/ || substr($1, 3, 1) == "R")' <<<"$PKG_ALL")
  PKG_HELD=$(awk -F'\t' '$2 ~ /nvidia|^linux-/ && substr($1, 1, 1) == "h" && substr($1, 2, 1) == "i" { print $2 }' <<<"$PKG_ALL")

  # ドライバ本体を構成するパッケージの「上流バージョン<TAB>名前」
  PKG_CORE_VERS=$(awk -F'\t' '
    $1 ~ /^(linux-|nvidia-firmware-|nvidia-settings$|nvidia-prime$|libnvidia-egl-(wayland|gbm|xcb|xlib))/ { next }
    { v = $2; sub(/^[0-9]+:/, "", v); sub(/-.*/, "", v); if (v ~ /^[0-9]+\./) print v "\t" $1 }' <<<"$PKG_NV_INST")
  PKG_CORE_DISTINCT=$(cut -f1 <<<"$PKG_CORE_VERS" | grep . | sort -u)
  BRANCHES=$(cut -f2 <<<"$PKG_CORE_VERS" | grep -oE -- '-[0-9]+(-|$)' | grep -oE '[0-9]+' | sort -u)
  PREBUILT_KREL=$(awk -F'\t' -v s="-$KREL" '$1 ~ /^linux-modules-nvidia-/ && substr($1, length($1) - length(s) + 1) == s { print $1 }' <<<"$PKG_NV_INST")

  # --- ユーザー空間ライブラリ (ファイル名末尾のバージョン)
  declare -gA LIB_VERS=()
  for f in /usr/lib/x86_64-linux-gnu/lib{nvidia-,cuda,GLX_nvidia,EGL_nvidia}*.so.* \
           /usr/lib/i386-linux-gnu/lib{nvidia-,cuda,GLX_nvidia,EGL_nvidia}*.so.*; do
    [[ -f $f && ! -L $f ]] || continue
    v=${f##*.so.}
    [[ $v =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || continue
    LIB_VERS[$v]=$(( ${LIB_VERS[$v]:-0} + 1 ))
  done
  USER_VER=""
  for f in libGLX_nvidia.so.0 libnvidia-ml.so.1 libcuda.so.1; do
    v=$(readlink -f "/usr/lib/x86_64-linux-gnu/$f" 2>/dev/null)
    [[ -f $v ]] || continue
    v=${v##*.so.}
    if [[ $v =~ ^[0-9]+\. ]]; then USER_VER=$v; break; fi
  done

  # --- カーネルモジュール
  MOD_LOADED=0 LOADED_VER="" LOADED_KIND=""
  if [[ -d /sys/module/nvidia ]]; then
    MOD_LOADED=1
    LOADED_VER=$(cat /sys/module/nvidia/version 2>/dev/null)
  fi
  if [[ -r /proc/driver/nvidia/version ]]; then
    l=$(grep -m1 NVRM /proc/driver/nvidia/version)
    [[ -z $LOADED_VER ]] && LOADED_VER=$(grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' <<<"$l" | head -n1)
    if [[ $l == *Open* ]]; then LOADED_KIND=open; else LOADED_KIND=proprietary; fi
  fi
  DISK_FILE=$(modinfo -F filename nvidia 2>/dev/null | head -n1)
  DISK_VER=$(modinfo -F version nvidia 2>/dev/null | head -n1)
  DISK_SIGNER=$(modinfo -F signer nvidia 2>/dev/null | head -n1)
  DKMS_MODULE=0; [[ $DISK_FILE == */updates/dkms/* ]] && DKMS_MODULE=1
  select_driver_packages
  KO_LIST=""
  while IFS= read -r f; do
    KO_LIST+="$f  ($(modinfo -F version "$f" 2>/dev/null))"$'\n'
  done < <(find "/lib/modules/$KREL" -name 'nvidia.ko*' 2>/dev/null)
  KO_LIST=${KO_LIST%$'\n'}

  # --- インストール済みカーネルと次回起動の推定
  KERNELS=()
  for f in /boot/vmlinuz-*; do [[ -f $f ]] && KERNELS+=("${f#/boot/vmlinuz-}"); done
  if (( ${#KERNELS[@]} )); then mapfile -t KERNELS < <(printf '%s\n' "${KERNELS[@]}" | sort -V); fi
  NEXT_KERNEL="" NEXT_HOW=""
  local gd se=""
  gd=$(grep -hE '^[[:space:]]*GRUB_DEFAULT=' /etc/default/grub /etc/default/grub.d/*.cfg 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d "\"' ")
  if [[ -r /boot/grub/grubenv ]]; then
    se=$(sed -n 's/^next_entry=//p' /boot/grub/grubenv)
    [[ -z $se && $gd == saved ]] && se=$(sed -n 's/^saved_entry=//p' /boot/grub/grubenv)
  fi
  if [[ -n $se ]]; then
    for k in "${KERNELS[@]}"; do
      if [[ $se == *"$k"* && ${#k} -gt ${#NEXT_KERNEL} ]]; then NEXT_KERNEL=$k; fi
    done
    [[ -n $NEXT_KERNEL ]] && NEXT_HOW="grubenv の指定"
  fi
  if [[ -z $NEXT_KERNEL ]] && [[ -r /boot/grub/grub.cfg ]] && (( ${#KERNELS[@]} )) &&
     [[ -z $gd || $gd == 0 || ( $gd == saved && ( -z $se || $se == 0 ) ) ]]; then
    local first_kernel
    first_kernel=$(awk '$1 == "linux" || $1 == "linuxefi" { for (i=2; i<=NF; i++) if ($i ~ /\/vmlinuz-/) { sub(/^.*\/vmlinuz-/, "", $i); print $i; exit } }' /boot/grub/grub.cfg)
    for k in "${KERNELS[@]}"; do
      [[ $k == "$first_kernel" ]] && NEXT_KERNEL=$k
    done
    [[ -n $NEXT_KERNEL ]] && NEXT_HOW="GRUB_DEFAULT=${gd:-0}、生成済み grub.cfg の先頭"

  fi

  # カーネルごとの nvidia モジュールの版と、ライブラリと版が合うカーネル
  declare -gA KMOD_VER=()
  GOOD_KERNELS=()
  for k in "${KERNELS[@]}"; do
    KMOD_VER[$k]=$(modinfo -k "$k" -F version nvidia 2>/dev/null | head -n1)
    [[ -n ${KMOD_VER[$k]} && ( -z $USER_VER || ${KMOD_VER[$k]} == "$USER_VER" ) ]] && GOOD_KERNELS+=("$k")
  done

  # --- Secure Boot と DKMS 署名鍵 (MOK)
  SB_ON="" SB_STATE=""
  have mokutil && SB_STATE=$(mokutil --sb-state 2>&1 | head -n1)
  case $SB_STATE in
    *"SecureBoot enabled"*)  SB_ON=1 ;;
    *"SecureBoot disabled"*) SB_ON=0 ;;
  esac
  if [[ -z $SB_ON ]]; then
    f=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
    if [[ -r $f ]]; then
      if [[ $(od -An -t u1 "$f" | awk '{ print $NF }') == 1 ]]; then SB_ON=1 SB_STATE="SecureBoot enabled (efivars)"
      else SB_ON=0 SB_STATE="SecureBoot disabled (efivars)"; fi
    elif [[ ! -d /sys/firmware/efi ]]; then
      SB_ON=0 SB_STATE="レガシー BIOS 起動 (Secure Boot なし)"
    fi
  fi
  MOK_CERT=/var/lib/shim-signed/mok/MOK.der
  local c; c=$(grep -hE '^[[:space:]]*mok_certificate=' /etc/dkms/framework.conf /etc/dkms/framework.conf.d/*.conf 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d "\"' ")
  [[ -n $c ]] && MOK_CERT=$c
  MOK_STATE=unknown MOK_PENDING=0
  if have mokutil && [[ $SB_ON == 1 ]]; then
    local t
    if $SUDO test -e "$MOK_CERT" 2>/dev/null; then
      t=$($SUDO mokutil --test-key "$MOK_CERT" 2>&1)
      case $t in
        *"already enrolled"*)   MOK_STATE=enrolled ;;
        *"enrollment request"*) MOK_STATE=pending ;;
        *"not enrolled"*)       MOK_STATE=not-enrolled ;;
        *)                      MOK_STATE="unknown ($(head -n1 <<<"$t"))" ;;
      esac
    elif [[ -n $SUDO || -x ${MOK_CERT%/*} ]]; then
      MOK_STATE=no-key
    else
      MOK_STATE=unreadable
    fi
    [[ $($SUDO mokutil --list-new 2>&1) == *"[key"* ]] && MOK_PENDING=1
    [[ $MOK_STATE == not-enrolled && $MOK_PENDING == 1 ]] && MOK_STATE=pending
  fi

  # --- モジュールの読み込みを妨げる設定
  NOUVEAU_LOADED=0; [[ -d /sys/module/nouveau ]] && NOUVEAU_LOADED=1
  CMDLINE=$(cat /proc/cmdline 2>/dev/null)
  CMDLINE_BL=$(grep -oE '(module_blacklist|modprobe\.blacklist)=[^ ]*nvidia[^ ]*' <<<"$CMDLINE")
  NOMODESET=0; [[ " $CMDLINE " == *" nomodeset "* ]] && NOMODESET=1
  local mpdirs=(/etc/modprobe.d /usr/lib/modprobe.d /run/modprobe.d)
  [[ /lib -ef /usr/lib ]] || mpdirs+=(/lib/modprobe.d)
  BLACKLIST_HITS=""
  for d in "${mpdirs[@]}"; do
    [[ -d $d ]] || continue
    BLACKLIST_HITS+=$(grep -HnE '^[[:space:]]*(blacklist[[:space:]]+nvidia([-_](drm|modeset|uvm))?[[:space:]]*$|install[[:space:]]+nvidia([-_](drm|modeset|uvm))?[[:space:]]+/bin/(false|true)|alias[[:space:]]+nvidia([-_](drm|modeset|uvm))?[[:space:]]+off)' "$d"/*.conf 2>/dev/null)$'\n'
  done
  BLACKLIST_HITS=$(grep . <<<"$BLACKLIST_HITS")
  PRIME_MODE=""; have prime-select && PRIME_MODE=$(timeout 10 prime-select query 2>/dev/null | head -n1)
  MODESET=$(cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null)

  # --- ログ
  KLOG="" KLOG_SRC=""
  if have journalctl; then
    KLOG=$($SUDO journalctl -k -b 0 -q --no-pager -o short-monotonic 2>/dev/null)
    [[ -n $KLOG ]] && KLOG_SRC="journalctl -k -b 0"
  fi
  if [[ -z $KLOG ]]; then
    KLOG=$($SUDO dmesg 2>/dev/null)
    [[ -n $KLOG ]] && KLOG_SRC=dmesg
  fi
  NVLOG=$(grep -iE 'nvidia|NVRM|nouveau|Xid|module verification|Key was rejected|Lockdown|unsigned module|unavailable key' <<<"$KLOG")
  JLOG_WARN=""
  have journalctl && JLOG_WARN=$($SUDO journalctl -b 0 -p warning -q --no-pager -o short-monotonic 2>/dev/null | grep -iE 'nvidia|NVRM|nouveau' | tail -n 150)
  SIG_REJECT_LINES=$(printf '%s\n%s\n' "$NVLOG" "$JLOG_WARN" | grep -iE 'Key was rejected|Loading of (unsigned module|module with unavailable key) is rejected|Lockdown:.*unsigned module' | sort -u | head -n 5)

  # --- DKMS
  MAKELOG=$(ls -t /var/lib/dkms/nvidia/*/build/make.log /var/lib/dkms/nvidia/*/*/*/log/make.log 2>/dev/null | head -n1)
  DKMS_STATUS=""; have dkms && DKMS_STATUS=$(dkms status 2>&1)
  # apt の端末ログに残る DKMS ビルド失敗 (カーネル名の一覧)
  DKMS_FAILED_KERNELS=$($SUDO tail -n 20000 /var/log/apt/term.log 2>/dev/null |
    sed -nE 's/.*Bad return status for module build on kernel: ([^ ]+).*/\1/p' | sort -u)
  MAKELOG_ERRORS=""
  [[ -n $MAKELOG ]] && MAKELOG_ERRORS=$($SUDO grep -m5 -E 'error:|Error [0-9]+|\*\*\*' "$MAKELOG" 2>/dev/null)
  NEXT_BAD=0

  # --- Secure Boot が読み込みを妨げているか
  SB_ISSUE=""
  if [[ $SB_ON == 1 ]]; then
    if (( ! MOD_LOADED )) && [[ -n $SIG_REJECT_LINES ]] && grep -qi nvidia <<<"$SIG_REJECT_LINES"; then
      SB_ISSUE=rejected
    elif [[ -n $DISK_VER && -z $DISK_SIGNER ]]; then
      SB_ISSUE=unsigned
    elif (( DKMS_MODULE )) && [[ $MOK_STATE == pending ]]; then
      SB_ISSUE=pending
    fi
  fi

  CORE_STATE=unknown
}

# ================================================================ 対処のヒント

module_fix_hint() {   # $1 = カーネル
  local k=$1
  if [[ -n $DKMS_PKG && -n $USER_VER && $DKMS_VER != "$USER_VER" ]]; then
    printf '%s\n' "→ $DKMS_PKG が $DKMS_VER のまま (ライブラリは $USER_VER)。sudo apt install $DKMS_PKG で揃える" \
      "  (更新が保留 (hold) されていれば先に sudo apt-mark unhold $DKMS_PKG)。揃えば各カーネル用のモジュールが自動でビルドされる"
  elif [[ -n $DKMS_PKG ]] && grep -qxF -- "$k" <<<"$DKMS_FAILED_KERNELS"; then
    printf '%s\n' "DKMS でのビルドが失敗した記録がある (/var/log/apt/term.log)。" \
      "${MAKELOG_ERRORS:+ビルドログ ($MAKELOG) のエラー:
$(sed 's/^/    /' <<<"$MAKELOG_ERRORS")
}新しいカーネルにドライバがまだ対応していないことが多い。" \
      "$(boot_other_kernel_hint "$k")" \
      "→ sudo apt update && sudo apt upgrade で対応版のドライバが来たら、sudo dkms autoinstall -k $k で再ビルド"
  elif [[ -n $DKMS_PKG ]]; then
    [[ -e /lib/modules/$k/build ]] || echo "→ sudo apt install linux-headers-$k"
    echo "→ sudo dkms autoinstall -k $k   (失敗したら ${MAKELOG:-/var/lib/dkms/nvidia/<版>/build/make.log} の末尾にエラーがある)"
  elif [[ -n $DRV_BRANCH ]]; then
    printf '%s\n' "→ sudo apt install linux-modules-nvidia-${DRV_BRANCH}${DRV_VARIANT}-$k   (このカーネル用のビルド済みモジュール)" \
      "  そのパッケージがなければ sudo apt install nvidia-dkms-${DRV_BRANCH}${DRV_VARIANT} で DKMS ビルドに切り替える"
  else
    echo "→ ubuntu-drivers list と apt-cache policy で、この GPU に対応するドライバとインストール済みパッケージの候補を確認する。ブランチを特定できないため自動で修復コマンドを決められない"
  fi
}

# $1 のカーネルを避け、nvidia モジュールの揃ったカーネルで起動する手順
boot_other_kernel_hint() {
  local k g="" c
  for c in "${GOOD_KERNELS[@]}"; do [[ $c == "$1" ]] || g=$c; done   # 版の新しいほう
  if [[ -z $g ]]; then
    echo "→ nvidia モジュールの揃った別のカーネルがない。対応版のドライバが来るまで GPU なしで使うか、ドライバのブランチを変える (ubuntu-drivers list)"
    return
  fi
  local cur=""; [[ $g == "$KREL" ]] && cur="今動いている"
  printf '%s
' "→ 当面は${cur}カーネル $g で起動する: 起動直後に Esc (または Shift) で GRUB メニューを出し、Advanced options for Ubuntu から選ぶ" \
    "  固定するなら /etc/default/grub を GRUB_DEFAULT=\"Advanced options for Ubuntu>Ubuntu, with Linux $g\" にして sudo update-grub"
}

sb_issue_text() {
  case $SB_ISSUE in
    rejected)     echo "カーネルがモジュールの署名を拒否している" ;;
    unsigned)     echo "モジュールに署名がない" ;;
    not-enrolled) echo "DKMS の署名鍵が MOK に登録されていない" ;;
    no-key)       echo "DKMS の署名鍵がない" ;;
    pending)      echo "MOK 鍵が登録待ち" ;;
  esac
}

sb_reboot_note() {
  case $SB_ISSUE in
    pending) printf '%s' "。再起動時に青い MOK Manager の画面が出たら Enroll MOK を選ぶ (下の Secure Boot の項目)" ;;
    not-enrolled|no-key|unsigned|rejected)
      printf '%s' "。ただし Secure Boot の署名の問題があり、再起動しても読み込めない見込み。先に下の Secure Boot の項目を対処する" ;;
  esac
}

# ================================================================ 判定

check_core() {
  CORE_STATE=ok
  if [[ -z $NV_GPUS ]]; then
    CORE_STATE=nogpu
    finding INFO "NVIDIA GPU が PCI 上に見えない" "lspci に NVIDIA (10de) の表示デバイスがない。NVIDIA GPU 非搭載か、BIOS 設定・物理的な接続・仮想マシンのパススルーの問題。"
    return
  fi
  if [[ -z $DRV_PKG && -z $USER_VER && -z $DISK_VER ]]; then
    CORE_STATE=nodriver
    finding FAIL "NVIDIA ドライバが入っていない" "nvidia-driver-* パッケージも NVIDIA のライブラリも見つからない。
→ ubuntu-drivers list で候補を確認し、sudo ubuntu-drivers install で推奨ドライバを入れる"
    return
  fi

  [[ -z $DRV_BRANCH ]] && finding WARN "使用するドライバのブランチを一意に特定できない" "複数候補やメタパッケージの欠落が考えられる。生データのパッケージ一覧、ライブラリ、modinfo の版を照合する。
→ ubuntu-drivers list と apt-cache policy で対応する候補を確認する"

  local vers="読み込み中 ${LOADED_VER:-なし} / ディスク上 ${DISK_VER:-なし} / ライブラリ ${USER_VER:-なし}"
  if (( MOD_LOADED )); then
    if [[ -n $USER_VER && $LOADED_VER != "$USER_VER" ]]; then
      if [[ $DISK_VER == "$USER_VER" ]]; then
        CORE_STATE=reboot
        finding FAIL "再起動待ち: メモリ上の nvidia モジュールが更新前のまま" "$vers
ドライバの更新で新しいモジュールは用意済みだが、読み込まれているのは更新前のもの。
このままでは OpenGL / Vulkan / CUDA / nvidia-smi がすべて失敗し、ブラウザなどはソフトウェア描画になる。
→ 下の「次回起動予定」の確認結果を見て、起動先のモジュールに問題がないことを確認してから再起動する$(sb_reboot_note)"
      else
        CORE_STATE=mismatch
        finding FAIL "nvidia モジュールとライブラリのバージョン不一致 (新しいモジュールが用意されていない)" "$vers
実行中カーネル ($KREL) 用の $USER_VER のモジュールがディスクにないため、再起動しても直らない。
$(module_fix_hint "$KREL")
→ 用意できたら再起動"
      fi
    elif [[ -z $USER_VER ]]; then
      CORE_STATE=nolib
      finding FAIL "NVIDIA のユーザー空間ライブラリが見つからない" "$vers
→ sudo apt install --reinstall ${DRV_PKG:-nvidia-driver-<番号>}"
    else
      finding OK "nvidia モジュールとライブラリのバージョンが一致 ($LOADED_VER)"
      if [[ -n $DISK_VER && $DISK_VER != "$LOADED_VER" ]]; then
        finding WARN "ディスク上の nvidia モジュール ($DISK_VER) が読み込み中 ($LOADED_VER) と違う" "次回起動でライブラリ ($USER_VER) と食い違うおそれ。パッケージが中途半端に更新・ダウングレードされた可能性。
$(module_fix_hint "$KREL")"
      fi
    fi
  else
    CORE_STATE=notloaded
    local why=() w
    [[ -z $DISK_VER ]] && why+=("実行中カーネル $KREL 用の nvidia.ko がディスクにない")
    [[ -n $BLACKLIST_HITS ]] && why+=("modprobe の設定でブラックリストされている")
    [[ -n $CMDLINE_BL ]] && why+=("カーネル起動オプションで無効化されている ($CMDLINE_BL)")
    (( NOUVEAU_LOADED )) && why+=("nouveau が先に GPU を掴んでいる")
    [[ $PRIME_MODE == intel ]] && why+=("prime-select が intel (NVIDIA を使わない設定)")
    if [[ $SB_ISSUE == pending ]]; then why+=("Secure Boot の MOK 鍵が登録待ち")
    elif [[ -n $SB_ISSUE ]]; then why+=("Secure Boot: $(sb_issue_text)"); fi
    [[ -n $DISK_VER && -n $USER_VER && $DISK_VER != "$USER_VER" ]] && why+=("ディスク上のモジュール ($DISK_VER) とライブラリ ($USER_VER) が不一致")
    local body="$vers"$'\n'"OpenGL / Vulkan / CUDA は NVIDIA を使えない。"
    if (( ${#why[@]} )); then
      body+=$'\n'"考えられる原因 (詳細と対処は下の各項目):"
      for w in "${why[@]}"; do body+=$'\n'"  - $w"; done
    else
      body+=$'\n'"個別の確認では原因を特定できなかった。"$'\n'"→ sudo modprobe nvidia を実行し、表示されるエラーを確認する (読み込みを試すだけ)"
    fi
    finding FAIL "nvidia カーネルモジュールが読み込まれていない" "$body"
  fi
}

check_kernels() {
  sec "インストール済みカーネルと nvidia モジュール"
  note "実行中: $KREL" "次回起動 (推定): ${NEXT_KERNEL:-不明}${NEXT_HOW:+ ($NEXT_HOW)}"
  note "実行中カーネル用の nvidia.ko:" "${KO_LIST:-(なし)}" ""
  local k v hdr tag no_mod=()
  for k in "${KERNELS[@]}"; do
    v=${KMOD_VER[$k]:-}
    if [[ -e /lib/modules/$k/build ]]; then hdr=あり; else hdr=なし; fi
    tag=""
    [[ $k == "$KREL" ]] && tag+=" [実行中]"
    [[ $k == "$NEXT_KERNEL" ]] && tag+=" [次回起動(推定)]"
    note "$k  ヘッダ:$hdr  nvidia:${v:-なし}$tag"
    if [[ $k != "$KREL" ]] && [[ -z $v || ( -n $USER_VER && $v != "$USER_VER" ) ]]; then no_mod+=("$k:${v:-なし}"); fi
  done

  [[ -n $NV_GPUS ]] || return 0

  if (( $(sed -n 's/.*(\(.*\))$/\1/p' <<<"$KO_LIST" | sort -u | grep -c .) > 1 )); then
    finding WARN "実行中カーネル用に版の違う nvidia.ko が複数ある" "$KO_LIST
updates/dkms にあるものが優先される (depmod の検索順)。使われないほうは古いパッケージの残り。"
  fi

  if [[ -z $NEXT_KERNEL ]]; then
    NEXT_BAD=1
    finding WARN "次回起動カーネルを特定できない" "GRUB の設定やカーネルの選択順を確認できない。
→ 再起動時に GRUB メニューでモジュールの版が合うカーネルを選ぶ (上の一覧を参照)"
  fi
  if [[ -n $NEXT_KERNEL ]]; then
    v=${KMOD_VER[$NEXT_KERNEL]:-}
    if [[ -z $v ]]; then
      NEXT_BAD=1
      finding WARN "次回起動予定 (推定) のカーネル $NEXT_KERNEL 用の nvidia モジュールがない" "再起動するとこのカーネルで起動し、GPU が使えない状態になる。再起動の前に用意する。
$(module_fix_hint "$NEXT_KERNEL")"
    elif [[ -n $USER_VER && $v != "$USER_VER" ]]; then
      NEXT_BAD=1
      finding WARN "次回起動予定 (推定) のカーネル $NEXT_KERNEL の nvidia モジュール ($v) がライブラリ ($USER_VER) と不一致" "$(module_fix_hint "$NEXT_KERNEL")"
    else
      finding OK "次回起動予定 (推定) のカーネル $NEXT_KERNEL にも nvidia $v が用意済み"
    fi
  fi

  local others=() e
  for e in "${no_mod[@]}"; do [[ ${e%%:*} == "$NEXT_KERNEL" ]] || others+=("  ${e%%:*}  (nvidia: ${e#*:})"); done
  if (( ${#others[@]} )); then
    finding INFO "ライブラリ (${USER_VER:-?}) に合う nvidia モジュールがない他のカーネルが ${#others[@]} 個" "$(printf '%s\n' "${others[@]}")
GRUB の詳細メニューでこれらを選んで起動すると GPU が使えない。普段使わないなら問題ない。"
  fi

  if [[ -n $DKMS_PKG && ! -e /lib/modules/$KREL/build ]]; then
    finding WARN "実行中カーネルのヘッダ (linux-headers-$KREL) がない" "DKMS でモジュールをビルドし直せない。
→ sudo apt install linux-headers-$KREL"
  fi
}

check_dkms() {
  sec "DKMS"
  if ! have dkms; then
    note "(dkms コマンドなし)"
    [[ -n $DKMS_PKG ]] && finding WARN "$DKMS_PKG は入っているのに dkms コマンドがない" "→ sudo apt install --reinstall dkms $DKMS_PKG"
    return 0
  fi
  note "\$ dkms status" "$DKMS_STATUS" ""
  run "${SUDO:+$SUDO }tail -n 4000 /var/log/apt/term.log 2>/dev/null | grep -nE 'Error!|Bad return status|Building module.*failed|dkms.*(failed|error)|ERROR \\(dkms' | tail -n 30"
  [[ -n $DKMS_PKG ]] || return 0

  local nv; nv=$(grep -E '^nvidia[/,]' <<<"$DKMS_STATUS")
  if ! grep -F ", $KREL," <<<"$nv" | grep -q ': installed'; then
    if [[ -n $DISK_VER && $DKMS_MODULE == 0 ]]; then
      finding INFO "DKMS では実行中カーネル用にビルドされていない (ビルド済みモジュールを使用中)" "$DISK_FILE"
    else
      local hdr=""
      [[ -e /lib/modules/$KREL/build ]] || hdr=$'\n'"実行中カーネルのヘッダ (linux-headers-$KREL) がないためビルドできない。"
      finding FAIL "DKMS: 実行中カーネル ($KREL) 用の nvidia モジュールがビルドされていない" "${nv:-(dkms status に nvidia がない)}$hdr
$(module_fix_hint "$KREL")"
    fi
  fi
  if [[ -n $MAKELOG ]]; then
    note "最新の DKMS ビルドログ: $MAKELOG ($(date -r "$MAKELOG" '+%F %T' 2>/dev/null))"
    run "${SUDO:+$SUDO }tail -n 60 '$MAKELOG'"
  fi
  local odd; odd=$(grep -vE ': installed$' <<<"$nv" | grep .)
  [[ -n $odd ]] && finding WARN "DKMS: 完了していないエントリがある" "$odd
built は「ビルドしたが組み込んでいない」、WARNING 付きは組み込み済みのものと食い違っている状態。"
  return 0
}

check_secureboot() {
  sec "Secure Boot"
  note "状態: ${SB_STATE:-不明}" "DKMS 署名鍵: $MOK_CERT ($MOK_STATE)" "モジュール: ${DISK_FILE:-なし}" "モジュール署名者: ${DISK_SIGNER:-なし}" ""
  if [[ $SB_ON == 1 ]] && have mokutil; then
    run "${SUDO:+$SUDO }mokutil --list-enrolled 2>&1 | grep -E 'Subject:|SHA1 Fingerprint|^\\[key'" 40
    run "${SUDO:+$SUDO }mokutil --list-new 2>&1 | head -n 20"
  fi
  [[ -n $NV_GPUS ]] || return 0
  case $SB_ON in
    0) finding INFO "Secure Boot: 無効 (モジュール署名の問題は起きない)"; return 0 ;;
    1) ;;
    *) finding INFO "Secure Boot の状態を判定できない" "→ mokutil --sb-state で確認"; return 0 ;;
  esac

  case $SB_ISSUE in
    rejected)
      local how="→ sudo mokutil --test-key $MOK_CERT で鍵の登録状況を確認
→ 未登録なら"
      [[ $MOK_STATE == not-enrolled ]] && how="DKMS の署名鍵 ($MOK_CERT) は MOK に未登録 (確認済み)。
→"
      [[ $MOK_STATE == pending ]] && how="DKMS の署名鍵は登録待ち。次の再起動で青い MOK Manager 画面が出たら Enroll MOK を選ぶ。
→ 画面が出なかった・見逃したなら"
      finding FAIL "Secure Boot: カーネルが nvidia モジュールの署名を拒否" "$SIG_REJECT_LINES
$how sudo mokutil --import $MOK_CERT (一時パスワードを決める) → 再起動 → 青い MOK Manager 画面で Enroll MOK → Continue → Yes → パスワード → Reboot" ;;
    unsigned)
      finding FAIL "Secure Boot が有効なのに nvidia モジュールが未署名" "$DISK_FILE には署名がなく、このままでは読み込めない。
→ 署名鍵がなければ sudo update-secureboot-policy --new-key
→ sudo dpkg-reconfigure ${DKMS_PKG:-nvidia-dkms-<番号>}   (再ビルドと署名)
→ sudo update-secureboot-policy --enroll-key → 再起動 → MOK Manager で Enroll MOK" ;;
    not-enrolled)
      finding FAIL "Secure Boot: DKMS の署名鍵が MOK に未登録" "設定上の DKMS 署名鍵 $MOK_CERT は未登録。独自の鍵で署名している場合は、実際の署名者との対応も確認する。
→ sudo mokutil --import $MOK_CERT   (一時パスワードを決めて入力)
→ 再起動 → 青い MOK Manager 画面で Enroll MOK → Continue → Yes → パスワード → Reboot" ;;
    no-key)
      finding FAIL "Secure Boot: DKMS 用の署名鍵がない" "$MOK_CERT がない。
→ sudo update-secureboot-policy --new-key → sudo dpkg-reconfigure ${DKMS_PKG:-nvidia-dkms-<番号>}
→ sudo update-secureboot-policy --enroll-key → 再起動 → MOK Manager で Enroll MOK" ;;
    pending)
      finding WARN "Secure Boot: MOK の登録待ち" "次の再起動で青い MOK Manager 画面が出る。Enroll MOK → Continue → Yes → mokutil --import で決めたパスワード → Reboot。
数秒で自動的に閉じ、閉じると登録されないので、画面が出たらすぐキーを押す。" ;;
    *)
      if (( DKMS_MODULE )); then
        if [[ $MOK_STATE == enrolled ]]; then
          finding OK "Secure Boot: 有効、設定上の DKMS 署名鍵は登録済み"
        elif (( MOD_LOADED )) && [[ $LOADED_VER == "$DISK_VER" ]]; then
          finding OK "Secure Boot: 有効、現在のモジュールは問題なく読み込めている"
        else
          finding INFO "Secure Boot: 有効、DKMS の署名鍵の登録状況は未確認" "確認結果: $MOK_STATE。実際のモジュール署名者と設定上の証明書の対応は未確認。
→ 必要なら --sudo を付けて実行すると確認できる (未登録や鍵の欠落だけでは、実際の読み込み拒否の原因とは断定できない)"
        fi
      elif [[ -n $DISK_VER ]]; then
        finding INFO "Secure Boot: 有効、ディスク上のモジュールに署名あり" "署名者: $DISK_SIGNER。署名の存在だけでは、このマシンで信頼される鍵かは判断できない。"
      fi ;;
  esac
}

check_blockers() {
  sec "モジュールの読み込みを妨げる設定"
  note "/proc/cmdline: $CMDLINE" "prime-select: ${PRIME_MODE:-(なし)}" "nvidia_drm modeset: ${MODESET:-(未読み込み)}" ""
  run "grep -rHnE 'nvidia|nouveau' /etc/modprobe.d /usr/lib/modprobe.d /run/modprobe.d 2>/dev/null"
  run "lsmod | grep -E '^(nvidia|nouveau|i915|xe|amdgpu|simpledrm)'"
  [[ -n $NV_GPUS ]] || return 0

  [[ -n $BLACKLIST_HITS ]] && finding FAIL "nvidia モジュールがブラックリストされている" "$BLACKLIST_HITS
→ 該当行を削除 (またはコメントアウト) し、sudo update-initramfs -u して再起動
→ prime-select が書いたもの (blacklist-nvidia.conf) なら sudo prime-select nvidia (または on-demand)"
  [[ -n $CMDLINE_BL ]] && finding FAIL "カーネル起動オプションで nvidia が無効化されている" "$CMDLINE_BL
→ /etc/default/grub の GRUB_CMDLINE_LINUX_DEFAULT から外し、sudo update-grub して再起動"
  if (( NOUVEAU_LOADED )) && [[ -n $DRV_PKG ]]; then
    finding FAIL "nouveau (オープンソースドライバ) が読み込まれている" "NVIDIA ドライバが入っているのに nouveau が GPU を掴んでいる。
→ modprobe.d に blacklist nouveau があるか確認し (上の生データ)、sudo update-initramfs -u して再起動"
  fi
  (( NOMODESET )) && finding WARN "カーネル起動オプションに nomodeset がある" "インストール時のセーフモード設定が残っている可能性。画面のモード設定や Wayland に影響する。
→ /etc/default/grub の GRUB_CMDLINE_LINUX_DEFAULT から nomodeset を外し、sudo update-grub"
  [[ $PRIME_MODE == intel ]] && finding WARN "prime-select が intel (NVIDIA を使わない設定)" "→ sudo prime-select nvidia (または on-demand) して再起動"
  if [[ $SESSION_TYPE == wayland && $MODESET == N ]]; then
    finding WARN "Wayland セッションなのに nvidia-drm の modeset が無効" "→ カーネル起動オプションに nvidia-drm.modeset=1 を追加して sudo update-grub"
  fi
  return 0
}

check_kernel_log() {
  sec "カーネルログ (今回の起動、NVIDIA 関連)"
  if [[ -z $KLOG_SRC ]]; then
    note "(読めなかった)"
    finding INFO "カーネルログを読めない" "→ adm グループに入っているユーザーで実行するか、--sudo を付けて実行"
  else
    note "取得元: $KLOG_SRC"
    printf '%s\n' "$NVLOG" | headtail 60 160 >>"$RAW"
    local l
    if [[ $CORE_STATE != reboot && $CORE_STATE != mismatch ]]; then
      l=$(grep -m3 'API mismatch' <<<"$NVLOG")
      [[ -n $l ]] && finding FAIL "カーネルログ: API mismatch" "$l
ライブラリとカーネルモジュールのバージョンが一致していない。"
    fi
    l=$(grep -m3 -E 'RmInitAdapter failed|rm_init_adapter failed' <<<"$NVLOG")
    [[ -n $l ]] && finding FAIL "カーネルログ: GPU の初期化に失敗 (RmInitAdapter failed)" "$l
GSP ファームウェアの欠落、補助電源、PCIe、ドライバと GPU の相性などで起きる。直前の NVRM 行が手がかり。"
    l=$(grep -m3 -i 'fallen off the bus' <<<"$NVLOG")
    [[ -n $l ]] && finding FAIL "カーネルログ: GPU がバスから脱落 (fallen off the bus)" "$l
ハードウェア寄りの障害 (電源、発熱、PCIe の接続、省電力設定)。ドライバの入れ直しでは直らないことが多い。"
    l=$(grep -oE 'Xid \([^)]*\): [0-9]+' <<<"$NVLOG" | grep -oE '[0-9]+$' | sort -n | uniq -c | awk '{ printf "Xid %s ×%s  ", $2, $1 }')
    [[ -n $l ]] && finding WARN "カーネルログ: Xid エラー" "$l
Xid はドライバが検出した GPU エラー。79 = バス脱落、119/120 = GSP の応答なし、
13/31/43 = アプリ側起因が多い、48/63/64/94/95 = メモリ (ECC) 関連。"
    l=$(grep -E 'Unknown symbol|disagrees about version of symbol|Invalid module format' <<<"$KLOG" | grep -i nv | head -n3)
    [[ -n $l ]] && finding FAIL "カーネルログ: モジュールとカーネルの不整合" "$l
別のカーネル向けにビルドされたモジュールを読み込もうとしている。
$(module_fix_hint "$KREL")"
    l=$(grep -iE 'NVRM.*(firmware|gsp).*(fail|error|not found)|firmware: failed to load nvidia|Direct firmware load for nvidia.*failed' <<<"$KLOG" | head -n3)
    [[ -n $l ]] && finding FAIL "カーネルログ: GPU ファームウェアの読み込みに失敗" "$l
→ 下の GSP ファームウェアの項目を確認"
    l=$(grep -E '\[drm[^]]*\] \*ERROR\*.*nvidia|nvidia-drm.*(fail|error)' <<<"$NVLOG" | head -n3)
    [[ -n $l ]] && finding WARN "カーネルログ: nvidia-drm のエラー" "$l"
  fi
  sec "システムジャーナル (今回の起動、warning 以上で NVIDIA 関連)"
  printf '%s\n' "$JLOG_WARN" | tail -n 120 >>"$RAW"
  sec "カーネルログ (前回の起動、NVIDIA 関連の末尾)"
  run "${SUDO:+$SUDO }journalctl -k -b -1 -q --no-pager -o short-monotonic 2>/dev/null | grep -iE 'nvidia|NVRM|nouveau|Xid|Key was rejected|Lockdown' | tail -n 80"
  run "journalctl --list-boots --no-pager 2>/dev/null | tail -n 5"
  return 0
}

check_firmware() {
  sec "GSP ファームウェア"
  run "ls -la /lib/firmware/nvidia/ 2>&1"
  local v=${DISK_VER:-$LOADED_VER}
  [[ -n $NV_GPUS && -n $v && -d /lib/firmware/nvidia ]] || return 0
  [[ -z $USER_VER || $v == "$USER_VER" ]] || return 0   # 版がずれているときは上の不一致の対処が先
  if [[ -d /lib/firmware/nvidia/$v ]]; then
    run "ls /lib/firmware/nvidia/$v"
  else
    finding WARN "ドライバ $v 用の GSP ファームウェアがない" "/lib/firmware/nvidia/$v がない。Turing 以降の GPU では初期化に失敗することがある (カーネルログに RmInitAdapter failed)。
→ sudo apt install nvidia-firmware-${DRV_BRANCH:-<番号>}-$v   (名前は apt-cache search nvidia-firmware で確認)"
  fi
}

check_userspace() {
  local f v
  sec "ユーザー空間ライブラリ"
  for v in "${!LIB_VERS[@]}"; do note "バージョン $v のライブラリ: ${LIB_VERS[$v]} 個"; done
  run "ls -l /usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.0 /usr/lib/x86_64-linux-gnu/libEGL_nvidia.so.0 /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 /usr/lib/x86_64-linux-gnu/libcuda.so.1 2>&1"
  run "ls -l /usr/share/vulkan/icd.d/ /etc/vulkan/icd.d/ /usr/share/glvnd/egl_vendor.d/ 2>&1"
  run "cat /usr/share/vulkan/icd.d/nvidia_icd.json /etc/vulkan/icd.d/nvidia_icd.json 2>/dev/null"
  [[ -n $NV_GPUS && ( -n $DRV_PKG || -n $USER_VER ) ]] || return 0

  if (( ${#LIB_VERS[@]} > 1 )); then
    finding WARN "版の違う NVIDIA ライブラリが混在 (${!LIB_VERS[*]})" "パッケージの部分的な更新か、.run インストーラの残骸の可能性。
→ dpkg -S <ファイル> で持ち主を確認。どのパッケージにも属さないファイルは .run 版の残骸"
  fi
  local glpkg="libnvidia-gl-${DRV_BRANCH:-<番号>}"; [[ $DRV_VARIANT == -server* ]] && glpkg+=-server
  if [[ ! -e /usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.0 ]]; then
    finding FAIL "OpenGL 用ライブラリ (libGLX_nvidia) がない" "描画用のライブラリが未導入か、リンクが壊れている可能性。
→ sudo apt install $glpkg"
  fi
  local icd=""
  for f in /usr/share/vulkan/icd.d/nvidia_icd.json /etc/vulkan/icd.d/nvidia_icd.json; do [[ -e $f ]] && icd=$f; done
  [[ -z $icd ]] && finding WARN "Vulkan ICD (nvidia_icd.json) がない" "Vulkan と、それを使う WebGPU などが NVIDIA で動かない。
→ sudo apt install --reinstall $glpkg"
  if [[ -e /usr/bin/nvidia-uninstall ]] && ! dpkg -S /usr/bin/nvidia-uninstall >/dev/null 2>&1; then
    finding WARN "NVIDIA 公式 .run インストーラで入れたドライバの痕跡がある" "/usr/bin/nvidia-uninstall がパッケージ管理外。apt 版と混在すると更新のたびに壊れやすい。
→ sudo nvidia-uninstall で .run 版を外し、apt 版を入れ直す"
  fi

  sec "nvidia-smi"
  if have nvidia-smi; then
    run "nvidia-smi" 60
    local out rc
    out=$(timeout 20 nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>&1); rc=$?
    if (( rc == 0 )); then
      finding OK "nvidia-smi: 正常 (${out//$'\n'/; })"
      run "nvidia-smi -q" 150
    elif [[ $out == *mismatch* ]]; then
      [[ $CORE_STATE == reboot || $CORE_STATE == mismatch ]] || finding FAIL "nvidia-smi: Driver/library version mismatch" "$out"
    elif [[ $CORE_STATE != notloaded ]]; then
      finding FAIL "nvidia-smi が失敗" "$out"
    fi
  else
    note "(nvidia-smi なし)"
  fi

  sec "OpenGL / Vulkan の実地確認"
  note "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-} XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-} DISPLAY=${DISPLAY:-} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}" ""
  local missing=()
  if (( HAS_DISPLAY )); then
    if have glxinfo; then
      local g vendor renderer
      g=$(timeout 20 glxinfo -B 2>&1)
      note "\$ glxinfo -B" "$g" ""
      vendor=$(sed -n 's/^OpenGL vendor string: //p' <<<"$g")
      renderer=$(sed -n 's/^OpenGL renderer string: //p' <<<"$g")
      if [[ $vendor == *NVIDIA* ]]; then
        finding OK "OpenGL: NVIDIA で描画 ($renderer)"
      elif [[ $renderer == *llvmpipe* || $renderer == *softpipe* ]]; then
        finding FAIL "OpenGL がソフトウェア描画 ($renderer)" "ブラウザを含むアプリの 3D 描画が CPU で行われている。原因はたいてい上の FAIL 項目。"
      elif [[ -n $renderer ]]; then
        finding INFO "OpenGL は NVIDIA 以外で描画 ($renderer)" "PRIME (on-demand) 構成なら正常。NVIDIA だけの構成なら異常。"
      else
        finding WARN "glxinfo が OpenGL コンテキストを作れない" "$(head -n3 <<<"$g")"
      fi
    else
      missing+=(mesa-utils)
    fi
  else
    finding INFO "画面のないセッション (ssh など) で実行したため OpenGL の確認を省略" "→ デスクトップのターミナルから実行すると確認できる"
  fi
  if have vulkaninfo; then
    local vk; vk=$(timeout 20 vulkaninfo --summary 2>&1)
    note "\$ vulkaninfo --summary" "$(headtail 80 0 <<<"$vk")" ""
    if grep -qE 'deviceName *= .*(NVIDIA|GeForce|RTX|Quadro)' <<<"$vk"; then
      finding OK "Vulkan: NVIDIA のデバイスが見える"
    elif grep -q deviceName <<<"$vk"; then
      finding FAIL "Vulkan に NVIDIA のデバイスがない" "$(grep deviceName <<<"$vk")
Vulkan と、それを使う WebGPU などが NVIDIA を使えない。"
    else
      finding WARN "vulkaninfo が失敗" "$(grep -m3 -iE 'error|fail' <<<"$vk")"
    fi
  else
    missing+=(vulkan-tools)
  fi
  (( ${#missing[@]} )) && finding INFO "${missing[*]} がないため一部の実地確認を省略" "→ sudo apt install ${missing[*]} を入れておくと、次回から OpenGL / Vulkan が実際に NVIDIA で動くかまで確認できる"

  local xl; xl=$(ls -t "$HOME"/.local/share/xorg/Xorg.*.log /var/log/Xorg.*.log 2>/dev/null | head -n1)
  if [[ -n $xl ]]; then
    sec "Xorg ログのエラー ($xl)"
    run "grep -nE '\\(EE\\)' '$xl' | tail -n 40"
    if [[ $SESSION_TYPE == x11 ]] && grep -qE '\(EE\).*NVIDIA|NVIDIA.*\(EE\)' "$xl" 2>/dev/null; then
      finding WARN "Xorg ログに NVIDIA のエラー" "$(grep -m3 -E '\(EE\).*NVIDIA|NVIDIA.*\(EE\)' "$xl")"
    fi
  fi
  return 0
}

check_packages() {
  sec "NVIDIA 関連パッケージ (dpkg)"
  note "$(awk -F'\t' '{ printf "%s %-48s %s\n", $1, $2, $3 }' <<<"$PKG_NV")" ""
  run "apt-mark showhold 2>/dev/null"
  run "dpkg --audit 2>&1 | head -n 30"
  run "ubuntu-drivers list 2>/dev/null" 30
  [[ -n $NV_GPUS ]] || return 0

  [[ -n $PKG_BROKEN ]] && finding FAIL "インストールや設定が途中で止まっているパッケージがある" "$(awk -F'\t' '{ print $1 " " $2 " " $3 }' <<<"$PKG_BROKEN")
→ sudo dpkg --configure -a、続けて sudo apt -f install。そこで出るエラーが手がかり (DKMS のビルド失敗が多い)"
  [[ -n $PKG_HELD ]] && finding WARN "更新が保留 (hold) されているパッケージがある" "$PKG_HELD
一部だけ更新されずにバージョンがずれる原因になる。意図した hold でなければ sudo apt-mark unhold <パッケージ>"
  if (( $(nlines "$PKG_CORE_DISTINCT") > 1 )); then
    finding WARN "NVIDIA ドライバのパッケージのバージョンが揃っていない" "$(sort <<<"$PKG_CORE_VERS" | awk -F'\t' '
      $1 != v { if (v != "") print v ": " l; v = $1; l = $2; next } { l = l ", " $2 } END { print v ": " l }' | fold -s -w 110 | sed 's/ *$//')
更新が途中で止まったか、一部だけ別の版が入っている (Ubuntu の段階的リリース (phased updates) で一部が後回しにされることもある)。
→ sudo apt update && sudo apt full-upgrade で揃える (揃わなければ apt-cache policy <パッケージ> で候補を確認)"
  fi
  if (( $(nlines "$BRANCHES") > 1 )); then
    finding WARN "複数のドライバブランチのパッケージが混在 ($(tr '\n' ' ' <<<"$BRANCHES"))" "古いブランチのパッケージが残っている。使っていない側は整理の候補。"
  fi
  if [[ $DRV_PKG == nvidia-headless* ]]; then
    finding WARN "画面出力用ではない headless ドライバ ($DRV_PKG)" "OpenGL / Vulkan のライブラリが含まれない。デスクトップ用途なら nvidia-driver-$DRV_BRANCH を入れる。"
  fi
  if [[ -n $PREBUILT_KREL && -n $DRV_BRANCH ]] && (( ! DKMS_MODULE )); then
    local pb; pb=$(sed -E 's/^linux-modules-nvidia-([0-9]+).*/\1/' <<<"$PREBUILT_KREL" | head -n1)
    [[ $pb != "$DRV_BRANCH" ]] && finding WARN "実行中カーネル用のビルド済みモジュールのブランチ ($pb) がドライバ ($DRV_BRANCH) と違う" "$PREBUILT_KREL
→ sudo apt install linux-modules-nvidia-${DRV_BRANCH}${DRV_VARIANT}-$KREL"
  fi
  local left; left=$(awk -F'\t' -v b="$DRV_BRANCH" '$1 ~ /^linux-(modules|objects|signatures)-nvidia-/ { split($1, a, "-"); if (a[4] != b) n++ } END { print n + 0 }' <<<"$PKG_NV_INST")
  (( left > 0 )) && [[ -n $DRV_BRANCH ]] && finding INFO "旧ブランチ用のビルド済みモジュールのパッケージが $left 個残っている" "現在のドライバ ($DRV_BRANCH) では使われず、不調の直接の原因ではない。整理は急がなくてよい。"
  return 0
}

# apt の履歴から NVIDIA / カーネル関連の操作を「開始日時<TAB>-<TAB>内容」で古い順に出す
# (引数でファイルを渡すと、そのファイルを読む)
# shellcheck disable=SC2120
apt_history_nv() {
  local files=() f
  if (( $# )); then
    files=("$@")
  else
    for f in /var/log/apt/history.log.2.gz /var/log/apt/history.log.1.gz /var/log/apt/history.log; do
      [[ -r $f ]] && files+=("$f")
    done
  fi
  (( ${#files[@]} )) || return 0
  zcat -f -- "${files[@]}" 2>/dev/null | awk '
    # "libnvidia-gl-595:amd64 (595.91.07-0ubuntu1, 595.99.02-0ubuntu1)" → "libnvidia-gl-595 595.91.07-0ubuntu1→595.99.02-0ubuntu1"
    function pick(s,   out, m, name, vers, n, v, cnt) {
      out = ""; cnt = 0
      while (match(s, /[^ ]*(nvidia|linux-(image|modules|headers|objects|signatures))[^ ]* [(][^)]*[)]/)) {
        m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        name = m; sub(/ [(].*/, "", name); sub(/:[a-z0-9]+$/, "", name)
        vers = m; sub(/^[^(]*[(]/, "", vers); sub(/[)]$/, "", vers)
        n = split(vers, v, ", ")
        if (n >= 2 && v[2] != "automatic") vers = v[1] "→" v[2]; else vers = v[1]
        if (++cnt <= 6) out = out (out == "" ? "" : ", ") name " " vers
      }
      if (cnt > 6) out = out sprintf(" ほか %d 件", cnt - 6)
      return out
    }
    /^Start-Date:/ { start = $2 " " $3; act = ""; next }
    /^(Install|Upgrade|Remove|Purge|Downgrade|Reinstall):/ {
      p = pick($0); if (p != "") act = act (act == "" ? "" : " / ") $1 " " p; next
    }
    /^End-Date:/ { if (act != "") print start "\t-\t" act }'
}

check_updates() {
  sec "再起動待ちと最近の更新"
  local pk="" rr=0 hist after body
  if [[ -e /run/reboot-required ]]; then
    rr=1; pk=$(sort -u /run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ')
    note "/run/reboot-required: あり (${pk:-対象不明})"
  else
    note "/run/reboot-required: なし"
  fi
  hist=$(apt_history_nv)
  note "起動時刻: $BOOT_TIME" "NVIDIA / カーネル関連の更新履歴 (新しい順に最大 10 件):"
  note "$(tail -n 10 <<<"$hist" | tac | awk -F'\t' '{ print $1 "  " $3 }')" ""
  after=$(awk -F'\t' -v b="$BOOT_TIME" '$1 > b' <<<"$hist")
  (( rr )) || [[ -n $after ]] || return 0

  body="起動: $BOOT_TIME"
  (( rr )) && body+=$'\n'"OS が再起動を求めている (/run/reboot-required、対象: ${pk:-不明})"
  [[ -n $after ]] && body+=$'\n'"起動後の NVIDIA / カーネル関連の更新:"$'\n'"$(tail -n 5 <<<"$after" | awk -F'\t' '{ print "  " $1 "  " $3 }')"
  if [[ $CORE_STATE == reboot ]]; then
    finding INFO "起動後にドライバ / カーネルが更新されている (上の再起動待ちの原因)" "$body
自動更新 (unattended-upgrades) で入ったものも含む。"
  elif (( NEXT_BAD )); then
    finding WARN "再起動待ちの更新がある" "$body
→ 上の「次回起動予定のカーネル」の問題を片付けてから再起動する。そのまま再起動すると GPU が使えなくなる"
  else
    finding WARN "再起動待ちの更新がある" "$body
更新されたドライバやカーネルは再起動するまで反映されない。今は動いていても、ライブラリだけ先に新しくなって不調が出ることがある。
→ 都合のよいときに再起動"
  fi
}

check_services() {
  sec "systemd"
  run "systemctl --failed --no-legend --plain --no-pager 2>&1"
  run "systemctl status nvidia-persistenced --no-pager -n 5 2>&1 | head -n 15"
  local failed; failed=$(systemctl --failed --no-legend --plain --no-pager 2>/dev/null | grep -i nvidia | awk '{ print $1 }')
  [[ -n $failed ]] && finding WARN "失敗している NVIDIA 関連サービスがある" "$failed
→ systemctl status <サービス名> と journalctl -b -u <サービス名> で理由を確認"
  return 0
}

chrome_local_state() {
python3 - "$1" <<'PY' 2>&1
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fp:
        d = json.load(fp)
except Exception as e:
    print("読めない:", e)
    sys.exit()
hw = d.get("hardware_acceleration_mode", {}).get("enabled")
print("hardware_acceleration_mode.enabled =", "未設定(有効)" if hw is None else hw)
for f in d.get("browser", {}).get("enabled_labs_experiments", []):
    print("flag:", f)
PY
}

check_chrome() {
  local dirs=() d procs
  for d in "$HOME/.config/google-chrome" "$HOME/.config/google-chrome-beta" "$HOME/.config/google-chrome-unstable" \
           "$HOME/.config/chromium" "$HOME/snap/chromium/common/chromium"; do
    [[ -d $d ]] && dirs+=("$d")
  done
  procs=$(ps -eo args= 2>/dev/null | grep -E '^[^ ]*/(chrome|chromium|google-chrome[^ /]*)( |$)')
  (( ${#dirs[@]} )) || [[ -n $procs ]] || return 0

  sec "Chrome / Chromium"
  have google-chrome && run "google-chrome --version"
  local out fl
  if have python3; then
    for d in "${dirs[@]}"; do
      [[ -r "$d/Local State" ]] || continue
      out=$(chrome_local_state "$d/Local State")
      note "[$d]" "$out" ""
      grep -q 'enabled = False' <<<"$out" &&
        finding WARN "Chrome のハードウェアアクセラレーションが OFF (${d#"$HOME"/})" "→ 設定 > システム >「グラフィック アクセラレーションが使用可能な場合は使用する」を ON にして Chrome を再起動"
      fl=$(grep '^flag:' <<<"$out" | grep -iE 'gpu|angle|vulkan|ozone|webgpu|raster|graphite|skia' | sed 's/^flag: //')
      [[ -n $fl ]] && finding INFO "Chrome で GPU 関連のフラグが変更されている (${d#"$HOME"/})" "$fl
切り分けるなら chrome://flags で Reset all"
    done
  fi

  local ex; ex=$(grep -hE '^Exec=' /usr/share/applications/google-chrome*.desktop "$HOME"/.local/share/applications/*chrom*.desktop 2>/dev/null |
    grep -oE -- '--(disable-gpu|use-gl=|use-angle=|ozone-platform)[^ ]*' | sort -u)
  note "ランチャー (.desktop) の GPU 関連オプション:" "${ex:-(なし)}" ""
  [[ $ex == *--disable-gpu* ]] && finding WARN "Chrome のランチャーに --disable-gpu が付いている" "$ex"

  if [[ -n $procs ]]; then
    local browser gpu
    browser=$(grep -v -- '--type=' <<<"$procs" | head -n3)
    gpu=$(grep -- '--type=gpu-process' <<<"$procs" | head -n1)
    note "起動中のブラウザプロセスの GPU 関連オプション:"
    note "$(grep -oE -- '--(disable-gpu[^ ]*|use-gl=[^ ]*|use-angle=[^ ]*|ozone-platform[^ ]*|ignore-gpu-blocklist|disable-software-rasterizer)' <<<"$browser" | sort -u)"
    note "GPU プロセスのオプション (抜粋):"
    note "$(grep -oE -- '--(use-gl|use-angle|disable-gpu[^ =]*|use-vulkan)(=[^ ]*)?' <<<"$gpu" | sort -u)" ""
    grep -qE -- '--disable-gpu( |$)' <<<"$browser" &&
      finding WARN "Chrome が --disable-gpu 付きで起動されている" "ランチャーやエイリアス、起動スクリプトに残っていないか確認"
    if grep -qiE -- 'swiftshader|use-gl=disabled|disable-gpu-compositing' <<<"$gpu"; then
      if [[ $CORE_STATE == ok ]]; then
        finding WARN "Chrome が GPU を使わずに動いている (GPU プロセスのオプションからの推定)" "OS 側の NVIDIA ドライバは正常。Chrome が過去の GPU プロセスのクラッシュで GPU を無効にしたままの可能性。
→ Chrome を完全に終了して起動し直す
→ 直らなければ Chrome を終了した状態で GPU のキャッシュ (~/.config/google-chrome/GrShaderCache、~/.config/google-chrome/GraphiteDawnCache、~/.config/google-chrome/Default/GPUCache) を削除して起動
→ それでも直らなければ chrome://gpu の Problems Detected と Log Messages を --attach で添付"
      else
        finding INFO "Chrome は GPU を使わずに動いている (推定)" "OS 側の問題の結果。OS 側が直ったら Chrome を完全に終了して起動し直す。"
      fi
    fi
  fi
  return 0
}

collect_raw_system() {
  sec "システム"
  note "nvidia-ubuntu-report / $NOW / 実行ユーザー: $(id -un) (EUID $EUID)${SUDO:+ / --sudo 使用}"
  run "grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release"
  run "uname -a"
  run "uptime"
  note "起動時刻: $BOOT_TIME"
  run "cat /proc/cmdline"
  run "cat /proc/sys/kernel/tainted"
  sec "GPU (lspci)"
  run "lspci -nnk | grep -A4 -E 'VGA|3D controller|Display controller'"
  sec "カーネルモジュール"
  run "lsmod | grep -E '^(nvidia|nouveau)'"
  run "cat /proc/driver/nvidia/version"
  run "modinfo nvidia | grep -E '^(filename|version|license|signer|sig_key|vermagic|srcversion):'"
  run "cat /sys/module/nvidia_drm/parameters/modeset /sys/module/nvidia_drm/parameters/fbdev"
  sec "ブート設定とカーネルパッケージ"
  run "grep -hE '^(GRUB_DEFAULT|GRUB_CMDLINE_LINUX_DEFAULT|GRUB_CMDLINE_LINUX)=' /etc/default/grub /etc/default/grub.d/*.cfg 2>/dev/null"
  run "grep -E '^(saved_entry|next_entry)=' /boot/grub/grubenv"
  run "dpkg-query -W -f='\${db:Status-Abbrev} \${Package} \${Version}\n' 'linux-image-*' 'linux-headers-*' 'linux-oem-*' 'linux-generic*' 2>/dev/null | grep -vE '^(un|pn)'"
  if (( EUID == 0 )); then
    finding INFO "root で実行された" "OpenGL や Chrome の確認はログイン中のユーザーの環境でないと正確でない。一般ユーザーで実行し、権限が要る確認は --sudo を使う。"
  fi
}

# ================================================================ 出力

render_summary() {   # $1 = color | plain
  local cF="" cW="" cI="" cO="" cB="" c0=""
  [[ $1 == color ]] && { cF=$C_FAIL cW=$C_WARN cI=$C_INFO cO=$C_OK cB=$C_B c0=$C_0; }
  local gpu; gpu=$(head -n1 <<<"$NV_GPUS" | sed -E 's/^[^ ]+ [^:]*: //')
  local sb; case $SB_ON in 1) sb=有効 ;; 0) sb=無効 ;; *) sb=不明 ;; esac
  local mod_src=""; (( DKMS_MODULE )) && mod_src=" (DKMS)"

  printf '%snvidia-ubuntu-report — %s%s\n' "$cB" "$NOW" "$c0"
  printf 'ホスト      %s (%s)\n' "$HOST" "${OS_NAME:-?}"
  printf 'カーネル    %s (起動 %s) / 次回起動(推定) %s\n' "$KREL" "$BOOT_TIME" "${NEXT_KERNEL:-不明}"
  printf 'GPU         %s\n' "${gpu:-NVIDIA GPU なし}"
  printf 'ドライバ    パッケージ %s / ライブラリ %s / モジュール ディスク上 %s%s・読み込み中 %s\n' \
    "${DRV_PKG:+$DRV_PKG }${PKG_VER:-なし}" "${USER_VER:-なし}" "${DISK_VER:-なし}" "$mod_src" "${LOADED_VER:-なし}${LOADED_KIND:+ ($LOADED_KIND)}"
  printf 'Secure Boot %s / セッション %s\n\n' "$sb" "${SESSION_TYPE:-不明}"

  local lv i tag col nF=0 nW=0 nI=0 nO=0
  for lv in FAIL WARN INFO OK; do
    case $lv in
      FAIL) tag='[FAIL]' col=$cF ;;
      WARN) tag='[WARN]' col=$cW ;;
      INFO) tag='[INFO]' col=$cI ;;
      OK)   tag='[ OK ]' col=$cO ;;
    esac
    for i in "${!F_LEVEL[@]}"; do
      [[ ${F_LEVEL[$i]} == "$lv" ]] || continue
      case $lv in FAIL) ((nF++)) ;; WARN) ((nW++)) ;; INFO) ((nI++)) ;; OK) ((nO++)) ;; esac
      printf '%s%s%s %s\n' "$col" "$tag" "$c0" "${F_TITLE[$i]}"
      [[ -n ${F_BODY[$i]} ]] && sed 's/^/       /' <<<"${F_BODY[$i]}"
    done
  done
  echo
  printf '%s判定: FAIL %d / WARN %d / INFO %d / OK %d%s\n' "$cB" "$nF" "$nW" "$nI" "$nO" "$c0"
  if (( nF == 0 && nW == 0 )); then
    echo "NVIDIA ドライバとカーネル周りに問題は見つからなかった。特定のアプリだけの不調なら、そのアプリ側 (chrome://gpu など) を確認する。"
  elif (( nF > 0 )); then
    echo "先頭の [FAIL] から順に対処する。"
  fi
}

re_escape() { printf '%s' "$1" | sed -e 's/[][\.*^$/+?(){}|]/\\&/g'; }

write_report() {
  if [[ -z $OUT ]]; then
    local name; name="nvidia-ubuntu-report-$(date +%Y%m%d-%H%M%S).txt"
    if [[ -w . ]]; then OUT="$PWD/$name"; else OUT="$HOME/$name"; fi
  fi
  local rep="$WORK/report.txt"
  {
    echo "# nvidia-ubuntu-report — Ubuntu の NVIDIA ドライバ / カーネル診断"
    echo "# 前半が自動判定、後半が生データ。判定で解決しないときは、このファイル全体をエージェントに渡して診断できる。"
    echo
    render_summary plain
    echo
    echo "================================================================ 生データ"
    cat "$RAW"
  } >"$rep"

  if (( REDACT )); then
    local args=() n
    for n in "$(hostname -f 2>/dev/null)" "$HOST"; do
      [[ -n $n && $n != unknown ]] && args+=(-e "s/\\b$(re_escape "$n")\\b/<host>/g")
    done
    for n in "$(id -un)" "${SUDO_USER:-}"; do
      [[ -n $n && $n != root ]] && args+=(-e "s/\\b$(re_escape "$n")\\b/<user>/g")
    done
    args+=(-e 's/GPU-[0-9a-fA-F-]{36}/GPU-<redacted>/g'
           -e 's/^( *(Serial Number|GPU UUID|Board Part Number|GPU Part Number|Module ID|GPU PDI)[^:]*: ).*/\1<redacted>/')
    sed -E -i "${args[@]}" "$rep"
  fi
  cp "$rep" "$OUT" || die "レポートを保存できない: $OUT"
}

# ================================================================ main

main() {
  parse_args "$@"
  setup
  echo "診断中…" >&2
  collect_facts
  collect_raw_system
  check_core
  check_kernels
  check_dkms
  check_secureboot
  check_blockers
  check_kernel_log
  check_firmware
  check_userspace
  check_packages
  check_updates
  check_services
  check_chrome

  local a
  for a in "${ATTACH[@]}"; do
    sec "添付: $a"
    if [[ -r $a ]]; then headtail 1500 0 <"$a" >>"$RAW"; else note "(読めない)"; fi
  done

  write_report
  render_summary color
  echo
  echo "レポート: $OUT"
  echo "(判定で解決しないときは、このファイルをエージェントに添付して診断を頼む)"

  local worst=0 l
  for l in "${F_LEVEL[@]}"; do
    if [[ $l == FAIL ]]; then worst=2; elif [[ $l == WARN ]] && (( worst < 2 )); then worst=1; fi
  done
  exit "$worst"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
