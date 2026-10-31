package funkin.backend.system;

#if sys
import sys.FileSystem;
#end

/**
 * The one hidden folder the engine writes to while it runs.
 *
 * There used to be three of them, all next to the executable and all there for the
 * same reason - a zip cannot be read or written in place:
 *
 *   .CNE_mods/   the key file copied out of a packed mod
 *   [zip]temp/   edits the editors staged for a packed mod
 *   .temp/       videos lifted out of a pack, editor undo data, updater scratch
 *
 * Three folders nobody can tell apart is three folders nobody looks after, so they
 * are one now:
 *
 *   .cne/keys/              what a pack's own script_key.txt was copied to
 *   .cne/mods/<mod>/        edits staged by the editors, laid over the pack as-is
 *   .cne/mods/<mod>/videos/ videos lifted out of the pack; read only, never merged
 *   .cne/temp/              genuinely temporary: editor undo, updater scratch
 *
 * `mods/` and `videos/` are the mod-asset side of the folder (the video part is what
 * hxvlc needs on disk, see ZipFolderLibrary.getVideoRemap); `keys/` is the key side.
 * Everything under the root is removed when the game closes.
 */
class RuntimeDirs {
	/** Root, hidden by attribute on Windows and swept on exit. */
	public static inline var ROOT:String = './.cne/';

	/** Key files copied out of packed mods. */
	public static inline var KEYS:String = ROOT + 'keys/';

	/** Staged mod assets, one folder per mod. */
	public static inline var MODS:String = ROOT + 'mods/';

	/** Anything genuinely temporary. */
	public static inline var TEMP:String = ROOT + 'temp/';

	/** Folders earlier builds wrote to; swept on sight. */
	public static var legacyFolders:Array<String> = ['./.CNE_mods/', './.cne_mods/', './[zip]temp/', './.temp/'];

	/** Creates `path` (and the root) when missing, and keeps every level hidden. */
	public static function ensure(path:String):Void {
		#if sys
		try {
			if (path == null) return;
			if (!FileSystem.exists(ROOT)) FileSystem.createDirectory(ROOT);
			if (!FileSystem.exists(path)) FileSystem.createDirectory(path);
			hideChain(path);
		} catch (e:Dynamic) {}
		#end
	}

	/**
	 * Hides the root, the folder itself and the folder above it.
	 *
	 * Windows hides a directory by attribute, so a child created later is visible again
	 * even though its parent is hidden: hiding only the root left the inside of .cne
	 * half visible. This walks the chain every time something is created, and
	 * hideAll() catches whatever was already there.
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
				var child = path + name;
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
	 * deleted. The other old folders only ever held rebuildable data - the key copies
	 * and the video scratch - so they just go.
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

		for (folder in ["./.CNE_mods/", "./.cne_mods/", "./[zip]temp/", "./.temp/"]) {
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
	 * ZipFolderLibrary does too; `Video.load` does accept Bytes, but a cutscene is
	 * usually the largest file in a pack and reading it back through the asset
	 * library on every play is worse than one extraction per launch.
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
		try funkin.backend.utils.CoolUtil.safeAddAttributes(path, funkin.backend.utils.NativeAPI.FileAttribute.HIDDEN) catch (e:Dynamic) {}
		#end
	}

	/** Empties the temporary side: editor undo data, updater scratch. */
	public static function clearTemp():Void {
		#if sys
		try funkin.backend.utils.CoolUtil.deleteFolder(TEMP) catch (e:Dynamic) {}
		#end
	}

	/** Drops the videos lifted out of the packs; they are extracted again on demand. */
	public static function clearVideos():Void {
		#if sys
		try {
			if (!FileSystem.exists(MODS) || !FileSystem.isDirectory(MODS)) return;
			for (mod in FileSystem.readDirectory(MODS)) {
				var dir = MODS + mod + "/videos/";
				if (FileSystem.exists(dir) && FileSystem.isDirectory(dir))
					funkin.backend.utils.CoolUtil.deleteFolder(dir);
			}
		} catch (e:Dynamic) {}
		#end
	}
}
