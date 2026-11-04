package funkin.menus;

import flixel.FlxG;
import funkin.backend.assets.ModPackCrypto;
import funkin.editors.ui.UIButton;
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
class ModPackCleanupState extends PopupScreen {
	/** Seconds the screen stays up after the wipe finished when the game is closing. */
	public static inline var AUTO_CLOSE_DELAY:Float = 3;
	/** Same, for the switch case: long enough to read the list, short enough to not nag. */
	public static inline var AUTO_CONTINUE_DELAY:Float = 1.5;

	/** Room kept for the list of removed items: six short lines, the most a pass produces. */
	static inline var SUMMARY_ROOM:Int = 112;

	/** True when this pass is part of a mod switch instead of a window close. */
	public var continuing:Bool = false;

	public var bar:PopupProgress;
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
			beginPanel(continuing ? "Cleaning up before the switch" : "Cleaning up before closing", 720);
			addText("The decrypted mod pack, the keys copied out of it and everything lifted onto disk only exist "
				+ "while the game runs. They are wiped now, so nothing readable is left behind.", 13, PopupScreen.COLOR_TEXT, 16);

			bar = addProgress(14);
			// the label is only filled once beginCleanup() runs, below
			stageText = addText(ModPackCrypto.cleanupLabel.length > 0 ? ModPackCrypto.cleanupLabel : "Releasing the pack handles",
				13, PopupScreen.COLOR_INFO, 14);

			// what was actually removed, one line per item; filled in as the steps run
			final summaryY = row(SUMMARY_ROOM, 14);
			summaryText = new UIText(contentX, summaryY, contentW, "", 13, PopupScreen.COLOR_TEXT);
			summaryText.wordWrap = true;
			place(summaryText);

			hintText = addText(continuing
				? "The switch continues on its own when this is done."
				: "The window closes on its own when this is done.", 13, PopupScreen.COLOR_TEXT, 0);

			setButtons([{label: continuing ? "Continue now" : "Close now", onClick: function() finish(), width: 200}]);
			endPanel();

			// the button is reachable from the first frame, but switching away in the middle of
			// the wipe is what leaves a half released pack behind
			closeButton = buttons.length > 0 ? buttons[0] : null;
			if (closeButton != null) closeButton.shouldPress = false;

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
		if (bar != null) {
			bar.value = p;
			if (progressLabel != null) progressLabel.text = Std.int(p * 100) + "%";
		}
		if (stageText != null && ModPackCrypto.cleanupLabel.length > 0) stageText.text = ModPackCrypto.cleanupLabel;
		// the list grows while the steps run, so it is refreshed instead of set once
		if (summaryText != null) summaryText.text = ModPackCrypto.cleanupSummary;

		if (!finished && ModPackCrypto.cleanupDone) {
			finished = true;
			countdown = continuing ? AUTO_CONTINUE_DELAY : AUTO_CLOSE_DELAY;
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
