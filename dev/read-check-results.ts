// Dev-only, never shipped. Prints the current Haggler_Check run as a markdown report and exits
// non-zero when any item failed or is not judged yet. Run after a /reload or logout:
//   node dev/read-check-results.ts                 the one account that has Haggler_Check.lua
//   node dev/read-check-results.ts <account>       an account folder name under WTF/Account
//   node dev/read-check-results.ts <path>          a Haggler_Check.lua anywhere
//   --version <v>                                    green only when the run is of Haggler <v>
// The Lua literal parser is the one in Provenance's Dev/read-probe-results.ts.
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

type LuaValue = string | number | boolean | undefined | LuaTable;
type LuaTable = Map<string | number, LuaValue>;
type Result<T, E = Error> = { ok: true; value: T } | { ok: false; error: E };
type Token =
	{ kind: 'string'; text: string } | { kind: 'number'; value: number } | { kind: 'name'; text: string } | { kind: 'symbol'; text: string };
type ItemState = 'pass' | 'fail' | 'look' | 'na' | 'pending';
type SavedState = Exclude<ItemState, 'pending'>;
type CheckItem = { id: string; title: string; zone: string; place: string; isOnce: boolean };
type CheckResult = { state: ItemState; evidence: string[] };
type CheckReport = { markdown: string; isGreen: boolean };
type ReaderArguments = { location: string | undefined; expectedVersion: string | undefined };
type ReportOptions = { expectedVersion?: string | undefined };

const DATABASE_NAME = 'Haggler_CheckDB';
const SAVED_VARIABLES_FILE = 'Haggler_Check.lua';
const ACCOUNT_ROOT = '/Applications/World of Warcraft/_forever_/WTF/Account';
const JUDGED_STATES: ReadonlySet<ItemState> = new Set(['pass', 'fail', 'na']);
const SAVED_STATES: readonly SavedState[] = ['pass', 'fail', 'look', 'na'];
const SYMBOLS = new Set(['{', '}', '[', ']', '=', ',', ';']);
// How the client writes math.huge and NaN into a saved table.
const NUMBER_NAMES: ReadonlyMap<string, number> = new Map([
	['inf', Number.POSITIVE_INFINITY],
	['nan', Number.NaN],
]);
const ESCAPES: Readonly<Record<string, string>> = { n: '\n', t: '\t', r: '\r', '\\': '\\', '"': '"', "'": "'" };

class TokenStream {
	readonly #tokens: Token[];
	#position = 0;

	constructor(tokens: Token[]) {
		this.#tokens = tokens;
	}

	get isDone(): boolean {
		return this.#position >= this.#tokens.length;
	}

	peek(): Token | undefined {
		return this.#tokens[this.#position];
	}

	peekAt(offset: number): Token | undefined {
		return this.#tokens[this.#position + offset];
	}

	next(): Token {
		const token = this.#tokens[this.#position];
		if (token === undefined) throw new SyntaxError('unexpected end of file');
		this.#position += 1;
		return token;
	}

	expectSymbol(symbol: string): void {
		const token = this.next();
		if (token.kind !== 'symbol' || token.text !== symbol) {
			throw new SyntaxError(`expected '${symbol}', got ${describeToken(token)}`);
		}
	}
}

if (isRunDirectly()) main();

function main(): void {
	const readerArguments = parseArguments(process.argv.slice(2));
	if (!readerArguments.ok) {
		process.stderr.write(`${readerArguments.error.message}\n`);
		process.exit(2);
	}
	const located = locateSavedVariables(readerArguments.value.location);
	if (!located.ok) {
		process.stderr.write(`${located.error.message}\n`);
		process.exit(2);
	}
	const parsed = parseSavedVariables(readFileSync(located.value, 'utf8'));
	if (!parsed.ok) {
		process.stderr.write(`could not read ${located.value}: ${parsed.error.message}\n`);
		process.exit(2);
	}
	const database = parsed.value.get(DATABASE_NAME);
	if (!(database instanceof Map)) {
		process.stderr.write(`${DATABASE_NAME} is missing from ${located.value}\n`);
		process.exit(2);
	}
	const report = renderReport(database, { expectedVersion: readerArguments.value.expectedVersion });
	process.stdout.write(report.markdown);
	process.exit(report.isGreen ? 0 : 1);
}

/**
 * Reads the command line: an optional `--version <v>` and an optional account or path.
 * @returns the arguments, or why they are malformed.
 */
