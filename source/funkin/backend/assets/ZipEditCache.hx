package funkin.backend.assets;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.Path;
#if sys
import sys.FileSystem;
import sys.io.File;
#end

/**
 * Staging folder for edits made to a mod that is loaded from a zip.
 *
 * A zip cannot be written in place, so anything the editors save for such a mod used
 * to land in `mods/<name>/` next to the pack. That folder is easy to lose track of and
 * has nothing to do with the pack it belongs to, so those edits go to `[zip]temp/<name>/`
 * instead - one folder, next to the executable, holding only unsaved work.
 *
 * The engine reads through this folder (see OverlayZipFolderLibrary), and when the game
 * closes with files still in it, the save warning asks whether they should be merged into
 * the pack. Merging rewrites the archive: entries present in the staging folder replace
 * the one in the pack, everything else is copied over untouched, and the result is
 * re-encrypted with the same scheme and key the pack already used.
 *
 * Nothing here runs for folder mods: they are written directly.
 */
class ZipEditCache {
	/** Root of the staging area, relative to the executable (the engine sets that as cwd). */
	public static var root:String = './[zip]temp/';

	/** Name the engine gives the pack of a mod, or null when the mod is a folder. */
	public static function packPath(mod:String):String {
		#if sys
		if (mod == null) return null;
		for (ext in Flags.ALLOWED_ZIP_EXTENSIONS) {
			var path = ModsFolder.modsPath + mod + "." + ext;
			if (FileSystem.exists(path) && !FileSystem.isDirectory(path)) return path;
		}
		#end
		return null;
	}

	/** True when this mod is loaded from a pack rather than from a folder. */
	public static function isPackedMod(mod:String):Bool {
		return packPath(mod) != null;
	}

	/** Staging folder of a mod, with a trailing slash. Created on demand. */
	public static function folder(mod:String, create:Bool = true):String {
		if (mod == null) return null;
		var dir = root + sanitize(mod) + '/';
		#if sys
		if (create) {
			try {
				if (!FileSystem.exists(dir)) FileSystem.createDirectory(dir);
			} catch (e:Dynamic) {}
		}
		#end
		return dir;
	}

	static function sanitize(mod:String):String {
		return mod.split("/").join("_").split("\\").join("_").split(":").join("_");
	}

	// ------------------------------------------------------------ contents

	/** Relative paths of every file staged for this mod (empty when there is none). */
	public static function listFiles(mod:String):Array<String> {
		var out:Array<String> = [];
		#if sys
		if (mod == null) return out;
		var base = folder(mod, false);
		if (base == null || !FileSystem.exists(base) || !FileSystem.isDirectory(base)) return out;
		collect(base, "", out);
		#end
		return out;
	}

	#if sys
	static function collect(base:String, prefix:String, out:Array<String>):Void {
		try {
			for (entry in FileSystem.readDirectory(base + prefix)) {
				var rel = prefix + entry;
				if (FileSystem.isDirectory(base + rel)) collect(base, rel + "/", out);
				else out.push(rel);
			}
		} catch (e:Dynamic) {}
	}
	#end

	/** True when the mod has at least one staged file. */
	public static function hasChanges(mod:String):Bool {
		return listFiles(mod).length > 0;
	}

	/** The mod currently loaded from a pack that has staged edits, or null. */
	public static function pendingMod():String {
		var mod = ModsFolder.currentModFolder;
		if (mod == null || !isPackedMod(mod)) return null;
		return hasChanges(mod) ? mod : null;
	}

	// ------------------------------------------------------------ close prompt

	static var installed:Bool = false;

