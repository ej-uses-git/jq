const std = @import("std");
const LinkMode = std.builtin.LinkMode;
const ConfigHeaderExt = @import("tools/ConfigHeaderExt.zig");

const build_zon = @import("build.zig.zon");
const version = std.SemanticVersion.parse(build_zon.version) catch @compileError("invalid version");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const linkage = b.option(LinkMode, "linkage", "Linkage to use for libjq (default: static)") orelse .static;
    const with_oniguruma = b.option(bool, "with-oniguruma", "Build with the oniguruma dependency") orelse true;
    const enable_decnum = b.option(bool, "enable-decnum", "Build with decimal number support (default: true)") orelse true;
    const build_exe = b.option(bool, "build-exe", "Whether to build the final executable (default: true)") orelse true;

    const oniguruma = b.dependency("oniguruma", .{
        .target = target,
        .optimize = optimize,
        .linkage = linkage,
    });

    const jq_h = b.addInstallHeaderFile(b.path("src/jq.h"), "jq.h");
    b.getInstallStep().dependOn(&jq_h.step);
    const jv_h = b.addInstallHeaderFile(b.path("src/jv.h"), "jv.h");
    b.getInstallStep().dependOn(&jv_h.step);

    b.installFile("README.md", "share/doc/jq/README.md");
    b.installFile("AUTHORS", "share/doc/jq/AUTHORS");
    b.installFile("COPYING", "share/doc/jq/COPYING");
    b.installFile("NEWS.md", "share/doc/jq/NEWS.md");
    b.installFile("jq.1.prebuilt", "share/man/man1/jq.1");

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });

    const c_flags = cFlags(b, target);
    const config_h = configH(b, target, with_oniguruma, enable_decnum);

    mod.addCSourceFiles(.{
        .files = &.{
            "src/lexer.c",
            "src/parser.c",
            "src/builtin.c",
            "src/bytecode.c",
            "src/compile.c",
            "src/execute.c",
            "src/jq_test.c",
            "src/jv.c",
            "src/jv_alloc.c",
            "src/jv_aux.c",
            "src/jv_dtoa.c",
            "src/jv_file.c",
            "src/jv_parse.c",
            "src/jv_print.c",
            "src/jv_unicode.c",
            "src/linker.c",
            "src/locfile.c",
            "src/util.c",
            "src/jv_dtoa_tsd.c",
            "vendor/decNumber/decContext.c",
            "vendor/decNumber/decNumber.c",
        },
        .flags = c_flags,
    });
    mod.addIncludePath(b.path("."));
    mod.addIncludePath(b.path("vendor"));
    mod.addIncludePath(config_h.getOutputDir());

    if (with_oniguruma) {
        mod.addIncludePath(oniguruma.path("src"));
        mod.linkLibrary(oniguruma.artifact("onig"));
    }

    const lib = b.addLibrary(.{
        .name = "jq",
        .root_module = mod,
        .linkage = linkage,
        .version = version,
    });
    dependOnBuiltinInc(b, &lib.step);

    b.installArtifact(lib);

    if (build_exe) {
        const exe = b.addExecutable(.{
            .name = "jq",
            .version = version,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addCSourceFile(.{
            .file = b.path("src/main.c"),
            .flags = c_flags,
        });
        dependOnVersionH(b, &exe.step);
        dependOnConfigOptsInc(b, &exe.step);
        exe.root_module.addIncludePath(b.path("."));
        exe.root_module.addIncludePath(config_h.getOutputDir());
        exe.root_module.linkLibrary(lib);

        if (with_oniguruma) {
            exe.root_module.addIncludePath(oniguruma.path("src"));
            exe.root_module.linkLibrary(oniguruma.artifact("onig"));
        }

        b.installArtifact(exe);
    }

    const gen_lexer_step = b.step("generate-lexer", "Generate lexer.c and lexer.h");
    const gen_lexer = b.addSystemCommand(&.{
        "flex",
        "-o",
        "src/lexer.c",
        "--header-file=src/lexer.h",
        "src/lexer.l",
    });
    gen_lexer_step.dependOn(&gen_lexer.step);

    const gen_parser_step = b.step("generate-parser", "Generate parser.c and parser.h");
    const gen_parser = b.addSystemCommand(&.{
        "bison",
        "-o",
        "src/parser.c",
        "--header=src/parser.h",
        "src/parser.y",
    });
    gen_parser_step.dependOn(&gen_parser.step);
}

fn cFlags(b: *std.Build, target: std.Build.ResolvedTarget) []const []const u8 {
    return struct {
        fn impl(b_: *std.Build, target_: std.Build.ResolvedTarget) ![]const []const u8 {
            const base_flags: []const []const u8 = &.{"--include=config.h"};

            var flags: std.ArrayList([]const u8) = try .initCapacity(b_.allocator, base_flags.len);
            flags.appendSliceAssumeCapacity(base_flags);

            if (target_.result.os.tag == .windows) {
                try flags.append(b_.allocator, "-municode");
            }

            return flags.items;
        }
    }.impl(b, target) catch @panic("OOM");
}

fn dependOnBuiltinInc(b: *std.Build, step: *std.Build.Step) void {
    const exe = b.addExecutable(.{
        .name = "inc_bytes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/inc_bytes.zig"),
            .target = b.graph.host,
        }),
    });

    const run = b.addRunArtifact(exe);
    run.addFileArg(b.path("src/builtin.jq"));
    run.addArg("-o");
    const builtin_inc = run.addOutputFileArg("builtin.inc");

    const update = b.addUpdateSourceFiles();
    update.addCopyFileToSource(builtin_inc, "src/builtin.inc");

    step.dependOn(&update.step);
}

