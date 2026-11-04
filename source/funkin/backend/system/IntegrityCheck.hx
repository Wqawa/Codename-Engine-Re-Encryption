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
 * Compares the files next to the executable against a signed manifest.
 *
 * The signing key is compiled into the binary, so this catches an edited asset or
 * library as long as the exe itself was not rebuilt. It cannot survive a replaced exe:
 * whoever can rebuild it can also drop the check or sign a new manifest.
 *
 * The work runs on a worker thread. Exactly one screen shows the result - the startup
 * screen when a pack has to be unlocked, the main menu otherwise.
 */
class IntegrityCheck {
	public static inline var MANIFEST:String = './integrity.dat';
	public static inline var EXE_NAME:String = 'CodenameEngine.exe';

	static inline var HEADER:String = 'CNEZ-INTEGRITY 1';
	static inline var SIGN_PREFIX:String = '# hmac ';
	static inline var NL:String = '\n';

	/** Mixed into the manifest signature; changing it invalidates old manifests. */
	static inline var MANIFEST_KEY:String = 'cnez::integrity::manifest::v1';

	public static var done(default, null):Bool = false;
	public static var running(default, null):Bool = false;

	/** Set when the manifest itself could not be read or trusted. */
	public static var manifestProblem:String = null;
	/** False when no manifest was shipped - nothing was checked, nothing failed. */
	public static var manifestFound:Bool = false;

	/** Listed in the manifest, missing on disk. */
	public static var missing:Array<String> = [];
	/** Size or digest differs from the manifest. */
	public static var changed:Array<String> = [];
	/** Present under assets/, not in the manifest. */
	public static var extra:Array<String> = [];

	/** Entries examined so far, for the progress bar. */
	public static var checked:Int = 0;
	/** Entries in the manifest. */
	public static var total:Int = 0;

	/** True once a screen showed the result, so it is not shown a second time. */
	public static var reported(default, null):Bool = false;

	public static function hasProblems():Bool {
		// `extra` counts: an unlisted file under assets/ is exactly the shape an injected
		// script takes, and leaving it out meant it was never shown to anyone
		return manifestProblem != null || missing.length > 0 || changed.length > 0 || extra.length > 0;
	}

	public static function markReported():Void {
		reported = true;
	}

	public static function summary():String {
		if (manifestProblem != null) return manifestProblem;
		if (!manifestFound) return 'no manifest shipped';
		var parts:Array<String> = [];
		if (missing.length > 0) parts.push('${missing.length} missing');
		if (changed.length > 0) parts.push('${changed.length} modified');
		if (extra.length > 0) parts.push('${extra.length} unlisted');
		return parts.length == 0 ? 'all $checked file(s) match' : parts.join(', ');
	}

	/** First `count` names plus "and N more", for a dialog that has to stay readable. */
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
	 * `assets/`. Mod packs stay out: they belong to the player, and the encrypted ones
	 * carry their own chunk tags.
	 */
	public static function generate():String {
		#if sys
		var entries = collect();
		var body = new StringBuf();
		body.add(HEADER + NL);
		for (e in entries) body.add('${e.size}\t${e.hash}\t${e.path}$NL');
		var text = body.toString();
		File.saveContent(MANIFEST, text + SIGN_PREFIX + sign(text) + NL);
		// no Logs here: the build hook runs this before the log file exists
		return '${entries.length} file(s), signed';
		#else
		return 'not supported on this target';
		#end
	}

	// ----------------------------------------------------------- verification

