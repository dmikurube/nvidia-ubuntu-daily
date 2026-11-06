# nvidia-ubuntu-daily

Ubuntu の NVIDIA ドライバと Linux カーネル周りの不調を診断するスクリプトです。

ドライバやカーネルの更新のあとに「GPU が使えない」「ブラウザの WebGL / WebGPU が無効になった」といった不調が起きたとき、原因の特定に必要な情報をまとめて集めます。そのうえで既知のパターンに当てはめて判定し、対処のコマンドまで表示します。

判定で解決しないときは、保存したレポートをエージェントに渡すと、同梱のスキルを使って原因を診断します。

スクリプトは情報を読むだけで、システムには何も変更を加えません。パッケージの導入、設定の変更、モジュールの読み込み、再起動はしません。

対象は Ubuntu 24.04 LTS、X11 の GNOME、NVIDIA GPU の複数マシンです。GPU 型番、ドライバやカーネルの版、Secure Boot の状態は実行時に取得します。ドライバの候補を一意に決められない場合や次回起動カーネルを確認できない場合は WARN とし、確認を促します。GPU 世代ごとの対応ドライバや open / proprietary の適合性は自動判定していないため、必要に応じてレポートから追加確認します。

## 使い方

デスクトップのターミナルから、一般ユーザーで実行します。

```
./dump-nvidia-ubuntu-diagnosis.sh
```

判定 (`[FAIL]` `[WARN]` `[INFO]` `[ OK ]`) が表示され、カレントディレクトリに `nvidia-ubuntu-report-日時.txt` としてレポートが保存されます。`[FAIL]` が出ていれば、先頭から順に対処します。

| オプション | 内容 |
|---|---|
| `--sudo` | Secure Boot の鍵 (MOK) の登録状況など、権限の要る確認も行う。読み取りのみ |
| `--redact` | レポート中のホスト名、ユーザー名、GPU のシリアル番号などを伏せる |
| `--attach FILE` | 任意のファイルをレポートに添付する (chrome://gpu のレポートなど) |
| `-o FILE` | レポートの保存先 |
| `--no-color` | 色を付けない |

終了コードは、0 が問題なし、1 が注意 (WARN) あり、2 が異常 (FAIL) ありです。

`mesa-utils` と `vulkan-tools` を入れておくと、OpenGL と Vulkan が実際に NVIDIA で動いているかまで確認します。Chrome の WebGL と WebGPU が使うのはこの 2 つです。

```
sudo apt install mesa-utils vulkan-tools
```

## 何を調べるか

NVIDIA ドライバは、メモリ上のカーネルモジュール、ディスク上のモジュール、ユーザー空間のライブラリ、パッケージのバージョンがすべて揃っていないと動きません。どこで食い違っているかを中心に調べます。

- 各バージョンの食い違い (更新後の再起動待ち、モジュールが用意されていない部分更新)
- インストール済みの各カーネルの nvidia モジュールの有無。次回起動するカーネル (GRUB の設定からの推定) に問題がないか
- DKMS のビルド状況とビルド失敗の記録 (`/var/log/apt/term.log`、make.log のエラー行)
- Secure Boot: モジュールの署名、DKMS 署名鍵の MOK 登録、署名拒否のログ
- 読み込みを妨げる設定: modprobe のブラックリスト、カーネル起動オプション、nouveau、prime-select
- カーネルログ: `API mismatch`、`RmInitAdapter failed`、Xid エラー、GPU のバス脱落
- GSP ファームウェア、OpenGL / Vulkan のライブラリと ICD、`.run` インストーラの残骸
- パッケージ: 途中で止まった設定、hold、バージョンの不揃い、旧ブランチの残り
- 再起動待ちの更新 (`/run/reboot-required`、起動後の apt 履歴)
- nvidia-smi、glxinfo、vulkaninfo の実地確認
- Chrome: ハードウェアアクセラレーションの設定、GPU 関連のフラグ、起動オプション、GPU プロセスの状態

## エージェントで診断する

`skill/nvidia-ubuntu-diagnosis/SKILL.md` は、dump-nvidia-ubuntu-diagnosis.sh のレポートを読んで原因と対処手順を出す AI スキルです。レポートの構成、Ubuntu の NVIDIA ドライバの各層、典型的な故障パターン、返答の形式を定めています。

## 構成

```
dump-nvidia-ubuntu-diagnosis.sh          診断スクリプト本体
AGENTS.md                                開発の引き継ぎ書 (AI エージェント向け)
skill/nvidia-ubuntu-diagnosis/SKILL.md   レポートを診断するスキル
```

レポート (`nvidia-ubuntu-report-*.txt`) にはホスト名などが含まれるため、`.gitignore` でリポジトリから外しています。
