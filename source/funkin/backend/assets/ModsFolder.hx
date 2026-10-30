package funkin.backend.assets;

import flixel.util.FlxSignal.FlxTypedSignal;
import funkin.backend.scripting.crypto.ScriptCrypto;
import funkin.backend.system.MainState;
import funkin.backend.utils.CoolUtil;
import haxe.ds.StringMap;
import haxe.io.Path;
import lime.text.Font;
import openfl.text.Font as OpenFLFont;
import openfl.utils.AssetLibrary;
import openfl.utils.AssetManifest;

using StringTools;
#if MOD_SUPPORT
import sys.FileSystem;
#end


class ModsFolder {
	/**
	 * INTERNAL - Only use when editing source mods!!
	 */
	@:dox(hide) public static var onModSwitch:FlxTypedSignal<String->Void> = new FlxTypedSignal<String->Void>();

	/**
	 * Current mod folder. Will affect `Paths`.
	 */
	public static var currentModFolder:String = null;
	/**
	 * Path to the `mods` folder.
	 */
	public static var modsPath:String = "./mods/";
	/**
	 * Path to the `addons` folder.
	 */
	public static var addonsPath:String = "./addons/";

	/**
	 * If accessing a file as assets/data/global/LIB_mymod.hx should redirect to mymod:assets/data/global.hx
	 */
	public static var useLibFile:Bool = true;

	/**
	 * Whenever its the first time mods has been reloaded.
	 */
	private static var __firstTime:Bool = true;
	
	@:dox(hide) public static var modsListSortCache:StringMap<Array<String>> = new StringMap();

	/**
	 * Initializes `mods` folder.
	 */
	public static function init() {
		if(!getModsList().contains(Options.lastLoadedMod)) {
			if(Options.lastLoadedMod != null)
				Logs.warn("Mod \"" + Options.lastLoadedMod + "\" not found in mods list, switching to base game!");
			Options.lastLoadedMod = null;
		}
	}

	/**
	 * Switches mod - unloads all the other mods, then load this one.
	 * @param libName
	 */
	public static function switchMod(mod:String) {
		ModPackCrypto.disableMods = false; // an explicit mod choice re-enables mods
		Options.lastLoadedMod = currentModFolder = mod;
		reloadMods();
		if(mod == null) {
			mod = "(default)";
		}
		Logs.traceColored([
			Logs.logText('Switched to mod: '),
			Logs.logText(mod, GREEN)
		], VERBOSE);
	}

	public static function reloadMods() {
		if (!__firstTime)
			FlxG.switchState(new MainState());
		__firstTime = false;
	}

	/**
	 * Loads a mod library from the specified path. Supports folders and zips.
	 * @param modName Name of the mod
	 * @param force Whenever the mod should be reloaded if it has already been loaded
	 */
	public static function loadModLib(path:String, force:Bool = false, ?modName:String) {
		#if MOD_SUPPORT
		for (ext in Flags.ALLOWED_ZIP_EXTENSIONS) {
			var packPath = '$path.$ext';
			if (!FileSystem.exists(packPath)) continue;
			// This path only runs without a progress screen when the loader could not
			// prepare the pack beforehand; warn so a missing decryption screen shows
			// up in the log instead of silently freezing the game.
			if (!ModPackCrypto.preparing && ModPackCrypto.needsKey(packPath) && !ModPackCrypto.hasCacheForKey(packPath))
				Logs.warn('Decrypting "$packPath" without the progress screen (no prepare pass was scheduled for it).');
			var zipPath = ModPackCrypto.zipPathToLoad(packPath);
			if (zipPath == null) {
				// Every scheme this fork understands (CNEZ, ZipCrypto, WinZip AES) only fails
				// for a missing or wrong key, so there is no separate "unsupported format" case.
				Logs.warn('Skipping encrypted mod pack "$packPath": it needs a password that was not given.');
				return null;
			}
			try {
				// `mods/Name.zip` with a `mods/Name/` folder next to it: the folder holds
				// what the editors saved, so it is laid on top of the pack instead of
				// being ignored (see OverlayZipFolderLibrary)
				var overlayFolder:String = null;
				if (FileSystem.exists(path) && FileSystem.isDirectory(path)) overlayFolder = path;
				return loadLibraryFromZip('$path'.toLowerCase(), zipPath, force, modName, MODS, overlayFolder);
			} catch (e:Dynamic) {
				// a broken or unsupported zip must not take the whole game down
				Logs.error('Failed to load mod pack "$packPath": ' + e);
				return null;
			}
		}
		// a script_key.txt inside the mod (usually mods/<name>/data/) is picked up
		// by the engine as well, so a mod can ship the key of its own encrypted pack
		ScriptCrypto.addKeyFile('$path/data/script_key.txt');
		ScriptCrypto.addKeyFile('$path/script_key.txt');
		return loadLibraryFromFolder('$path'.toLowerCase(), '$path', force, modName);

		#else
		return null;
		#end
	}

