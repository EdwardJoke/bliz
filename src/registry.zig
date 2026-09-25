//! Agent registry.
//!
//! Ported from the reference tool's agent table, trimmed to the layout facts
//! that matter for discovery: where each agent keeps project-scoped and
//! global-scoped skills. Global paths are written as shell-ish templates so
//! environment overrides (`$CODEX_HOME`, `$CLAUDE_CONFIG_DIR`, `$XDG_CONFIG_HOME`)
//! resolve the same way the reference resolves them.

const std = @import("std");

/// Rough ordering signal for the UI, so shared hub directories and the
/// best-known agents surface first instead of being buried alphabetically.
pub const Tier = enum {
    /// Shared `.agents/skills` style hubs, several agents to one directory.
    hub,
    /// Agents with a dedicated skills directory.
    major,
    /// Everything else.
    other,
};

pub const Agent = struct {
    key: []const u8,
    display: []const u8,
    project: []const u8,
    /// Empty string means the agent is project-only.
    global: []const u8,
    tier: Tier,
};

pub const agents = [_]Agent{
    // --- shared hubs -------------------------------------------------------
    .{ .key = "claude-code", .display = "Claude Code", .project = ".claude/skills", .global = "${CLAUDE_CONFIG_DIR:-~/.claude}/skills", .tier = .major },
    .{ .key = "codebuddy", .display = "CodeBuddy", .project = ".codebuddy/skills", .global = "~/.codebuddy/skills", .tier = .major },
    .{ .key = "workbuddy", .display = "WorkBuddy", .project = ".workbuddy/skills", .global = "~/.workbuddy/skills", .tier = .major },
    .{ .key = "cursor", .display = "Cursor", .project = ".agents/skills", .global = "~/.cursor/skills", .tier = .hub },
    .{ .key = "codex", .display = "Codex", .project = ".agents/skills", .global = "${CODEX_HOME:-~/.codex}/skills", .tier = .hub },
    .{ .key = "gemini-cli", .display = "Gemini CLI", .project = ".agents/skills", .global = "~/.gemini/skills", .tier = .hub },
    .{ .key = "github-copilot", .display = "GitHub Copilot", .project = ".agents/skills", .global = "~/.copilot/skills", .tier = .hub },
    .{ .key = "amp", .display = "Amp", .project = ".agents/skills", .global = "${XDG_CONFIG_HOME:-~/.config}/agents/skills", .tier = .hub },
    .{ .key = "replit", .display = "Replit", .project = ".agents/skills", .global = "${XDG_CONFIG_HOME:-~/.config}/agents/skills", .tier = .hub },
    .{ .key = "universal", .display = "Universal", .project = ".agents/skills", .global = "${XDG_CONFIG_HOME:-~/.config}/agents/skills", .tier = .hub },
    .{ .key = "cline", .display = "Cline", .project = ".agents/skills", .global = "~/.agents/skills", .tier = .hub },
    .{ .key = "zed", .display = "Zed", .project = ".agents/skills", .global = "~/.agents/skills", .tier = .hub },
    .{ .key = "warp", .display = "Warp", .project = ".agents/skills", .global = "~/.agents/skills", .tier = .hub },
    .{ .key = "dexto", .display = "Dexto", .project = ".agents/skills", .global = "~/.agents/skills", .tier = .hub },
    .{ .key = "kimi-code-cli", .display = "Kimi Code CLI", .project = ".agents/skills", .global = "~/.agents/skills", .tier = .hub },
    .{ .key = "loaf", .display = "Loaf", .project = ".agents/skills", .global = "~/.agents/skills", .tier = .hub },
    .{ .key = "sarvam-code", .display = "Sarvam Code", .project = ".agents/skills", .global = "~/.agents/skills", .tier = .hub },
    .{ .key = "deepagents", .display = "Deep Agents", .project = ".agents/skills", .global = "~/.deepagents/agent/skills", .tier = .hub },
    .{ .key = "droid", .display = "Droid", .project = ".agents/skills", .global = "~/.factory/skills", .tier = .hub },
    .{ .key = "firebender", .display = "Firebender", .project = ".agents/skills", .global = "~/.firebender/skills", .tier = .hub },
    .{ .key = "kilo", .display = "Kilo Code", .project = ".agents/skills", .global = "~/.kilo/skills", .tier = .hub },
    .{ .key = "promptscript", .display = "PromptScript", .project = ".agents/skills", .global = "", .tier = .hub },
    .{ .key = "antigravity", .display = "Antigravity", .project = ".agents/skills", .global = "~/.gemini/antigravity/skills", .tier = .hub },
    .{ .key = "antigravity-cli", .display = "Antigravity CLI", .project = ".agents/skills", .global = "~/.gemini/antigravity-cli/skills", .tier = .hub },

    // --- dedicated directories --------------------------------------------
    .{ .key = "opencode", .display = "OpenCode", .project = ".opencode/skills", .global = "${XDG_CONFIG_HOME:-~/.config}/opencode/skills", .tier = .major },
    .{ .key = "openclaw", .display = "OpenClaw", .project = "skills", .global = "~/.openclaw/skills", .tier = .major },
    .{ .key = "windsurf", .display = "Windsurf", .project = ".windsurf/skills", .global = "~/.codeium/windsurf/skills", .tier = .major },
    .{ .key = "continue", .display = "Continue", .project = ".continue/skills", .global = "~/.continue/skills", .tier = .major },
    .{ .key = "qwen-code", .display = "Qwen Code", .project = ".qwen/skills", .global = "~/.qwen/skills", .tier = .major },
    .{ .key = "kiro-cli", .display = "Kiro CLI", .project = ".kiro/skills", .global = "~/.kiro/skills", .tier = .major },
    .{ .key = "junie", .display = "Junie", .project = ".junie/skills", .global = "~/.junie/skills", .tier = .major },
    .{ .key = "roo", .display = "Roo Code", .project = ".roo/skills", .global = "~/.roo/skills", .tier = .major },
    .{ .key = "augment", .display = "Augment", .project = ".augment/skills", .global = "~/.augment/skills", .tier = .major },
    .{ .key = "goose", .display = "Goose", .project = ".goose/skills", .global = "${XDG_CONFIG_HOME:-~/.config}/goose/skills", .tier = .major },
    .{ .key = "crush", .display = "Crush", .project = ".crush/skills", .global = "${XDG_CONFIG_HOME:-~/.config}/crush/skills", .tier = .major },
    .{ .key = "trae", .display = "Trae", .project = ".trae/skills", .global = "~/.trae/skills", .tier = .major },
    .{ .key = "trae-cn", .display = "Trae CN", .project = ".trae/skills", .global = "~/.trae-cn/skills", .tier = .major },
    .{ .key = "qoder", .display = "Qoder", .project = ".qoder/skills", .global = "~/.qoder/skills", .tier = .major },
    .{ .key = "qoder-cn", .display = "Qoder CN", .project = ".qoder/skills", .global = "~/.qoder-cn/skills", .tier = .major },
    .{ .key = "zcode", .display = "ZCode", .project = ".zcode/skills", .global = "~/.zcode/skills", .tier = .major },
    .{ .key = "zencoder", .display = "Zencoder", .project = ".zencoder/skills", .global = "~/.zencoder/skills", .tier = .major },
    .{ .key = "zenflow", .display = "Zenflow", .project = ".zencoder/skills", .global = "~/.zencoder/skills", .tier = .major },
    .{ .key = "mistral-vibe", .display = "Mistral Vibe", .project = ".vibe/skills", .global = "${VIBE_HOME:-~/.vibe}/skills", .tier = .major },
    .{ .key = "openhands", .display = "OpenHands", .project = ".openhands/skills", .global = "~/.openhands/skills", .tier = .major },
    .{ .key = "bob", .display = "IBM Bob", .project = ".bob/skills", .global = "~/.bob/skills", .tier = .major },
    .{ .key = "lingma", .display = "Lingma", .project = ".lingma/skills", .global = "~/.lingma/skills", .tier = .major },
    .{ .key = "minimax-code", .display = "MiniMax Code", .project = ".minimax/skills", .global = "~/.minimax/skills", .tier = .major },
    .{ .key = "kode", .display = "Kode", .project = ".kode/skills", .global = "~/.kode/skills", .tier = .major },
    .{ .key = "iflow-cli", .display = "iFlow CLI", .project = ".iflow/skills", .global = "~/.iflow/skills", .tier = .major },
    .{ .key = "tabnine-cli", .display = "Tabnine CLI", .project = ".tabnine/agent/skills", .global = "~/.tabnine/agent/skills", .tier = .major },
    .{ .key = "rovodev", .display = "Rovo Dev", .project = ".rovodev/skills", .global = "~/.rovodev/skills", .tier = .major },
    .{ .key = "posit-assistant", .display = "Posit Assistant", .project = ".posit/assistant/skills", .global = "~/.posit/assistant/skills", .tier = .major },

    // --- community / long tail --------------------------------------------
    .{ .key = "aider-desk", .display = "AiderDesk", .project = ".aider-desk/skills", .global = "~/.aider-desk/skills", .tier = .other },
    .{ .key = "autohand-code", .display = "Autohand Code CLI", .project = ".autohand/skills", .global = "${AUTOHAND_HOME:-~/.autohand}/skills", .tier = .other },
    .{ .key = "codearts-agent", .display = "CodeArts Agent", .project = ".codeartsdoer/skills", .global = "~/.codeartsdoer/skills", .tier = .other },
    .{ .key = "codemaker", .display = "Codemaker", .project = ".codemaker/skills", .global = "~/.codemaker/skills", .tier = .other },
    .{ .key = "codestudio", .display = "Code Studio", .project = ".codestudio/skills", .global = "~/.codestudio/skills", .tier = .other },
    .{ .key = "command-code", .display = "Command Code", .project = ".commandcode/skills", .global = "~/.commandcode/skills", .tier = .other },
    .{ .key = "cortex", .display = "Cortex Code", .project = ".cortex/skills", .global = "~/.snowflake/cortex/skills", .tier = .other },
    .{ .key = "devin", .display = "Devin for Terminal", .project = ".devin/skills", .global = "${XDG_CONFIG_HOME:-~/.config}/devin/skills", .tier = .other },
    .{ .key = "eve", .display = "Eve", .project = "agent/skills", .global = "", .tier = .other },
    .{ .key = "forgecode", .display = "ForgeCode", .project = ".forge/skills", .global = "~/.forge/skills", .tier = .other },
    .{ .key = "fx", .display = "fx", .project = ".fx/skills", .global = "~/.fx/skills", .tier = .other },
    .{ .key = "grok", .display = "Grok Build", .project = ".grok/skills", .global = "${GROK_HOME:-~/.grok}/skills", .tier = .other },
    .{ .key = "hermes-agent", .display = "Hermes Agent", .project = ".hermes/skills", .global = "${HERMES_HOME:-~/.hermes}/skills", .tier = .other },
    .{ .key = "inference-sh", .display = "inference.sh", .project = ".inferencesh/skills", .global = "~/.inferencesh/skills", .tier = .other },
    .{ .key = "jazz", .display = "Jazz", .project = ".jazz/skills", .global = "~/.jazz/skills", .tier = .other },
    .{ .key = "kimchi", .display = "Kimchi", .project = ".kimchi/skills", .global = "${XDG_CONFIG_HOME:-~/.config}/kimchi/harness/skills", .tier = .other },
    .{ .key = "mcpjam", .display = "MCPJam", .project = ".mcpjam/skills", .global = "~/.mcpjam/skills", .tier = .other },
    .{ .key = "moxby", .display = "Moxby", .project = ".moxby/skills", .global = "~/.moxby/skills", .tier = .other },
    .{ .key = "mux", .display = "Mux", .project = ".mux/skills", .global = "~/.mux/skills", .tier = .other },
    .{ .key = "neovate", .display = "Neovate", .project = ".neovate/skills", .global = "~/.neovate/skills", .tier = .other },
    .{ .key = "ona", .display = "Ona", .project = ".ona/skills", .global = "~/.ona/skills", .tier = .other },
    .{ .key = "pi", .display = "Pi", .project = ".pi/skills", .global = "~/.pi/agent/skills", .tier = .other },
    .{ .key = "pochi", .display = "Pochi", .project = ".pochi/skills", .global = "~/.pochi/skills", .tier = .other },
    .{ .key = "reasonix", .display = "Reasonix", .project = ".reasonix/skills", .global = "~/.reasonix/skills", .tier = .other },
    .{ .key = "terramind", .display = "Terramind", .project = ".terramind/skills", .global = "~/.terramind/skills", .tier = .other },
    .{ .key = "tinycloud", .display = "Tinycloud", .project = ".tinycloud/skills", .global = "~/.tinycloud/skills", .tier = .other },
    .{ .key = "adal", .display = "AdaL", .project = ".adal/skills", .global = "~/.adal/skills", .tier = .other },
    .{ .key = "astrbot", .display = "AstrBot", .project = "data/skills", .global = "~/.astrbot/data/skills", .tier = .other },
};

