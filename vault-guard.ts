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
//   - URLs are allowed only for reading public web pages (the host must not
//     resolve to a loopback or private address);
//   - everything else (shell, code eval, subagents, browser, MCP, …) is refused.
//
// Paths are normalized the way omp's expandPath() does before it opens them
// (stray leading ":" or "@", file:// URLs, \\?\ prefixes, "~name", Unicode
// spaces, /c/... and /mnt/c/... drive aliases), so a prefix omp strips cannot
// make an outside path look like a vault-relative one.

import * as dns from "node:dns";
import * as fs from "node:fs";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import * as url from "node:url";

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
const UNICODE_SPACES = /[\u00A0\u2000-\u200A\u202F\u205F\u3000]/g;

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

function isPrivateIp(ip: string): boolean {
	if (net.isIPv4(ip)) {
		const [a, b] = ip.split(".").map(Number);
		return a === 0 || a === 10 || a === 127 || a >= 224 ||
			(a === 192 && b === 168) || (a === 172 && b >= 16 && b <= 31) ||
			(a === 169 && b === 254) || (a === 100 && b >= 64 && b <= 127);
	}
	const v6 = ip.toLowerCase();
	const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(v6);
	if (mapped) return isPrivateIp(mapped[1]);
	return v6 === "::" || v6 === "::1" || v6.startsWith("fe8") || v6.startsWith("fe9") ||
		v6.startsWith("fea") || v6.startsWith("feb") || v6.startsWith("fc") || v6.startsWith("fd") ||
		v6.startsWith("::ffff:");
}

// The host of a readable public web URL, or undefined when the URL is not one.
// DNS is checked separately (see the handler): a public-looking name can still
// point at 127.0.0.1 or the home network.
function publicWebHost(value: string): string | undefined {
	let parsed: URL;
	try {
		parsed = new URL(value);
	} catch {
		return undefined;
	}
	if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return undefined;
	const host = parsed.hostname.toLowerCase().replace(/\.+$/, "");
	if (host.startsWith("[") || net.isIPv6(host)) return undefined; // IPv6 literals: not worth the risk
	if (!host.includes(".") || /\.(local|localhost|internal|lan|home|arpa)$/.test(host)) return undefined;
	if (net.isIPv4(host) && isPrivateIp(host)) return undefined;
	return host;
}

// Mirrors omp's expandPath() + Windows drive-alias mapping, so the guard
// judges the same path omp will open.
function ompExpand(value: string): string {
	let v = value;
	if (/^:(?=[/\\~]|\.\.?[/\\]|[A-Za-z]:)/.test(v)) v = v.slice(1);
	if (v.startsWith("@")) {
		const rest = v.slice(1);
		if (rest.startsWith("/") || rest.startsWith("~") || path.win32.isAbsolute(rest) || URL_SCHEME.test(rest)) v = rest;
	}
	v = v.replace(UNICODE_SPACES, " ");
	if (v.toLowerCase().startsWith("file://")) {
		try {
			v = url.fileURLToPath(v);
		} catch {
			// left as is; it is then judged as a URL and refused
		}
	}
	if (/^\\\\\?\\UNC\\/i.test(v)) v = "\\\\" + v.slice(8);
	else if (/^\\\\[?.]\\/.test(v)) v = v.slice(4);
	if (v === "~") v = os.homedir();
	else if (v.startsWith("~")) v = P.join(os.homedir(), v.slice(1));
	if (IS_WINDOWS) {
		const alias = /^\/(?:mnt\/)?([A-Za-z])(?:\/(.*))?$/.exec(v);
		if (alias) v = `${alias[1].toUpperCase()}:\\${(alias[2] ?? "").split("/").filter(Boolean).join("\\")}`;
	}
	return v;
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
	const v = ompExpand(value.trim());
	if (/^[/\\]+$/.test(v)) return P.resolve(cwd); // omp treats a bare slash as the session folder
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
		// Judge both the raw text and what omp's normalization turns it into.
		for (const form of new Set([t, ompExpand(t)])) {
			out.add(form);
			out.add(globBase(form));
			const selector = /^(.*[^:\\/]):[^:\\/]*$/.exec(form);
			if (selector && !/^[a-z]$/i.test(selector[1])) out.add(selector[1]);
			// Brace alternatives ({a,b}) are judged one by one, so "{../x,y}" cannot hide "../x".
			for (const alt of form.match(/\{[^{}]*\}/g) ?? []) {
				for (const part of alt.slice(1, -1).split(",")) {
					const expanded = form.replace(alt, part);
					out.add(expanded);
					out.add(globBase(expanded));
				}
			}
		}
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

interface Verdict {
	reason?: string;
	/** Hosts of public URLs the call reads; their DNS answers still need checking. */
	hosts: string[];
}

function check(toolName: string, input: Record<string, unknown>, cwd: string): Verdict {
	const deny = (reason: string): Verdict => ({ reason, hosts: [] });
	const hosts: string[] = [];
	const tool = toolName.toLowerCase();
	if (PATHLESS_TOOLS.has(tool)) return { hosts };
	const writes = WRITE_TOOLS.has(tool);
	if (!writes && !READ_TOOLS.has(tool)) {
		return deny(`инструмент «${toolName}» отключён: помощник работает только с заметками`);
	}

	const raw: string[] = [];
	collectPaths(input, raw);
	if (tool === "edit") raw.push(...patchPaths(input));
	if (raw.length === 0) {
		if (writes) return deny("не удалось определить, какой файл меняется");
		raw.push("."); // search tools default to the session folder
	}

	for (const value of raw) {
		for (const candidate of candidates(value, cwd)) {
			if (URL_SCHEME.test(candidate)) {
				const host = writes ? undefined : publicWebHost(candidate);
				if (host) {
					hosts.push(host);
					continue;
				}
				return deny(`адрес «${candidate}» недоступен: разрешены только файлы в папке заметок и публичные сайты`);
			}
			const absolute = toAbsolute(candidate, cwd);
			if (!insideVault(absolute)) {
				return deny(`путь «${candidate}» вне папки заметок (${VAULT})`);
			}
			if (writes && isProtected(absolute)) {
				return deny(`«${candidate}» — служебный файл, его менять нельзя`);
			}
		}
	}
	return { hosts };
}

// Refuses a host whose DNS answer includes a loopback or private address, so a
// name like "127.0.0.1.nip.io" cannot reach Ollama, ComfyUI or the router.
// A failed lookup is refused too.
async function privateHostReason(hosts: string[]): Promise<string | undefined> {
	for (const host of new Set(hosts)) {
		let addresses: { address: string }[];
		try {
			addresses = net.isIP(host) ? [{ address: host }] : await dns.promises.lookup(host, { all: true });
		} catch {
			return `не удалось проверить адрес сайта «${host}»`;
		}
		if (addresses.some(a => isPrivateIp(a.address))) {
			return `сайт «${host}» ведёт на этот компьютер или домашнюю сеть`;
		}
	}
	return undefined;
}

export default function vaultGuard(pi: any): void {
	pi.on("tool_call", async (event: any, ctx: any) => {
		const cwd = typeof ctx?.cwd === "string" && ctx.cwd ? ctx.cwd : process.cwd();
		const verdict = check(String(event?.toolName ?? ""), (event?.input ?? {}) as Record<string, unknown>, cwd);
		const reason = verdict.reason ?? (await privateHostReason(verdict.hosts));
		if (reason) return { block: true, reason: `Заблокировано: ${reason}.` };
	});
}

export { check as _checkForTests, privateHostReason as _privateHostReasonForTests };
