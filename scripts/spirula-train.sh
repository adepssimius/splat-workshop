#!/bin/bash
# Spirula for the Arcturus pipeline, with Splat Workshop's training options: the pipeline passes none of
# Spirula's own through, so splat.sh hands it this script instead of Spirula itself.
#
# Environment:
#   SPIRULA_REAL  the real Spirula executable
#   NORMALS=1     estimate surface normals for the dataset first (`spirula geometry`, into dataset/normals,
#                 which the training finds by itself): flatter walls and floors, far fewer floating flakes;
#                 about 2.5 s per image. An interrupted estimate continues where it stopped.
#   SH0=1         no view-dependent colour (--sh-degree 0): about 20 % smaller, no visible loss
# Everything but `train` goes to Spirula unchanged.
#
# Lines starting with "@@" are machine-readable progress markers for the web interface.
set -euo pipefail
real=${SPIRULA_REAL:?SPIRULA_REAL is not set}
[ "${1:-}" = train ] || exec "$real" "$@"

data=
args=("$@")
for ((i = 0; i < ${#args[@]} - 1; i++)); do
    [ "${args[i]}" = --data ] && data=${args[i + 1]}
done
extra=()
if [ "${NORMALS:-0}" = 1 ] && [ -n "$data" ]; then
    images=$( (find "$data/images" -type f 2>/dev/null || true) | wc -l)
    echo "@@ normals $images"
    echo "Estimating surface normals for $images images ..."
    # Spirula can crash on exit with every image written (seen on a GTX 1060, driver 580). Ask again: with
    # nothing left to do it ends cleanly, and with a real failure it fails again and stops the run here.
    "$real" geometry "$data" || {
        echo "Normals: Spirula exited with an error, checking whether all images are done ..."
        "$real" geometry "$data"
    }
fi
if [ "${SH0:-0}" = 1 ]; then
    extra+=(--sh-degree 0)
fi
echo "Spirula training options: normals ${NORMALS:-0}, ${extra[*]:-default colours}"
exec "$real" "$@" "${extra[@]}"
