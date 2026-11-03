package funkin.backend.assets;

import haxe.crypto.Sha256;
import haxe.io.Bytes;

/**
 * Enforces the script list that a protected pack carries.
 *
 * While protection mode is on, a script the pack did not declare is refused, and so is
 * one whose bytes no longer match the recorded hash. Both cases land in `violations` so
 * a dialog can report them; the script itself never runs.
 *
 * A v1 marker has no list, and then this does nothing - there is nothing to compare
 * against, and silently blocking every script would be worse than not checking.
 */
class ScriptGuard {
	/** Human readable reasons, one per refused script. */
	public static var violations:Array<String> = [];

	public static function allows(path:String, data:Bytes):Bool {
		if (!ProtectionState.isLocked()) return true;

		var scripts = ProtectionState.scripts();
		if (scripts == null || Lambda.count(scripts) == 0) return true;

		var key = normalize(path);
		var expected = scripts.get(key);
		if (expected == null) {
			refuse('$path is not listed in this pack');
			return false;
		}
		if (Sha256.make(data).toHex() != expected) {
			refuse('$path does not match its recorded hash');
			return false;
		}
		return true;
	}

	public static function reset():Void {
		violations = [];
	}

	static function refuse(what:String):Void {
		violations.push(what);
		Logs.error('Protection mode refused a script: ' + what);
	}

	/**
	 * Packs address scripts through their mod prefix (`mods/x/scripts/a.hx`), while the
	 * list stores the archive path (`scripts/a.hx`). Reduce both to the part after the
	 * first `scripts/` so the two can meet.
	 */
	static function normalize(path:String):String {
		var p = StringTools.replace(path, '\\', '/').toLowerCase();
		var at = p.indexOf('scripts/');
		return at >= 0 ? p.substr(at) : p;
	}
}
