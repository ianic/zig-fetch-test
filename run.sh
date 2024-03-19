#! /bin/bash


function run {
	# fill cache
	rm -rf $cache
	$zig_bin build --global-cache-dir $cache

	# error BadFileName stripped to empty file name
	#$zig_bin fetch https://chromium.googlesource.com/chromium/tools/depot_tools.git/+archive/7b8f3503d64cf530cff5f4e9e88e3e80e7529b95.tar.gz
	#$zig_bin fetch https://zig-gamedev-pkgs.ams3.cdn.digitaloceanspaces.com/zmath-0.9.6.tar.gz
}

echo master build
zig_bin=~/zig/zig/build/stage3/bin/zig
cache=./zig-global-cache-master
run

echo release
zig_bin=zig
cache=./zig-global-cache-release
run

diff --brief --recursive --no-dereference zig-global-cache-release/p zig-global-cache-master/p