	/** Starts the check on a worker thread. Calling it twice is a no-op. */
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
				// a build that never generated one is unchecked, not broken
				manifestFound = false;
				Logs.trace('No integrity manifest next to the executable; skipping the check.', INFO);
			} else {
				manifestFound = true;
				verifyAll();
			}
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
		// CRLF would change the bytes the signature was made over
		var raw = StringTools.replace(File.getContent(MANIFEST), '\r\n', '\n');
		var lines = raw.split(NL);
		if (lines.length < 2 || StringTools.trim(lines[0]) != HEADER) {
			manifestProblem = 'The integrity manifest is not in a format this build understands.';
			return;
		}

		// rebuild the exact text `generate` signed: header, then every entry line
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
		// a hand-edited manifest, or one swapped for another set of hashes, dies here
		if (sign(body.toString()) != signature.toLowerCase()) {
			manifestProblem = 'The integrity manifest was modified (its signature does not match).';
			Logs.error(manifestProblem);
			return;
		}

		// A rebuild changes the exe but leaves assets alone. Only the exe line is skipped
		// then: skipping the whole check meant one rebuild disabled it until somebody
		// regenerated the manifest, which is how a renamed asset went unnoticed.
		var skipExe = exeDiffers(entries);

		total = entries.length;
		var listed = new Map<String, Bool>();
		for (e in entries) {
			listed.set(e.path, true);
			checked++;
			if (skipExe && isExePath(e.path)) continue;
			if (!FileSystem.exists(e.path)) {
				missing.push(e.path);
				continue;
			}
			var data = File.getBytes(e.path);
			if (data.length != e.size || Sha256.make(data).toHex() != e.hash) changed.push(e.path);
		}

		walkAssets(function(path:String) {
			if (!listed.exists(path)) extra.push(path);
		});

		var line = 'Integrity check: ' + summary();
		if (hasProblems()) {
			// the dialog has room for a few names per kind; the log keeps the whole list
			Logs.warn(line + ' - see the dialog for the first few of each kind.');
			logList('missing', missing);
			logList('modified', changed);
			logList('unlisted', extra);
		}
		else Logs.trace(line, INFO);
		#end
	}

	/** Writes a whole category to the log, capped so one bad build cannot flood it. */
	static function logList(kind:String, list:Array<String>):Void {
		if (list == null || list.length == 0) return;
		var cap = 40;
		var shown = list.length > cap ? list.slice(0, cap) : list;
		var tail = list.length > cap ? ' ... and ${list.length - cap} more' : '';
		Logs.warn('Integrity: $kind (${list.length}): ' + shown.join(' | ') + tail);
	}

	/** True when the exe listed in the manifest no longer matches the one on disk. */
	static function exeDiffers(entries:Array<IntegrityEntry>):Bool {
		#if sys
		for (e in entries) {
			if (!isExePath(e.path) || !FileSystem.exists(e.path)) continue;
			var differs = Sha256.make(File.getBytes(e.path)).toHex() != e.hash;
			if (differs) Logs.trace('Integrity: the exe does not match the manifest; checking everything else.', INFO);
			return differs;
		}
		#end
		return false;
	}

	static function isExePath(path:String):Bool {
		return StringTools.endsWith(path.toLowerCase(), EXE_NAME.toLowerCase());
	}

	// ------------------------------------------------------------------ helpers

	#if sys
	static function collect():Array<IntegrityEntry> {
		var out:Array<IntegrityEntry> = [];
		var exe = './' + EXE_NAME;
		if (FileSystem.exists(exe)) out.push(entryFor(exe, EXE_NAME));

		for (name in FileSystem.readDirectory('.')) {
			var lower = name.toLowerCase();
			if (!lower.endsWith('.ndll') && !lower.endsWith('.dll')) continue;
			var path = './' + name;
			if (!FileSystem.isDirectory(path)) out.push(entryFor(path, name));
		}

		walkAssets(function(path:String) out.push(entryFor(path, path)));
		return out;
	}

	/** Calls `visit` for every file under `assets/`, path normalised to forward slashes. */
	static function walkAssets(visit:String->Void):Void {
		walk('assets', visit);
	}

	static function walk(dir:String, visit:String->Void):Void {
		if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir)) return;
		for (name in FileSystem.readDirectory(dir)) {
			var path = dir + '/' + name;
			if (FileSystem.isDirectory(path)) walk(path, visit);
			else visit(normalize(path));
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
