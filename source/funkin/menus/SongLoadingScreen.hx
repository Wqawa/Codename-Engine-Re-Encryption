package funkin.menus;

import animate.FlxAnimateFrames;
import flixel.FlxG;
import flixel.FlxSprite;
import flixel.graphics.FlxGraphic;
import flixel.graphics.frames.FlxFramesCollection;
import flixel.sound.FlxSoundData;
import funkin.backend.MusicBeatState;
import funkin.backend.assets.Paths;
import funkin.backend.chart.ChartData;
import funkin.editors.ui.UIState;
import funkin.editors.ui.UIText;
import funkin.game.Character;
import funkin.game.PlayState;
import funkin.options.Options;
import openfl.utils.Assets;

using StringTools;

typedef LoadStep = {
	var label:String;
	var run:Void->Void;
}

/**
 * Shown between the menus and `PlayState` so the assets a song needs are decoded
 * while a progress bar is on screen, instead of on the first frame of the song.
 *
 * Everything is decoded on the main thread, a few assets per frame, so the window
 * keeps responding and the bar really moves. Only things that can be enumerated
 * *before* `PlayState.create()` runs are preloaded: the music, the note skins, the
 * characters and the stage spritesheets. `PlayState.create()` itself still builds
 * its objects, but it no longer has to decode any of those files, which is where
 * the long hitch came from.
 *
 * Turn it off with `SongLoadingScreen.enabled = false`; every entry point then goes
 * straight to `PlayState` like the vanilla engine did.
 */
class SongLoadingScreen extends UIState {
	/**
	 * Set to false to skip this screen entirely.
	 */
	public static var enabled:Bool = true;
	/**
	 * The screen stays up at least this long, so a song whose assets are already
	 * cached does not flash a half drawn bar.
	 */
	public static var minDisplayTime:Float = 0.25;
	/**
	 * Time budget per frame, in seconds. Small enough to keep 60 fps.
	 */
	public static var frameBudget:Float = 0.008;
	/**
	 * When the `CNE_LOAD_PROFILE=1` environment variable is set, every load writes
	 * `songload-profile.log` next to the executable: how long each step took, how
	 * long the longest frame was, and how long `PlayState.create()` took after the
	 * screen was done. Handy when a specific mod's song still hitches.
	 */
	@:noCompletion static var profileEnabled:Bool = #if sys Sys.getEnv("CNE_LOAD_PROFILE") == "1" #else false #end;
	@:noCompletion static var profileLines:Array<String> = [];

	@:noCompletion static function profileStep(label:String, ms:Float) {
		if (profileEnabled) profileLines.push(Std.string(Std.int(ms * 1000) / 1000) + ' ms\t' + label);
	}

	@:noCompletion static function flushProfile(totalMs:Float, maxFrameMs:Float, steps:Int) {
		if (!profileEnabled) return;
		profileEnabled = false;
		try {
			final header = ['# song load: ' + Std.int(totalMs) + ' ms in ' + steps + ' steps, longest frame ' + Std.int(maxFrameMs) + ' ms'];
			profileLines = header.concat(profileLines);
			sys.io.File.saveContent('./songload-profile.log', profileLines.join('\n') + '\n');
		} catch (e:Dynamic) {}
	}

	/**
	 * Graphics preloaded by this screen. They are kept `useCount`-referenced so
	 * that switching to `PlayState` does not drop them from `FlxG.bitmap` before
	 * `PlayState.create()` gets to reuse them; the next song load releases them.
	 */
	@:noCompletion static var held:Array<FlxGraphic> = [];

	@:noCompletion static function hold(g:FlxGraphic) {
		if (g != null && !held.contains(g)) {
			g.incrementUseCount();
			held.push(g);
		}
	}

	@:noCompletion static function releaseHeld() {
		for (g in held) {
			if (g != null) g.decrementUseCount();
		}
		held = [];
	}

	/**
	 * Keeps every graphic a frame collection was built from alive, so the frames
	 * themselves stay in `Paths`' static frame cache until the next song load.
	 */
	@:noCompletion static function holdFrames(frames:FlxFramesCollection) {
		if (frames == null) return;
		// for the usual one-sheet character the parent *is* the sheet graphic; a
		// multi-sheet character gets a dummy 1x1 parent that is never destroyed, and
		// `FlxAtlasFrames.addAtlas` already keeps the sheet graphics referenced
		hold(frames.parent);
	}

