// Vault guard for Oh My Pi: the agent may only touch files inside the notes vault.
//
// setup.ps1 installs this as ~/.omp/agent/hooks/pre/vault-guard.ts (outside the
// vault, so the agent cannot edit its own guard) with __VAULT__ replaced by the
// vault path. omp runs every `tool_call` handler before a tool executes; returning
// { block: true } refuses the call, and a handler that throws also refuses it.
//
// Policy, deny by default:
//   - only the file tools below are allowed, and every path they name must
//     resolve inside the vault (symlinks and junctions are followed);
//   - inside the vault, hidden folders (.omp, .obsidian, …) and agent config
//     files are read-only: writing there could plant hooks or MCP servers;
//   - URLs are allowed only for reading public web pages;
//   - everything else (shell, code eval, subagents, browser, MCP, …) is refused.

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const VAULT = __VAULT__;

const IS_WINDOWS = process.platform === "win32";
const P = IS_WINDOWS ? path.win32 : path.posix;

// Tools that take no filesystem path at all.
const PATHLESS_TOOLS = new Set(["ask", "todo", "think", "yield", "goal", "web_search", "context_notes", "new_context", "wait"]);
// Tools that read the paths they name.
const READ_TOOLS = new Set(["read", "grep", "glob", "find"]);
// Tools that create or change the paths they name.
const WRITE_TOOLS = new Set(["write", "edit"]);

// Argument keys that carry paths, at any depth of the tool input.
const PATH_KEYS = new Set([
	"path", "paths", "file", "files", "file_path", "filepath", "filePath", "cwd", "dir",
	"directory", "root", "target", "destination", "dest", "rename", "from", "to", "source",
]);

// Files that steer the agent itself; writing them is refused anywhere in the vault.
const PROTECTED_NAMES = new Set(["agents.md", "claude.md", "gemini.md", "rules.md", "system.md", "mcp.json"]);

const GLOB_CHARS = /[*?[\]{}]/;
const URL_SCHEME = /^[a-z][a-z0-9+.-]*:\/\//i;

function fold(p: string): string {
	return IS_WINDOWS ? p.toLowerCase() : p;
}

// Resolves symlinks/junctions through the nearest existing ancestor, so a link
// inside the vault that points elsewhere is judged by where it really leads.
function realish(absolute: string): string {
	let current = absolute;
	const rest: string[] = [];
	for (;;) {
		if (fs.existsSync(current)) {
			const real = fs.realpathSync.native(current);
			return rest.length ? P.join(real, ...rest.reverse()) : real;
		}
		const parent = P.dirname(current);
		if (parent === current) return absolute;
		rest.push(P.basename(current));
		current = parent;
	}
}

const VAULT_REAL = fold(realish(P.resolve(VAULT)));

function insideVault(absolute: string): boolean {
	const real = fold(realish(absolute));
	const rel = P.relative(VAULT_REAL, real);
	return rel === "" || (!rel.startsWith("..") && !P.isAbsolute(rel));
}

function isProtected(absolute: string): boolean {
	const rel = P.relative(VAULT_REAL, fold(realish(absolute)));
	const parts = rel.split(/[\\/]+/).filter(Boolean);
	return parts.some(part => part.startsWith(".")) || PROTECTED_NAMES.has((parts[parts.length - 1] ?? "").toLowerCase());
}

function isPublicWebUrl(value: string): boolean {
	let url: URL;
	try {
		url = new URL(value);
	} catch {
		return false;
	}
	if (url.protocol !== "http:" && url.protocol !== "https:") return false;
	let host = url.hostname.toLowerCase();
	if (host.startsWith("[")) return false; // IPv6 literals: not worth the risk
	if (!host.includes(".") || /\.(local|localhost|internal|lan|home)$/.test(host)) return false;
	const v4 = /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(host);
	if (v4) {
		const [a, b] = [Number(v4[1]), Number(v4[2])];
		if (a === 0 || a === 10 || a === 127 || a >= 224) return false;
		if (a === 192 && b === 168) return false;
		if (a === 172 && b >= 16 && b <= 31) return false;
		if (a === 169 && b === 254) return false;
		if (a === 100 && b >= 64 && b <= 127) return false;
	}
	return true;
}

// The folder a glob actually walks: everything before the first wildcard segment.
function globBase(value: string): string {
	const parts = value.split(/[\\/]/);
	const index = parts.findIndex(part => GLOB_CHARS.test(part));
	if (index === -1) return value;
	const base = parts.slice(0, index).join("/");
	return base === "" ? (value.startsWith("/") || value.startsWith("\\") ? "/" : ".") : base;
}

