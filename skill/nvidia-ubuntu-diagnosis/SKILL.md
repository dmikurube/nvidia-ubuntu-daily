---
name: "nvidia-ubuntu-diagnosis"
description: "Ubuntu の NVIDIA ドライバ/カーネル診断スクリプト dump-nvidia-ubuntu-diagnosis.sh のレポート (nvidia-ubuntu-report-*.txt) が添付・貼り付けされたとき、原因を特定して対処手順を示す。"
---

# nvidia-ubuntu-report の診断

ユーザーは自分の Ubuntu マシン (NVIDIA GPU、Chrome 利用) で `dump-nvidia-ubuntu-diagnosis.sh` を実行し、そのレポートを渡してくる。

対象は複数の Ubuntu 24.04 LTS、X11 の GNOME、NVIDIA GPU のマシン。GPU の型番・世代、ドライバのブランチ・版・供給元、カーネルの種類・版、Secure Boot の状態は固定しない。レポートに記録された実行時の情報を使う。特定の版を「最新」と仮定せず、対応 GPU と Ubuntu のパッケージ候補を必要に応じて確認する。

このマシンはエージェントが直接操作できない。エージェントはレポートを読んで原因と手順を示し、コマンドはユーザーが自分で実行する。

やりとりの往復を減らすことが目的なので、できるだけ**一回の返答で結論と手順まで出す**ように努力する。

## レポートの構造