	public static function getModConfig(mod:String):Map<String, Map<String, String>> {
		for (ext in Flags.ALLOWED_ZIP_EXTENSIONS) {
			var path = modsPath + mod + "." + ext;
			if (!FileSystem.exists(path))
				continue;

			// Encrypted packs are not readable as zips in place: hand SysZip the
			// decrypted copy instead. Never decrypt here (this runs for every pack in
			// the mod menu, on the main thread), so a pack whose key is still unknown
			// simply reports no config.
			var zipPath:String = path;
			if (ModPackCrypto.needsKey(path)) {
				if (!ModPackCrypto.hasCacheForKey(path)) break;
				zipPath = ModPackCrypto.zipPathToLoad(path);
				if (zipPath == null) break;
			}

			// A broken pack must not take the whole menu down with it.
			try {
				var zip = new SysZip(zipPath);
				for (entry in zip.entries) {
					if (entry.fileName.toLowerCase() == "data/config/modpack.ini") {
						var bytes = zip.unzipEntry(entry);
						return IniUtil.parseString(bytes.getString(0, bytes.length));
					}
				}
			} catch (e:Dynamic) {
				Logs.warn('Could not read the config of "$path": ' + e);
			}
			break; // theoretically once it finds a zip mod, it'll stop even if there's no config
		}

		var filePath = modsPath + mod + "/data/config/modpack.ini";
		if (FileSystem.exists(filePath))
			return IniUtil.parseString(sys.io.File.getContent(filePath));

		return [];
	}

	public static function getModsList(?sortingOptions:ModSortingOptions):Array<String> {
		var mods:Array<String> = [];
		#if MOD_SUPPORT
		// Mods directory does not exist yet, create it
		if (!FileSystem.exists(modsPath)) FileSystem.createDirectory(modsPath);
		
		final modsList:Array<String> = FileSystem.readDirectory(modsPath);

		if (modsList == null || modsList.length <= 0) return mods;

		for (modFolder in modsList) {
			// "Name.zip" and "Name/" are the same mod (the folder is the writable
			// overlay of the pack), so list it once instead of twice
			var modName:String = null;
			if (FileSystem.isDirectory(modsPath + modFolder)) modName = modFolder;
			else if (Flags.ALLOWED_ZIP_EXTENSIONS.contains(Path.extension(modFolder))) modName = Path.withoutExtension(modFolder);
			if (modName != null && !mods.contains(modName)) mods.push(modName);
		}
		
		if (sortingOptions != null) {
		    var sortForge:StringBuf = new StringBuf();
			for (i in mods) {
			    sortForge.add(i);
				sortForge.add("::");
			}

			sortForge.add(Std.string(sortingOptions.descending ? 1 : 0));

			sortForge.add(sortingOptions.mode);
			
			final sortForgePure:String = sortForge.toString();

			if (modsListSortCache.exists(sortForgePure))
			    mods = modsListSortCache.get(sortForgePure);
				if (mods.length > 0 && mods[mods.length - 1] == null) mods.pop();
			else {
			    ModSortingController.sort(sortingOptions, mods);
				modsListSortCache.set(sortForgePure, mods);
			}
		}
		#end
		return mods;
	}
	public static function getLoadedModsLibs(skipTranslated:Bool = false):Array<IModsAssetLibrary> {
		var libs = [];
		if (Paths.assetsTree == null) return libs;
		for (i in Paths.assetsTree.libraries) {
			var l = AssetsLibraryList.getCleanLibrary(i);
			#if TRANSLATIONS_SUPPORT
			if(skipTranslated && (l is TranslatedAssetLibrary)) continue;
			#end
			// No need to check for it being a `ScriptedAssetLibrary`, if `ScriptedAssetLibrary` extends ModsFolderLibrary, which implements `IModsAssetLibrary`
			// If you have to revert this change then uhhhhh wasn't me, trust 🙏
			if (/*l is ScriptedAssetLibrary ||*/ l is IModsAssetLibrary) libs.push(cast(l, IModsAssetLibrary));
		}
		return libs;
	}
	public static function getLoadedMods(skipTranslated:Bool = false):Array<String>
		return [for (modLib in getLoadedModsLibs(skipTranslated)) modLib.modName];