fn configH(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    with_oniguruma: bool,
    enable_decnum: bool,
) *std.Build.Step.ConfigHeader {
    const config_h = b.addConfigHeader(.{}, .{});

    if (with_oniguruma) {
        config_h.addValue("HAVE_LIBONIG", c_int, 1);
    }
    if (enable_decnum) {
        config_h.addValue("USE_DECNUM", c_int, 1);
    }

    switch (target.result.cpu.arch.endian()) {
        .big => config_h.addValue("IEEE_MC68k", c_int, 1),
        .little => config_h.addValue("IEEE_8087", c_int, 1),
    }

    const exe = b.addExecutable(.{
        .name = "configquery",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/configquery.zig"),
            .target = b.graph.host,
        }),
    });

    const run = b.addRunArtifact(exe);
    run.addArg("--zig-exe");
    run.addArg(b.graph.zig_exe);
    if (b.cache_root.path) |cache_root| {
        run.addArg("--cache-dir");
        run.addArg(cache_root);
    }
    run.addArg("-target");
    run.addArg(target.query.zigTriple(b.allocator) catch @panic("OOM"));
    run.addArg("-mcpu");
    run.addArg(target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM"));
    run.addFileArg(b.path("config"));
    run.addArg("-o");
    ConfigHeaderExt.addFile(config_h, run.addOutputFileArg("config"));

    return config_h;
}

fn dependOnVersionH(b: *std.Build, step: *std.Build.Step) void {
    const version_h = b.addConfigHeader(.{ .include_path = "version.h" }, .{
        .JQ_VERSION = b.fmt("{f}", .{version}),
    });

    const update = b.addUpdateSourceFiles();
    update.addCopyFileToSource(version_h.getOutputFile(), "src/version.h");
    step.dependOn(&update.step);
}

fn writeBuildOptions(b: *std.Build, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var it = b.user_input_options.iterator();

    var first = true;
    while (it.next()) |entry| {
        if (first) {
            first = false;
        } else {
            try w.writeByte(' ');
        }

        const key = entry.key_ptr.*;
        switch (entry.value_ptr.value) {
            .flag => {
                try w.print("-D{s}", .{key});
            },
            .scalar => |value| {
                try w.print("-D{s}={s}", .{ key, value });
            },
            .list => |list| {
                var first_item = true;
                for (list.items) |value| {
                    if (first_item) {
                        first_item = false;
                    } else {
                        try w.writeByte(' ');
                    }
                    try w.print("-D{s}={s}", .{ key, value });
                }
            },
            .lazy_path => |path| {
                try w.print("-D{s}={s}", .{ key, path.getDisplayName() });
            },
            .lazy_path_list => |list| {
                var first_item = true;
                for (list.items) |value| {
                    if (first_item) {
                        first_item = false;
                    } else {
                        try w.writeByte(' ');
                    }
                    try w.print("-D{s}={s}", .{ key, value.getDisplayName() });
                }
            },
            .map => @panic("TODO: handle maps as CLI arguments"),
        }
    }
}

fn fmtBuildOptions(b: *std.Build) std.fmt.Alt(*std.Build, writeBuildOptions) {
    return .{ .data = b };
}

fn dependOnConfigOptsInc(b: *std.Build, step: *std.Build.Step) void {
    const config_opts_inc = b.addConfigHeader(.{
        .include_path = "config_opts.inc",
    }, .{
        .JQ_CONFIG = b.fmt("{f}", .{fmtBuildOptions(b)}),
    });

    const update = b.addUpdateSourceFiles();
    update.addCopyFileToSource(config_opts_inc.getOutputFile(), "src/config_opts.inc");
    step.dependOn(&update.step);
}
