# AGENTS.md

このファイルは、このリポジトリを管理する AI エージェントへの引き継ぎ書です。作業の前に一度読んでください。

## このリポジトリについて

Ubuntu 24.04 + NVIDIA GPU のマシンでは、ドライバやカーネルの更新のたびに「GPU が使えない」「Chrome の WebGL / WebGPU が無効になる」といった不調が起きます。このリポジトリは、その原因を素早く特定するための道具です。

- `dump-nvidia-ubuntu-diagnosis.sh`: 診断スクリプト。情報を集め、既知のパターンで判定し、対処のコマンドまで表示する。**判定だけで解決できることを第一の目標にしている。**
- `skill/nvidia-ubuntu-diagnosis/SKILL.md`: 判定で解決しないとき、ユーザーがレポートをエージェントに添付して診断を頼むためのスキル。

前提として、**対象のマシンは AI に全権を渡せるマシンではありません**。AI が直接コマンドを実行して調べる代わりに、ユーザーがスクリプトを実行し、その出力 (またはレポート) を AI が読む、という分担で設計しています。

## 守ること

1. **`dump-nvidia-ubuntu-diagnosis.sh` は読み取り専用に保つ。** パッケージの導入、設定の変更、モジュールの読み込み、再起動など、システムを変える処理を入れない。書き込んでよいのは、レポートのファイルと `mktemp` の一時ディレクトリだけ。対処はコマンドを「表示する」だけにする。
2. **ユーザーのマシンでシステムを変えるコマンドを実行しない。** `sudo`、`apt`、`modprobe`、`mokutil --import`、`update-grub`、`dkms` などは、必要ならユーザーに提示して実行してもらう。`./dump-nvidia-ubuntu-diagnosis.sh --no-sudo` は読み取りだけなので実行してよい。ただし、出たレポートはコミットしない (ホスト名などを含む。`.gitignore` で `nvidia-ubuntu-report-*.txt` を除外済み)。
3. **終了コードの約束を変えない。** 0 = 問題なし、1 = WARN あり、2 = FAIL あり。
4. **Ubuntu 24.04 の標準環境で動くこと。** bash 5.2、awk は **mawk** (gawk 専用の機能は使わない: `gensub`、`strftime`、`asort`、配列の配列など)、GNU の coreutils / sed / grep。Python は `chrome_local_state` で使っているだけで、なくても動く。
5. 表示、レポート、コード内のコメントは日本語。コミットメッセージは英語。
6. コミットの author date / committer date は、作業環境のローカルタイムゾーンを尊重する。UTC に固定しない。

## よく使うコマンド

```
./dump-nvidia-ubuntu-diagnosis.sh -h
```

## dump-nvidia-ubuntu-diagnosis.sh の構成

処理の流れは `main()` を見るのが早い。

1. `collect_facts`: 判定に使う事実をグローバル変数に集める。主なもの:
   - バージョン: `USER_VER` (ライブラリ)、`LOADED_VER` / `LOADED_KIND` (読み込み中のモジュール)、`DISK_VER` / `DISK_FILE` / `DISK_SIGNER` / `DKMS_MODULE` (実行中カーネル用のディスク上のモジュール)、`PKG_VER` / `DRV_PKG` / `DRV_BRANCH` / `DRV_VARIANT` (パッケージ)、`DKMS_PKG` / `DKMS_VER`
   - カーネル: `KREL`、`KERNELS` (`/boot/vmlinuz-*` を版の順に)、`NEXT_KERNEL` (GRUB の設定からの推定)、`KMOD_VER[k]`、`GOOD_KERNELS` (ライブラリと同じ版のモジュールがあるカーネル)
   - Secure Boot: `SB_ON`、`MOK_STATE` (`enrolled` / `not-enrolled` / `pending` / `no-key` / `unreadable` / `unknown`)、`SB_ISSUE`
   - DKMS とログ: `DKMS_STATUS`、`DKMS_FAILED_KERNELS` (apt の term.log から)、`MAKELOG` / `MAKELOG_ERRORS`、`KLOG` / `NVLOG` / `JLOG_WARN`、`SIG_REJECT_LINES`
   - パッケージ: `PKG_NV` / `PKG_NV_INST` / `PKG_CORE_VERS` / `PKG_BROKEN` / `PKG_HELD`

   関数内には順序の依存がある (例: `GOOD_KERNELS` は `USER_VER` のあとに求める)。
