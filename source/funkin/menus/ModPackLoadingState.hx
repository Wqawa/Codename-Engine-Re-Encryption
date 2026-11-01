package funkin.menus;

import flixel.FlxG;
import flixel.FlxSprite;
import funkin.backend.assets.ModPackCrypto;
import funkin.backend.assets.ModPackCrypto.PreparePhase;
import funkin.backend.system.MainState;
import funkin.editors.ui.UIState;
import funkin.editors.ui.UIText;
import haxe.io.Path;

/**
 * Shown while an encrypted mod pack is decrypted, so a big pack does not freeze
 * the game for a few seconds with a black screen.
 *
 * The work runs on a worker thread (ModPackCrypto.startPrepare) and this state
 * only draws the progress it reports. When every pack opened, the loader runs
 * again and this time finds the decrypted copies in the cache; when some pack
 * failed, the key prompt is shown for those packs only.
 *
 * Three levels of detail on purpose: the thick bar is the whole pass, the thin one is
 * the pack being decrypted right now, and the list at the bottom names every pack this
 * pass has to open - yellow while it is being worked on, green once it is done. The
 * container is one cipher stream, so there is no per-entry figure to report: the packs
 * are the unit the engine actually decrypts.
 *
 * Closing the window while this runs is handled by ModPackCrypto.installCloseVeto: it
 * pauses the pass first, asks, and resumes or exits.
 */
class ModPackLoadingState extends UIState {
	static inline var MARGIN:Int = 40;
	/** One start in this many shows the little animation (see maybeAddEasterEgg). */
	static inline var EASTER_EGG_CHANCE:Int = 20;

	static inline var BAR_BACK:Int = 0xFF2A2A34;
	static inline var BAR_MAIN:Int = 0xFF61C4FF;
	static inline var BAR_SUB:Int = 0xFF9B7BFF;
	static inline var RULE:Int = 0xFF2A2A34;

	static inline var PENDING_COLOR:Int = 0xFF7A7A88;
	static inline var CURRENT_COLOR:Int = 0xFFFFE066;
	static inline var DONE_COLOR:Int = 0xFF6BE26B;
	static inline var FAILED_COLOR:Int = 0xFFFF5A5A;

	public var packs:Array<String> = [];
	public var bar:FlxSprite;
	public var packBar:FlxSprite;
	public var percentText:UIText;
	public var packText:UIText;
	public var hintText:UIText;
	public var etaText:UIText;
	public var packEtaText:UIText;
	public var stepText:UIText;
	public var listTexts:Array<UIText> = [];
	public var finished:Bool = false;
	public var startedAt:Float = 0;
	public var barWidth:Int = 0;

	// estimate bookkeeping: progress is not linear (reading the file, deriving the
	// key and the cipher pass all run at different speeds), so both estimates are
	// smoothed instead of following the raw ratio
	var elapsedTotal:Float = 0;
	var elapsedPack:Float = 0;
	var lastPackIndex:Int = 0;
	var etaSmooth:Float = -1;
	var packEtaSmooth:Float = -1;

	public function new(packs:Array<String>) {
		super();
		this.packs = packs == null ? [] : packs;
	}

