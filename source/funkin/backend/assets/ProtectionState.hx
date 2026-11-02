package funkin.backend.assets;

import funkin.backend.assets.ProtectionMark.ProtectionData;
import funkin.backend.utils.SysZip;
import funkin.options.Options;
import haxe.io.Bytes;

/**
 * Whether the loaded mod runs in protection mode.
 *
 * A pack author can drop `data/cne_protect.dat` into the archive (the encryption editor
 * does it when the box is ticked). When that pack loads, protection mode turns on:
 * developer mode is switched off and the option is locked grey until the pack's own
 * password turns it back off.
 *
 * Scope, honestly: this is a speed bump for the player of a mod, not a security
 * boundary. It stops the developer menu from being one keypress away and makes turning
 * it back on cost a password; anyone who edits the pack or the executable walks around
 * it. The pack key is never involved - the marker stores a salted digest, not the key.
 */
class ProtectionState {
	/** True when the loaded mod is an encrypted pack carrying a marker. */
	public static var available(default, null):Bool = false;
	/** True while protection mode is on for the loaded mod. */
	public static var active(default, null):Bool = false;

	static var mark:ProtectionData = null;
	static var packName:String = null;
	/** Password handed in on the command line, applied once a pack with a marker loads. */
	static var pendingUnlock:String = null;
	static inline var ARG:String = '--unlock-protection=';

	/**
	 * Picks up `--unlock-protection=<password>`.
	 *
	 * There is no password prompt in the settings screen yet, so this is how a player who
	 * knows the password turns protection mode off for a session. The value is only
	 * checked once the pack that owns the marker is loaded, because that is where the
	 * digest lives.
	 */
	public static function applyUnlockArgument(args:Array<String>):Void {
		if (args == null) return;
		for (a in args) {
			if (a == null || !StringTools.startsWith(a, ARG)) continue;
			var pass = a.substr(ARG.length);
			if (pass.length > 0) pendingUnlock = pass;
			return;
		}
	}

	/** Called when the mod goes away, so a stale lock cannot follow the player. */
	public static function reset():Void {
		available = false;
		active = false;
		mark = null;
		packName = null;
		Options.protectionMode = false;
	}

	/**
	 * Reads the marker out of a loaded pack and switches protection mode on when it is
	 * there. A pack without one leaves everything as it was.
	 */
	public static function applyFromPack(zip:SysZip, name:String):Void {
		#if sys
		if (zip == null) {
			reset();
			return;
		}

		var data = readEntry(zip, ProtectionMark.PATH);
		if (data == null) data = readEntry(zip, 'cne_protect.dat');
		if (data == null) {
			// an encrypted pack without a marker is still a normal mod
			reset();
			return;
		}

		var parsed = ProtectionMark.parse(data);
		if (parsed == null) {
			Logs.warn('The protection marker in "$name" is unreadable; ignoring it.');
			reset();
			return;
		}

		mark = parsed;
		packName = name;
		available = true;
		lock(true);

		// a password given on the command line is checked here, where the digest is
		if (pendingUnlock != null && unlock(pendingUnlock))
			Logs.trace('Protection mode: unlocked from the command line for this session.', INFO);
		#end
	}

	/** True when the player can still see the toggle greyed out. */
	public static function isLocked():Bool {
		return available && active;
	}

	/**
	 * Turns protection mode on or off and keeps developer mode consistent with it.
	 *
	 * Turning it on always disables developer mode; turning it off gives it back at the
	 * default (off), which is what the option looked like before the pack loaded.
	 */
	static function lock(on:Bool):Void {
		active = on;
		Options.protectionMode = on;
		if (on) Options.devMode = false;
	}

	/**
	 * Tries a password. Returns true when it turns protection mode off.
	 *
	 * The caller is responsible for asking; this only answers yes or no, so a wrong
	 * password never changes anything.
	 */
	public static function unlock(pass:String):Bool {
		if (!available || mark == null) return false;
		if (!ProtectionMark.matches(mark, pass)) {
			Logs.trace('Protection mode: the password did not match.', INFO);
			return false;
		}
		lock(false);
		Logs.trace('Protection mode: unlocked for this session.', INFO);
		return true;
	}

	/** Name of the pack that owns the lock, for the dialog. */
	public static function owner():String {
		return packName;
	}

	static function readEntry(zip:SysZip, name:String):Bytes {
		var wanted = name.toLowerCase();
		for (entry in zip.entries) {
			var entryName = entry.fileName.replace("\\", "/").toLowerCase();
			if (entryName != wanted) continue;
			return zip.unzipEntry(entry);
		}
		return null;
	}
}