	/**
	 * Loads `song` the vanilla way, then shows this screen before entering the game.
	 */
	public static function startSong(song:String, ?difficulty:String, ?variation:Dynamic, opponentMode:Bool = false, coopMode:Bool = false) {
		PlayState.loadSong(song, difficulty, variation, opponentMode, coopMode);
		enterPlayState();
	}

	/**
	 * Enters `PlayState` for whatever song was loaded last, through this screen.
	 */
	public static function enterPlayState() {
		if (!enabled || PlayState.SONG == null) {
			FlxG.switchState(new PlayState());
			return;
		}
		FlxG.switchState(new SongLoadingScreen());
	}

	// ---- ui ----
	var bar:FlxSprite;
	var percentText:UIText;
	var stepText:UIText;
	var songText:UIText;
	var barWidth:Int = 0;

	// ---- work ----
	var queue:Array<LoadStep> = [];
	var totalSteps:Int = 0;
	var doneSteps:Int = 0;
	var elapsed:Float = 0;
	var maxFrameMs:Float = 0;
	var finished:Bool = false;

	public function new() {
		super();
	}

	override function create() {
		super.create();
		// the previous song's graphics are only needed until the player loads another
		// one, so let go of them here rather than growing the cache forever
		releaseHeld();

		FlxG.camera.bgColor = 0xFF101017;

		var songName = PlayState.SONG != null && PlayState.SONG.meta != null ? PlayState.SONG.meta.name : "song";

		add(new UIText(40, 60, FlxG.width - 80, "Loading", 26, 0xFFFFE066, false));
		add(songText = new UIText(40, 100, FlxG.width - 80, songName, 15, 0xFFB0B0BE, false));

		barWidth = FlxG.width - 80;
		add(new FlxSprite(40, 210).makeGraphic(barWidth, 22, 0xFF2A2A34));
		bar = new FlxSprite(43, 213).makeGraphic(Std.int(barWidth - 6), 16, 0xFF61C4FF);
		// scale around the left edge, otherwise the bar grows from the middle outwards
		bar.origin.set(0, 0);
		bar.scale.x = 0.001;
		add(bar);

		add(percentText = new UIText(40, 244, FlxG.width - 80, "0%", 15, 0xFF9BE28C, false));
		add(stepText = new UIText(40, 274, FlxG.width - 80, "Preparing...", 13, 0xFF7A7A88, false));

		#if sys final queueStart = Sys.time(); #end
		buildQueue();
		totalSteps = queue.length;
		#if sys if (profileEnabled) profileLines.push(Std.int((Sys.time() - queueStart) * 1000) + ' ms\tbuildQueue()'); #end

		if (totalSteps == 0) finish();
	}

	override function update(elapsed:Float) {
		super.update(elapsed);
		if (finished) return;

		this.elapsed += elapsed;
		if (elapsed * 1000 > maxFrameMs) maxFrameMs = elapsed * 1000;

		#if sys final started = Sys.time(); #end
		while (queue.length > 0) {
			final step = queue.shift();
			stepText.text = step.label;
			#if sys final stepStart = Sys.time(); #end
			try {
				step.run();
			} catch (e:Dynamic) {
				// a broken mod asset must never keep the player out of the song
				trace('Song preload failed on "' + step.label + '": ' + e);
			}
			#if sys profileStep(step.label, Sys.time() - stepStart); #end
			doneSteps++;
			#if sys if (Sys.time() - started > frameBudget) break; #end
		}

		updateBar();

		if (queue.length == 0 && this.elapsed >= minDisplayTime) finish();
	}

	function updateBar() {
		final p = totalSteps == 0 ? 1.0 : (doneSteps / totalSteps);
		bar.scale.x = Math.max(0.001, p);
		percentText.text = Std.int(p * 100) + "%";
	}

	function finish() {
		if (finished) return;
		finished = true;
		// the screen *is* the transition, a tile wipe here would only stall during
		// PlayState.create(), when nothing can animate anyway
		MusicBeatState.skipTransIn = true;
		MusicBeatState.skipTransOut = true;

		#if sys final totalMs = this.elapsed * 1000;
		final switchStart = Sys.time();
		final steps = totalSteps;
		final longest = maxFrameMs;
		if (profileEnabled) {
			var listener:Void->Void = null;
			listener = function() {
				FlxG.signals.postStateSwitch.remove(listener);
				profileLines.push(Std.int((Sys.time() - switchStart) * 1000) + ' ms\tPlayState.create()');
				flushProfile(totalMs, longest, steps);
			};
			FlxG.signals.postStateSwitch.add(listener);
		}
		#end

		FlxG.switchState(new PlayState());
	}

