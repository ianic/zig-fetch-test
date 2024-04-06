const std = @import("std");
const Package = @import("zig-src/Package.zig");
const Fetch = Package.Fetch;
const ThreadPool = std.Thread.Pool;
const Cache = std.Build.Cache;
const fs = std.fs;
const Manifest = Package.Manifest;
const testing = std.testing;

pub fn main() !void {}

// Builds Fetch with required dependencies, clears dependencies on deinit().
const TestFetchBuilder = struct {
    thread_pool: ThreadPool,
    http_client: std.http.Client,
    global_cache_directory: Cache.Directory,
    progress: std.Progress,
    job_queue: Fetch.JobQueue,
    fetch: Fetch,

    fn build(
        self: *TestFetchBuilder,
        allocator: std.mem.Allocator,
        cache_parent_dir: std.fs.Dir,
        path_or_url: []const u8,
    ) !*Fetch {
        const cache_dir = try cache_parent_dir.makeOpenPath("zig-global-cache", .{});

        try self.thread_pool.init(.{ .allocator = allocator });
        self.http_client = .{ .allocator = allocator };
        self.global_cache_directory = .{ .handle = cache_dir, .path = null };

        self.progress = .{ .dont_print_on_dumb = true };

        self.job_queue = .{
            .http_client = &self.http_client,
            .thread_pool = &self.thread_pool,
            .global_cache = self.global_cache_directory,
            .recursive = false,
            .read_only = false,
            .debug_hash = false,
            .work_around_btrfs_bug = false,
        };

        self.fetch = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .location = .{ .path_or_url = path_or_url },
            .location_tok = 0,
            .hash_tok = 0,
            .name_tok = 0,
            .lazy_status = .eager,
            .parent_package_root = Cache.Path{ .root_dir = Cache.Directory{
                .handle = std.fs.cwd(),
                .path = null,
            } },
            .parent_manifest_ast = null,
            .prog_node = self.progress.start("Fetch", 0),
            .job_queue = &self.job_queue,
            .omit_missing_hash_error = true,
            .allow_missing_paths_field = false,

            .package_root = undefined,
            .error_bundle = undefined,
            .manifest = null,
            .manifest_ast = undefined,
            .actual_hash = undefined,
            .has_build_zig = false,
            .oom_flag = false,
            .module = null,
        };
        return &self.fetch;
    }

    fn deinit(self: *TestFetchBuilder) void {
        self.fetch.deinit();
        self.job_queue.deinit();
        self.fetch.prog_node.end();
        self.global_cache_directory.handle.close();
        self.http_client.deinit();
        self.thread_pool.deinit();
    }

    fn packageDir(self: *TestFetchBuilder) !fs.Dir {
        const root = self.fetch.package_root;
        return try root.root_dir.handle.openDir(root.sub_path, .{ .iterate = true });
    }

    // Test helper, asserts thet package dir constains expected_files.
    // expected_files must be sorted.
    fn expectPackageFiles(self: *TestFetchBuilder, expected_files: []const []const u8) !void {
        var package_dir = try self.packageDir();
        defer package_dir.close();

        var actual_files: std.ArrayListUnmanaged([]u8) = .{};
        defer actual_files.deinit(std.testing.allocator);
        defer for (actual_files.items) |file| std.testing.allocator.free(file);
        var walker = try package_dir.walk(std.testing.allocator);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            // std.debug.print("{s}\n", .{entry.path});
            const path = try std.testing.allocator.dupe(u8, entry.path);
            errdefer std.testing.allocator.free(path);
            std.mem.replaceScalar(u8, path, std.fs.path.sep, '/');
            try actual_files.append(std.testing.allocator, path);
        }
        std.mem.sortUnstable([]u8, actual_files.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        try std.testing.expectEqual(expected_files.len, actual_files.items.len);
        for (expected_files, 0..) |file_name, i| {
            try std.testing.expectEqualStrings(file_name, actual_files.items[i]);
        }
        try std.testing.expectEqualDeep(expected_files, actual_files.items);
    }

    // Test helper, asserts that fetch has failed with `msg` error message.
    fn expectFetchErrors(self: *TestFetchBuilder, notes_len: usize, msg: []const u8) !void {
        var errors = try self.fetch.error_bundle.toOwnedBundle("");
        defer errors.deinit(std.testing.allocator);

        const em = errors.getErrorMessage(errors.getMessages()[0]);
        try std.testing.expectEqual(1, em.count);
        if (notes_len > 0) {
            try std.testing.expectEqual(notes_len, em.notes_len);
        }
        var al = std.ArrayList(u8).init(std.testing.allocator);
        defer al.deinit();
        try errors.renderToWriter(.{ .ttyconf = .no_color }, al.writer());
        try std.testing.expectEqualStrings(msg, al.items);
    }
};