	override function create() {
		super.create();
		FlxG.camera.bgColor = 0xFF101017;

		var names = "";
		for (p in packs) {
			var n = Path.withoutExtension(Path.withoutDirectory(p));
			names += (names.length == 0 ? "" : ", ") + n;
		}
		if (packs.length > 4) names = packs.length + " mod packs";

		final w = FlxG.width - MARGIN * 2;

		// header: title, what this screen does, which pack it is about
		add(new UIText(MARGIN, 48, w, "Unlocking mod pack", 40, 0xFFFFE066, false));
		add(new UIText(MARGIN, 110, w,
			"Decrypting the pack into memory so the engine can read it. Nothing is written to disk,\n"
			+ "so this pass runs on every start and for as long as the pack stays loaded.",
			14, 0xFFB0B0BE, false));
		add(packText = new UIText(MARGIN, 158, w, "Pack: " + names, 16, 0xFFFFFFFF, false));

		// the whole pass, thick
		barWidth = w;
		add(new FlxSprite(MARGIN, 190).makeGraphic(w, 38, BAR_BACK));
		bar = new FlxSprite(MARGIN + 4, 194).makeGraphic(w - 8, 30, BAR_MAIN);
		// scale around the left edge, otherwise the bar grows from the middle outwards
		bar.origin.set(0, 0);
		bar.scale.x = 0.001;
		add(bar);

		// estimate on the left, what the pass as a whole is at on the right
		add(etaText = new UIText(MARGIN, 236, Std.int(w * 0.7), "", 13, 0xFF7A7A88, false));
		add(percentText = new UIText(MARGIN, 236, w, "0%", 15, 0xFF9BE28C, false));
		percentText.alignment = RIGHT;

		// the pack being decrypted right now, thin
		add(new FlxSprite(MARGIN, 274).makeGraphic(w, 16, BAR_BACK));
		packBar = new FlxSprite(MARGIN + 2, 276).makeGraphic(w - 4, 12, BAR_SUB);
		packBar.origin.set(0, 0);
		packBar.scale.x = 0.001;
		add(packBar);

		add(packEtaText = new UIText(MARGIN, 298, Std.int(w * 0.7), "", 13, 0xFF7A7A88, false));
		add(stepText = new UIText(MARGIN, 298, w, "", 13, 0xFF9B7BFF, false));
		stepText.alignment = RIGHT;

		// every pack this pass has to open, so the player can see what is left
		add(new UIText(MARGIN, 330, w, "Files to unlock:", 13, 0xFF7A7A88, false));
		for (i in 0...packs.length) {
			var text = new UIText(MARGIN + 12, 350 + 20 * i, w - 12, Path.withoutDirectory(packs[i]), 14, PENDING_COLOR, false);
			listTexts.push(text);
			add(text);
		}

		maybeAddEasterEgg();

		// footer: the animated hint sits bottom right, the rule closes the screen off
		add(hintText = new UIText(MARGIN, FlxG.height - 74, w, "Working...", 13, 0xFF7A7A88, false));
		hintText.alignment = RIGHT;
		add(new FlxSprite(MARGIN, FlxG.height - 40).makeGraphic(w, 2, RULE));

		startedAt = 0;
		elapsedTotal = 0;
		elapsedPack = 0;
		lastPackIndex = 0;
		ModPackCrypto.startPrepare(packs);
	}

	override function update(elapsed:Float) {
		super.update(elapsed);

		var p = ModPackCrypto.progress;
		if (p < 0) p = 0;
		if (p > 1) p = 1;
		bar.scale.x = Math.max(0.001, p);
		percentText.text = Std.int(p * 100) + "%" + (ModPackCrypto.progressLabel.length > 0 ? "  -  " + ModPackCrypto.progressLabel : "");

		var pp = ModPackCrypto.packProgress;
		if (pp < 0) pp = 0;
		if (pp > 1) pp = 1;
		packBar.scale.x = Math.max(0.001, pp);

		if (ModPackCrypto.packIndex != lastPackIndex) {
			lastPackIndex = ModPackCrypto.packIndex;
			elapsedPack = 0;
			packEtaSmooth = -1;
		}
		elapsedTotal += elapsed;
		elapsedPack += elapsed;

		var eta = EtaFrom(elapsedTotal, p, etaSmooth);
		etaSmooth = eta;
		etaText.text = eta < 0 ? "Estimating the time left..." : "About " + FormatSeconds(eta) + " left";
		var packEta = EtaFrom(elapsedPack, pp, packEtaSmooth);
		packEtaSmooth = packEta;
		packEtaText.text = (ModPackCrypto.packCount > 1 ? 'Pack ${ModPackCrypto.packIndex}/${ModPackCrypto.packCount}  -  ' : "")
			+ (packEta < 0 ? "estimating..." : "about " + FormatSeconds(packEta) + " left");

		stepText.text = StepLabel(ModPackCrypto.preparePhase, ModPackCrypto.packBytes, pp);
		updateList();

		// a tiny animated marker, so the screen clearly still runs while a single
		// big entry is being decrypted
		startedAt += elapsed;
		var dots = Std.int(startedAt * 2) % 4;
		hintText.text = "Working" + ".".repeat(dots) + "  (the window may stop responding for a moment)";

		if (!finished && ModPackCrypto.prepareDone && !ModPackCrypto.preparing) {
			finished = true;
			if (ModPackCrypto.prepareFailed.length > 0) {
				var failed = ModPackCrypto.prepareFailed.copy();
				// drop the rejected key so the prompt does not retry it every frame
				for (pack in failed) ModPackCrypto.clearSessionKey(pack);
				// the key passed the quick check but decryption still failed: say so
				FlxG.switchState(new ModPackKeyState(failed,
					"Wrong password: the pack could not be decrypted. Check the password and try again."));
			}
			else
				FlxG.switchState(new MainState());
		}
	}

