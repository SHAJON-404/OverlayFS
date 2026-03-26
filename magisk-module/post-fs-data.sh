MODDIR="${0%/*}"

set -o standalone

export MAGISKTMP="$(magisk --path)"

chmod 777 "$MODDIR/overlayfs_system"

OVERLAYDIR="/data/adb/overlay"
OVERLAYMNT="/dev/mount_overlayfs"
MODULEMNT="/dev/mount_loop"


mv -fT /cache/overlayfs.log /cache/overlayfs.log.bak
rm -rf /cache/overlayfs.log
echo "--- Start debugging log ---" >/cache/overlayfs.log
echo "init mount namespace: $(readlink /proc/1/ns/mnt)" >>/cache/overlayfs.log
echo "current mount namespace: $(readlink /proc/self/ns/mnt)" >>/cache/overlayfs.log

mkdir -p "$OVERLAYMNT"
mkdir -p "$OVERLAYDIR"
mkdir -p "$MODULEMNT"

mount -t tmpfs tmpfs "$MODULEMNT"

loop_setup() {
  unset LOOPDEV

  LOOPDEV=$(/system/bin/losetup -s -f "$1")
  if [ $? -ne 0 ]; then
     unset LOOPDEV
     echo "loop_setup: losetup failed for $1" >>/cache/overlayfs.log
     return 1
  fi
  # wait for ueventd to create loop block device
  local i=0
  while [ $i -lt 10 ]; do
      [ -b "$LOOPDEV" ] && break
      sleep 0.1
      i=$((i + 1))
  done
  if [ ! -b "$LOOPDEV" ]; then
      local minor=${LOOPDEV#/dev/block/loop}
      mknod "$LOOPDEV" b 7 "$minor" 2>>/cache/overlayfs.log
  fi
}

if [ -f "$OVERLAYDIR" ]; then
    loop_setup /data/adb/overlay
    if [ ! -z "$LOOPDEV" ]; then
        if mount -o rw -t ext4 "$LOOPDEV" "$OVERLAYMNT" 2>>/cache/overlayfs.log; then
            ln "$LOOPDEV" /dev/block/overlayfs_loop
            echo "overlay image mounted successfully on $OVERLAYMNT" >>/cache/overlayfs.log
        else
            echo "mount failed first attempt: trying e2fsck recovery on $LOOPDEV" >>/cache/overlayfs.log
            /system/bin/e2fsck -p -f "$LOOPDEV" >>/cache/overlayfs.log 2>&1
            if mount -o rw -t ext4 "$LOOPDEV" "$OVERLAYMNT" 2>>/cache/overlayfs.log; then
                ln "$LOOPDEV" /dev/block/overlayfs_loop
                echo "overlay image repaired and mounted successfully on $OVERLAYMNT" >>/cache/overlayfs.log
            else
                echo "mount failed: could not mount $LOOPDEV on $OVERLAYMNT (errno=$?)" >>/cache/overlayfs.log
                /system/bin/losetup -d "$LOOPDEV" 2>/dev/null
                unset LOOPDEV
            fi
        fi
    else
        echo "loop_setup failed: no loop device available for $OVERLAYDIR" >>/cache/overlayfs.log
    fi
else
    echo "overlay image not found at $OVERLAYDIR — skipping loop mount" >>/cache/overlayfs.log
fi

if ! "$MODDIR/overlayfs_system" --test --check-ext4 "$OVERLAYMNT"; then
    echo "unable to mount writeable dir (OVERLAYMNT=$OVERLAYMNT, LOOPDEV=${LOOPDEV:-none})" >>/cache/overlayfs.log
    exit
fi

num=0

for i in /data/adb/modules/*; do
    [ ! -e "$i" ] && break;
    module_name="$(basename "$i")"
    if [ ! -e "$i/disable" ] && [ ! -e "$i/remove" ]; then
        if [ -f "$i/overlay.img" ]; then
            loop_setup "$i/overlay.img"
            if [ ! -z "$LOOPDEV" ]; then
                echo "mount overlayfs for module: $module_name" >>/cache/overlayfs.log
                mkdir -p "$MODULEMNT/$num"
                mount -o rw -t ext4 "$LOOPDEV" "$MODULEMNT/$num"
            fi
            num="$((num+1))"
        fi
        if [ "$KSU" == "true" ]; then
            mkdir -p "$MODULEMNT/$num"
            mount --bind "$i" "$MODULEMNT/$num"
            num="$((num+1))"
        fi
    fi
done

OVERLAYLIST=""

for i in "$MODULEMNT"/*; do
    [ ! -e "$i" ] && break;
    if [ -d "$i" ] && [ ! -L "$i" ] && "$MODDIR/overlayfs_system" --test --check-ext4 "$i"; then
        OVERLAYLIST="$i:$OVERLAYLIST"
    fi
done

mkdir -p "$OVERLAYMNT/upper"
rm -rf "$OVERLAYMNT/worker"
mkdir -p "$OVERLAYMNT/worker"

if [ ! -z "$OVERLAYLIST" ]; then
    export OVERLAYLIST="${OVERLAYLIST%:}"
    echo "mount overlayfs list: [$OVERLAYLIST]" >>/cache/overlayfs.log
fi

# overlay_system <writeable-dir>
. "$MODDIR/mode.sh"
"$MODDIR/overlayfs_system" "$OVERLAYMNT" | tee -a /cache/overlayfs.log

if [ ! -z "$MAGISKTMP" ]; then
    mkdir -p "$MAGISKTMP/overlayfs_mnt"
    mount --bind "$OVERLAYMNT" "$MAGISKTMP/overlayfs_mnt"
fi


umount -l "$OVERLAYMNT"
rmdir "$OVERLAYMNT"
umount -l "$MODULEMNT"
rmdir "$MODULEMNT"

rm -rf /dev/.overlayfs_service_unblock
echo "--- Mountinfo (post-fs-data) ---" >>/cache/overlayfs.log
cat /proc/mounts >>/cache/overlayfs.log
(
    # block until /dev/.overlayfs_service_unblock
    while [ ! -e "/dev/.overlayfs_service_unblock" ]; do
        sleep 1
    done
    rm -rf /dev/.overlayfs_service_unblock

    echo "--- Mountinfo (late_start) ---" >>/cache/overlayfs.log
    cat /proc/mounts >>/cache/overlayfs.log
) &