pub fn find(key: []const u8) ?Agent {
    for (agents) |a| {
        if (std.mem.eql(u8, a.key, key)) return a;
    }
    return null;
}

/// The agent-agnostic hub, used as the anchor when a scope has no agent
/// directory at all. Project-scoped that is `.agents/skills`; globally the
/// reference's canonical location is `~/.agents/skills`.
///
/// This is deliberately not the `universal` row in `agents`: that row's global
/// path follows the per-agent XDG convention, whereas the hub the reference
/// actually creates is `~/.agents/skills`.
pub const universal_hub = Agent{
    .key = "universal",
    .display = "Universal",
    .project = ".agents/skills",
    .global = "~/.agents/skills",
    .tier = .hub,
};

/// Agents whose project directory the reference creates even when the agent has
/// never been used in that project (`createProjectSkillsDirByDefault`). Claude
/// Code is the only agent upstream opts in, and it is the most common target,
/// so honouring it is what puts a bare install where people actually look.
pub fn createsProjectDirByDefault(key: []const u8) bool {
    return std.mem.eql(u8, key, "claude-code");
}

/// True when the agent looks installed on this machine, judged by the directory
/// that holds its global skills rather than by any project directory.
///
/// This is the reference's detection rule, and it is the real reason `npx
/// skills add` succeeds in a fresh checkout while a project-directory scan
/// finds nothing: Claude Code counts as installed because `~/.claude` exists,
/// not because this particular project happens to have a `.claude/skills`.
pub fn installedGlobally(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    agent: Agent,
) bool {
    if (agent.global.len == 0) return false;
    const skills = expand(allocator, agent.global, env) catch return false;
    defer allocator.free(skills);
    // Global paths end in `skills`; the install marker is its parent, e.g.
    // `~/.claude` for `~/.claude/skills`.
    const config_dir = std.fs.path.dirname(skills) orelse return false;
    var d = std.Io.Dir.cwd().openDir(io, config_dir, .{}) catch return false;
    d.close(io);
    return true;
}