2. `collect_raw_system` / `collect_tools` と通常権限の `check_*`: システム・ツール・描画・パッケージ・自動削除シミュレーション・サービス・Chrome を先に収集する。描画・Chrome 判定用に `check_core` を一度実行するが、その暫定所見は捨てる。
3. 最後に `setup_sudo` で説明と `show_sudo_plan` による実行候補一覧を表示してから認証を行い、成功した場合だけ `collect_boot_facts` / `collect_mok_facts` / `collect_log_facts` と `derive_secureboot_issue` で権限が必要な情報を更新する。「権限が必要な追加確認」節以降が追加取得と最終判定。`check_core` / `check_kernels` / `check_dkms` / `check_secureboot` / `check_kernel_log` は最終情報で実行し、所見を通常権限の確認結果より前に置く。`check_updates` は更新した `NEXT_BAD` を参照する。生データを `sec` / `note` / `run` で記録し、所見を `finding LEVEL TITLE BODY` で追加する。
   - `check_core` が `CORE_STATE` (`ok` / `nogpu` / `nodriver` / `reboot` / `mismatch` / `nolib` / `notloaded`) を決め、後の関数はこれを見て重複する所見を出さない (例: 再起動待ちのとき nvidia-smi の mismatch は所見にしない)。
   - `check_kernels` が `NEXT_BAD` を決め、`check_updates` が再起動を勧めるかどうかに使う。
   - `check_autoremove` は `check_packages` の後に `apt-get --simulate autoremove` を実行し、「自動削除のシミュレーション」節に出力全体と終了コードを記録する。実際の削除はしない。移行先が導入済みで削除予定にない移行用 NVIDIA パッケージは INFO、追加照合が必要な GPU / カーネル関連候補は WARN、その他の用途の候補は INFO とする。
   - `PKG_FILES[p]` は収集できたパッケージの所有ファイル一覧。`unused_firmware_candidate` は候補の版別ディレクトリの実体を確認し、現在・ディスク上・ライブラリ・全カーネルの版と照合して、必要な版のファームウェアのパッケージと実体が削除後も残る場合のみ INFO に分類する。不明な版・ファイル、共有パス、シンボリックリンクなどは WARN に残す。次回起動先が不明でも全インストール済みカーネルを照合し、手動で退避したモジュールや将来のダウングレード用途は保証しない。
   - 自動削除の WARN は故障や削除の危険性が確定したという意味ではない。旧ファームウェア・予備カーネルも含むため、所有ファイルと依存関係を現在・ディスク上のモジュール、各カーネル、次回起動先と照合する。移行用の候補が問題なくても、自動削除全体の安全性は保証しない。シミュレーション失敗・タイムアウト・未知の出力は「候補なし」と区別し、一般ユーザーで読めない APT 設定や採取後の状態変化にも注意する。
4. `write_report` → `render_summary`: 所見は FAIL → WARN → INFO → OK の順に、同じレベルの中は追加した順に表示する。**根本原因の所見が先に出るよう、追加する順番を意識する。**

所見の書き方の約束:

- TITLE は 1 行で何が起きているかを書く。スキルがこの文言を参照しているので、変えたらスキルも直す。
- BODY は説明のあとに `→ ` で始まる対処の行を置く。対処は実行できる具体的なコマンドで書く。
- 対処の文面を作る関数: `module_fix_hint` (カーネル用モジュールの用意)、`boot_other_kernel_hint` (動くカーネルで起動する手順)、`sb_issue_text` / `sb_reboot_note` (Secure Boot)。