	/**
	 * Asks about the staged files when the window is closed, the way the editors ask
	 * before dropping unsaved work.
	 *
	 * This registers its own window listener instead of chaining onto
	 * WindowUtils.onClosing: that callback runs after the window already passed its
	 * "should I close?" check, and SaveWarning.init() leaves WindowUtils.preventClosing
	 * false, so by then the close is on its way and a late cancel does nothing.
	 * Cancelling from here runs while the event is still being dispatched, which is
	 * early enough to keep the window open.
	 */
	public static function installClosingPrompt():Void {
		if (installed) return;
		installed = true;
		var app = openfl.Lib.application;
		if (app == null) return;
		app.window.onClose.add(function() {
			if (pendingMod() == null) return;
			app.window.onClose.cancel();
			promptOnClose();
		});
	}

	/** Shows the merge prompt; does nothing when nothing is staged for the current mod. */
	public static function promptOnClose():Void {
		var mod = pendingMod();
		if (mod == null) {
			#if sys
			// A staging folder that exists but is not attributed to the loaded mod is the
			// case worth a line in the log, since that is exactly when no prompt appears.
			if (FileSystem.exists(root))
				Logs.trace('zip edits: nothing staged for "${Std.string(ModsFolder.currentModFolder)}"', INFO);
			#end
			return;
		}
		var state = flixel.FlxG.state;
		if (state == null) return;
		// An editor that has its own unsaved work already owns this close: its dialog
		// saves into [zip]temp, so the merge offer comes up on the next close instead of
		// stacking two prompts on top of each other.
		if (funkin.editors.SaveWarning.showWarning) return;

		// the window has to stay open while the player decides
		funkin.backend.utils.WindowUtils.preventClosing = true;
		funkin.backend.utils.WindowUtils.resetClosing();

		state.openSubState(new funkin.editors.ui.UIWarningSubstate(
			"Unsaved mod changes",
			'The changes made to "$mod" are still waiting in the [zip]temp folder.\n'
			+ 'Merging writes them into the pack, so they are there the next time it loads.',
			[
				{
					label: "Keep editing",
					color: 0x969533,
					onClick: function(_) {
						funkin.backend.utils.WindowUtils.preventClosing = true;
						funkin.backend.utils.WindowUtils.resetClosing();
					}
				},
				{
					label: "Close without merging",
					color: 0x969533,
					onClick: function(_) {
						// the staged files stay in [zip]temp, so nothing is lost
						funkin.backend.utils.WindowUtils.preventClosing = false;
						openfl.system.System.exit(0);
					}
				},
				{
					label: "Merge and close",
					color: 0x969533,
					onClick: function(_) {
						try {
							var summary = merge(mod);
							Logs.trace('$summary', INFO);
						} catch (e:Dynamic) {
							// left staged on purpose: a failed merge must not lose the work
							Logs.error('Could not merge the staged changes into "$mod": ' + e);
						}
						funkin.backend.utils.WindowUtils.preventClosing = false;
						openfl.system.System.exit(0);
					}
				}
			], false));
	}

	// -------------------------------------------------------------- merging

	/**
	 * Writes every staged file of `mod` into its pack.
	 *
	 * The pack is rewritten entry by entry (existing entries are copied as they are,
	 * staged files replace or extend them) and only then put in place of the original,
	 * so a failure halfway cannot leave a half written mod behind. Returns a one line
	 * summary for the caller to show; throws when the merge could not happen.
	 */
	public static function merge(mod:String):String {
		#if sys
		var pack = packPath(mod);
		if (pack == null) throw 'not a packed mod: $mod';
		var files = listFiles(mod);
		if (files.length == 0) return 'nothing to merge';

		var plain = plainCopyOf(pack);
		var merged = plain + '.merged';
		try {
			writeMerged(plain, folder(mod, false), files, merged);
			replaceWith(pack, merged);
		} catch (e:Dynamic) {
			try if (FileSystem.exists(merged)) FileSystem.deleteFile(merged) catch (e2:Dynamic) {}
			throw e;
		}

		// only drop what really made it into the pack
		for (file in files) {
			try FileSystem.deleteFile(folder(mod, false) + file) catch (e:Dynamic) {}
		}
		return 'merged ${files.length} file(s) into ${Path.withoutDirectory(pack)}';
		#else
		return 'not supported on this target';
		#end
	}

