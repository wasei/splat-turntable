#!/usr/bin/env bash
# 3DGS PLY を Web配信用の SOG(WebP圧縮)に変換する。ファイルは大幅に小さく・読み込みも速くなる。
# 使い方: ./compress_splat.sh <in.ply> [out.sog]
# 環境変数:
#   SOG_ARGS  splat-transform への追加アクション (既定: "-N -H 0")
#             -N: NaN等の不正なガウシアン除去 / -H 0: 球面調和(SH)を0次のみに(最小・最速。2D画像が主役なので画質差は小さい)
#             SHを残す: SOG_ARGS="-N -H 1" / 浮遊物除去を足す: SOG_ARGS="-N -H 0 -F"
# 必要: Node.js 22以上 (splat-transform の要件)。未導入でも npx 経由で実行を試みる。
set -euo pipefail
IN="${1:?使い方: $0 <in.ply> [out.sog]}"
OUT="${2:-${IN%.*}.sog}"
if command -v splat-transform >/dev/null; then
  RUN=(splat-transform)
elif command -v npx >/dev/null; then
  RUN=(npx --yes @playcanvas/splat-transform)
else
  echo "ERROR: Node.js 22以上が必要です (例: nvm install 22 && npm i -g @playcanvas/splat-transform)"; exit 1
fi
# shellcheck disable=SC2086
"${RUN[@]}" "$IN" ${SOG_ARGS:--N -H 0} "$OUT"
echo "== $(du -h "$IN" | cut -f1) -> $(du -h "$OUT" | cut -f1): $OUT =="
