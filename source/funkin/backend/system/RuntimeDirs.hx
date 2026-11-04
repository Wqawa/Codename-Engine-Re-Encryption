package funkin.backend.system;

#if sys
import sys.FileSystem;
#end

/**
 * The one hidden folder the engine writes to while it runs.
 *
 * Older builds used three of them next to the executable, all for the same reason - a zip
 * cannot be read or written in place. Three folders nobody can tell apart are three
 * folders nobody looks after, so they are one:
 *
 *   .cne/keys/              what a pack's own script_key.txt was copied to
 *   .cne/mods/<mod>/        edits staged by the editors, laid over the pack as-is
 *   .cne/mods/<mod>/videos/ videos lifted out of the pack; read only, never merged
 *   .cne/temp/              genuinely temporary: editor undo, updater scratch
 *   .cne/logs/              engine.log, written while the game runs
 *
 * The root is hidden on Windows and swept on exit, except for the staged edits and the
 * log: those are the two things a player would miss.
 */
class RuntimeDirs {
	/** Root, hidden by attribute on Windows. */
	public static inline var ROOT:String = './.cne/';

	/** Key files copied out of packed mods. */
	public static inline var KEYS:String = ROOT + 'keys/';

	/** Staged mod assets, one folder per mod. */
	public static inline var MODS:String = ROOT + 'mods/';

	/** Anything genuinely temporary. */
	public static inline var TEMP:String = ROOT + 'temp/';

	/** Log file of the current run. */
	public static inline var LOGS:String = ROOT + 'logs/';

	/** Folders earlier builds wrote to; swept on sight. */
	public static var legacyFolders:Array<String> = ['./.CNE_mods/', './.cne_mods/', './[zip]temp/', './.temp/'];

	/** Creates `path` (and every missing parent) and keeps the chain hidden. */
	public static function ensure(path:String):Void {
		#if sys
		try {
			if (path == null || path.length == 0) return;
			makeDirs(path);
			hideChain(path);
		} catch (e:Dynamic) {}
		#end
	}

	#if sys
	/** createDirectory only handles one level, and these paths are always nested. */
	static function makeDirs(path:String):Void {
		var target = trimSeparator(path);
		if (target.length == 0 || FileSystem.exists(target)) return;
		var parent = haxe.io.Path.directory(target);
		if (parent != null && parent.length > 1 && parent != target) makeDirs(parent);
		try FileSystem.createDirectory(target) catch (e:Dynamic) {}
	}

	static function trimSeparator(path:String):String {
		var out = path;
		while (out.length > 1 && (out.endsWith('/') || out.endsWith('\\'))) out = out.substr(0, out.length - 1);
		return out;
	}
	#end

	/**
	 * Hides the root, the folder itself and the folder above it.
	 *
	 * Windows hides a directory by attribute, so a child created later is visible again
	 * even when its parent is hidden: hiding only the root left the inside of .cne half
	 * visible. hideAll() catches whatever was already there.
	 */
	static function hideChain(path:String):Void {
		#if windows
		hide(ROOT);
		hide(path);
		var parent = path.substr(0, path.lastIndexOf("/", path.length - 2) + 1);
		if (parent.length > ROOT.length) hide(parent);
		#end
	}

	/** Hides everything under the root, including files created by an older build. */
	public static function hideAll():Void {
		#if windows
		try {
			if (!FileSystem.exists(ROOT)) return;
			hideTree(ROOT);
		} catch (e:Dynamic) {}
		#end
	}

	static function hideTree(path:String):Void {
		#if windows
		try {
			hide(path);
			if (!FileSystem.isDirectory(path)) return;
			for (name in FileSystem.readDirectory(path)) {
				var child = join(path, name);
				if (FileSystem.isDirectory(child)) hideTree(child + "/");
				else hide(child);
			}
		} catch (e:Dynamic) {}
		#end
	}

	/**
	 * Brings what earlier builds left behind into the new layout, once per start.
	 *
	 * `[zip]temp/<mod>/` holds the player's unmerged edits, so it is moved rather than
	 * deleted. The other old folders only held rebuildable data and just go.
	 */
	public static function migrateLegacy():Void {
		#if sys
		try {
			var old = "./[zip]temp/";
			if (FileSystem.exists(old) && FileSystem.isDirectory(old)) {
				for (mod in FileSystem.readDirectory(old)) {
					var from = old + mod + "/";
					if (!FileSystem.isDirectory(from)) continue;
					ensure(MODS);
					moveTree(from, MODS + mod + "/");
				}
			}
		} catch (e:Dynamic) {}

		for (folder in legacyFolders) {
			try {
				if (!FileSystem.exists(folder) || !FileSystem.isDirectory(folder)) continue;
				funkin.backend.utils.CoolUtil.deleteFolder(folder);
				FileSystem.deleteDirectory(folder);
			} catch (e:Dynamic) {}
		}

		hideAll();
		#end
	}