pub fn tierLabel(t: Tier) []const u8 {
    return switch (t) {
        .hub => "hub",
        .major => "agent",
        .other => "community",
    };
}

/// Expands `~`, `${VAR}` and `${VAR:-fallback}` in a path template using the
/// process environment. Allocates the result.
pub fn expand(
    allocator: std.mem.Allocator,
    template: []const u8,
    env: *const std.process.Environ.Map,
) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const home = env.get("HOME") orelse "";

    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '~' and (i == 0 or template[i - 1] == '/')) {
            try out.appendSlice(allocator, home);
            i += 1;
            continue;
        }
        if (template[i] == '$' and i + 1 < template.len and template[i + 1] == '{') {
            const close = std.mem.findScalarPos(u8, template, i + 2, '}') orelse {
                try out.append(allocator, template[i]);
                i += 1;
                continue;
            };
            const body = template[i + 2 .. close];
            var name = body;
            var fallback: ?[]const u8 = null;
            if (std.mem.find(u8, body, ":-")) |sep| {
                name = body[0..sep];
                fallback = body[sep + 2 ..];
            }
            if (env.get(name)) |v| {
                if (v.len > 0) {
                    try out.appendSlice(allocator, v);
                } else if (fallback) |f| {
                    try appendExpanded(allocator, &out, f, env);
                }
            } else if (fallback) |f| {
                try appendExpanded(allocator, &out, f, env);
            }
            i = close + 1;
            continue;
        }
        try out.append(allocator, template[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn appendExpanded(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    env: *const std.process.Environ.Map,
) !void {
    const sub = try expand(allocator, text, env);
    defer allocator.free(sub);
    try out.appendSlice(allocator, sub);
}

test "the universal hub is the agent-agnostic .agents/skills" {
    const t = std.testing;
    try t.expectEqualStrings(".agents/skills", universal_hub.project);
    try t.expectEqualStrings("~/.agents/skills", universal_hub.global);
    // The hub has to agree with the rows that share its project directory,
    // otherwise a fallback install would land where no hub agent reads it.
    var shared: usize = 0;
    for (agents) |a| {
        if (std.mem.eql(u8, a.project, universal_hub.project)) shared += 1;
    }
    try t.expect(shared > 10);
}

test "only Claude Code creates its project directory by default" {
    const t = std.testing;
    try t.expect(createsProjectDirByDefault("claude-code"));
    try t.expect(!createsProjectDirByDefault("codex"));
    try t.expect(!createsProjectDirByDefault("universal"));
    // The opted-in agent must actually exist, or the fallback would quietly
    // install to the hub alone and never reach the agent it was meant for.
    try t.expect(find("claude-code") != null);
}

test "installedGlobally keys off the config directory, not a project dir" {
    const t = std.testing;

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    // `installedGlobally` resolves `$HOME`, so the test needs the absolute
    // path of the temp dir, not just the handle.
    const cwd = try std.process.currentPathAlloc(t.io, t.allocator);
    defer t.allocator.free(cwd);
    const home = try std.fs.path.join(t.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer t.allocator.free(home);

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HOME", home);

    const claude = find("claude-code").?;
    // No `~/.claude` yet — and note the project directory existing is
    // irrelevant, which is the whole point of this rule.
    try t.expect(!installedGlobally(t.allocator, t.io, &env, claude));

    try tmp.dir.createDirPath(t.io, ".claude");
    try t.expect(installedGlobally(t.allocator, t.io, &env, claude));

    // A project-only agent has no install marker, so it can never be detected
    // this way; it falls through to the universal hub instead.
    const eve = find("eve").?;
    try t.expectEqualStrings("", eve.global);
    try t.expect(!installedGlobally(t.allocator, t.io, &env, eve));
}
