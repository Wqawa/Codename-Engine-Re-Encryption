package funkin.menus;

import flixel.FlxG;
import flixel.FlxSprite;
import flixel.graphics.FlxGraphic;
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

		buildQueue();
		totalSteps = queue.length;

		if (totalSteps == 0) finish();
	}

	override function update(elapsed:Float) {
		super.update(elapsed);
		if (finished) return;

		this.elapsed += elapsed;

		#if sys final started = Sys.time(); #end
		while (queue.length > 0) {
			final step = queue.shift();
			stepText.text = step.label;
			try {
				step.run();
			} catch (e:Dynamic) {
				// a broken mod asset must never keep the player out of the song
				trace('Song preload failed on "' + step.label + '": ' + e);
			}
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
			hold(graphicCache.cache(path));
		});
	}

	function addCharacterSteps(char:String) {
		final xmlPath = Paths.xml('characters/' + char);
		if (xmlPath != null && Assets.exists(xmlPath)) {
			final keys = collectSpriteRefs(Assets.getText(xmlPath), "");
			for (key in keys) addImageRef(key);
		}

		var icon = char;
		try {
			final fromXml = Character.getIconFromCharName(char);
			if (fromXml != null && fromXml.length > 0) icon = fromXml;
		} catch (e:Dynamic) {}
		addImageStep('icons/icon-' + icon);
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
