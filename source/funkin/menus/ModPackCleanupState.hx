package funkin.menus;

import flixel.FlxG;
import flixel.FlxSprite;
import funkin.backend.assets.ModPackCrypto;
import funkin.editors.ui.UIButton;
import funkin.editors.ui.UIState;
import funkin.editors.ui.UIText;

/**
 * Shown while a decrypted pack is wiped, in two situations:
 *
 *  - the window is being closed with a decrypted pack still held: the close is vetoed
 *    for the whole pass (see Main.installModCleanupVeto) and the game exits when it is
 *    done;
 *  - a mod switch leaves an encrypted pack: the switch is queued and continues as soon
 *    as the wipe finished (ModPackCrypto.beginSwitchCleanup).
 *
 * The steps run one per frame from ModPackCrypto.stepCleanup. Doing the wipe inside
 * create(), or on a worker thread as this first did, disposed buffers the engine was
 * still reading and crashed the game on the way out.
 *
 * Every removed item is listed as its own line, so the screen says what happened rather
 * than "done".
 */
class ModPackCleanupState extends UIState {
	static inline var MARGIN:Int = 40;
	/** Seconds the screen stays up after the wipe finished when the game is closing. */
	public static inline var AUTO_CLOSE_DELAY:Float = 3;
	/** Same, for the switch case: long enough to read the list, short enough to not nag. */
	public static inline var AUTO_CONTINUE_DELAY:Float = 1.5;

	/** True when this pass is part of a mod switch instead of a window close. */
	public var continuing:Bool = false;

	public var bar:FlxSprite;
	public var percentText:UIText;
	public var stageText:UIText;
	public var summaryText:UIText;
	public var hintText:UIText;
	public var closeButton:UIButton;

	public var finished:Bool = false;
	public var quitting:Bool = false;
	public var countdown:Float = 0;

	public function new(?continuing:Bool = false) {
		super();
		this.continuing = continuing;
	}

	override function create() {
		super.create();
		// This screen runs on the close path, so nothing here may throw: a broken bit of
		// UI would turn "the game cannot close" into "the game crashes when closing".
		// When it does fail the exit hook still wipes the same things on the way out.
		try {
			FlxG.camera.bgColor = 0xFF101017;
			final w = FlxG.width - MARGIN * 2;

			add(new UIText(MARGIN, 56, w, continuing ? "Cleaning up before the switch" : "Cleaning up before closing",
				34, 0xFFFFE066, false));
			add(new UIText(MARGIN, 108, w,
				"The decrypted mod pack, the keys copied out of it and everything lifted onto disk\n"
				+ "only exist while the game runs. They are wiped now, so nothing readable is left behind.",
				14, 0xFFB0B0BE, false));

			add(new FlxSprite(MARGIN, 168).makeGraphic(w, 26, 0xFF2A2A34));
			bar = new FlxSprite(MARGIN + 4, 172).makeGraphic(w - 8, 18, 0xFF61C4FF);
			// scale around the left edge, otherwise the bar grows from the middle outwards
			bar.origin.set(0, 0);
			bar.scale.x = 0.001;
			add(bar);

			add(percentText = new UIText(MARGIN, 202, w, "0%", 15, 0xFF9BE28C, false));
			add(stageText = new UIText(MARGIN, 232, w, ModPackCrypto.cleanupLabel, 13, 0xFF7A7A88, false));

			// what was actually removed, one line per item; filled in as the steps run
			add(summaryText = new UIText(MARGIN, 262, w, "", 14, 0xFFFFFFFF, false));

			add(hintText = new UIText(MARGIN, 392, w, continuing
				? "The switch continues on its own when this is done."
				: "The window closes on its own when this is done.", 14, 0xFFB0B0BE, false));
			add(closeButton = new UIButton(MARGIN, 424, continuing ? "Continue now" : "Close now", function() finish(), 200, 36));
			// the button is reachable from the first frame, but switching away in the middle of
			// the wipe is what leaves a half released pack behind
			closeButton.shouldPress = false;

			ModPackCrypto.beginCleanup();
		} catch (e:Dynamic) {
			Logs.error('The cleanup screen could not be built, continuing directly: ' + e);
			finish();
		}
	}

	override function update(elapsed:Float) {
		super.update(elapsed);

		// one step per frame, on the main thread; see ModPackCrypto.stepCleanup
		if (!finished) ModPackCrypto.stepCleanup();

		var p = ModPackCrypto.cleanupProgress;
		if (p < 0) p = 0;
		if (p > 1) p = 1;
		if (bar != null) bar.scale.x = Math.max(0.001, p);
		if (percentText != null) percentText.text = Std.int(p * 100) + "%";
		if (stageText != null && ModPackCrypto.cleanupLabel.length > 0) stageText.text = ModPackCrypto.cleanupLabel;
		// the list grows while the steps run, so it is refreshed instead of set once
		if (summaryText != null) summaryText.text = ModPackCrypto.cleanupSummary;

		if (!finished && ModPackCrypto.cleanupDone) {
			finished = true;
			countdown = continuing ? AUTO_CONTINUE_DELAY : AUTO_CLOSE_DELAY;
			if (summaryText != null) summaryText.text = ModPackCrypto.cleanupSummary;
			if (closeButton != null) closeButton.shouldPress = true;
		}
		if (!finished) return;

		countdown -= elapsed;
		if (countdown <= 0) {
			finish();
			return;
		}
		if (hintText != null)
			hintText.text = (continuing ? "Continuing in " : "Closing in ") + Math.ceil(countdown) + " second(s) - or press the button.";
	}

	/**
	 * Ends this screen: either the queued switch runs, or the game exits.
	 *
	 * Both are idempotent on purpose - the button and the countdown can both arrive.
	 */
	function finish():Void {
		if (quitting) return;
		// never switch away from a half finished wipe, even if the button is hit early
		if (continuing && !ModPackCrypto.cleanupDone) return;
		quitting = true;
		if (continuing) {
			// Main/ModsFolder take it from here; the exit hook still covers the leftovers
			ModPackCrypto.completeSwitchCleanup();
			return;
		}
		// the exit hook wipes the same things again; both passes are idempotent
		openfl.system.System.exit(0);
	}
}