	#if sys
	/**
	 * Path of a plain (readable) zip holding the pack's current contents. An encrypted
	 * pack is unwrapped into the cache folder first, with the key it is already unlocked
	 * with; a plain pack is used as it is.
	 */
	static function plainCopyOf(pack:String):String {
		if (ModPackCrypto.isEncryptedPackFile(pack)) {
			var key = ModPackCrypto.resolveKey(pack);
			if (key == null) throw 'the pack is locked: no key opens ${Path.withoutDirectory(pack)}';
			var zip = ModPackCrypto.unpack(File.getBytes(pack), key);
			var out = ModPackCrypto.cacheFolder + ModPackCrypto.CACHE_PREFIX + 'merge_' + Path.withoutExtension(Path.withoutDirectory(pack)) + '.zip';
			ModPackCrypto.ensureCacheFolder();
			File.saveBytes(out, zip);
			return out;
		}
		if (ZipPassword.isProtected(pack)) {
			var key = ModPackCrypto.resolveKey(pack);
			if (key == null) throw 'the pack is locked: no password opens ${Path.withoutDirectory(pack)}';
			return ZipPassword.extractToCache(pack, key);
		}
		return pack;
	}

	/** Rewrites `source` into `out`, replacing/appending everything listed in `files`. */
	static function writeMerged(source:String, overlay:String, files:Array<String>, out:String):Void {
		var entries = ZipPassword.readCentral(source);
		if (entries == null) throw 'cannot read the zip index of ${Path.withoutDirectory(source)}';

		var staged = new Map<String, Bool>();
		for (file in files) staged.set(file.toLowerCase(), true);

		var input = File.read(source, true);
		var output = File.write(out, true);
		var central = new BytesBuffer();
		var pos = 0;
		var count = 0;

		try {
			for (e in entries) {
				var name = e.name;
				var isStaged = staged.exists(name.toLowerCase());
				staged.remove(name.toLowerCase());

				var raw:Bytes;
				var method:Int;
				var crc:Int;
				var usize:Int;
				if (isStaged) {
					var plain = File.getBytes(overlay + name);
					var packed = deflate(plain);
					raw = packed.data;
					method = packed.method;
					crc = ZipPassword.crc32(plain);
					usize = plain.length;
				} else {
					// the source is always a plain copy, so no password is needed here
					var entry = ZipPassword.readRawEntry(input, e, "");
					raw = entry.data;
					method = entry.method;
					crc = e.crc;
					usize = e.usize;
				}

				pos += writeEntry(output, central, name, e.time, e.date, method, crc, raw, usize, pos);
				count++;
			}

			// staged files the pack does not have yet
			for (file in files) {
				if (!staged.exists(file.toLowerCase())) continue;
				var plain = File.getBytes(overlay + file);
				var packed = deflate(plain);
				var crc = ZipPassword.crc32(plain);
				var time = 0, date = 0x21; // 1980-01-01, the zip epoch
				pos += writeEntry(output, central, file, time, date, packed.method, crc, packed.data, plain.length, pos);
				count++;
			}

			var cd = central.getBytes();
			var eocd = new BytesBuffer();
			ZipPassword.writeU32(eocd, 0x06054B50);
			ZipPassword.writeU16(eocd, 0);
			ZipPassword.writeU16(eocd, 0);
			ZipPassword.writeU16(eocd, count);
			ZipPassword.writeU16(eocd, count);
			ZipPassword.writeU32(eocd, cd.length);
			ZipPassword.writeU32(eocd, pos);
			ZipPassword.writeU16(eocd, 0);

			output.write(cd);
			output.write(eocd.getBytes());
			output.close();
			input.close();
		} catch (e:Dynamic) {
			try output.close() catch (e2:Dynamic) {}
			try input.close() catch (e2:Dynamic) {}
			throw e;
		}
	}

