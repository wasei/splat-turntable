#!/usr/bin/env bash
# 画像フォルダ内の全画像を DZI(Deep Zoom)タイルに変換するバッチ(マルチプロセス・再開可)
# レンダラーには依存しない: 入力は「画像ファイルが入ったフォルダ」だけ。
# 使い方: ./make_dzi.sh <images_dir> <out_dir>
#   出力: <out_dir>/<画像名>.dzi と <out_dir>/<画像名>_files/<level>/<col>_<row>.<形式>
# 環境変数:
#   FORMAT            webp(既定) | jpg
#   QUALITY           85
#   TILE              510   (+重なり1pxで512px相当。大きくするとファイル数が減る)
#   OVERLAP           1
#   JOBS              同時に処理する画像数 (0または未指定 = 論理コア数の半分)
#   VIPS_CONCURRENCY  1画像あたりのスレッド数 (既定: 2)  ※メモリが足りなければ JOBS を減らす
# 必要: libvips (Linux Mint: sudo apt install libvips-tools)
set -euo pipefail
IN="${1:?使い方: $0 <images_dir> <out_dir>}"
OUT="${2:?使い方: $0 <images_dir> <out_dir>}"
command -v vips >/dev/null || { echo "ERROR: vips がありません: sudo apt install libvips-tools"; exit 1; }
[ -d "$IN" ] || { echo "ERROR: $IN がありません"; exit 1; }

FORMAT="${FORMAT:-webp}"; [ "$FORMAT" = "jpeg" ] && FORMAT=jpg
export OUT FORMAT QUALITY="${QUALITY:-85}" TILE="${TILE:-510}" OVERLAP="${OVERLAP:-1}"
NPROC="$(nproc)"
JOBS="${JOBS:-0}"; [ "$JOBS" -gt 0 ] || JOBS=$(( NPROC >= 4 ? NPROC / 2 : 1 ))
export VIPS_CONCURRENCY="${VIPS_CONCURRENCY:-2}"
mkdir -p "$OUT/.tmp"

tile_one() {
  local f="$1" n; n="$(basename "${f%.*}")"
  if [ -f "$OUT/$n.dzi" ] && [ "$OUT/$n.dzi" -nt "$f" ]; then echo "skip  $n"; return 0; fi   # 画像より新しい変換済みはスキップ(再開・差分更新)
  local t="$OUT/.tmp/$n"; rm -rf "$t.dzi" "${t}_files"
  vips dzsave "$f" "$t" --tile-size "$TILE" --overlap "$OVERLAP" --suffix ".${FORMAT}[Q=${QUALITY}]"
  rm -rf "$OUT/${n}_files"; mv "${t}_files" "$OUT/${n}_files"; mv "$t.dzi" "$OUT/$n.dzi"  # .dziは最後に置く=完了の目印
  echo "done  $n"
}
export -f tile_one

N="$(find "$IN" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.tif' -o -iname '*.tiff' -o -iname '*.webp' \) | wc -l)"
[ "$N" -gt 0 ] || { echo "ERROR: $IN に画像がありません"; exit 1; }
echo "== DZI変換: ${N}枚 / JOBS=$JOBS x VIPS_CONCURRENCY=$VIPS_CONCURRENCY / ${FORMAT} Q${QUALITY} / tile ${TILE}+${OVERLAP} =="
find "$IN" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.tif' -o -iname '*.tiff' -o -iname '*.webp' \) -print0 \
  | sort -z | xargs -0 -n1 -P "$JOBS" bash -c 'tile_one "$0"'
rmdir "$OUT/.tmp" 2>/dev/null || true
echo "== 完了: $(ls "$OUT"/*.dzi | wc -l)/${N} 枚 -> $OUT =="
