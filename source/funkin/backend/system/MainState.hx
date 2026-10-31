package funkin.backend.system;

import funkin.backend.system.console.ConsoleCommandManager;
#if MOD_SUPPORT
import sys.FileSystem;
#end
import flixel.FlxState;
import funkin.backend.assets.AssetsLibraryList;
import funkin.backend.assets.ModsFolder;
import funkin.backend.assets.ModPackCrypto;
import funkin.backend.assets.ModsFolderLibrary;
import funkin.backend.assets.ZipFolderLibrary;
import funkin.backend.chart.EventsData;
import funkin.backend.system.framerate.Framerate;
import funkin.editors.ModConfigWarning;
import funkin.menus.TitleState;
import haxe.io.Path;
import openfl.Lib;


@dox(hide)
typedef AddonInfo = {
	var name:String;
	var path:String;
}

/**
 * Simple state used for loading the game
 */
class MainState extends FlxState {
	public static var initiated:Bool = false;
	public override function create() {
		super.create();
		// the initiated flag is set right away so an early return (decryption screen)
		// cannot run the game settings twice, but the goToSong block at the end still
		// needs to know whether this was the first pass
		final firstLoad = !initiated;
		if (firstLoad) Main.loadGameSettings();
		initiated = true;

		#if sys
		CoolUtil.deleteFolder('./.temp/'); // delete temp folder
		#end
		Options.save();

		ControlsUtil.resetCustomControls();
		ConsoleCommandManager.unregisterModdedCommands();
		FlxG.bitmap.reset();
		FlxG.sound.destroy(true);
		FlxG.sound.resetCache();

		Paths.assetsTree.reset();

		// The decrypted pack of the previous mod lives in memory now, not in a cache
		// folder: drop it (and the key file copied out of it) before another one loads.
		ModPackCrypto.releaseZips();
		ModPackCrypto.cleanCache();

		final skipMods = ModPackCrypto.disableMods; // "play without mods" was picked

		#if MOD_SUPPORT
		inline function isDirectory(path:String):Bool
			return FileSystem.exists(path) && FileSystem.isDirectory(path);

		inline function ltrim(str:String, prefix:String):String
			return str.substr(prefix.length).ltrim();

		inline function loadLib(path:String, name:String) {
			var lib = ModsFolder.loadModLib(path, name);
			if (lib != null) Paths.assetsTree.addLibrary(lib);
		}

		var _lowPriorityAddons:Array<AddonInfo> = [];
		var _highPriorityAddons:Array<AddonInfo> = [];
		var _noPriorityAddons:Array<AddonInfo> = [];

		var quick_modsPath = ModsFolder.modsPath + ModsFolder.currentModFolder;

		// handing if the loading mod (before it's properly loaded) is a compressed mod
		// we just need to use `Paths.assetsTree.hasCompressedLibrary` to complete valid checks for actual loaded compressed mods
		var isZipMod = false;
		
		// If we know it's a compressed mod, then we can check if it's using the `cnemod` folder path.
		// All it is really is a folder with the mod's name, then a compressed file called "cnemod.[zip|7z|rar|etc]"
		var isCneMod = false;

		// We are doing it like this because think about it: it's 1 for loop lol
		// We just need to know if any of these values is true, so if only one is true and we are not close to being done in the loop, that's fine.
		// 
		for (ext in Flags.ALLOWED_ZIP_EXTENSIONS) {
			if (FileSystem.exists(quick_modsPath+"."+ext)) isZipMod = true;
			if (FileSystem.exists(quick_modsPath+"/cnemod."+ext)) isCneMod = true;
			if (isZipMod && isCneMod) break;
		}
		
		// We get the addons folder from relative space (`./`) and then our mod's addons.
		var addonPaths = skipMods ? [] : [
			ModsFolder.addonsPath,
			// So to check the mod's addons folder, we need to decompress it. Which is impossible* in this stage of the loading library process.
			// TODO: Write a function when the library is loaded to decompress the contents and then load the libraries :)
			( (ModsFolder.currentModFolder != null && !isZipMod) ?
				quick_modsPath + "/addons/" : null
			)
		];

		for (path in addonPaths) {
			if (path == null) continue;
			if (!isDirectory(path)) continue;

			for (addon in FileSystem.readDirectory(path)) {
				if (!FileSystem.isDirectory(path + addon)) {
					if (Flags.ALLOWED_ZIP_EXTENSIONS.contains(Path.extension(addon))) addon = Path.withoutExtension(addon);
					else continue;
				}
				if (Options.disabledAddons.contains(addon)) continue;

				var data:AddonInfo = {
					name: addon,
					path: path + addon
				};

				if (addon.startsWith("[LOW]")) _lowPriorityAddons.insert(0, data);
				else if (addon.startsWith("[HIGH]")) _highPriorityAddons.insert(0, data);
				else _noPriorityAddons.insert(0, data);
			}
		}

		var libPaths:Array<String> = [];
		for (addon in _lowPriorityAddons) libPaths.push(addon.path);
		for (addon in _noPriorityAddons) libPaths.push(addon.path);
		for (addon in _highPriorityAddons) libPaths.push(addon.path);
		if (!skipMods && ModsFolder.currentModFolder != null)
			libPaths.push(ModsFolder.modsPath + ModsFolder.currentModFolder);

		// Encrypted packs must be decrypted before the loader touches them: the plain
		// zip reader cannot read password protected entries and would throw. The
		// decryption runs on a worker thread behind a progress screen.
		// No attempt counter here: switching mods from the menu must always show the
		// progress screen again when the cached copy is gone. Packs that already
		// failed during this session are filtered out by packsNeedingWork instead.
		if (!skipMods) {
			var work = ModPackCrypto.packsNeedingWork(libPaths);
			if (work.length > 0) {
				// These screens are shown before Flags.load(), and lazy flags are null
				// until reset() runs, which made the title bar and the version text
				// read "null". Initialise the base flags first.
				Flags.reset();
				WindowUtils.title = Flags.TITLE;
				#if SHOW_BUILD_ON_FPS
				if (Framerate.isLoaded && Framerate.codenameBuildField != null)
					Framerate.codenameBuildField.reload();
				#end

				// Ask for the key first when no known key really opens the pack; only
				// then does the progress screen have something to do. The check is
				// cheap (a few decrypted bytes), so a script_key.txt with a stale
				// password no longer flashes the loading screen before the prompt.
				var locked:Array<String> = [];
				for (zip in work)
					if (!ModPackCrypto.hasWorkingKey(zip)) locked.push(zip);

				if (locked.length > 0)
					FlxG.switchState(new funkin.menus.ModPackKeyState(locked));
				else
					FlxG.switchState(new funkin.menus.ModPackLoadingState(work));
				return;
			}
		}
		#end

		#if GLOBAL_SCRIPT
		funkin.backend.scripting.GlobalScript.destroy();
		#end
		funkin.backend.scripting.Script.staticVariables.clear();

		#if MOD_SUPPORT
		try {
			for (addon in _lowPriorityAddons)
				loadLib(addon.path, ltrim(addon.name, "[LOW]"));

			if (!skipMods && ModsFolder.currentModFolder != null) {
				// isCneMod is a guarentee to be a zip mod because we just checked for it, so this will always load as a CompressedLibrary
				if (isCneMod)
					loadLib(quick_modsPath + "/cnemod", ModsFolder.currentModFolder);
				else
					loadLib(quick_modsPath, ModsFolder.currentModFolder);
			}

			for (addon in _noPriorityAddons)
				loadLib(addon.path, addon.name);

			for (addon in _highPriorityAddons)
				loadLib(addon.path, ltrim(addon.name, "[HIGH]"));
		} catch (e:Dynamic) {
			// a broken pack must never take the whole game down: show the blue screen,
			// where Enter restarts with every mod disabled
			funkin.backend.system.modules.CrashHandler.present(Std.string(e), haxe.CallStack.exceptionStack());
			return;
		}
		#end

		Flags.reset();
		Flags.load();
		funkin.savedata.FunkinSave.init();

		Framerate.fontName = Framerate.defaultFontName;

		FlxG.mouse.load();
		FlxG.mouse.useSystemCursor = true;

		if (Framerate.isLoaded)
			Framerate.instance.visible = Framerate.memoryCounter.visible = Framerate.codenameBuildField.visible = Framerate.fpsCounter.visible = true;

		Main.refreshAssets();
		TranslationUtil.findAllLanguages();
		TranslationUtil.setLanguage(Flags.DISABLE_LANGUAGES ? Flags.DEFAULT_LANGUAGE : null);
		MusicBeatTransition.script = Flags.DEFAULT_TRANSITION_SCRIPT;
		WindowUtils.setResolution();
		WindowUtils.resetIcon();
		WindowUtils.resetAffixes(false);
		WindowUtils.setWindow();
		ModsFolder.onModSwitch.dispatch(skipMods ? null : ModsFolder.currentModFolder); // Loads global.hx
		DiscordUtil.init();
		EventsData.reloadEvents();
		ControlsUtil.loadCustomControls();
		TitleState.initialized = false;

		if (Framerate.isLoaded)
			Framerate.instance.reload();

		#if sys
		CoolUtil.safeAddAttributes('./.temp/', NativeAPI.FileAttribute.HIDDEN);
		#end

		for (lib in ModsFolder.getLoadedModsLibs()) {
			if (!(lib is ZipFolderLibrary)) continue;
			if (cast(lib, ZipFolderLibrary).PRELOAD_VIDEOS) cast(lib, ZipFolderLibrary).precacheVideos();
		}

		#if MOD_SUPPORT
		// An encrypted mod pack asks for its key once everything else is ready. The
		// prompt has to come after the asset tree exists (its state inherits from
		// MusicBeatState, which loads per-state scripts), and after the mod pass
		// above has already loaded every pack it could open.
		//
		// Only the packs this pass actually tried to open are asked about (the current
		// mod and the addons that belong to it), so an unused encrypted zip elsewhere
		// in mods/ cannot interrupt a session that plays a plain mod.
		if (!skipMods) {
			var candidates:Array<String> = [];
			for (addon in _lowPriorityAddons) candidates.push(addon.path);
			for (addon in _noPriorityAddons) candidates.push(addon.path);
			for (addon in _highPriorityAddons) candidates.push(addon.path);
			if (ModsFolder.currentModFolder != null)
				candidates.push(ModsFolder.modsPath + ModsFolder.currentModFolder);

			var pendingPacks:Array<String> = [];
			for (candidate in candidates) {
				var zip = ModPackCrypto.pendingPackFor(candidate);
				if (zip != null) pendingPacks.push(zip);
			}

			if (pendingPacks.length > 0) {
				FlxG.switchState(new funkin.menus.ModPackKeyState(pendingPacks));
				return;
			}
		}
		#end

		if (firstLoad) {
			if (Main.goToSong != null) {
				if (Main.goToCharter) FlxG.switchState(new funkin.editors.charter.Charter(Main.goToSong, Main.goToDifficulty, Main.goToVariation));
				else {
					// `play-song` boot flag: same route as Freeplay, with the loading screen
					funkin.menus.SongLoadingScreen.startSong(Main.goToSong, Main.goToDifficulty, Main.goToVariation);
				}
			}
		}

		if (@:privateAccess FlxG.game._nextState == null) {
			var startState:Class<FlxState> = Flags.DISABLE_WARNING_SCREEN ? TitleState : funkin.menus.WarningState;
			var outdatedAPI:Bool = (Flags.MOD_API_VERSION ?? Flags.CURRENT_API_VERSION) < Flags.CURRENT_API_VERSION;
			// In this case if the mod we just loaded a compressed modpack, we can't edit or modify files without decompressing it.
			if (Options.devMode && Options.allowConfigWarning && !isZipMod && !skipMods) {
				var lib:ModsFolderLibrary;
				for (e in Paths.assetsTree.libraries) if ((lib = cast AssetsLibraryList.getCleanLibrary(e)) is ModsFolderLibrary
					&& lib.modName == ModsFolder.currentModFolder)
				{
					if (!outdatedAPI && lib.exists(Paths.ini("config/modpack"), lime.utils.AssetType.TEXT)) break;

					FlxG.switchState(new ModConfigWarning(lib, startState, outdatedAPI));
					return;
				}
			}

			FlxG.switchState(cast Type.createInstance(startState, []));
		}
	}
}
