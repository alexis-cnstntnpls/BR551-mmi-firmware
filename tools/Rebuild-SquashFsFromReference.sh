#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <reference_squashfs.bin> <overlay_dir> <output_bin>" >&2
    exit 1
fi

REF_BIN=$1
OVERLAY_DIR=$2
OUTPUT_BIN=$3
TMP_BASE=${TMPDIR:-/tmp}
WORKDIR=$(mktemp -d "$TMP_BASE/squashfs-ref-XXXXXX")

cleanup() {
    rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

MKFS_TIME=$(python3 - "$REF_BIN" <<'PY'
import struct
import sys

with open(sys.argv[1], 'rb') as fh:
    fh.seek(8)
    print(struct.unpack('<I', fh.read(4))[0])
PY
)

unsquashfs -d "$WORKDIR/base" "$REF_BIN" >/dev/null

python3 - "$OVERLAY_DIR" "$WORKDIR/base" <<'PY'
import filecmp
import os
import shutil
import stat
import sys

src_root, dst_root = sys.argv[1:3]


def remove_path(path: str) -> None:
    if os.path.islink(path) or os.path.isfile(path):
        os.unlink(path)
    elif os.path.isdir(path):
        shutil.rmtree(path)


def copy_new_file(src: str, dst: str) -> None:
    shutil.copyfile(src, dst)
    src_mode = stat.S_IMODE(os.stat(src, follow_symlinks=False).st_mode)
    os.chmod(dst, src_mode, follow_symlinks=False)
    src_stat = os.stat(src, follow_symlinks=False)
    os.utime(dst, ns=(src_stat.st_atime_ns, src_stat.st_mtime_ns), follow_symlinks=False)


def overlay_dir(src_dir: str, dst_dir: str) -> None:
    dst_dir_stat = None
    if os.path.isdir(dst_dir) and not os.path.islink(dst_dir):
        dst_dir_stat = os.stat(dst_dir, follow_symlinks=False)

    with os.scandir(src_dir) as it:
        entries = sorted(it, key=lambda e: e.name)

    for entry in entries:
        src = entry.path
        dst = os.path.join(dst_dir, entry.name)

        if entry.is_symlink():
            src_link = os.readlink(src)
            if os.path.lexists(dst):
                if os.path.islink(dst) and os.readlink(dst) == src_link:
                    continue
                remove_path(dst)
            os.symlink(src_link, dst)
            continue

        if entry.is_dir(follow_symlinks=False):
            if os.path.lexists(dst):
                if os.path.islink(dst) or not os.path.isdir(dst):
                    remove_path(dst)
                    os.mkdir(dst)
            else:
                os.mkdir(dst)
            overlay_dir(src, dst)
            continue

        if entry.is_file(follow_symlinks=False):
            if os.path.lexists(dst):
                if os.path.islink(dst) or not os.path.isfile(dst):
                    remove_path(dst)
                    copy_new_file(src, dst)
                    continue

                if filecmp.cmp(src, dst, shallow=False):
                    continue

                dst_stat = os.stat(dst, follow_symlinks=False)
                with open(src, 'rb') as sfh, open(dst, 'wb') as dfh:
                    shutil.copyfileobj(sfh, dfh)
                os.chmod(dst, stat.S_IMODE(dst_stat.st_mode), follow_symlinks=False)
                os.utime(dst, ns=(dst_stat.st_atime_ns, dst_stat.st_mtime_ns), follow_symlinks=False)
                continue

            copy_new_file(src, dst)

    if dst_dir_stat is not None:
        os.utime(dst_dir, ns=(dst_dir_stat.st_atime_ns, dst_dir_stat.st_mtime_ns), follow_symlinks=False)


overlay_dir(src_root, dst_root)
PY

mksquashfs "$WORKDIR/base" "$OUTPUT_BIN" \
    -comp lzo \
    -Xalgorithm lzo1x_999 \
    -Xcompression-level 9 \
    -b 32768 \
    -noappend \
    -no-exports \
    -all-root \
    -mkfs-time "$MKFS_TIME" \
    >/dev/null