	/** Moves a directory tree, merging into `to` when it already exists. */
	static function moveTree(from:String, to:String):Void {
		#if sys
		try {
			if (!FileSystem.exists(to)) {
				FileSystem.rename(from, to);
				return;
			}
			if (!FileSystem.isDirectory(to)) return;
			for (name in FileSystem.readDirectory(from)) {
				var src = from + name;
				var dst = to + name;
				if (FileSystem.isDirectory(src)) moveTree(src + "/", dst + "/");
				else if (!FileSystem.exists(dst)) FileSystem.rename(src, dst);
			}
		} catch (e:Dynamic) {}
		#end
	}

	/** Staging folder of a mod, with a trailing slash. Created on demand. */
	public static function modAssets(mod:String, create:Bool = true):String {
		if (mod == null) return null;
		var dir = MODS + sanitize(mod) + '/';
		if (create) ensure(dir);
		return dir;
	}

	/**
	 * Where the videos of a packed mod are lifted to.
	 *
	 * hxvlc is handed a path here rather than bytes, which is what upstream's
	 * ZipFolderLibrary does too; a cutscene is usually the largest file in a pack, and
	 * reading it back through the asset library on every play costs more than one
	 * extraction per launch.
	 */
	public static function modVideos(mod:String):String {
		if (mod == null) return null;
		var dir = modAssets(mod, true) + 'videos/';
		ensure(dir);
		return dir;
	}

	/** What a mod's folder name becomes on disk. */
	public static function sanitize(mod:String):String {
		return mod.split("/").join("_").split("\\").join("_").split(":").join("_");
	}

	public static function hide(path:String):Void {
		#if windows
		// SetFileAttributes fails when the path ends with a separator, and hideTree() builds
		// them that way ("child/"): the folders then stayed visible with a
		// "Failed to add attributes ... code of: 0" warning on every mod switch.
		try funkin.backend.utils.CoolUtil.safeAddAttributes(trimSeparator(path), funkin.backend.utils.NativeAPI.FileAttribute.HIDDEN) catch (e:Dynamic) {}
		#end
	}

	/** Empties the temporary side: editor undo data, updater scratch. */
	public static function clearTemp():Void {
		#if sys
		try funkin.backend.utils.CoolUtil.deleteFolder(TEMP) catch (e:Dynamic) {}
		#end
	}

	/**
	 * Drops the videos lifted out of the packs; they are extracted again on demand.
	 *
	 * With a mod name only that mod's folder goes, which is what a switch away from an
	 * encrypted pack uses: those videos are decrypted content on disk, while a plain mod's
	 * copy is a cache that is cheaper to keep than to extract again.
	 * Returns how many files were removed.
	 */
	public static function clearVideos(?mod:String):Int {
		#if sys
		var removed = 0;
		try {
			if (!FileSystem.exists(MODS) || !FileSystem.isDirectory(MODS)) return 0;
			if (mod != null) {
				var only = MODS + sanitize(mod) + "/videos/";
				if (FileSystem.exists(only) && FileSystem.isDirectory(only)) {
					removed = countFiles(only);
					funkin.backend.utils.CoolUtil.deleteFolder(only);
				}
				return removed;
			}
			for (name in FileSystem.readDirectory(MODS)) {
				var dir = MODS + name + "/videos/";
				if (FileSystem.exists(dir) && FileSystem.isDirectory(dir)) {
					removed += countFiles(dir);
					funkin.backend.utils.CoolUtil.deleteFolder(dir);
				}
			}
		} catch (e:Dynamic) {}
		return removed;
		#else
		return 0;
		#end
	}

	/** Files below a folder, recursively, for the cleanup summary. */
	public static function countFiles(dir:String):Int {
		#if sys
		var n = 0;
		try {
			if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir)) return 0;
			for (entry in FileSystem.readDirectory(dir)) {
				var path = join(dir, entry);
				if (FileSystem.isDirectory(path)) n += countFiles(path);
				else n++;
			}
		} catch (e:Dynamic) {}
		return n;
		#else
		return 0;
		#end
	}

	/** `dir` + `name`, with exactly one separator in between. */
	static function join(dir:String, name:String):String {
		if (dir == null || dir.length == 0) return name;
		return dir.endsWith('/') || dir.endsWith('\\') ? dir + name : dir + '/' + name;
	}
}