export function parseArguments(argv: readonly string[]): Result<ReaderArguments> {
	let location: string | undefined;
	let expectedVersion: string | undefined;
	for (let index = 0; index < argv.length; index += 1) {
		const argument = argv[index];
		if (argument === '--version') {
			expectedVersion = argv[index + 1];
			if (expectedVersion === undefined || expectedVersion === '') {
				return { ok: false, error: new Error('--version needs a version, e.g. --version 0.1.0') };
			}
			index += 1;
		} else if (argument !== undefined && location === undefined) {
			location = argument;
		} else {
			return { ok: false, error: new Error(`unexpected argument ${String(argument)}`) };
		}
	}
	return { ok: true, value: { location, expectedVersion } };
}

/**
 * Finds the saved variables file from the argument: a path, an account folder name, or nothing
 * (the single account that has one).
 * @returns the file path, or why none was found.
 */
export function locateSavedVariables(argument: string | undefined): Result<string> {
	if (argument !== undefined && argument.endsWith('.lua')) {
		return existsSync(argument) ? { ok: true, value: argument } : { ok: false, error: new Error(`no file at ${argument}`) };
	}
	if (argument !== undefined) {
		const path = savedVariablesPathOf(argument);
		if (existsSync(path)) return { ok: true, value: path };
		return { ok: false, error: new Error(`no ${SAVED_VARIABLES_FILE} for account ${argument}`) };
	}
	const candidates = listAccounts()
		.map(savedVariablesPathOf)
		.filter((path) => existsSync(path));
	const [only, ...others] = candidates;
	if (only === undefined) {
		return { ok: false, error: new Error(`no account under ${ACCOUNT_ROOT} has ${SAVED_VARIABLES_FILE}; /reload in game first`) };
	}
	if (others.length > 0) {
		return { ok: false, error: new Error(`several accounts have ${SAVED_VARIABLES_FILE}; name one:\n${candidates.join('\n')}`) };
	}
	return { ok: true, value: only };
}

/**
 * Parses a SavedVariables file: top-level `Name = value` assignments of Lua literals.
 * @returns the globals by name, or the syntax error for a file the client did not write.
 */
export function parseSavedVariables(source: string): Result<Map<string, LuaValue>, Error> {
	try {
		const stream = new TokenStream(tokenize(source));
		const globals = new Map<string, LuaValue>();
		while (!stream.isDone) {
			const name = stream.next();
			if (name.kind !== 'name') throw new SyntaxError(`expected a global name, got ${describeToken(name)}`);
			stream.expectSymbol('=');
			globals.set(name.text, parseValue(stream));
		}
		return { ok: true, value: globals };
	} catch (error) {
		if (error instanceof SyntaxError) return { ok: false, error };
		throw error;
	}
}

/**
 * Renders the current run: a summary, then one row per item in suite order. Green only when no
 * item failed, every item passed or was marked not applicable, and the run is of the expected
 * Haggler version when one is given.
 * @param database the parsed Haggler_CheckDB
 * @param options expectedVersion: the Haggler version the run must be of
 */
export function renderReport(database: LuaTable, options: ReportOptions = {}): CheckReport {
	const items = readItems(database.get('items'));
	const runKey = database.get('current');
	const runs = database.get('runs');
	const run = typeof runKey === 'string' && runs instanceof Map ? runs.get(runKey) : undefined;
	if (typeof runKey !== 'string' || items.length === 0 || !(run instanceof Map)) {
		return { markdown: '## Haggler checks\n\nNo run saved yet: load the game with Haggler_Check, then /reload.\n', isGreen: false };
	}
	const results = run.get('results');
	const onceResults = database.get('once');
	const rows = items.map((item) => ({ item, result: resultOf(item, results, onceResults) }));
	const counts = countStates(rows.map((row) => row.result.state));
	const runVersion = run.get('version');
	const isExpectedVersion = options.expectedVersion === undefined || runVersion === options.expectedVersion;
	const isGreen = isExpectedVersion && counts.fail === 0 && rows.every((row) => JUDGED_STATES.has(row.result.state));
	const summary = [
		`${String(counts.pass)} pass`,
		`${String(counts.na)} n/a`,
		`${String(counts.fail)} fail`,
		`${String(counts.look)} to look at`,
		`${String(counts.pending)} pending`,
	].join(', ');
	const lines = [
		`## Haggler checks: ${runKey}`,
		'',
		`${isGreen ? 'GREEN' : 'NOT GREEN'}: ${summary}, of ${String(items.length)}.`,
		...(isExpectedVersion
			? []
			: [
					'',
					`The current run is of Haggler ${stringOr(runVersion, '?')}, not ${String(options.expectedVersion)}: run the suite on that build.`,
				]),
		'',
		'| State | Place | Item | Evidence |',
		'| --- | --- | --- | --- |',
		...rows.map((row) => renderRow(row.item, row.result)),
	];
	return { markdown: `${lines.join('\n')}\n`, isGreen };
}

