const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const add_paths = b.option(
        bool,
        "add-paths",
        "add apple SDK paths from Xcode installation",
    ) orelse true;

    const sysroot: std.Build.LazyPath = .{
        .cwd_relative = std.zig.system.darwin.getSdk(b.allocator, &target.result).?,
    };

    const translate_header = b.addTranslateC(.{
        .root_source_file = b.path("zig-objc.h"),
        .optimize = optimize,
        .target = target,
    });
    translate_header.addSystemIncludePath(sysroot.path(b, "usr/include"));

    switch (target.result.cpu.arch) {
        .powerpc => translate_header.defineCMacro("TARGET_CPU_PPC", null),
        .powerpc64 => translate_header.defineCMacro("TARGET_CPU_PPC64", null),
        .m68k => translate_header.defineCMacro("TARGET_CPU_68K", null),
        .x86 => translate_header.defineCMacro("TARGET_CPU_X86", null),
        .x86_64 => translate_header.defineCMacro("TARGET_CPU_X86_64", null),
        .arm => translate_header.defineCMacro("TARGET_CPU_ARM", null),
        .aarch64 => translate_header.defineCMacro("TARGET_CPU_ARM64", null),
        .mips => translate_header.defineCMacro("TARGET_CPU_MIPS", null),
        .sparc => translate_header.defineCMacro("TARGET_CPU_SPARC", null),
        .alpha => translate_header.defineCMacro("TARGET_CPU_ALPHA", null),
        else => @panic("unsupported architecture"),
    }

    if (target.result.os.tag.isDarwin()) {
        translate_header.defineCMacro("TARGET_OS_MAC", null);
        if (target.result.abi == .simulator)
            translate_header.defineCMacro("TARGET_OS_SIMULATOR", null);
    }

    switch (target.result.os.tag) {
        .windows => translate_header.defineCMacro("TARGET_OS_WINDOWS", null),
        .linux => translate_header.defineCMacro("TARGET_OS_LINUX", null),
        .macos => translate_header.defineCMacro("TARGET_OS_OSX", null),
        inline .ios, .maccatalyst => |tag| {
            translate_header.defineCMacro("TARGET_OS_IPHONE", null);
            translate_header.defineCMacro("TARGET_OS_IOS", null);
            if (tag == .maccatalyst)
                translate_header.defineCMacro("TARGET_OS_MACCATALYST", null);
        },
        inline .tvos, .watchos, .visionos, .driverkit => |tag| {
            translate_header.defineCMacro("TARGET_OS_IPHONE", null);
            const target_os = std.mem.cutSuffix(u8, @tagName(tag), "os") orelse @tagName(tag);
            const upper = std.ascii.allocUpperString(b.allocator, target_os) catch @panic("OOM");
            translate_header.defineCMacro(b.fmt("TARGET_OS_{s}", .{upper}), null);
        },
        else => @panic("unsupported OS"),
    }

    switch (target.result.cpu.arch.endian()) {
        .big => translate_header.defineCMacro("TARGET_RT_BIG_ENDIAN", null),
        .little => translate_header.defineCMacro("TARGET_RT_LITTLE_ENDIAN", null),
    }

    if (target.result.ptrBitWidth() == 64)
        translate_header.defineCMacro("TARGET_RT_64_BIT", null);

    // TODO: TARGET_RT_MAC_CFM
    if (target.result.os.tag.isDarwin() and target.result.ofmt == .macho)
        translate_header.defineCMacro("TARGET_RT_MAC_MACHO", null);

    const translated_header = translate_header.createModule();

    const objc = b.addModule("objc", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    objc.addImport("objc.h", translated_header);
    if (add_paths) try addAppleSDK(b, objc);
    objc.linkSystemLibrary("objc", .{});
    objc.linkFramework("Foundation", .{});

    const tests = b.addTest(.{
        .name = "objc-test",
        .root_module = objc,
    });
    tests.linkFramework("AppKit"); // Required by 'tagged pointer' test.
    b.installArtifact(tests);

    const test_step = b.step("test", "Run tests");
    const tests_run = b.addRunArtifact(tests);
    test_step.dependOn(&tests_run.step);
}

/// Add the SDK framework, include, and library paths to the given module.
/// The module target is used to determine the SDK to use so it must have
/// a resolved target.
///
/// The Apple SDK is determined based on the build target and found using
/// xcrun, so it requires a valid Xcode installation.
pub fn addAppleSDK(b: *std.Build, m: *std.Build.Module) !void {
    // The cache. This always uses b.allocator and never frees memory
    // (which is idiomatic for a Zig build exe).
    const Cache = struct {
        const Key = struct {
            arch: std.Target.Cpu.Arch,
            os: std.Target.Os.Tag,
            abi: std.Target.Abi,
        };

        var map: std.AutoHashMapUnmanaged(Key, ?[]const u8) = .{};
    };

    const target = m.resolved_target.?.result;
    const gop = try Cache.map.getOrPut(b.allocator, .{
        .arch = target.cpu.arch,
        .os = target.os.tag,
        .abi = target.abi,
    });

    // This executes `xcrun` to get the SDK path. We don't want to execute
    // this multiple times so we cache the value.
    if (!gop.found_existing) {
        gop.value_ptr.* = std.zig.system.darwin.getSdk(
            b.allocator,
            &m.resolved_target.?.result,
        );
    }

    // The active SDK we want to use
    const path = gop.value_ptr.* orelse return switch (target.os.tag) {
        // Return a more descriptive error. Before we just returned the
        // generic error but this was confusing a lot of community members.
        // It costs us nothing in the build script to return something better.
        .macos => error.XcodeMacOSSDKNotFound,
        .ios => error.XcodeiOSSDKNotFound,
        .tvos => error.XcodeTVOSSDKNotFound,
        .watchos => error.XcodeWatchOSSDKNotFound,
        else => error.XcodeAppleSDKNotFound,
    };
    m.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ path, "/System/Library/Frameworks" }) });
    m.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ path, "/usr/include" }) });
    m.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ path, "/usr/lib" }) });
}
