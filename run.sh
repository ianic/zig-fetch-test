#! /bin/bash

function run {
	# fill cache
	rm -rf $cache
	$zig_bin build --global-cache-dir $cache
}

zig_bin=${1:-~/Code/zig/build/stage3/bin/zig}

echo master build $zig_bin
cache=./zig-global-cache-master
run

echo release
zig_bin=zig
cache=./zig-global-cache-release
run

echo compare master and release
diff --brief --recursive --no-dereference zig-global-cache-release/p zig-global-cache-master/p