// Using test cases from: https://github.com/ianprime0509/pathological-packages
// repository. Depends on existence of the FAT32 file system at /tmp/fat32.mnt
// (look at the fat32TmpDir function below how to create it). If that folder is
// not found test will be skipped. Folder is in FAT32 file system because it is
// case insensitive and and does not support symlinks.
test "pathological packages" {
    const gpa = std.testing.allocator;
    var buf: [128]u8 = undefined;

    const urls: []const []const u8 = &.{
        "https://github.com/ianprime0509/pathological-packages/archive/{s}.tar.gz",
        "git+https://github.com/ianprime0509/pathological-packages#{s}",
    };
    const branches: []const []const u8 = &.{
        "excluded-case-collisions",
        "excluded-symlinks",
        "included-case-collisions",
        "included-symlinks",
    };

    // Expected fetched package files or error message for each combination of url/branch.
    const expected = [_]struct {
        files: []const []const u8 = &.{},
        err_msg: []const u8 = "",
    }{
        // tar
        .{ .files = &.{ "build.zig", "build.zig.zon" } },
        .{ .files = &.{ "build.zig", "build.zig.zon", "main" } },
        .{ .err_msg =
        \\error: unable to unpack tarball
        \\    note: unable to create file 'main': PathAlreadyExists
        \\    note: unable to create file 'subdir/main': PathAlreadyExists
        \\
        },
        .{ .err_msg =
        \\error: unable to unpack tarball
        \\    note: unable to create symlink from 'link' to 'main': AccessDenied
        \\    note: unable to create symlink from 'subdir/link' to 'main': AccessDenied
        \\
        },
        // git
        .{ .files = &.{ "build.zig", "build.zig.zon" } },
        .{ .files = &.{ "build.zig", "build.zig.zon", "main" } },
        .{ .err_msg =
        \\error: unable to unpack packfile
        \\    note: unable to create file 'main': PathAlreadyExists
        \\    note: unable to create file 'subdir/main': PathAlreadyExists
        \\
        },
        .{ .err_msg =
        \\error: unable to unpack packfile
        \\    note: unable to create symlink from 'link' to 'main': AccessDenied
        \\    note: unable to create symlink from 'subdir/link' to 'main': AccessDenied
        \\
        },
    };

    var expected_no: usize = 0;
    inline for (urls) |url_fmt| {
        var tmp = try fat32TmpDir();
        defer tmp.cleanup();

        for (branches) |branch| {
            defer expected_no += 1;
            const url = try std.fmt.bufPrint(&buf, url_fmt, .{branch});
            // std.debug.print("fetching url: {s}\n", .{url});

            var fb: TestFetchBuilder = undefined;
            var fetch = try fb.build(gpa, tmp.dir, url);
            defer fb.deinit();

            const ex = expected[expected_no];
            if (ex.err_msg.len > 0) {
                try std.testing.expectError(error.FetchFailed, fetch.run());
                try fb.expectFetchErrors(0, ex.err_msg);
            } else {
                try fetch.run();
                try fb.expectPackageFiles(ex.files);
            }
        }
    }
}

