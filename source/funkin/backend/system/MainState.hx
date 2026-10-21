package funkin.backend.system;

#if MOD_SUPPORT
import sys.FileSystem;
#end
import flixel.FlxState;
import funkin.backend.assets.AssetsLibraryList;
import funkin.backend.assets.ModsFolder;
import funkin.backend.assets.ModPackCrypto;
import funkin.backend.assets.ModsFolderLibrary;
import funkin.backend.chart.EventsData;
import funkin.backend.system.framerate.Framerate;
import funkin.editors.ModConfigWarning;
import funkin.menus.TitleState;
import haxe.io.Path;

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

		if (!initiated) {
			Main.loadGameSettings();
		}

		initiated = true;

		#if sys
		CoolUtil.deleteFolder('./.temp/'); // delete temp folder
		#end
		Options.save();

		ControlsUtil.resetCustomControls();
		FlxG.bitmap.reset();
		FlxG.sound.destroy(true);

		Paths.assetsTree.reset();

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

		var addonPaths = skipMods ? [] : [
			ModsFolder.addonsPath,
			(
				ModsFolder.currentModFolder != null ?
					ModsFolder.modsPath + ModsFolder.currentModFolder + "/addons/" :
					null
			)
		];

		for(path in addonPaths) {
			if (path == null) continue;
			if (!isDirectory(path)) continue;

			for(addon in FileSystem.readDirectory(path)) {
				if(!FileSystem.isDirectory(path + addon)) {
					switch(Path.extension(addon).toLowerCase()) {
						case 'zip':
							addon = Path.withoutExtension(addon);
						default:
							continue;
					}
				}

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

		try {
			for (addon in _lowPriorityAddons)
				loadLib(addon.path, ltrim(addon.name, "[LOW]"));

			if (!skipMods && ModsFolder.currentModFolder != null)
				loadLib(ModsFolder.modsPath + ModsFolder.currentModFolder, ModsFolder.currentModFolder);

			for (addon in _noPriorityAddons)
				loadLib(addon.path, addon.name);

			for (addon in _highPriorityAddons)
				loadLib(addon.path, ltrim(addon.name, "[HIGH]"));
		} catch (e:Dynamic) {
			// a broken pack must never take the whole game down: show the blue screen,
			// where Enter restarts with every mod disabled
			var info = funkin.menus.CrashScreenState.describe(e);
			if (!funkin.menus.CrashScreenState.show(info.message, info.stack)) throw e;
			return;
		}
		#end

		Flags.reset();
		Flags.load();
		funkin.savedata.FunkinSave.init();

		TranslationUtil.findAllLanguages();
		TranslationUtil.setLanguage(Flags.DISABLE_LANGUAGES ? Flags.DEFAULT_LANGUAGE : null);
		ModsFolder.onModSwitch.dispatch(skipMods ? null : ModsFolder.currentModFolder); // Loads global.hx
		MusicBeatTransition.script = Flags.DEFAULT_TRANSITION_SCRIPT;
		WindowUtils.resetAffixes(false);
		WindowUtils.setWindow();
		Main.refreshAssets();
		DiscordUtil.init();
		EventsData.reloadEvents();
		ControlsUtil.loadCustomControls();
		TitleState.initialized = false;

		if (Framerate.isLoaded)
			Framerate.instance.reload();

		#if sys
		CoolUtil.safeAddAttributes('./.temp/', NativeAPI.FileAttribute.HIDDEN);
		#end

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

		var startState:Class<FlxState> = Flags.DISABLE_WARNING_SCREEN ? TitleState : funkin.menus.WarningState;

		if (Options.devMode && Options.allowConfigWarning && !skipMods) {
			var lib:ModsFolderLibrary;
			for (e in Paths.assetsTree.libraries) if ((lib = cast AssetsLibraryList.getCleanLibrary(e)) is ModsFolderLibrary
				&& lib.modName == ModsFolder.currentModFolder)
			{
				if (lib.exists(Paths.ini("config/modpack"), lime.utils.AssetType.TEXT)) break;

				FlxG.switchState(new ModConfigWarning(lib, startState));
				return;
			}
		}

		FlxG.switchState(cast Type.createInstance(startState, []));
	}
}