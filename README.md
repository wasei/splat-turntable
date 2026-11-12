# splat-turntable

3DCGのレンダリング画像から、**360°回せる商品ビューアー**(静的HTML)を作るパイプラインです。

- 回している間は **3D Gaussian Splatting**(軽い・滑らか)
- 止めると最寄りのカメラ位置へ寄って、**8Kの高解像度画像**(ディープズーム)に切り替わる

3DGSの粗が目立つ「寄り」は2D画像に任せ、3DGSは「移動中の補間」だけに使うハイブリッド構成です。
画像を何百枚も送る従来のターンテーブルに比べて、枚数を増やさずに滑らかに動かせ、初回の読み込みも軽くなります。

```
 レンダリング画像 + カメラ情報
        │   run.sh
        ├─→ 3DGS学習 (Brush) → 圧縮 (SOG)
        ├─→ 8K画像をタイル化 (DZI)
        ▼
   site/  ← サーバーに置くだけ(index.html / model.sog / dzi/ ...)
```

## 使い方

### 1. ツールを入れる(Linux)

| ツール | 用途 | 入れ方 |
|---|---|---|
| [Brush](https://github.com/ArthurBrussee/brush) | 3DGS学習(Vulkanで動作。CUDA不要) | [Releases](https://github.com/ArthurBrussee/brush/releases) からLinux版を取得してPATHへ |
| libvips | タイル化 | `sudo apt install libvips-tools` |
| Node.js 22以上 + [splat-transform](https://github.com/playcanvas/splat-transform) | 3DGSの圧縮(任意) | `nvm install 22 && npm i -g @playcanvas/splat-transform` |

圧縮ツールが無くても動きます(その場合は非圧縮の `model.ply` で出力され、サイズが大きくなります)。

### 2. 素材を用意する

フォルダを1つ作り(**場所も名前も自由**)、中に次を入れます。

```
(好きな名前のフォルダ)/
  images/     r00_a00.png, r00_a01.png ...   レンダリング画像。ファイル名がカメラ名。8K推奨
  sparse/0/   cameras.txt, images.txt        カメラ情報(COLMAP形式)
```

画像とカメラ情報は、お使いのレンダラーから書き出してください。形式の詳細は [docs/SPEC.md](docs/SPEC.md) にあります。

### 3. 実行する

**コマンドで実行**: ターミナルで、先頭に `bash` を付けて `run.sh` と素材のフォルダを指定します。

```bash
bash run.sh /path/to/フォルダ
```

パスに空白が含まれるときは `"..."` で囲みます。`bash` を付ければ、実行権限の設定は要りません。

**ダブルクリックで実行**: `run.sh` と同じ場所に `images/` と `sparse/` を置き、ファイルマネージャーで `run.sh` を実行します(「端末で実行」などを選びます。お使いの環境で変わります)。終わるとEnter待ちになるので、結果を確認してから閉じてください。

### 4. 確認する

実行が終わると、確認用のコマンドが表示されます。

```
python3 -m http.server 8000 --directory "…/site"
```

これを実行して、ブラウザで http://localhost:8000/ を開きます。止めるときは Ctrl+C です。
実行時に `--serve` を付けると、完了後に自動で起動します(`bash run.sh /path/to/フォルダ --serve`)。

### 5. 公開する

出力された `site/` の中身を、そのまま静的なWebサーバーに置きます(`file://` で直接開いても動きません)。

## 2回目以降(モデルを更新したとき)

画像(と `sparse/`)を差し替えて、もう一度 `run.sh` を実行するだけです。HTMLは触りません。

- 変更のあった画像だけが再タイル化されます。
- 画像・カメラ・設定が前回から変わっていれば、3DGSは自動で再学習されます。
- **既存の成果物が最新のとき**は、最初に「作り直しますか?」と聞きます(処理の途中では聞きません)。

```bash
bash run.sh /path/to/フォルダ -y       # 確認せず、すべて作り直す
bash run.sh /path/to/フォルダ --keep   # 確認せず、最新のものはそのまま使う
bash run.sh -h                         # ヘルプ
```

## 設定(pipeline.ini)

リポジトリ直下の `pipeline.ini` が既定値です。**素材のフォルダに `pipeline.ini` を置くと、そちらが優先**されます(必要な項目だけ書けば十分)。
`-c 設定ファイル` で別のファイルも指定できます。これは「生成」の設定(学習・タイル・圧縮・出力)です。ビューアーの見え方は、下の `config.json` で変更します。主な項目は次のとおりです。

| 項目 | 既定 | 説明 |
|---|---|---|
| `[train] steps` | 10000 | 学習ステップ数。**時間と品質に最も効く**。時間はほぼ比例 |
| `[train] max_resolution` | 1920 | 学習時に画像を縮小する長辺px。2D画像は8Kのまま使われる |
| `[tiles] format` | webp | `webp`(軽い) / `jpg`(互換性重視) |
| `[tiles] quality` | 85 | タイルの画質(1-100) |
| `[compress] sh_bands` | 0 | 3DGSの視点依存の色。0が最小・最速 |
| `[output] dir` | site | 出力フォルダ名 |
| `[output] keep_ply` | no | 学習結果の非圧縮PLY(SOG変換用の中間ファイル。サイトには入らない)を、変換後に削除するか |
| `[advanced] tile_size` / `jobs` / `parallel` / `brush_args` | 510 / 0 / yes / (空) | 通常は触らない |

## ビューアーの操作

ドラッグで回転、ホイール(ピンチ)でズーム(画角のみ変更。位置は動かない)、離すと最寄りのカメラ位置へ移動して高解像度画像に切り替わります。
画面のアスペクト比が違っても、短辺合わせで長辺側が見切れるだけです。
`index.html?debug` を付けると、手元のGLB・PLYやフォルダを選んで確認できるデバッグ用の画面が出ます(通常は表示されません)。

## ビューアーの設定(site/config.json)

出力された `site/config.json` を、テキストエディタで直接編集します。**`run.sh` を再実行しても上書きされません**(無いときだけ雛形が作られます)。
再生成しなくても、保存してブラウザを再読み込みすれば反映されます。

| キー | 既定 | 説明 |
|---|---|---|
| `initial.az` / `initial.el` | 0 / 30 | 初期の方位角・仰角(度) |
| `zoom.initial` / `zoom.min` / `zoom.max` | 1 / 1 / 8 | ズーム倍率(画角を狭める倍率) |
| `splatUpsideDown` | false | 3Dが上下逆に表示されたら `true` |
| `snapMs` | 450 | 最寄りのカメラへ移動する時間(ミリ秒) |
| `fadeMs` | 300 | 2D画像へ切り替わるフェードの時間(ミリ秒) |
| `dragSpeed` | 0.35 | ドラッグの感度(度/px) |

書式を間違えると画面に「config.json の書式が正しくありません」と表示されます。

## フォルダ構成(このリポジトリ)

```
run.sh              入口。画像フォルダ → サイトまで一括
pipeline.ini        設定(コメント付き)
scripts/            make_dzi.sh(タイル化)、compress_splat.sh(圧縮)。単体でも使える
viewer/index.html   ビューアー(サイトにコピーされる。固定)
viewer/config.json  ビューアー設定の雛形(site/ に無いときだけコピーされる)
tools/              付属の書き出しツール(任意)
docs/SPEC.md        入出力の仕様
```

## 付属ツール(任意)

`tools/orbit-exporter.html` は、GLBから上記の形式(画像・カメラ)を書き出す簡易ツールです。Chromeで開きます。
他のレンダラーを使う場合は不要です。

## トラブルシュート

| 症状 | 対処 |
|---|---|
| ブラウザで何も出ない | `file://` では動きません。確認用サーバー(上の手順4)を使う |
| `Format not recognized` (Brush) | `sparse/0/` の場所を確認。Brushが古い場合は最新版に更新 |
| タイル化でメモリ不足 | `pipeline.ini` の `[advanced] jobs` を減らす(例: 2) |
| 3Dが上下逆 | `site/config.json` の `splatUpsideDown` を `true` に |
| 3Dと2Dの切り替え時に位置がずれる | 全画像のFOV・サイズが同一か、カメラ情報が画像と対応しているか確認 |
| 学習をやり直したい | `-y` を付ける、または `.build/` を削除 |
| `sh_bands` を変えたら再学習になった | `keep_ply = no` のため。`yes` にすると、圧縮設定だけの変更は再学習なしで済む |

## 動作環境と状況

- Linux(Linux Mint 22 で開発)。bash前提のため、Windows / macOS は未確認です。
- GPU: Brush が動くVulkan対応GPU。
- 開発中のプロジェクトです。仕様は変わる可能性があります。

## 使っているもの

[Brush](https://github.com/ArthurBrussee/brush)(Apache-2.0)、[libvips](https://github.com/libvips/libvips)(LGPL、外部コマンドとして使用)、
[splat-transform](https://github.com/playcanvas/splat-transform)(MIT)、[Spark](https://github.com/sparkjsdev/spark)(MIT)、
[OpenSeadragon](https://openseadragon.github.io/)(BSD-3-Clause)、[three.js](https://threejs.org/)(MIT)。

## ライセンス

未定(`LICENSE` を追加してください)。