	// ---- work queue ----

	inline function step(label:String, run:Void->Void) {
		queue.push({label: label, run: run});
	}

	function buildQueue() {
		final song = PlayState.SONG;
		if (song == null || song.meta == null) return;

		// ---- music: the longest single stall, and the easiest to enumerate ----
		var instPath = Paths.inst(song.meta.name, PlayState.difficulty, song.meta.instSuffix);
		if (instPath != null && Assets.exists(instPath)) addSoundStep(instPath, "music");

		var vocalsPath = Paths.voices(song.meta.name, PlayState.difficulty, song.meta.vocalsSuffix);
		// streamed vocals are read from disk while playing, decoding them here would
		// just throw the work away
		if (song.meta.needsVoices && !Options.streamedVocals && vocalsPath != null && Assets.exists(vocalsPath)) addSoundStep(vocalsPath, "vocals");

		// ---- shared gameplay sprites ----
		addImageStep("game/healthBar");
		for (i in 1...4) addSoundStep(Paths.sound('missnote' + i), 'miss sound ' + i);

		var noteSkins = ["game/notes/default"];
		if (song.noteTypes != null) {
			for (type in song.noteTypes) {
				if (type == null || type == "default") continue;
				final skin = 'game/notes/' + type;
				if (!noteSkins.contains(skin)) noteSkins.push(skin);
			}
		}
		for (skin in noteSkins) addImageStep(skin);

		// ---- characters (spritesheets + health icons) ----
		var characters:Array<String> = [];
		if (song.strumLines != null) {
			for (line in song.strumLines) {
				if (line == null || line.characters == null) continue;
				for (char in line.characters) {
					if (char != null && !characters.contains(char)) characters.push(char);
				}
			}
		}
		for (char in characters) addCharacterSteps(char);

		// ---- stage ----
		addStageSteps(song.stage);
	}

	function addSoundStep(path:String, label:String) {
		if (path == null || !Assets.exists(path)) return;
		step(label, () -> {
			// same call PlayState makes, so it hits the sound cache instead of decoding
			FlxSoundData.fromAssetKey(path, false);
		});
	}

	function addImageStep(key:String) {
		if (key == null) return;
		addImagePath(Paths.image(key), key);
	}

	/**
	 * Adds an image whose reference may be either a plain key ("characters/BF") or a
	 * full asset path ("images/characters/BF.png"), which is how spritesheet nodes
	 * inside stage/character XMLs write it.
	 */
	function addImageRef(ref:String) {
		if (ref == null) return;
		ref = ref.trim();
		if (ref.length == 0) return;

		if (ref.startsWith("images/") && Assets.exists(ref)) {
			addImagePath(ref, ref);
			return;
		}
		final key = ref.startsWith("images/") ? ref.substr("images/".length) : ref;
		addImageStep(key);
	}

	function addImagePath(path:String, label:String) {
		if (path == null || !Assets.exists(path)) return;
		step(label, () -> {
			final g = graphicCache.cache(path);
			hold(g);
		});
	}

	function addCharacterSteps(char:String) {
		final xmlPath = Paths.xml('characters/' + char);
		if (xmlPath != null && Assets.exists(xmlPath)) {
			final text = Assets.getText(xmlPath);
			// the frames step loads every sheet this character references, so there is
			// no need to preload the raw <sprite>/<spritesheet> paths on their own
			addCharacterFramesStep(char, text);
		}

		var icon = char;
		try {
			final fromXml = Character.getIconFromCharName(char);
			if (fromXml != null && fromXml.length > 0) icon = fromXml;
		} catch (e:Dynamic) {}
		addImageStep('icons/icon-' + icon);
	}

	/**
	 * Builds the character's frames here, on the loading screen, instead of letting
	 * `Character.buildCharacter()` do it on the first frame of the song.
	 *
	 * `PlayState` ends up doing the exact same `Paths.getMultiFrames()` call with
	 * the exact same sheet list (see `XMLUtil.appendSpriteSheetsFromXML`), so this
	 * just moves the work earlier and the real load hits the frame cache.
	 */
	function addCharacterFramesStep(char:String, xmlText:String) {
		final sheets = collectCharacterSheets(xmlText, char);
		if (sheets.length == 0) return;
		final firstImage = Paths.image(sheets[0], null, true);
		if (firstImage == null || !Assets.exists(firstImage)) return;

		final settings = animateSettingsFrom(xmlText);
		step('character ' + char + ' frames', () -> {
			final frames = Paths.getMultiFrames(sheets, false, false, null, false, null, settings);
			holdFrames(frames);
		});
	}

