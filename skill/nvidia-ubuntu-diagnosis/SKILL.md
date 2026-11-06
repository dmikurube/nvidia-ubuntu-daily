---
name: "nvidia-ubuntu-diagnosis"
description: "Ubuntu の NVIDIA ドライバ/カーネル診断スクリプト dump-nvidia-ubuntu-diagnosis.sh のレポート (nvidia-ubuntu-report-*.txt) が添付・貼り付けされたとき、原因を特定して対処手順を示す。"
---

# nvidia-ubuntu-report の診断

ユーザーは自分の Ubuntu マシン (NVIDIA GPU、Chrome 利用) で `dump-nvidia-ubuntu-diagnosis.sh` を実行し、そのレポートを渡してくる。

このマシンはエージェントが直接操作できない。エージェントはレポートを読んで原因と手順を示し、コマンドはユーザーが自分で実行する。

やりとりの往復を減らすことが目的なので、できるだけ**一回の返答で結論と手順まで出す**ように努力する。

## レポートの構造

- 前半: 自動判定。概要 (カーネル、GPU、ドライバの各バージョン、Secure Boot、セッション) と `[FAIL]` `[WARN]` `[INFO]` `[ OK ]` の所見。
- 後半: `######## 見出し ########` ごとの生データ。`$ コマンド` の行に続いて出力がある。`[exit N]` は終了コード (grep の 1 は「一致なし」)。
  主な見出し: システム、GPU (lspci)、カーネルモジュール、ブート設定とカーネルパッケージ、インストール済みカーネルと nvidia モジュール、DKMS、Secure Boot、モジュールの読み込みを妨げる設定、カーネルログ (今回/前回の起動)、システムジャーナル、GSP ファームウェア、ユーザー空間ライブラリ、nvidia-smi、OpenGL / Vulkan の実地確認、Xorg ログ、NVIDIA 関連パッケージ、再起動待ちと最近の更新、systemd、Chrome / Chromium、添付: <ファイル> (chrome://gpu のコピーなど)。
- `--redact` 付きならホスト名は `<host>`、ユーザー名は `<user>`。

## 進め方

1. **自動判定を出発点にし、生データで裏を取る。** 判定は既知のパターンを機械的に当てたもの。生データと食い違えば生データを優先し、判定の誤りを指摘する。
2. 判定が `[FAIL]` を 1 つ出していて生データとも合うなら、それが答え。長い説明はせず、判定の内容を確認したことと手順を簡潔に示す。
3. 判定が `FAIL 0 / WARN 0` なのに症状がある、判定どうしが矛盾する、または判定が原因を絞れていない (「個別の確認では原因を特定できなかった」など) ときが、エージェントが深く読む場面。下の「層ごとの確認」に沿って生データを読む。
4. 複数の問題があれば、**因果の上流から**並べる (例: ライブラリだけ更新 → モジュール不一致 → OpenGL がソフトウェア描画 → Chrome の GPU 無効)。下流の症状は上流を直せば消えることを明記する。

## 層ごとの確認

NVIDIA ドライバは次の層がすべて**同じバージョン**でないと動かない。どこで食い違っているかを特定するのが診断の中心。

| 層 | レポート上の場所 |
|---|---|
| 読み込み中のカーネルモジュール | 概要の「読み込み中」、`/proc/driver/nvidia/version` |
| ディスク上のモジュール (次回起動で読まれる) | `modinfo nvidia` の version と filename、カーネルごとの一覧 |
| ユーザー空間ライブラリ | 「ユーザー空間ライブラリ」の版、`libGLX_nvidia.so.0` などのリンク先 |
| パッケージ | dpkg の一覧 (`nvidia-driver-NNN`、`libnvidia-gl-NNN`、`nvidia-dkms-NNN` など) |

- 読み込み中だけ古く、ディスク上とライブラリが新しい → 更新後の再起動待ち。`nvidia-smi` は `Driver/library version mismatch`、カーネルログに `NVRM: API mismatch`。対処は再起動のみ。
- ディスク上も古い → 新しいモジュールが用意されていない。DKMS のビルド失敗、`nvidia-dkms-NNN` の hold、段階的リリース (phased updates) による部分更新を疑う。
- モジュールが読み込まれていない → 実行中カーネル用の `nvidia.ko` がない、Secure Boot の署名拒否、ブラックリスト、nouveau が先に掴んでいる、のどれか。

### Ubuntu のパッケージ構成

- モジュールの供給元は 2 通り。`nvidia-dkms-NNN` (DKMS でビルド、`/lib/modules/<k>/updates/dkms/`) と、Canonical がビルド・署名した `linux-modules-nvidia-NNN-<k>` (`/lib/modules/<k>/kernel/nvidia-NNN*/`)。`-open` が付くのはオープンカーネルモジュール版。
- `linux-modules-nvidia-*` や `linux-objects-nvidia-*` の旧ブランチ分が大量に残っていても、それ自体は不調の原因ではない。
- `nvidia-headless-*` や `-server` 系だけでは OpenGL/Vulkan のライブラリ (`libnvidia-gl-NNN`) が入らない。
- `/usr/bin/nvidia-uninstall` がパッケージ管理外にあれば、NVIDIA 公式 .run インストーラの残骸。apt 版と混在すると更新のたびに壊れる。
- `nvidia-firmware-NNN-<ver>` は GSP ファームウェア (`/lib/firmware/nvidia/<ver>/`)。モジュールの版と同じディレクトリが要る。

### カーネルと GRUB

- 「インストール済みカーネルと nvidia モジュール」で、各カーネルにライブラリと同じ版のモジュールがあるかを見る。
- 次回起動カーネルは推定。`GRUB_DEFAULT=0` なら通常は版の最も新しいカーネル。`saved` や `grubenv` の `saved_entry` / `next_entry` があればそれに従う。
- 新しいカーネル (HWE や OEM の更新) で DKMS のビルドが失敗するのは典型的な更新起因の障害。`/var/log/apt/term.log` の `Bad return status for module build on kernel: <k>` と make.log の `error:` 行が証拠。ドライバが新しいカーネルに未対応なことが多く、対処は「動くカーネルで起動して対応版のドライバを待つ」。
- 実行中カーネルのヘッダ (`linux-headers-<k>`) がなければ DKMS はビルドできない。

### Secure Boot

- DKMS のモジュールは `/var/lib/shim-signed/mok/MOK.der` の鍵で署名される。この鍵がファームウェアの MOK に登録されていないと、`Loading of module with unavailable key is rejected` や `Key was rejected by service` で読み込みが拒否される。
- 登録は `sudo mokutil --import <MOK.der>` → 再起動 → 青い MOK Manager 画面で Enroll MOK。画面は数秒で閉じ、閉じると登録されない。
- `MOK_STATE` が `unreadable` なのは一般ユーザーで実行したため。判定に影響しないことが多いが、Secure Boot が疑わしいときは `--sudo` 付きでの再実行を頼む。
- Secure Boot を無効にする案は最後の手段としてのみ挙げる。

### カーネルログ

- `RmInitAdapter failed`: GPU の初期化失敗。GSP ファームウェアの欠落、補助電源、PCIe、ドライバとの相性。直前の NVRM 行を読む。
- `fallen off the bus` / Xid 79: ハードウェア寄り (電源、発熱、PCIe の接続、省電力設定)。ドライバの入れ直しでは直らないことが多い。
- Xid 119/120: GSP の応答なし。13/31/43: アプリ側が原因のことが多い。48/63/64/94/95: メモリ (ECC) 関連。
- `Unknown symbol` / `disagrees about version of symbol`: 別のカーネル向けのモジュール。
- 「前回の起動」のログは、再起動後に直った・壊れた場合の比較に使う。

### 描画とセッション

- `glxinfo -B` の renderer が `llvmpipe` ならソフトウェア描画。PRIME (on-demand) 構成で iGPU の名前が出るのは正常。
- `vulkaninfo` に NVIDIA のデバイスがなければ、Vulkan とそれを使う WebGPU が使えない。ICD (`nvidia_icd.json`) の欠落も確認する。
- Wayland セッションでは `nvidia_drm modeset` が `Y` である必要がある。
- `prime-select` が `intel` なら NVIDIA を使わない設定。`/lib/modprobe.d/blacklist-nvidia.conf` などのブラックリストも確認する。
- mesa-utils や vulkan-tools がなく実地確認が省略されていて、それが診断に必要なら、インストールして再実行するよう頼む。

### Chrome

- OS 側 (上の層) に問題があれば、Chrome の GPU 無効は単なる結果。OS 側を直した後に Chrome を完全終了して起動し直せばよい。
- OS 側が正常なのに Chrome だけ GPU が無効なら、ハードウェアアクセラレーションの設定、`chrome://flags` の変更、起動オプション (`--disable-gpu` など)、GPU プロセスの過去のクラッシュによる無効化、GPU キャッシュ (`GrShaderCache`、`GraphiteDawnCache`、`Default/GPUCache`) の破損を順に疑う。
- GPU プロセスのオプションからの判定は推定にすぎない。確証が要るときは chrome://gpu のレポート (ページ上部の「Copy Report to Clipboard」) をファイルに保存し、`--attach` で添付してもらう。

## 返答の形

ユーザーの言語 (通常は日本語) で、次の順に書く。見出しは短く、余計な前置きはしない。

1. **結論**: 原因を 1〜2 文で。確度が低ければそう書く。
2. **根拠**: レポートの該当行を短く引用する (どの見出しのどの行か分かるように)。
3. **対処**: 実行するコマンドを順番どおりにコードブロックで示す。各手順について、再起動が要るか、元に戻しにくいか (`apt purge`、`autoremove`、MOK の変更、GRUB 設定の変更など) を明記する。読み取りだけの確認を先に、変更を伴う操作を後にする。
4. **確認**: 対処後に `dump-nvidia-ubuntu-diagnosis.sh` を再実行し、どの項目が `[ OK ]` になれば解決か (例: 「nvidia モジュールとライブラリのバージョンが一致」「OpenGL: NVIDIA で描画」)。Chrome が絡むなら chrome://gpu の確認点も。
5. **追加で必要な情報** (原因を絞れないときだけ): 次に実行してほしいコマンドを最小限、まとめて 1 回で頼む。何を確かめるためのものかも一言添える。

## 避けること

- NVIDIA 公式 .run インストーラの利用は勧めない。
- 根拠なしに「ドライバを purge して入れ直す」を勧めない。まず層ごとの食い違いを特定する。
- 判定が既に正しく指摘している内容を長々と言い直さない。
- このスクリプトに足りない確認項目に気づいたら、最後に一行で「dump-nvidia-ubuntu-diagnosis.sh に追加するとよい確認」として挙げる (スクリプトの改善につなげるため)。