	/** One local header + data + central directory record; returns the bytes written. */
	static function writeEntry(output:haxe.io.Output, central:BytesBuffer, name:String, time:Int, date:Int, method:Int, crc:Int,
			data:Bytes, usize:Int, offset:Int):Int {
		var nameBytes = Bytes.ofString(name);
		var flags = ZipPassword.isAscii(name) ? 0 : 0x800;

		var local = new BytesBuffer();
		ZipPassword.writeU32(local, 0x04034B50);
		ZipPassword.writeU16(local, 20);
		ZipPassword.writeU16(local, flags);
		ZipPassword.writeU16(local, method);
		ZipPassword.writeU16(local, time);
		ZipPassword.writeU16(local, date);
		ZipPassword.writeU32(local, crc);
		ZipPassword.writeU32(local, data.length);
		ZipPassword.writeU32(local, usize);
		ZipPassword.writeU16(local, nameBytes.length);
		ZipPassword.writeU16(local, 0);
		local.add(nameBytes);

		output.write(local.getBytes());
		if (data.length > 0) output.write(data);

		var head = new BytesBuffer();
		ZipPassword.writeU32(head, 0x02014B50);
		ZipPassword.writeU16(head, 20);
		ZipPassword.writeU16(head, 20);
		ZipPassword.writeU16(head, flags);
		ZipPassword.writeU16(head, method);
		ZipPassword.writeU16(head, time);
		ZipPassword.writeU16(head, date);
		ZipPassword.writeU32(head, crc);
		ZipPassword.writeU32(head, data.length);
		ZipPassword.writeU32(head, usize);
		ZipPassword.writeU16(head, nameBytes.length);
		ZipPassword.writeU16(head, 0);
		ZipPassword.writeU16(head, 0);
		ZipPassword.writeU16(head, 0);
		ZipPassword.writeU16(head, 0);
		ZipPassword.writeU32(head, 0);
		ZipPassword.writeU32(head, offset);
		head.add(nameBytes);
		central.add(head.getBytes());

		return 30 + nameBytes.length + data.length;
	}

	/** Deflates a staged file; falls back to storing it when that does not help. */
	static function deflate(data:Bytes):{data:Bytes, method:Int} {
		if (data.length == 0) return {data: Bytes.alloc(0), method: 0};
		try {
			var out = Bytes.alloc(data.length + 64);
			var c = new haxe.zip.Compress(-15);
			var r = c.execute(data, 0, out, 0);
			c.close();
			if (r.done && r.write > 0 && r.write < data.length) return {data: out.sub(0, r.write), method: 8};
		} catch (e:Dynamic) {}
		return {data: data, method: 0};
	}

	/** Puts the merged zip in place of the pack, re-encrypting it the way it came. */
	static function replaceWith(pack:String, merged:String):Void {
		var out = merged;
		if (ModPackCrypto.isEncryptedPackFile(pack)) {
			var key = ModPackCrypto.resolveKey(pack);
			if (key == null) throw 'the pack is locked: no key opens ${Path.withoutDirectory(pack)}';
			out = merged + '.cnez';
			File.saveBytes(out, ModPackCrypto.pack(File.getBytes(merged), key));
		} else if (ZipPassword.isProtected(pack)) {
			var key = ModPackCrypto.resolveKey(pack);
			if (key == null) throw 'the pack is locked: no password opens ${Path.withoutDirectory(pack)}';
			out = merged + '.aes';
			ZipAes.encryptZip(merged, out, key);
		}

		// The pack is moved aside instead of deleted, so a failed rename cannot leave the
		// player without a mod: the original goes back and the staged files stay staged.
		var backup = pack + '.old';
		try if (FileSystem.exists(backup)) FileSystem.deleteFile(backup) catch (e:Dynamic) {}
		FileSystem.rename(pack, backup);
		try {
			FileSystem.rename(out, pack);
		} catch (e:Dynamic) {
			try FileSystem.rename(backup, pack) catch (e2:Dynamic) {}
			throw e;
		}
		try FileSystem.deleteFile(backup) catch (e:Dynamic) {}
	}
	#end
}
