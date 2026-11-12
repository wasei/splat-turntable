#!/usr/bin/env bash
# splat-turntable ─ レンダリング画像から、360°回せる静的サイトを一括で作る
#
# 使い方:  bash run.sh [フォルダ] [オプション]
#   フォルダ          images/ と sparse/0/ が入ったフォルダ(場所・名前は自由。省略時はカレント)
#   -y, --overwrite   既存の成果物を、確認なしですべて作り直す
#       --keep        既存の成果物が最新なら、確認なしでそのまま使う
#       --serve       完了後に、確認用のテストサーバーを起動する(Ctrl+C で停止)
#   -c, --config F    設定ファイル(省略時: フォルダ内の pipeline.ini → 無ければこの場所の pipeline.ini)
#   -h, --help        このヘルプ
#
# フォルダの中身(入力)                   出力 → <フォルダ>/site/
#   images/<カメラ名>.png                   index.html, model.sog, sparse/0/*.txt, dzi/, config.json
#   sparse/0/cameras.txt, images.txt        (中間ファイルは <フォルダ>/.build/)
#
# run.sh と同じフォルダに素材を置いて、ファイルマネージャーから run.sh を実行(ダブルクリック)することもできます。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die()   { echo "ERROR: $*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo pipefail/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
# ダブルクリックで起動したとき(引数なし)は、結果が読めるよう最後にEnter待ちにする
NOARGS=0; [ $# -eq 0 ] && NOARGS=1
pause_exit() { local c=$?; if [ "$NOARGS" = 1 ] && [ -t 0 ] && [ -z "${NO_PAUSE:-}" ]; then echo; read -r -p "Enterキーで閉じます " _ || true; fi; exit "$c"; }
trap pause_exit EXIT

WORK="."; MODE=ask; INI=""; SERVE=0; WORK_GIVEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--overwrite) MODE=force ;;
    --keep)         MODE=keep ;;
    --serve)        SERVE=1 ;;
    -c|--config)    INI="${2:?-c にはファイル名が必要です}"; shift ;;
    -h|--help)      usage; exit 0 ;;
    -*)             die "不明なオプション: $1 (./run.sh -h)" ;;
    *)              WORK="$1"; WORK_GIVEN=1 ;;
  esac; shift
done
# フォルダ指定なしで、カレントに images/ が無く run.sh の隣にある場合は、そちらを使う(ダブルクリック起動の保険)
if [ "$WORK_GIVEN" = 0 ] && [ ! -d "$WORK/images" ] && [ -d "$ROOT/images" ]; then WORK="$ROOT"; fi
WORK="$(cd "$WORK" 2>/dev/null && pwd)" || die "フォルダが見つかりません"
if [ -z "$INI" ]; then [ -f "$WORK/pipeline.ini" ] && INI="$WORK/pipeline.ini" || INI="$ROOT/pipeline.ini"; fi
[ -f "$INI" ] || die "設定ファイルがありません: $INI"

