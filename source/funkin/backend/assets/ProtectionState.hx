package funkin.backend.assets;

import funkin.backend.assets.ProtectionMark.ProtectionData;
import funkin.backend.utils.SysZip;
import funkin.options.Options;
import haxe.io.Bytes;

/**
 * Protection mode for the loaded mod.
 *
 * A pack carrying `data/cne_protect.dat` turns it on: developer mode goes off and the
 * option locks until the pack's password unlocks it. Packs without a marker leave the
 * setting alone.
 */
class ProtectionState {
	/** True when the loaded mod is an encrypted pack carrying a marker. */
	public static var available(default, null):Bool = false;
	/** True while protection mode is on for the loaded mod. */
	public static var active(default, null):Bool = false;

	static var mark:ProtectionData = null;
	static var packName:String = null;
	/** Developer mode as it was before the lock took it, so it can be handed back. */
	static var devModeBefore:Bool = false;

	/** Called when the mod goes away, so a stale lock cannot follow the player. */
	public static function reset():Void {
		if (active) Options.devMode = devModeBefore;
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
		if (on && !active) devModeBefore = Options.devMode;
		active = on;
		Options.protectionMode = on;
		if (on) Options.devMode = false;
		else Options.devMode = devModeBefore;
	}

	/**
	 * Checks a password without changing anything.
	 *
	 * Separate from unlock(): turning protection back on needs the same password check,
	 * but must not clear the state the way unlocking does.
	 */
	public static function verify(pass:String):Bool {
		return available && mark != null && ProtectionMark.matches(mark, pass);
	}

	/** Turns protection mode on or off, for a caller that already checked the password. */
	public static function setActive(on:Bool):Void {
		if (!available) return;
		lock(on);
	}

	/**
	 * Tries a password. Returns true when it turns protection mode off.
	 *
	 * The caller is responsible for asking; this only answers yes or no, so a wrong
	 * password never changes anything.
	 */
	public static function unlock(pass:String):Bool {
		if (!verify(pass)) {
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