`run "コマンド" [行数]` はコマンド行と出力を生データに記録する (40 秒でタイムアウト、出力は既定で先頭 200 行)。通常権限での確認を済ませた後、既定では `setup_sudo` が説明を表示してから認証を確認し、成功した場合だけ `SUDO="sudo -n"` を権限の要る読み取りの前に付ける。スクリプト全体は一般ユーザーで動かす。`--no-sudo` は sudo を呼ばず、`--sudo` は互換用。非対話実行では `sudo -n -v` を使い、認証不可・sudo 不在なら一般ユーザーで読める範囲を続ける。`announce_command` は実行前の sudo コマンドを、リダイレクトやコマンド置換でも消えない表示用 FD と生データへ出す。直接読み取りは `read_privileged`、シェル文字列の読み取りは `run` を通し、sudo の未表示実行を追加しない。新しい sudo コマンドを追加するときは、パスワード入力前の `show_sudo_plan` の一覧も更新する。MAKELOG は通常権限で選んだパスを認証後も維持し、一覧にないパスへ差し替えない。エージェントによる検証では sudo を実行せず、必要ならモックで経路を確認する。

新しい故障パターンに対応するときの手順:

1. `dump-nvidia-ubuntu-diagnosis.sh` に判定を足す。根本原因の所見が先に出るよう、追加する位置に気をつける。
2. 表示やレポートの形 (見出し、所見の文言、`MOK_STATE` の値など) を変えたら、`skill/nvidia-ubuntu-diagnosis/SKILL.md` と `README.md` も直す。

## スキルとの関係

スキルはレポートの構成 (`######## 見出し ########` の区切り、`[FAIL]` などの所見、生データの各節) を前提に書かれている。スキルは「dump-nvidia-ubuntu-diagnosis.sh に追加するとよい確認」を返答の最後に挙げるよう指示しているので、ユーザーがそれを持ち込んだら改善の候補として扱う。

## 対象のマシン

対象は複数のマシン。共通の前提は Ubuntu 24.04 LTS、X11 の GNOME セッション、NVIDIA GPU。ブラウザは Google Chrome を想定している。

GPU の型番・世代、ドライバのブランチ・バージョン・モジュールの供給元 (DKMS / ビルド済み)、カーネルの種類・バージョン、Secure Boot の有効・無効や MOK の登録状況はマシンごとに異なり、更新でも変わる。これらは固定の前提にせず、実行時に収集した情報やレポートから判断する。

## 発端となったマシンと事例

以下は 2026 年 11 月の一例であり、他のマシンや更新後の状態の前提にはしない。

- GPU: NVIDIA RTX 2000 Ada Generation (AD107GL)
- ドライバ: Ubuntu の `nvidia-driver-595` (DKMS でビルド)。旧ブランチ (570 / 580) のビルド済みモジュールのパッケージが多数残っている (不調の原因ではない)
- カーネル: OEM カーネル (6.17 系) で起動。generic カーネル (7.0 系) も入っていて、DKMS のモジュールは両方に用意されている
- Secure Boot は有効。DKMS でビルドしたモジュールが読み込めていたので、DKMS の署名鍵は MOK に登録済みと見られる

発端の事例 (2026 年 11 月): ドライバが 595.91.07 から 595.99.02 に更新され、ライブラリとディスク上のモジュールは新しくなったが、メモリ上のモジュールは 595.91.07 のままだった。そのため OpenGL / Vulkan が使えず、Chrome の WebGL / WebGPU が Disabled になった。対処は再起動。

## 実機で確かめていない点と改善の候補

次の点は、想定した出力の文言をもとに判定していて、実機の出力で確かめていない。実際の出力が手に入ったら、判定を合わせる。

- Chrome の GPU プロセスの起動オプションから「GPU を使っていない」と推定する判定 (`--use-angle=swiftshader-webgl`、`--use-gl=disabled`、`--disable-gpu-compositing` を手がかりにしている)
- 次回起動カーネルの推定 (生成済み grub.cfg のエントリ ID または先頭項目を照合。サブメニューの階層指定は末尾の ID で照合し、実機の grub.cfg の行で確認済み。番号・タイトルによる指定、複雑な条件分岐や別設定への移動などは解釈しない)
- Secure Boot の署名拒否のログの文言、`mokutil --test-key` の出力の文言
- `--sudo` の経路

改善の候補:

- Wayland セッションの確認が薄い (`eglinfo -B` での確認がない)
- オープンカーネルモジュールが必須の GPU 世代 (Blackwell 以降) かどうかの確認がない
- ハイブリッド GPU (PRIME) やマルチ GPU の構成を詳しく見ていない
- ライブラリの確認は x86_64 だけ (i386 は数えているが判定していない)
