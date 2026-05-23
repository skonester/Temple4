#!/bin/bash
for m in $(awk '{print $2}' /proc/mounts | grep '^/root/temple4_work/squashfs-root' | sort -r); do
    umount -l "$m" || true
done
rm -rf /root/temple4_work/squashfs-root
