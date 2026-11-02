package funkin.backend.system;

import funkin.backend.scripting.crypto.ScriptCrypto;
import haxe.crypto.Sha256;
import haxe.io.Bytes;
#if sys
import sys.FileSystem;
import sys.io.File;
#end

/** One manifest line: size, digest and the path as it sits next to the executable. */
typedef IntegrityEntry = {
	var size:Int;
	var hash:String;
	var path:String;
}

/**
 * Startup check that the files shipped with the game are still the ones that were built.
 *
 * What this can and cannot do, stated up front: the manifest is signed with a key that
 * lives in this binary, so swapping a resource without touching the executable is
 * caught. Someone who edits the executable as well can remove the check or re-sign the
 * manifest - no local integrity check survives that, and pretending otherwise would be
 * worse than saying so.
 *
 * The manifest is generated after a build (editor > Tools > Generate integrity
 * manifest) and sits next to the executable. Verification runs on a worker thread after
 * the window opens, so a large assets folder does not delay startup; the result is read
 * by the main menu, which shows it once.
 */
class IntegrityCheck {
	public static inline var MANIFEST:String = './integrity.dat';
	static inline var HEADER:String = 'CNEZ-INTEGRITY 1';
	static inline var SIGN_PREFIX:String = '# hmac ';
	static inline var NL:String = '\n';
	/** Mixed into the manifest signature; changing it invalidates old manifests. */
	static inline var MANIFEST_KEY:String = 'cnez::integrity::manifest::v1';

	public static var done(default, null):Bool = false;
	public static var running(default, null):Bool = false;
	/** Set when the manifest itself could not be trusted or read. */
	public static var manifestProblem:String = null;
	/** False when no manifest was shipped at all - nothing was checked, nothing failed. */
	public static var manifestFound:Bool = false;
	/** Files listed in the manifest but not on disk. */
	public static var missing:Array<String> = [];
	/** Files whose bytes no longer match the manifest. */
	public static var changed:Array<String> = [];
	/** Files under assets/ that are not in the manifest. */
	public static var extra:Array<String> = [];
	public static var checked:Int = 0;
	public static var total:Int = 0;

	/** True once the check ran and found something worth telling the player. */
	public static function hasProblems():Bool {
		return manifestProblem != null || missing.length > 0 || changed.length > 0;
	}

	public static function summary():String {
		if (manifestProblem != null) return manifestProblem;
		if (!manifestFound) return 'no manifest shipped';
		var parts:Array<String> = [];
		if (missing.length > 0) parts.push('${missing.length} missing');
		if (changed.length > 0) parts.push('${changed.length} modified');
		if (extra.length > 0) parts.push('${extra.length} unlisted');
		if (parts.length == 0) return 'all $checked file(s) match';
		return parts.join(', ');
	}

	/** The first few names, for a dialog that should stay readable. */
	public static function sample(list:Array<String>, count:Int = 5):String {
		var out:Array<String> = [];
		for (i in 0...list.length) {
			if (i >= count) {
				out.push('... and ${list.length - count} more');
				break;
			}
			out.push(list[i]);
		}
		return out.join('\n');
	}

	// ------------------------------------------------------------- generation

	/**
	 * Writes the manifest for the current build.
	 *
	 * Covers the executable, the native libraries next to it and everything under
	 * `assets/`. Mod packs are deliberately excluded: they belong to the player, and the
	 * encrypted ones already carry their own chunk tags.
	 */
	public static function generate():String {
		#if sys
		var entries = collect();
		var body = new StringBuf();
		body.add(HEADER + NL);
		for (e in entries) body.add('${e.size}\t${e.hash}\t${e.path}$NL');
		var text = body.toString();
		File.saveContent(MANIFEST, text + SIGN_PREFIX + sign(text) + NL);
		// no Logs here: this also runs from the build hook, before the log is ready
		return '${entries.length} file(s), signed';
		#else
		return 'not supported on this target';
		#end
	}

	// ----------------------------------------------------------- verification

	/** Starts the check on a worker thread; safe to call when one is already running. */
	public static function startVerify():Void {
		#if sys
		if (running || done) return;
		running = true;
		#if target.threaded
		sys.thread.Thread.create(function() runVerify());
		#else
		runVerify();
		#end
		#end
	}

