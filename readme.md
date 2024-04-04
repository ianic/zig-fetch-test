Assumes that Zig repo is found at `../zig` relative from here.

Package.Fetch unit test can be then run by `zig test src/main.zig`.

To run "pathological packages" test FAT32 file system is expected in
/tmp/fat32.fs. Can be created with:

```
$ cd /tmp && fallocate -l 1M fat32.fs && mkfs.fat -F32 fat32.fs &&  mkdir fat32.mnt && sudo mount -o rw,umask=0000 fat32.fs fat32.mnt 
```
and removed with:
```
$ cd /tmp && sudo umount fat32.mnt && rm -rf fat32.mnt fat32.fs
```
Those tests are based on ianprime0509's work in https://github.com/ianprime0509/pathological-packages.


`run.sh` compares package manager fetching of prepared packages from build.zig.zon with locally build zig (master) and zig binary found in path (release).