// Using logic from std.testing.tmpDir() to make temporary directory at specific
// location.
//
// This assumes FAT32 file system in /tmp/fat32.mnt folder,
// created with something like this:
// $ cd /tmp && fallocate -l 1M fat32.fs && mkfs.fat -F32 fat32.fs &&  mkdir fat32.mnt && sudo mount -o rw,umask=0000 fat32.fs fat32.mnt
//
// To remove that folder:
// $ cd /tmp && sudo umount fat32.mnt && rm -rf fat32.mnt fat32.fs
//
pub fn fat32TmpDir() !std.testing.TmpDir {
    const fat32fs_path = "/tmp/fat32.mnt/";

    const random_bytes_count = 12;
    var random_bytes: [random_bytes_count]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    var sub_path: [std.fs.base64_encoder.calcSize(random_bytes_count)]u8 = undefined;
    _ = std.fs.base64_encoder.encode(&sub_path, &random_bytes);

    const parent_dir = std.fs.openDirAbsolute(fat32fs_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    const dir = parent_dir.makeOpenPath(&sub_path, .{}) catch
        @panic("unable to make tmp dir for testing: unable to make and open the tmp dir");

    return .{
        .dir = dir,
        .parent_dir = parent_dir,
        .sub_path = sub_path,
    };
}

test "fetch build.zig.zon" {
    try fetchManifest("build.zig.zon");
}

test "fetch git_packages.zig.zon" {
    if (true) return error.SkipZigTest;
    try fetchManifest("git_packages.zig.zon");
}

fn fetchManifest(manifest_name: []const u8) !void {
    const gpa = testing.allocator;
    const build_zig_zon = try std.fs.cwd().readFileAllocOptions(
        gpa,
        manifest_name,
        Manifest.max_bytes,
        null,
        1,
        0,
    );
    defer gpa.free(build_zig_zon);

    var ast = try std.zig.Ast.parse(gpa, build_zig_zon, .zon);
    defer ast.deinit(gpa);

    try testing.expect(ast.errors.len == 0);

    var manifest = try Manifest.parse(gpa, ast, .{});
    defer manifest.deinit(gpa);

    try testing.expect(manifest.errors.len == 0);
    //try testing.expectEqual(15, manifest.dependencies.count());

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    for (manifest.dependencies.values(), 0..) |dep, i| {
        var fb: TestFetchBuilder = undefined;
        const path_or_url = switch (dep.location) {
            .url => |u| u,
            .path => |p| p,
        };
        std.debug.print("fetch {}: {s}\n", .{ i, path_or_url });

        var fetch = try fb.build(gpa, tmp.dir, path_or_url);
        defer fb.deinit();
        try fetch.run();

        if (i <= 16) {
            // guard against: https://github.com/ziglang/zig/issues/19561
            //                https://github.com/ziglang/zig/issues/19557
            try testing.expect(fetch.has_build_zig == !(i == 2 or i == 11 or i == 16));
        }

        try testing.expectEqualStrings(
            dep.hash.?,
            &Manifest.hexDigest(fetch.actual_hash),
        );
    }
}

test "set executable bit based on file content" {
    if (!std.fs.has_executable_bit) return error.SkipZigTest;
    const gpa = testing.allocator;
    const path = "assets/executables.tar.gz";
    // $ tar -tvf executables.tar.gz
    // drwxrwxr-x        0  executables/
    // -rwxrwxr-x      170  executables/hello
    // lrwxrwxrwx        0  executables/hello_ln -> hello
    // -rw-rw-r--        0  executables/file1
    // -rw-rw-r--       17  executables/script_with_shebang_without_exec_bit
    // -rwxrwxr-x        7  executables/script_without_shebang
    // -rwxrwxr-x       17  executables/script

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fb: TestFetchBuilder = undefined;
    var fetch = try fb.build(gpa, tmp.dir, path);
    defer fb.deinit();

    try fetch.run();
    try testing.expectEqualStrings(
        "1220fecb4c06a9da8673c87fe8810e15785f1699212f01728eadce094d21effeeef3",
        &Manifest.hexDigest(fetch.actual_hash),
    );

    var out = try fb.packageDir();
    defer out.close();
    const S = std.posix.S;
    // expect executable bit not set
    try testing.expect((try out.statFile("file1")).mode & S.IXUSR == 0);
    try testing.expect((try out.statFile("script_without_shebang")).mode & S.IXUSR == 0);
    // expect executable bit set
    try testing.expect((try out.statFile("hello")).mode & S.IXUSR != 0);
    try testing.expect((try out.statFile("script")).mode & S.IXUSR != 0);
    try testing.expect((try out.statFile("script_with_shebang_without_exec_bit")).mode & S.IXUSR != 0);
    try testing.expect((try out.statFile("hello_ln")).mode & S.IXUSR != 0);

    //
    // $ ls -al zig-cache/tmp/OCz9ovUcstDjTC_U/zig-global-cache/p/1220fecb4c06a9da8673c87fe8810e15785f1699212f01728eadce094d21effeeef3
    // -rw-rw-r-- 1     0 Apr   file1
    // -rwxrwxr-x 1   170 Apr   hello
    // lrwxrwxrwx 1     5 Apr   hello_ln -> hello
    // -rwxrwxr-x 1    17 Apr   script
    // -rw-rw-r-- 1     7 Apr   script_without_shebang
    // -rwxrwxr-x 1    17 Apr   script_with_shebang_without_exec_bit
}