# ---------- 設定の読み込み(INI) ----------
ini() {  # ini <section> <key> <default>
  local v; v="$(awk -v sec="$1" -v key="$2" '
    /^[ \t]*\[/ { if (match($0,/\[[^]]+\]/)) cur=substr($0,RSTART+1,RLENGTH-2); next }
    /^[ \t]*[#;]/ || !NF { next }
    cur==sec { k=$0; sub(/=.*/,"",k); gsub(/[ \t]/,"",k)
      if (k==key) { v=substr($0,index($0,"=")+1); sub(/^[ \t]+/,"",v); if (v ~ /^[#;]([ \t]|$)/) v=""; sub(/[ \t]+[#;].*$/,"",v); sub(/[ \t]+$/,"",v); print v; exit } }' "$INI")"
  echo "${v:-$3}"
}
OUT_NAME="$(ini output dir site)"; case "$OUT_NAME" in /*) OUT="$OUT_NAME" ;; *) OUT="$WORK/$OUT_NAME" ;; esac
STEPS="$(ini train steps 10000)";        MAXRES="$(ini train max_resolution 1920)"
FMT="$(ini tiles format webp)";          Q="$(ini tiles quality 85)"
SH="$(ini compress sh_bands 0)";            KEEP_PLY="$(ini output keep_ply no)"
TS="$(ini advanced tile_size 510)";      JOBS="$(ini advanced jobs 0)"
PAR="$(ini advanced parallel yes)";      BRUSH_ARGS="$(ini advanced brush_args '')"
[ "$FMT" = jpeg ] && FMT=jpg
[[ $STEPS =~ ^[0-9]+$ && $MAXRES =~ ^[0-9]+$ && $Q =~ ^[0-9]+$ && $TS =~ ^[0-9]+$ && $JOBS =~ ^[0-9]+$ ]] || die "pipeline.ini の数値項目に数字以外が入っています ($INI)"
[[ $SH =~ ^[0-3]$ ]]                      || die "compress.sh_bands は 0〜3 です"
[[ $KEEP_PLY =~ ^(yes|no)$ ]]             || die "output.keep_ply は yes か no です"
[[ $FMT =~ ^(webp|jpg)$ ]]                || die "tiles.format は webp か jpg です"

# ---------- 入力のチェック ----------
shopt -s nullglob nocaseglob
IMGS=("$WORK"/images/*.{png,jpg,jpeg,tif,tiff,webp})
shopt -u nocaseglob
N="${#IMGS[@]}"
[ "$N" -gt 0 ] || die "$WORK/images に画像がありません。images/ と sparse/0/ を入れたフォルダを指定してください(例: bash run.sh /path/to/フォルダ)"
for f in cameras.txt images.txt; do [ -f "$WORK/sparse/0/$f" ] || die "$WORK/sparse/0/$f がありません (SPEC.md 参照)"; done
mapfile -t NAMES < <(awk '!/^#/ && NF>=10 && $10 ~ /\.[A-Za-z0-9]+$/ {print $10}' "$WORK/sparse/0/images.txt")
MISS=0; for nm in "${NAMES[@]}"; do [ -f "$WORK/images/$nm" ] || [ -f "$WORK/images/$(basename "$nm")" ] || MISS=$((MISS+1)); done
[ "$MISS" -eq 0 ] || die "images.txt に書かれた画像のうち ${MISS} 枚が images/ に見つかりません"
[ "${#NAMES[@]}" -eq "$N" ] || echo "WARN: images/ は ${N}枚、images.txt は ${#NAMES[@]}枚です(多い方は使われません)"
INDIRS=("$WORK/images" "$WORK/sparse")

# ---------- 既存の成果物の確認(質問は最初にまとめて行い、以降は待たせない) ----------
BUILD="$WORK/.build"; SPLAT="$BUILD/splat/splat.ply"; mkdir -p "$BUILD"
ask_yn() {  # ask_yn "質問" → yes=0 / no=1  (--overwrite=常にyes, --keep・非対話=常にno)
  [ "$MODE" = force ] && return 0; [ "$MODE" = keep ] && return 1; [ -t 0 ] || return 1
  local a; read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[yY] ]]
}
newest_input_after() { [ -n "$(find "${INDIRS[@]}" -type f -newer "$1" -print -quit)" ]; }

PROMPTED=0; [ "$MODE" = ask ] && [ -t 0 ] && PROMPTED=1   # 実際に質問が表示されるか
echo "== 確認: $WORK  (画像 ${N}枚) =="
# -- タイル --
NEED_TILES=1; REBUILD_T=0; TILE_PARAMS="format=$FMT quality=$Q tile=$TS"
FRESH=0; for f in "${IMGS[@]}"; do n="$(basename "${f%.*}")"; [ "$OUT/dzi/$n.dzi" -nt "$f" ] && FRESH=$((FRESH+1)); done
if [ -d "$OUT/dzi" ] && [ "$(cat "$OUT/dzi/.params" 2>/dev/null)" != "$TILE_PARAMS" ] && [ "$FRESH" -gt 0 ]; then
  echo "・DZIタイル: 設定(形式/品質/サイズ)が前回と違うため、全て作り直します"; REBUILD_T=1
elif [ "$FRESH" -eq "$N" ]; then
  if ask_yn "・DZIタイル: 全${N}枚が最新です。作り直しますか?"; then REBUILD_T=1; [ "$PROMPTED" = 1 ] || echo "・DZIタイル: 全${N}枚を作り直します"
  else NEED_TILES=0; [ "$PROMPTED" = 1 ] || echo "・DZIタイル: 全${N}枚が最新のため、そのまま使います"; fi
elif [ "$FRESH" -gt 0 ]; then echo "・DZIタイル: 変換済み${FRESH}枚はそのまま使い、残り$((N-FRESH))枚を変換します"
else echo "・DZIタイル: 新規に${N}枚を変換します"; fi
# -- 3DGS学習 --
NEED_TRAIN=1; TRAIN_PARAMS="steps=$STEPS max_resolution=$MAXRES brush_args=$BRUSH_ARGS"; SOG_PARAMS="sh=$SH"
HAVE_PLY=0; [ -f "$SPLAT" ] && HAVE_PLY=1
HAVE_SOG=0; [ -f "$OUT/model.sog" ] && [ "$(cat "$BUILD/sog.params" 2>/dev/null)" = "$SOG_PARAMS" ] && HAVE_SOG=1
TRAINED=0
if [ "$(cat "$BUILD/train.params" 2>/dev/null)" = "$TRAIN_PARAMS" ] && ! newest_input_after "$BUILD/train.params" \
   && { [ "$HAVE_PLY" = 1 ] || [ -f "$OUT/model.sog" ]; }; then TRAINED=1; fi
if [ "$TRAINED" = 1 ] && [ "$HAVE_PLY" = 0 ] && [ "$HAVE_SOG" = 0 ]; then
  echo "・3DGS: 圧縮設定(sh_bands)が変わりましたが、中間PLYを残していない(keep_ply = no)ため再学習します"
elif [ "$TRAINED" = 1 ]; then
  if ask_yn "・3DGS: 学習済み($(date -r "$BUILD/train.params" '+%F %T'))が最新です。再学習しますか?"; then [ "$PROMPTED" = 1 ] || echo "・3DGS: 再学習します"
  else NEED_TRAIN=0; [ "$PROMPTED" = 1 ] || echo "・3DGS: 学習済みが最新のため、そのまま使います"; fi
elif [ -f "$BUILD/train.params" ]; then echo "・3DGS: 画像・カメラ・設定のいずれかが前回から変わったため、再学習します"
else echo "・3DGS: 新規に学習します(${STEPS}ステップ)"; fi
[ -d "$OUT" ] && echo "・出力 ${OUT} を更新します(index.html / model / sparse / dzi。config.json は既存のものを残します)"

# ---------- 必要なツールの確認(長い処理の前にまとめて) ----------
MISSING=(); BRUSH=""
if [ "$NEED_TRAIN" = 1 ]; then
  BRUSH="${BRUSH_BIN:-$(command -v brush_app || command -v brush || true)}"
  [ -n "$BRUSH" ] && [ -x "$BRUSH" ] || MISSING+=("Brush: https://github.com/ArthurBrussee/brush/releases から取得してPATHへ(または BRUSH_BIN=/path/to/brush_app)")
  if command -v vulkaninfo >/dev/null; then vulkaninfo --summary >/dev/null 2>&1 || echo "WARN: Vulkanが動作していません(GPUドライバを確認)"; fi
fi
[ "$NEED_TILES" = 1 ] && ! command -v vips >/dev/null && MISSING+=("libvips: sudo apt install libvips-tools")
if [ "${#MISSING[@]}" -gt 0 ]; then echo "ERROR: 次のツールが必要です:" >&2; printf '  - %s\n' "${MISSING[@]}" >&2; exit 1; fi
SOG_OK=0
if command -v splat-transform >/dev/null; then SOG_OK=1
elif command -v npx >/dev/null && [ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -ge 22 ]; then SOG_OK=1
else echo "WARN: splat-transform(Node.js 22以上)が無いため、3DGSは圧縮されず model.ply で出力されます(サイズ大)。 nvm install 22 && npm i -g @playcanvas/splat-transform"; fi

# ---------- 実行 ----------
run_tiles() {
  [ "$REBUILD_T" = 1 ] && rm -rf "$OUT/dzi"; mkdir -p "$OUT/dzi"
  FORMAT="$FMT" QUALITY="$Q" TILE="$TS" JOBS="$JOBS" bash "$ROOT/scripts/make_dzi.sh" "$WORK/images" "$OUT/dzi"
  echo "$TILE_PARAMS" > "$OUT/dzi/.params"
}
TPID=""; trap 'echo; echo "中断しました"; kill 0' INT TERM
if [ "$NEED_TILES" = 1 ] && [ "$NEED_TRAIN" = 1 ] && [ "$PAR" = yes ]; then
  echo "== タイル変換を並行して開始(ログ: $BUILD/tiles.log) =="; run_tiles >"$BUILD/tiles.log" 2>&1 & TPID=$!
elif [ "$NEED_TILES" = 1 ]; then echo "== DZIタイル変換 =="; run_tiles; fi

if [ "$NEED_TRAIN" = 1 ]; then
  echo "== 3DGS学習: ${STEPS}ステップ / 最大解像度 ${MAXRES}px =="
  # Brushはデータセット内の .ply を初期点群として拾うため、画像とsparseだけを入れた作業用データセットを作る(画像はハードリンクで容量ゼロ)
  rm -f "$BUILD/train.params"; rm -rf "$BUILD/dataset" "$BUILD/splat"; mkdir -p "$BUILD/dataset/sparse" "$BUILD/splat"
  cp -al "$WORK/images" "$BUILD/dataset/images" 2>/dev/null || { echo "WARN: ハードリンクできないため画像をコピーします"; cp -a "$WORK/images" "$BUILD/dataset/images"; }
  cp -a "$WORK/sparse/0" "$BUILD/dataset/sparse/0"
  # shellcheck disable=SC2086
  "$BRUSH" "$BUILD/dataset" --total-steps "$STEPS" --max-resolution "$MAXRES" \
    --export-path "$BUILD/splat" --export-every "$STEPS" $BRUSH_ARGS
  LATEST="$(ls -t "$BUILD"/splat/*.ply 2>/dev/null | head -n1 || true)"
  [ -n "$LATEST" ] || die "Brushの出力PLYが見つかりません($BUILD/splat)"
  mv "$LATEST" "$SPLAT"; echo "$TRAIN_PARAMS" > "$BUILD/train.params"; rm -rf "$BUILD/dataset"
fi
if [ -n "$TPID" ]; then echo "== タイル変換の完了を待っています =="; wait "$TPID" || { tail -n 20 "$BUILD/tiles.log" >&2; die "タイル変換に失敗しました(ログ: $BUILD/tiles.log)"; }; tail -n 1 "$BUILD/tiles.log"; fi

# ---------- サイトの組み立て ----------
echo "== サイト生成: $OUT =="
mkdir -p "$OUT/sparse/0"
cp "$WORK/sparse/0/cameras.txt" "$WORK/sparse/0/images.txt" "$OUT/sparse/0/"   # points3D.txt はビューア不要なので載せない
if [ "$NEED_TRAIN" = 0 ] && [ "$HAVE_SOG" = 1 ]; then echo "model.sog は最新のため、そのまま使います"
else
  rm -f "$OUT"/model.*
  if [ "$SOG_OK" = 1 ] && SOG_ARGS="-N -H $SH" bash "$ROOT/scripts/compress_splat.sh" "$SPLAT" "$OUT/model.sog"; then
    echo "$SOG_PARAMS" > "$BUILD/sog.params"
    # PLYはBrushが出せる唯一の形式で、SOGはそこから変換して作る中間ファイル。サイトには含まれない
    if [ "$KEEP_PLY" = no ]; then rm -f "$SPLAT"; echo "中間ファイル splat.ply を削除しました(output.keep_ply = no)"; fi
  else echo "WARN: 圧縮に失敗したため model.ply で出力します(中間PLYは残します)"; rm -f "$OUT/model.sog"; cp "$SPLAT" "$OUT/model.ply"; fi
fi
cp "$ROOT/viewer/index.html" "$OUT/index.html"
# config.json はビューアーの設定(初期の視点・ズーム・上下反転など)。ユーザーが編集するので、無いときだけ雛形を作る
[ -f "$OUT/config.json" ] || cp "$ROOT/viewer/config.json" "$OUT/config.json"
PORT="${PORT:-8000}"
echo
echo "== 完了 =="
echo "出力フォルダ: $OUT  (サイズ $(du -sh "$OUT" | cut -f1))"
echo
echo "【ブラウザで確認する】"
echo "  1. 次のコマンドで、確認用のサーバーを起動します(止めるときは Ctrl+C)"
echo
printf '       python3 -m http.server %s --directory "%s"\n' "$PORT" "$OUT"
echo
echo "  2. ブラウザで  http://localhost:$PORT/  を開きます"
echo "  (次回から、実行のときに --serve を付けると、完了後に自動で起動します)"
echo
echo "【ビューアーの設定】 $OUT/config.json を編集します(初期の視点・ズーム・3Dの上下反転など)。再実行しても上書きされません"
echo "【公開する】 出力フォルダの中身を、そのままWebサーバーに置きます"
if [ "$SERVE" = 1 ]; then echo; echo "== サーバー起動中: http://localhost:$PORT/  (Ctrl+C で停止) =="; exec python3 -m http.server "$PORT" --directory "$OUT"; fi