	static function runVerify():Void {
		#if sys
		try {
			if (!FileSystem.exists(MANIFEST)) {
				// a build that never generated one is not a failure, just unchecked
				manifestFound = false;
				done = true;
				running = false;
				Logs.trace('No integrity manifest next to the executable; skipping the check.', INFO);
				return;
			}
			manifestFound = true;
			verifyAll();
		} catch (e:Dynamic) {
			manifestProblem = 'The integrity manifest could not be read: ' + Std.string(e);
			Logs.error(manifestProblem);
		}
		done = true;
		running = false;
		#end
	}

	static function verifyAll():Void {
		#if sys
		// CRLF would change the bytes the signature was made over, so normalise first
		var raw = StringTools.replace(File.getContent(MANIFEST), '\r\n', '\n');
		var lines = raw.split(NL);
		if (lines.length < 2 || StringTools.trim(lines[0]) != HEADER) {
			manifestProblem = 'The integrity manifest is not in a format this build understands.';
			return;
		}

		// rebuild exactly the text `generate` signed: the header, then every entry line
		var body = new StringBuf();
		body.add(lines[0] + NL);
		var signature:String = null;
		var entries:Array<IntegrityEntry> = [];

		for (i in 1...lines.length) {
			var line = lines[i];
			if (line == null || line.length == 0) continue;
			if (StringTools.startsWith(line, SIGN_PREFIX)) {
				signature = StringTools.trim(line.substr(SIGN_PREFIX.length));
				continue;
			}
			var parts = line.split('\t');
			if (parts.length < 3) continue;
			entries.push({size: Std.parseInt(parts[0]), hash: parts[1], path: parts[2]});
			body.add(line + NL);
		}

		if (signature == null) {
			manifestProblem = 'The integrity manifest is not signed.';
			return;
		}
		// a manifest edited by hand - or swapped for one listing other hashes - fails here
		if (sign(body.toString()) != signature.toLowerCase()) {
			manifestProblem = 'The integrity manifest was modified (its signature does not match).';
			Logs.error(manifestProblem);
			return;
		}

		total = entries.length;
		var listed = new Map<String, Bool>();
		for (e in entries) {
			listed.set(e.path, true);
			if (!FileSystem.exists(e.path)) {
				missing.push(e.path);
				continue;
			}
			var data = File.getBytes(e.path);
			checked++;
			if (data.length != e.size || Sha256.make(data).toHex() != e.hash) changed.push(e.path);
		}

		// files that appeared under assets/ but were never built: an injected script or a
		// dropped-in replacement shows up here even though nothing listed was touched
		var onDisk:Array<String> = [];
		walk('assets', onDisk);
		for (p in onDisk)
			if (!listed.exists(p)) extra.push(p);

		if (missing.length > 0 || changed.length > 0)
			Logs.warn('Integrity check: ' + summary() + ' - see the list in the dialog.');
		else
			Logs.trace('Integrity check: ' + summary(), INFO);
		#end
	}

	// ------------------------------------------------------------------ helpers

	#if sys
	static function collect():Array<IntegrityEntry> {
		var out:Array<IntegrityEntry> = [];
		var exe = './CodenameEngine.exe';
		if (FileSystem.exists(exe)) out.push(entryFor(exe, 'CodenameEngine.exe'));

		for (f in FileSystem.readDirectory('.')) {
			var lower = f.toLowerCase();
			if (lower.endsWith('.ndll') || lower.endsWith('.dll')) {
				var p = './' + f;
				if (!FileSystem.isDirectory(p)) out.push(entryFor(p, f));
			}
		}

		var files:Array<String> = [];
		walk('assets', files);
		for (p in files) out.push(entryFor(p, p));
		return out;
	}

	static function walk(dir:String, out:Array<String>):Void {
		if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir)) return;
		for (f in FileSystem.readDirectory(dir)) {
			var p = dir + '/' + f;
			if (FileSystem.isDirectory(p)) walk(p, out);
			else out.push(normalize(p));
		}
	}

	static function normalize(path:String):String {
		return StringTools.replace(path, '\\', '/');
	}

	static function entryFor(path:String, shown:String):IntegrityEntry {
		var data = File.getBytes(path);
		return {size: data.length, hash: Sha256.make(data).toHex(), path: normalize(shown)};
	}
	#end

	static function sign(text:String):String {
		var key = Sha256.make(Bytes.ofString(MANIFEST_KEY));
		return ScriptCrypto.hmacTag(key, Bytes.ofString(text)).toHex();
	}
}