function toAbsolute(value: string, cwd: string): string {
	let v = value.trim();
	if (v === "/" || v === "\\") return P.resolve(cwd); // omp treats a bare slash as the session folder
	if (v === "~" || v.startsWith("~/") || v.startsWith("~\\")) v = P.join(os.homedir(), v.slice(1));
	return P.resolve(cwd, v);
}

// Every way omp might read one path argument: the whole string, list parts
// (`a; b`, and comma/space lists for paths that do not exist), the glob base,
// and the string without a trailing `:selector` (`notes.md:10-20`, `a.zip:inner`).
function candidates(value: string, cwd: string): string[] {
	const out = new Set<string>();
	const add = (v: string) => {
		const t = v.trim();
		if (!t) return;
		out.add(t);
		out.add(globBase(t));
		const selector = /^(.*[^:\\/]):[^:\\/]*$/.exec(t);
		if (selector && !/^[a-z]$/i.test(selector[1])) out.add(selector[1]);
	};
	for (const entry of value.split(";")) {
		add(entry);
		// omp splits comma/space lists only into parts that exist; a missing part reads nothing.
		if (!fs.existsSync(toAbsolute(entry, cwd))) {
			for (const part of entry.split(/[,\s]+/)) {
				if (part.trim() && fs.existsSync(toAbsolute(part, cwd))) add(part);
			}
		}
	}
	return [...out];
}

function collectPaths(input: unknown, found: string[], key = ""): void {
	if (typeof input === "string") {
		if (PATH_KEYS.has(key)) found.push(input);
		return;
	}
	if (Array.isArray(input)) {
		for (const item of input) collectPaths(item, found, key);
		return;
	}
	if (input && typeof input === "object") {
		for (const [k, v] of Object.entries(input)) collectPaths(v, found, k);
	}
}

// Paths named inside an edit patch body: `[path#TAG]` sections and
// `*** Add/Update/Delete/Edit File:` / `*** Move to:` headers.
function patchPaths(input: Record<string, unknown>): string[] {
	const text = typeof input.input === "string" ? input.input : "";
	const out: string[] = [];
	for (const m of text.matchAll(/^\s*\[([^\]#\n]+)#[^\]\n]*\]/gm)) out.push(m[1]);
	for (const m of text.matchAll(/^\*\*\* (?:Add|Update|Delete|Edit) File:\s*(.+)$/gm)) out.push(m[1]);
	for (const m of text.matchAll(/^\*\*\* Move to:\s*(.+)$/gm)) out.push(m[1]);
	return out;
}

function check(toolName: string, input: Record<string, unknown>, cwd: string): string | undefined {
	const tool = toolName.toLowerCase();
	if (PATHLESS_TOOLS.has(tool)) return undefined;
	const writes = WRITE_TOOLS.has(tool);
	if (!writes && !READ_TOOLS.has(tool)) {
		return `инструмент «${toolName}» отключён: помощник работает только с заметками`;
	}

	const raw: string[] = [];
	collectPaths(input, raw);
	if (tool === "edit") raw.push(...patchPaths(input));
	if (raw.length === 0) {
		if (writes) return "не удалось определить, какой файл меняется";
		raw.push("."); // search tools default to the session folder
	}

	for (const value of raw) {
		for (const candidate of candidates(value, cwd)) {
			if (URL_SCHEME.test(candidate)) {
				if (!writes && isPublicWebUrl(candidate)) continue;
				return `адрес «${candidate}» недоступен: разрешены только файлы в папке заметок и публичные сайты`;
			}
			const absolute = toAbsolute(candidate, cwd);
			if (!insideVault(absolute)) {
				return `путь «${candidate}» вне папки заметок (${VAULT})`;
			}
			if (writes && isProtected(absolute)) {
				return `«${candidate}» — служебный файл, его менять нельзя`;
			}
		}
	}
	return undefined;
}

export default function vaultGuard(pi: any): void {
	pi.on("tool_call", async (event: any, ctx: any) => {
		const cwd = typeof ctx?.cwd === "string" && ctx.cwd ? ctx.cwd : process.cwd();
		const reason = check(String(event?.toolName ?? ""), (event?.input ?? {}) as Record<string, unknown>, cwd);
		if (reason) return { block: true, reason: `Заблокировано: ${reason}.` };
	});
}

export { check as _checkForTests };