	/**
	 * Mirrors the sheet list `XMLUtil.appendSpriteSheetsFromXML` builds, otherwise
	 * `getMultiFrames()` would cache the frames under a different key.
	 */
	static function collectCharacterSheets(xmlText:String, char:String):Array<String> {
		final sheets:Array<String> = [];
		final root = parseRoot(xmlText);
		if (root == null) return sheets;

		final spriteAttr = cleanAttribute(root.get("sprite"));
		sheets.push("characters/" + (spriteAttr != null ? spriteAttr : char));

		for (node in root.elements()) {
			if (node.nodeName != "spritesheet" && node.nodeName != "sheet") continue;
			var path = cleanAttribute(node.get("path"));
			if (path == null && node.firstChild() != null) path = cleanAttribute(node.firstChild().nodeValue);
			if (path == null || sheets.contains(path)) continue;
			if (!Paths.framesExists(path, true)) continue;
			sheets.push(path);
		}
		return sheets;
	}

	/**
	 * Same three attributes `Character.buildCharacter()` copies into its own
	 * `animateSettings`, so the cached frames match what the character expects.
	 */
	static function animateSettingsFrom(xmlText:String):FlxAnimateSettings {
		final settings:FlxAnimateSettings = {};
		final root = parseRoot(xmlText);
		if (root == null) return settings;

		final swf = cleanAttribute(root.get("swfMode"));
		if (swf != null) settings.swfMode = (swf == "true");
		final cache = cleanAttribute(root.get("cacheOnLoad"));
		if (cache != null) settings.cacheOnLoad = (cache == "true");
		final quality = cleanAttribute(root.get("filterQuality"));
		if (quality != null) {
			final n = Std.parseInt(quality);
			if (n != null)
				settings.filterQuality = cast(n, FilterQuality);
			else {
				final values = ["high", "medium", "low", "rudy"];
				final index = values.indexOf(quality.toLowerCase());
				if (index > -1) settings.filterQuality = cast(index, FilterQuality);
			}
		}
		return settings;
	}

	static function parseRoot(xmlText:String):Xml {
		if (xmlText == null) return null;
		try {
			return Xml.parse(xmlText).firstElement();
		} catch (e:Dynamic) {
			return null;
		}
	}

	function addStageSteps(stage:String) {
		if (stage == null || stage.length == 0) return;
		final xmlPath = Paths.xml('stages/' + stage);
		if (xmlPath == null || !Assets.exists(xmlPath)) return;

		final text = Assets.getText(xmlPath);
		// stage sprites live in the folder named by the root "folder" attribute
		final folder = getAttribute(text, "folder");
		for (key in collectSpriteRefs(text, folder == null ? "" : folder)) addImageRef(key);
	}

	static function getAttribute(xmlText:String, attribute:String):String {
		try {
			final root = Xml.parse(xmlText).firstElement();
			if (root == null) return null;
			return cleanAttribute(root.get(attribute));
		} catch (e:Dynamic) {
			return null;
		}
	}

	/**
	 * Walks a character/stage XML and returns every sprite reference it declares.
	 */
	static function collectSpriteRefs(xmlText:String, folder:String):Array<String> {
		final refs:Array<String> = [];
		var root:Xml = null;
		try {
			root = Xml.parse(xmlText).firstElement();
		} catch (e:Dynamic) {
			return refs;
		}
		if (root == null) return refs;

		if (folder == null) folder = "";
		if (folder.length > 0 && !folder.endsWith("/")) folder += "/";

		final stack:Array<Xml> = [root];
		while (stack.length > 0) {
			final node = stack.pop();
			if (node == null || node.nodeType != Xml.Element) continue;

			final sprite = cleanAttribute(node.get("sprite"));
			if (sprite != null && sprite.length > 0 && !refs.contains(folder + sprite)) refs.push(folder + sprite);

			if (node.nodeName == "spritesheet" || node.nodeName == "sheet") {
				var path = cleanAttribute(node.get("path"));
				if (path == null && node.firstChild() != null) path = cleanAttribute(node.firstChild().nodeValue);
				if (path != null && path.length > 0 && !refs.contains(path)) refs.push(path);
			}

			for (child in node) {
				if (child.nodeType == Xml.Element) stack.push(child);
			}
		}
		return refs;
	}

	static inline function cleanAttribute(value:String):String {
		if (value == null) return null;
		value = value.trim();
		if (value.length == 0 || value == "null") return null;
		return value;
	}
}