- 前半: 自動判定。概要 (カーネル、GPU、ドライバの各バージョン、Secure Boot、セッション) と `[FAIL]` `[WARN]` `[INFO]` `[ OK ]` の所見。
- 後半: `######## 見出し ########` ごとの生データ。`$ コマンド` の行に続いて出力がある。`[exit N]` は終了コード (grep の 1 は「一致なし」)。
  主な見出し: システム、診断ツールの有無、GPU (lspci)、カーネルモジュール、ブート設定とカーネルパッケージ、インストール済みカーネルと nvidia モジュール、DKMS、Secure Boot、モジュールの読み込みを妨げる設定、カーネルログ (今回/前回の起動)、システムジャーナル、GSP ファームウェア、ユーザー空間ライブラリ、nvidia-smi、OpenGL / Vulkan の実地確認、Xorg ログ、NVIDIA 関連パッケージ、再起動待ちと最近の更新、systemd、Chrome / Chromium、添付: <ファイル> (chrome://gpu のコピーなど)。
- `--redact` 付きならホスト名は `<host>`、ユーザー名は `<user>`。

## 進め方

1. 「診断ツールの有無」で確認できた範囲を把握する。ツールがないことと GPU の故障を区別し、構成上不要なツールの導入は求めない。コマンドが存在しても権限不足や実行失敗はあり得るため、各節の実際の出力も確認する。
2. **自動判定を出発点にし、生データで裏を取る。** 判定は既知のパターンを機械的に当てたもの。生データと食い違えば生データを優先し、判定の誤りを指摘する。
3. 判定が `[FAIL]` を 1 つ出していて生データとも合うなら、それが答え。長い説明はせず、判定の内容を確認したことと手順を簡潔に示す。
4. 判定が `FAIL 0 / WARN 0` なのに症状がある、判定どうしが矛盾する、または判定が原因を絞れていない (「個別の確認では原因を特定できなかった」など) ときが、エージェントが深く読む場面。下の「層ごとの確認」に沿って生データを読む。
5. 複数の問題があれば、**因果の上流から**並べる (例: ライブラリだけ更新 → モジュール不一致 → OpenGL がソフトウェア描画 → Chrome の GPU 無効)。下流の症状は上流を直せば消えることを明記する。

## 層ごとの確認

NVIDIA のカーネルモジュールと、それに対応するユーザー空間ライブラリは上流バージョンの整合が必要。Ubuntu のパッケージ改訂番号や Linux カーネルの版を NVIDIA の版と一致させる必要はない。どこで食い違っているかを特定するのが診断の中心。

| 層 | レポート上の場所 |
|---|---|
| 読み込み中のカーネルモジュール | 概要の「読み込み中」、`/proc/driver/nvidia/version` |
| ディスク上のモジュール (次回起動で読まれる) | `modinfo nvidia` の version と filename、カーネルごとの一覧 |
| ユーザー空間ライブラリ | 「ユーザー空間ライブラリ」の版、`libGLX_nvidia.so.0` などのリンク先 |
| パッケージ | dpkg の一覧 (`nvidia-driver-NNN`、`libnvidia-gl-NNN`、`nvidia-dkms-NNN` など) |

- 「ユーザー空間ライブラリ」の版別一覧は収集情報として扱う。EGL / Wayland / GBM などの連携ライブラリはドライバ本体とは独立した版を持つため、複数の版が記録されているだけでは異常ではない。「NVIDIA 関連ライブラリで複数の版を検出」は INFO として表示する。旧レポートに「版の違う NVIDIA ライブラリが混在」という WARN があっても、直ちに部分更新や .run 版の残骸と判断しない。
- 不一致の判断には、`libGLX_nvidia.so.0`、`libEGL_nvidia.so.0`、`libnvidia-ml.so.1`、`libcuda.so.1` の実際のリンク先とモジュールの版、nvidia-smi と描画テストの結果を使う。独立した版の存在だけを根拠に削除・再インストール・更新を勧めない。集計だけではどのファイルの版か分からない場合は、異常と断定せず、必要な場合だけファイル名と所有パッケージの追加確認を求める。
- 読み込み中だけ古く、ディスク上とライブラリが新しい → 更新後の再起動待ち。`nvidia-smi` は `Driver/library version mismatch`、カーネルログに `NVRM: API mismatch`。次回起動カーネルのモジュールと Secure Boot に問題がなければ、対処は再起動。
- ディスク上も古い → 新しいモジュールが用意されていない。DKMS のビルド失敗、`nvidia-dkms-NNN` の hold、段階的リリース (phased updates) による部分更新を疑う。
- モジュールが読み込まれていない → 実行中カーネル用の `nvidia.ko` がない、Secure Boot の署名拒否、ブラックリスト、nouveau が先に掴んでいる、などを調べる。GPU とモジュール種別の非対応や初期化失敗などもあり、列挙した原因に限定しない。

### Ubuntu のパッケージ構成

- モジュールの供給元は 2 通り。`nvidia-dkms-NNN` (DKMS でビルド、`/lib/modules/<k>/updates/dkms/`) と、Canonical がビルド・署名した `linux-modules-nvidia-NNN-<k>` (`/lib/modules/<k>/kernel/nvidia-NNN*/`)。`-open` が付くのはオープンカーネルモジュール版。
- `linux-modules-nvidia-*` や `linux-objects-nvidia-*` の旧ブランチ分が大量に残っていても、それ自体は不調の原因ではない。
- `nvidia-headless-*` は描画用ライブラリを含まない。`-server` は用途別のブランチで、描画用の `libnvidia-gl-NNN-server` もある。名称だけで不足と決めず、実ファイルと依存関係を確認する。
- 複数ブランチの候補があるときは、一覧の先頭を使用中とみなさない。ライブラリのリンク先、modinfo、パッケージの所有関係を照合する。GPU の対応世代と open / proprietary の要件も確認する。
- `/usr/bin/nvidia-uninstall` がパッケージ管理外にあれば、NVIDIA 公式 .run インストーラの残骸。apt 版と混在すると更新のたびに壊れる。
- `nvidia-firmware-NNN-<ver>` は GSP ファームウェア (`/lib/firmware/nvidia/<ver>/`)。モジュールの版と同じディレクトリが要る。

### カーネルと GRUB

- 「インストール済みカーネルと nvidia モジュール」で、各カーネルにライブラリと同じ版のモジュールがあるかを見る。
- 次回起動カーネルは推定。`GRUB_DEFAULT=0` では生成済み grub.cfg の先頭の起動エントリを確認する。版番号順だけでは OEM / generic などの選択を確定できない。`saved` や `grubenv` の `saved_entry` / `next_entry` があればそれに従う。
- 新しいカーネル (HWE や OEM の更新) で DKMS のビルドが失敗するのは典型的な更新起因の障害。`/var/log/apt/term.log` の `Bad return status for module build on kernel: <k>` と make.log の `error:` 行が証拠。失敗だけでカーネル未対応と断定せず、ヘッダ不足、コンパイラ、署名やディスク容量などの具体的なエラーを確認する。未対応なら、動くカーネルで起動して対応版を待つ。
- 実行中カーネルのヘッダ (`linux-headers-<k>`) がなければ DKMS はビルドできない。

### Secure Boot

- DKMS の署名鍵は通常 `/var/lib/shim-signed/mok/MOK.der`。設定変更や独自署名もあるため、レポートの証明書パスと実際のモジュール署名者を照合する。設定上の鍵が未登録でも、それだけで読み込み拒否の原因と断定しない。実際に使った鍵が信頼されなければ、`Loading of module with unavailable key is rejected` や `Key was rejected by service` で読み込みが拒否される。
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

- 「OpenGL (PRIME オフロード): NVIDIA で描画」は、`__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia glxinfo -B` の確認結果。通常の描画先と分けて判断する。「NVIDIA での描画を確認できない」は GLX の失敗や非 NVIDIA の結果であり、GPU の故障と即断しない。通常の Intel 描画と NVIDIA オフロードが両方成功する構成は正常。
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
