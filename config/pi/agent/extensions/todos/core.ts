import crypto from "node:crypto";
import path from "node:path";
import fs from "node:fs/promises";

export interface TodoOrderFields {
	status: string;
	created_at: string;
	assigned_to_session?: string;
}

export interface TodoSearchMatch<T extends TodoOrderFields> {
	todo: T;
	score: number;
}

export interface TodoFileLockInfo {
	id: string;
	pid: number;
	session?: string | null;
	created_at: string;
	token: string;
}

export interface TodoFileLockSnapshot {
	info: TodoFileLockInfo | null;
	mtimeMs: number;
}

export type TodoFileLockResult =
	| {
			acquired: true;
			info: TodoFileLockInfo;
			release: () => Promise<void>;
	  }
	| {
			acquired: false;
			snapshot: TodoFileLockSnapshot | null;
	  };

export const TODO_DIR_GITIGNORE = "/todos/\n";
export const LEGACY_TODO_DIR_GITIGNORE = "*\n!.gitignore\n";

export function shouldMigrateLegacyTodoGitignore(content: string): boolean {
	return content === LEGACY_TODO_DIR_GITIGNORE;
}

export function isTodoClosed(status: string): boolean {
	return ["closed", "done", "complete"].includes(status.toLowerCase());
}

export function compareTodoPriority(a: TodoOrderFields, b: TodoOrderFields): number {
	const aClosed = isTodoClosed(a.status);
	const bClosed = isTodoClosed(b.status);
	if (aClosed !== bClosed) return aClosed ? 1 : -1;

	const aAssigned = !aClosed && Boolean(a.assigned_to_session);
	const bAssigned = !bClosed && Boolean(b.assigned_to_session);
	if (aAssigned !== bAssigned) return aAssigned ? -1 : 1;

	return 0;
}

export function compareTodoOrder(a: TodoOrderFields, b: TodoOrderFields): number {
	return compareTodoPriority(a, b) || (a.created_at || "").localeCompare(b.created_at || "");
}

export function compareTodoSearchMatches<T extends TodoOrderFields>(
	a: TodoSearchMatch<T>,
	b: TodoSearchMatch<T>,
): number {
	return (
		compareTodoPriority(a.todo, b.todo) ||
		a.score - b.score ||
		(a.todo.created_at || "").localeCompare(b.todo.created_at || "")
	);
}

export async function writeTextFileAtomic(filePath: string, content: string): Promise<void> {
	const tempPath = path.join(
		path.dirname(filePath),
		`.${path.basename(filePath)}.${process.pid}.${crypto.randomBytes(6).toString("hex")}.tmp`,
	);
	const existingStats = await fs.stat(filePath).catch(() => null);
	const mode = existingStats ? existingStats.mode & 0o777 : 0o666;
	let handle: Awaited<ReturnType<typeof fs.open>> | undefined;
	try {
		handle = await fs.open(tempPath, "wx", mode);
		await handle.writeFile(content, "utf8");
		await handle.sync();
		await handle.close();
		handle = undefined;
		await fs.rename(tempPath, filePath);
	} finally {
		await handle?.close().catch(() => undefined);
		await fs.unlink(tempPath).catch(() => undefined);
	}
}

export async function ensureTodoGitignore(gitignorePath: string): Promise<void> {
	try {
		await fs.writeFile(gitignorePath, TODO_DIR_GITIGNORE, { encoding: "utf8", flag: "wx" });
	} catch (error: any) {
		if (error?.code !== "EEXIST") throw error;
		const current = await fs.readFile(gitignorePath, "utf8").catch(() => "");
		if (shouldMigrateLegacyTodoGitignore(current)) {
			await writeTextFileAtomic(gitignorePath, TODO_DIR_GITIGNORE);
		}
	}
}

export async function readTodoFileLockSnapshot(
	lockPath: string,
): Promise<TodoFileLockSnapshot | null> {
	let handle: Awaited<ReturnType<typeof fs.open>> | undefined;
	try {
		handle = await fs.open(lockPath, "r");
		const raw = await handle.readFile("utf8");
		const stats = await handle.stat();
		let info: TodoFileLockInfo | null = null;
		try {
			info = JSON.parse(raw) as TodoFileLockInfo;
		} catch {
			// Malformed locks remain occupied and require explicit manual cleanup.
		}
		return { info, mtimeMs: stats.mtimeMs };
	} catch (error: any) {
		if (error?.code === "ENOENT") return null;
		throw error;
	} finally {
		await handle?.close().catch(() => undefined);
	}
}

export async function tryAcquireTodoFileLock(
	lockPath: string,
	info: Omit<TodoFileLockInfo, "token">,
): Promise<TodoFileLockResult> {
	let handle: Awaited<ReturnType<typeof fs.open>> | undefined;
	try {
		handle = await fs.open(lockPath, "wx");
	} catch (error: any) {
		if (error?.code !== "EEXIST") throw error;
		return { acquired: false, snapshot: await readTodoFileLockSnapshot(lockPath) };
	}

	const ownedInfo: TodoFileLockInfo = { ...info, token: crypto.randomUUID() };
	try {
		await handle.writeFile(JSON.stringify(ownedInfo, null, 2), "utf8");
		await handle.sync();
		await handle.close();
		handle = undefined;
	} catch (error) {
		await handle?.close().catch(() => undefined);
		handle = undefined;
		await fs.unlink(lockPath).catch(() => undefined);
		throw error;
	}

	// Occupied locks are never stolen or replaced by this implementation. That invariant
	// lets the owner release with one atomic unlink instead of a check-then-unlink race.
	let released = false;
	return {
		acquired: true,
		info: ownedInfo,
		release: async () => {
			if (released) return;
			released = true;
			try {
				await fs.unlink(lockPath);
			} catch (error: any) {
				if (error?.code !== "ENOENT") throw error;
			}
		},
	};
}
