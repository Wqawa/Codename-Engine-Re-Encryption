package funkin.menus;

import flixel.FlxG;
import flixel.FlxSprite;
import funkin.backend.assets.ModPackCrypto;
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
 * One bar on purpose. The container is a single ChaCha20 stream over the whole zip, so
 * there is no sub-file progress to draw: everything below "the pass is at 40%" would be
 * invented detail. The bar, the percentage, the estimated time and the name of the pack
 * being read are all that is real.
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
	static inline var RULE:Int = 0xFF2A2A34;

	public var packs:Array<String> = [];
	public var bar:FlxSprite;
	public var percentText:UIText;
	public var packText:UIText;
	public var hintText:UIText;
	public var etaText:UIText;
	public var finished:Bool = false;
	public var startedAt:Float = 0;
	public var barWidth:Int = 0;

	// the estimate leans on the raw ratio and smooths it: only part of the pass is linear
	// (the cipher reads at a steady rate, the key derivation is a one-off cost)
	var elapsedTotal:Float = 0;
	var etaSmooth:Float = -1;

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

		// the pass, thick
		barWidth = w;
		add(new FlxSprite(MARGIN, 190).makeGraphic(w, 38, BAR_BACK));
		bar = new FlxSprite(MARGIN + 4, 194).makeGraphic(w - 8, 30, BAR_MAIN);
		// scale around the left edge, otherwise the bar grows from the middle outwards
		bar.origin.set(0, 0);
		bar.scale.x = 0.001;
		add(bar);

		// estimate on the left, the percentage on the right
		add(etaText = new UIText(MARGIN, 236, Std.int(w * 0.7), "", 13, 0xFF7A7A88, false));
		add(percentText = new UIText(MARGIN, 236, w, "0%", 15, 0xFF9BE28C, false));
		percentText.alignment = RIGHT;

		maybeAddEasterEgg();

		// footer: the animated hint sits bottom right, the rule closes the screen off
		add(hintText = new UIText(MARGIN, FlxG.height - 74, w, "Working...", 13, 0xFF7A7A88, false));
		hintText.alignment = RIGHT;
		add(new FlxSprite(MARGIN, FlxG.height - 40).makeGraphic(w, 2, RULE));

		startedAt = 0;
		elapsedTotal = 0;
		ModPackCrypto.startPrepare(packs);
	}

	override function update(elapsed:Float) {
		super.update(elapsed);

		var p = ModPackCrypto.progress;
		if (p < 0) p = 0;
		if (p > 1) p = 1;
		bar.scale.x = Math.max(0.001, p);
		percentText.text = Std.int(p * 100) + "%" + (ModPackCrypto.progressLabel.length > 0 ? "  -  " + ModPackCrypto.progressLabel : "");

		elapsedTotal += elapsed;
		var eta = EtaFrom(elapsedTotal, p, etaSmooth);
		etaSmooth = eta;
		etaText.text = eta < 0 ? "Estimating the time left..." : "About " + FormatSeconds(eta) + " left";

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

	/**
	 * Seconds left, or -1 while there is nothing to base it on.
	 *
	 * The key derivation and the zip indexing are one-off costs, so the raw ratio jumps;
	 * the estimate follows it slowly instead of flicking between 2 and 40 seconds.
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

	/**
	 * One start in EASTER_EGG_CHANCE shows the little desk animation in the empty lower
	 * half. Wrapped in try/catch on purpose: a missing or broken sheet must not cost the
	 * player their load.
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
		var spr = new FlxSprite(MARGIN, 380);
		spr.frames = frames;
		spr.animation.addByPrefix('idle', 'frame', 30, true);
		spr.animation.play('idle');
		spr.antialiasing = false;
		spr.setGraphicSize(size, size);
		spr.updateHitbox();
		add(spr);
	}
}
