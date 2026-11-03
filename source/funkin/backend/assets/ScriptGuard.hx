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
		// another mod's script, or one outside any mod folder: not this pack's business
		if (key == null) return true;

		// The engine ships its own scripts under assets/. They are not this pack's to
		// police, and refusing them would break the game instead of protecting it.
		if (StringTools.startsWith(key, 'assets/')) return true;

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
	 * Reduces a runtime path to the form the marker stores.
	 *
	 * A script reached through the mod folder looks like `mods/<name>/data/a.hx` here and
	 * `data/a.hx` in the archive, so the prefix is dropped. Returns null for a path that
	 * belongs to a different mod, which the caller treats as "not ours, leave it alone".
	 */
	static function normalize(path:String):String {
		var p = StringTools.replace(path, '\\', '/').toLowerCase();
		if (!StringTools.startsWith(p, 'mods/')) return p;

		var rest = p.substr(5);
		var slash = rest.indexOf('/');
		if (slash < 0) return p;

		var owner = ProtectionState.owner();
		if (owner != null && rest.substr(0, slash) != owner.toLowerCase()) return null;
		return rest.substr(slash + 1);
	}
}