function renderRow(item: CheckItem, result: CheckResult): string {
	const title = `${item.title} (${item.id}${item.zone === 'fight' ? ', fight' : ''})`;
	return `| ${result.state} | ${item.place} | ${escapeCell(title)} | ${escapeCell(result.evidence.join('; '))} |`;
}

function resultOf(item: CheckItem, results: LuaValue, onceResults: LuaValue): CheckResult {
	const own = results instanceof Map ? readResult(results.get(item.id)) : undefined;
	const once = item.isOnce && onceResults instanceof Map ? readResult(onceResults.get(item.id)) : undefined;
	return own ?? once ?? { state: 'pending', evidence: [] };
}

function readItems(value: LuaValue): CheckItem[] {
	return arrayOf(value).flatMap((itemValue) => {
		if (!(itemValue instanceof Map)) return [];
		const id = itemValue.get('id');
		const title = itemValue.get('title');
		if (typeof id !== 'string' || typeof title !== 'string') return [];
		return [
			{
				id,
				title,
				zone: stringOr(itemValue.get('zone'), 'safe'),
				place: stringOr(itemValue.get('place'), '?'),
				isOnce: itemValue.get('once') === true,
			},
		];
	});
}

function readResult(value: LuaValue): CheckResult | undefined {
	if (!(value instanceof Map)) return undefined;
	const state = value.get('state');
	const savedState = SAVED_STATES.find((each) => each === state);
	// An unknown state is a checker the reader does not know yet: never green.
	return { state: savedState ?? 'look', evidence: arrayOf(value.get('evidence')).map(String) };
}

function parseValue(stream: TokenStream): LuaValue {
	const token = stream.next();
	switch (token.kind) {
		case 'string':
			return token.text;
		case 'number':
			return token.value;
		case 'name':
			if (token.text === 'true') return true;
			if (token.text === 'false') return false;
			if (token.text === 'nil') return undefined;
			if (NUMBER_NAMES.has(token.text)) return NUMBER_NAMES.get(token.text);
			throw new SyntaxError(`unexpected name '${token.text}'`);
		case 'symbol':
			if (token.text === '{') return parseTableBody(stream);
			if (token.text === '-') {
				const negated = stream.next();
				if (negated.kind === 'number') return -negated.value;
				const namedNumber = negated.kind === 'name' ? NUMBER_NAMES.get(negated.text) : undefined;
				if (namedNumber !== undefined) return -namedNumber;
			}
			throw new SyntaxError(`unexpected ${describeToken(token)}`);
	}
}

function parseTableBody(stream: TokenStream): LuaTable {
	const table: LuaTable = new Map();
	let nextArrayIndex = 1;
	for (;;) {
		const token = stream.peek();
		if (token === undefined) throw new SyntaxError('unclosed table');
		if (token.kind === 'symbol' && token.text === '}') {
			stream.next();
			return table;
		}
		if (token.kind === 'symbol' && token.text === '[') {
			stream.next();
			const key = parseValue(stream);
			if (typeof key !== 'string' && typeof key !== 'number') throw new SyntaxError('table key must be a string or number');
			stream.expectSymbol(']');
			stream.expectSymbol('=');
			table.set(key, parseValue(stream));
		} else if (token.kind === 'name' && isAssignmentAhead(stream)) {
			stream.next();
			stream.expectSymbol('=');
			table.set(token.text, parseValue(stream));
		} else {
			table.set(nextArrayIndex, parseValue(stream));
			nextArrayIndex += 1;
		}
		const separator = stream.peek();
		if (separator?.kind === 'symbol' && (separator.text === ',' || separator.text === ';')) stream.next();
	}
}

function isAssignmentAhead(stream: TokenStream): boolean {
	const following = stream.peekAt(1);
	return following?.kind === 'symbol' && following.text === '=';
}