	public static function prepareLibrary(libName:String, force:Bool = false) {
		var assets:AssetManifest = new AssetManifest();
		assets.name = libName;
		assets.version = 2;
		assets.libraryArgs = [];
		assets.assets = [];

		return AssetLibrary.fromManifest(assets);
	}

	public static function registerFont(font:Font) {
		var openflFont = new OpenFLFont();
		@:privateAccess
		openflFont.__fromLimeFont(font);
		OpenFLFont.registerFont(openflFont);
		return font;
	}

	public static function prepareModLibrary(libName:String, lib:IModsAssetLibrary, force:Bool = false, ?tag:AssetSource) {
		var openLib = prepareLibrary(libName, force);
		lib.prefix = 'assets/';
		@:privateAccess
		openLib.__proxy = cast(lib, lime.utils.AssetLibrary);
		if (tag != null) {
			openLib.tag = tag;
			cast(lib, lime.utils.AssetLibrary).tag = tag;
		}
		return openLib;
	}

	#if MOD_SUPPORT
	public static function loadLibraryFromFolder(libName:String, folder:String, force:Bool = false, ?modName:String, ?tag:AssetSource = MODS) {
		return prepareModLibrary(libName, new ModsFolderLibrary(folder, libName, modName), force, tag);
	}

	public static function loadLibraryFromZip(libName:String, zipPath:String, force:Bool = false, ?modName:String, ?tag:AssetSource = MODS, ?overlayFolder:String) {
		// with a writable folder next to the pack, files saved in-game must win over
		// the archive (OverlayZipFolderLibrary); otherwise the plain zip library is used
		var lib:IModsAssetLibrary = (overlayFolder == null)
			? new ZipFolderLibrary(zipPath, libName, modName)
			: new OverlayZipFolderLibrary(zipPath, libName, modName, overlayFolder);
		return prepareModLibrary(libName, lib, force, tag);
	}
	#end
}

/**
 * Describes how mods should be sorted when getting the mods list.
 */
typedef ModSortingOptions = {
    /**
     * Whether or not the list should go in descending order (e.g. `[2, 1, 0]`).
     */
    var descending:Bool;
    /**
     * The sorting mode to use.
     */
    var mode:ModSortingMode;
}

/**
 * This class performs the actual sorting for the mods list.
 */
class ModSortingController {
    /**
     * Sort the mods list, according to the provided sorting options.
     */
    public static function sort(sortingOptions:ModSortingOptions, list:Array<String>):Void {
        switch (sortingOptions.mode) {
            case ModSortingMode.CLEAN: {}
            case ModSortingMode.ALPHABETICAL: CoolUtil.sortAlphabetically(list);
        }
        if (sortingOptions.descending) list.reverse();
    }
}

/**
 * The mods list can be sorted in all of the ways provided by this enum.
 */
enum abstract ModSortingMode(String) {
    /**
     * Use the original list received from reading the directory. This may depend
     * on the current platform, but remains for legacy purposes.
     */
    var CLEAN;
    /**
     * The list should be in alphabetical order.
     */
    var ALPHABETICAL;
}