package funkin.menus;

import flixel.FlxG;
import flixel.FlxSprite;
import funkin.backend.assets.ModPackCrypto;
import funkin.backend.system.MainState;
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
class ModPackLoadingState extends PopupScreen {
	/** One start in this many shows the little animation (see maybeAddEasterEgg): 4 = 25%. */
	static inline var EASTER_EGG_CHANCE:Int = 4;

	public var packs:Array<String> = [];
	public var bar:PopupProgress;
	public var statusText:UIText;
	public var etaText:UIText;
	public var hintText:UIText;
	public var finished:Bool = false;
	public var startedAt:Float = 0;

	// the estimate leans on the raw ratio and smooths it: only part of the pass is linear
	// (the cipher reads at a steady rate, the key derivation is a one-off cost)
	var elapsedTotal:Float = 0;
	var etaSmooth:Float = -1;

	public function new(packs:Array<String>) {
		super();
		this.packs = packs == null ? [] : packs;
		bgType = 'lock';
		// the pass can run for seconds without the bar moving; a panel that drifts makes
		// that read as "still working" instead of "stuck"
		bobAmplitude = 2;
	}

	override function create() {
		super.create();

		var names = "";
		for (p in packs) {
			var n = Path.withoutExtension(Path.withoutDirectory(p));
			names += (names.length == 0 ? "" : ", ") + n;
		}
		if (packs.length > 4) names = packs.length + " mod packs";

		beginPanel(TU.translate('pack.loading.title', null, "Unlocking mod pack"), 720);
		addText(TU.translate('pack.loading.intro', null, "The pack is decrypted into memory so the engine can read it. Nothing is written to disk, so this pass runs on every start for as long as the pack stays loaded."), 13, PopupScreen.COLOR_TEXT, 16);
		addText(TU.translate('pack.loading.pack', [names], "Pack: " + names), 15, PopupScreen.COLOR_TEXT, 20);

		bar = addProgress(14);

		// one line kept for the pack currently being read, so the panel does not jump
		statusText = new UIText(contentX, row(18), contentW, "", 13, PopupScreen.COLOR_INFO);
		place(statusText);

		etaText = addText(TU.translate('pack.loading.estimating', null, "Estimating the time left..."), 13, PopupScreen.COLOR_TEXT, 12);
		hintText = addText(TU.translate('pack.loading.working', null, "Working..."), 13, PopupScreen.COLOR_TEXT, 12);

		var egg = maybeAddEasterEgg();
		if (egg != null) {
			egg.setPosition(contentX + (contentW - egg.width) / 2, row(egg.height, 0));
			place(egg);
		}

		endPanel();

		startedAt = 0;
		elapsedTotal = 0;
		ModPackCrypto.startPrepare(packs);
	}

	override function update(elapsed:Float) {
		super.update(elapsed);

		var p = ModPackCrypto.progress;
		if (p < 0) p = 0;
		if (p > 1) p = 1;
		bar.value = p;
		progressLabel.text = Std.int(p * 100) + "%";
		statusText.text = ModPackCrypto.progressLabel;

		elapsedTotal += elapsed;
		var eta = EtaFrom(elapsedTotal, p, etaSmooth);
		etaSmooth = eta;
		etaText.text = eta < 0
			? TU.translate('pack.loading.estimating', null, "Estimating the time left...")
			: TU.translate('pack.loading.eta', [FormatSeconds(eta)], "About " + FormatSeconds(eta) + " left");

		// a tiny animated marker, so the screen clearly still runs while a single
		// big entry is being decrypted
		startedAt += elapsed;
		var dots = Std.int(startedAt * 2) % 4;
		hintText.text = TU.translate('pack.loading.workingDots', [".".repeat(dots)],
			"Working" + ".".repeat(dots) + "  (the window may stop responding for a moment)");

		if (!finished && ModPackCrypto.prepareDone && !ModPackCrypto.preparing) {
			finished = true;
			if (ModPackCrypto.prepareFailed.length > 0) {
				var failed = ModPackCrypto.prepareFailed.copy();
				// drop the rejected key so the prompt does not retry it every frame
				for (pack in failed) ModPackCrypto.clearSessionKey(pack);
				// the key passed the quick check but decryption still failed: say so
				FlxG.switchState(new ModPackKeyState(failed,
					TU.translate('pack.loading.errWrong', null, "Wrong password: the pack could not be decrypted. Check the password and try again.")));
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
		if (seconds < 1) return TU.translate('pack.time.lessThanSecond', null, "less than a second");
		if (seconds < 60) return TU.translate('pack.time.seconds', [Std.int(seconds + 0.5)], Std.int(seconds + 0.5) + "s");
		var minutes = Std.int(seconds / 60);
		var rest = Std.int(seconds - minutes * 60);
		var padded = (rest < 10 ? "0" : "") + rest;
		return TU.translate('pack.time.minutes', [minutes, padded], minutes + "m " + padded + "s");
	}

	/**
	 * One start in EASTER_EGG_CHANCE returns the little desk animation. Wrapped in
	 * try/catch on purpose: a missing or broken sheet must not cost the player their load.
	 */
	function maybeAddEasterEgg():FlxSprite {
		if (FlxG.random.int(1, EASTER_EGG_CHANCE) != 1) return null;

		var frames:flixel.graphics.frames.FlxAtlasFrames = null;
		try {
			frames = Paths.getSparrowAtlas('menus/packDeskMeme');
		} catch (e:Dynamic) {
			Logs.warn('The loading screen animation is missing: ' + e);
			return null;
		}
		if (frames == null || frames.frames == null || frames.frames.length == 0) return null;

		final size = 170;
		var spr = new FlxSprite(0, 0);
		spr.frames = frames;
		spr.animation.addByPrefix('idle', 'frame', 30, true);
		spr.animation.play('idle');
		spr.antialiasing = false;
		spr.setGraphicSize(size, size);
		spr.updateHitbox();
		return spr;
	}
}