	/** Yellow for the pack being worked on, green for the finished ones, grey for the rest. */
	function updateList() {
		var index = ModPackCrypto.packIndex;
		var allDone = ModPackCrypto.prepareDone;
		for (i in 0...listTexts.length) {
			var text = listTexts[i];
			if (text == null) continue;
			var name = Path.withoutDirectory(packs[i]);
			if (allDone && ModPackCrypto.prepareFailed.indexOf(packs[i]) != -1) {
				text.color = FAILED_COLOR;
				text.text = name + "  -  failed";
			} else if (allDone || i + 1 < index) {
				text.color = DONE_COLOR;
				text.text = name + "  -  done";
			} else if (i + 1 == index) {
				text.color = CURRENT_COLOR;
				text.text = name + "  -  " + Std.int(ModPackCrypto.packProgress * 100) + "%";
			} else {
				text.color = PENDING_COLOR;
				text.text = name + "  -  waiting";
			}
		}
	}

	/**
	 * Seconds left, or -1 while there is nothing to base it on.
	 *
	 * Only a share of the pass is linear (the cipher reads at a steady rate, the key
	 * derivation and the zip indexing are one-off costs), so this leans on the raw
	 * ratio and smooths it - a number that keeps flicking between 2 and 40 seconds
	 * is worse than no number at all.
	 */
	static function EtaFrom(elapsed:Float, fraction:Float, previous:Float):Float {
		if (fraction >= 0.999) return 0;
		if (fraction <= 0.02 || elapsed <= 0.5) return previous;
		var raw = elapsed * (1 - fraction) / fraction;
		if (previous < 0) return raw;
		return previous + (raw - previous) * 0.2;
	}

	static function FormatSeconds(seconds:Float):String {
		if (seconds < 1) return "less than a second";
		if (seconds < 60) return Std.int(seconds + 0.5) + "s";
		var minutes = Std.int(seconds / 60);
		var rest = Std.int(seconds - minutes * 60);
		return minutes + "m " + (rest < 10 ? "0" : "") + rest + "s";
	}

	/** What the pass is doing, plus how much of the current pack it already read. */
	static function StepLabel(phase:PreparePhase, bytes:Int, fraction:Float):String {
		var amount = "";
		if (bytes > 0 && fraction > 0)
			amount = "  -  " + FormatBytes(Std.int(bytes * fraction)) + " / " + FormatBytes(bytes);
		return switch (phase) {
			case PreparePhase.READING: "Reading the pack" + (bytes > 0 ? "  -  " + FormatBytes(bytes) : "");
			case PreparePhase.VERIFYING: "Checking the key";
			case PreparePhase.DECRYPTING: "Decrypting" + amount;
			case PreparePhase.INDEXING: "Opening the entries";
			case PreparePhase.DONE: "Done";
			case PreparePhase.IDLE: "";
		}
	}

	public static function FormatBytes(bytes:Int):String {
		if (bytes < 1024) return bytes + " B";
		var kb = bytes / 1024;
		if (kb < 1024) return Std.string(Math.round(kb * 10) / 10) + " KB";
		return Std.string(Math.round(bytes / (1024 * 1024) * 10) / 10) + " MB";
	}

	/**
	 * One start in EASTER_EGG_CHANCE shows the little desk animation, parked on the right
	 * where it does not cover the file list. Wrapped in try/catch on purpose: a missing or
	 * broken sheet must not cost the player their load.
	 */
	function maybeAddEasterEgg() {
		if (FlxG.random.int(1, EASTER_EGG_CHANCE) != 1) return;

		var frames:flixel.graphics.frames.FlxAtlasFrames = null;
		try {
			frames = Paths.getSparrowAtlas('menus/packDeskMeme');
		} catch (e:Dynamic) {
			Logs.warn('The loading screen animation is missing: ' + e);
			return;
		}
		if (frames == null || frames.frames == null || frames.frames.length == 0) return;

		final size = 170;
		var spr = new FlxSprite(FlxG.width - MARGIN - size, 360);
		spr.frames = frames;
		spr.animation.addByPrefix('idle', 'frame', 30, true);
		spr.animation.play('idle');
		spr.antialiasing = false;
		spr.setGraphicSize(size, size);
		spr.updateHitbox();
		add(spr);
	}
}