function tokenize(source: string): Token[] {
	const tokens: Token[] = [];
	let position = 0;
	while (position < source.length) {
		const character = source.charAt(position);
		if (/\s/.test(character)) {
			position += 1;
		} else if (source.startsWith('--', position)) {
			position = skipComment(source, position);
		} else if (character === '"' || character === "'") {
			const read = readQuotedString(source, position);
			tokens.push({ kind: 'string', text: read.text });
			position = read.end;
		} else if (/[0-9.]/.test(character)) {
			const match = /^(?:0x[0-9a-fA-F]+|[0-9]*\.?[0-9]+(?:[eE][+-]?[0-9]+)?)/.exec(source.slice(position));
			if (match === null) throw new SyntaxError(`bad number at ${String(position)}`);
			tokens.push({ kind: 'number', value: Number(match[0]) });
			position += match[0].length;
		} else if (/[A-Za-z_]/.test(character)) {
			const match = /^[A-Za-z_][A-Za-z0-9_]*/.exec(source.slice(position));
			const name = match?.[0] ?? character;
			tokens.push({ kind: 'name', text: name });
			position += name.length;
		} else if (SYMBOLS.has(character) || character === '-') {
			tokens.push({ kind: 'symbol', text: character });
			position += 1;
		} else {
			throw new SyntaxError(`unexpected character '${character}' at ${String(position)}`);
		}
	}
	return tokens;
}

function skipComment(source: string, start: number): number {
	const longComment = /^--\[(=*)\[/.exec(source.slice(start));
	if (longComment !== null) {
		const closing = `]${longComment[1] ?? ''}]`;
		const end = source.indexOf(closing, start);
		return end === -1 ? source.length : end + closing.length;
	}
	const lineEnd = source.indexOf('\n', start);
	return lineEnd === -1 ? source.length : lineEnd + 1;
}

function readQuotedString(source: string, start: number): { text: string; end: number } {
	const quote = source.charAt(start);
	const bytes: number[] = [];
	let position = start + 1;
	while (position < source.length) {
		const character = source.charAt(position);
		if (character === quote) return { text: Buffer.from(bytes).toString('utf8'), end: position + 1 };
		if (character === '\\') {
			const escaped = source.charAt(position + 1);
			const digits = /^[0-9]{1,3}/.exec(source.slice(position + 1));
			if (digits !== null) {
				bytes.push(Number(digits[0]));
				position += 1 + digits[0].length;
			} else {
				pushText(bytes, escaped === '\n' ? '\n' : (ESCAPES[escaped] ?? escaped));
				position += 2;
			}
		} else {
			const codePoint = source.codePointAt(position) ?? 0;
			const text = String.fromCodePoint(codePoint);
			pushText(bytes, text);
			position += text.length;
		}
	}
	throw new SyntaxError('unclosed string');
}

function pushText(bytes: number[], text: string): void {
	bytes.push(...Buffer.from(text, 'utf8'));
}

function arrayOf(value: LuaValue): LuaValue[] {
	if (!(value instanceof Map)) return [];
	const items: LuaValue[] = [];
	for (let index = 1; value.has(index); index += 1) items.push(value.get(index));
	return items;
}

function describeToken(token: Token): string {
	return token.kind === 'number' ? `number ${String(token.value)}` : `${token.kind} '${token.text}'`;
}

// True when node runs this file, false when a test or another script imports it.
function isRunDirectly(): boolean {
	const entry = process.argv[1];
	return entry !== undefined && resolve(entry) === fileURLToPath(import.meta.url);
}

function countStates(states: ItemState[]): Record<ItemState, number> {
	const counts: Record<ItemState, number> = { pass: 0, fail: 0, look: 0, na: 0, pending: 0 };
	for (const state of states) counts[state] += 1;
	return counts;
}

function stringOr(value: LuaValue, fallback: string): string {
	return typeof value === 'string' ? value : fallback;
}

function escapeCell(text: string): string {
	return text.replaceAll('|', '\\|').replaceAll('\n', ' ');
}

function listAccounts(): string[] {
	try {
		return readdirSync(ACCOUNT_ROOT, { withFileTypes: true })
			.filter((entry) => entry.isDirectory() && entry.name !== 'SavedVariables')
			.map((entry) => entry.name);
	} catch {
		return [];
	}
}

function savedVariablesPathOf(account: string): string {
	return join(ACCOUNT_ROOT, account, 'SavedVariables', SAVED_VARIABLES_FILE);
}
