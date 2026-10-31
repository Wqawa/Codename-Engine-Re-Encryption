package funkin.menus;

import flixel.FlxG;
import flixel.FlxSprite;
import funkin.backend.assets.ModPackCrypto;
import funkin.editors.ui.UIButton;
import funkin.editors.ui.UIState;
import funkin.editors.ui.UIText;

/**
 * Shown instead of closing the window while a decrypted pack is still held.
 *
 * A decrypted pack is never written to disk, so it is wiped on the way out instead of
 * being left for the next start: the buffers in memory, the zip handles, the key files
 * copied out of packs and the video cache under .cne/. The window close is vetoed for
 * the whole pass (see Main.installModCleanupVeto), which is why this state can take its
 * time.
 *
 * The steps run one per frame from ModPackCrypto.stepCleanup. Doing the wipe inside
 * create(), or on a worker thread as this first did, disposed buffers the engine was
 * still reading and crashed the game on the way out.
 *
 * When the wipe reports done the screen waits a few seconds and closes the game by
 * itself; the button closes at once for anyone who does not want to wait.
 */
class ModPackCleanupState extends UIState {
	/** Seconds the screen stays up after the wipe finished, so the result can be read. */
	public static inline var AUTO_CLOSE_DELAY:Float = 3;

	public var bar:FlxSprite;
	public var percentText:UIText;
	public var stageText:UIText;
	public var summaryText:UIText;
	public var hintText:UIText;
	public var closeButton:UIButton;

	public var finished:Bool = false;
	public var quitting:Bool = false;
	public var countdown:Float = 0;

	override function create() {
		super.create();
		// This screen runs on the close path, so nothing here may throw: a broken bit of
		// UI would turn "the game cannot close" into "the game crashes when closing".
		// When it does fail the exit hook still wipes the same things on the way out.
		try {
			FlxG.camera.bgColor = 0xFF101017;

			add(new UIText(40, 60, FlxG.width - 80, "Cleaning up before closing", 26, 0xFFFFE066, false));
			add(new UIText(40, 100, FlxG.width - 80,
				"The decrypted mod pack, the keys copied out of it and the video cache only exist while\n"
				+ "the game runs. They are wiped now, so nothing readable is left behind.",
				14, 0xFFB0B0BE, false));

			var barWidth = FlxG.width - 80;
			add(new FlxSprite(40, 160).makeGraphic(barWidth, 22, 0xFF2A2A34));
			bar = new FlxSprite(43, 163).makeGraphic(Std.int(barWidth - 6), 16, 0xFF61C4FF);
			// scale around the left edge, otherwise the bar grows from the middle outwards
			bar.origin.set(0, 0);
			bar.scale.x = 0.001;
			add(bar);

			add(percentText = new UIText(40, 194, FlxG.width - 80, "0%", 15, 0xFF9BE28C, false));
			add(stageText = new UIText(40, 224, FlxG.width - 80, ModPackCrypto.cleanupLabel, 13, 0xFF7A7A88, false));
			add(summaryText = new UIText(40, 258, FlxG.width - 80, "", 14, 0xFFFFFFFF, false));
			add(hintText = new UIText(40, 300, FlxG.width - 80, "The window closes on its own when this is done.", 14,
				0xFFB0B0BE, false));
			add(closeButton = new UIButton(40, 336, "Close now", function() quit(), 200, 36));

			ModPackCrypto.beginCleanup();
		} catch (e:Dynamic) {
			Logs.error('The cleanup screen could not be built, closing directly: ' + e);
			quit();
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

		if (!finished && ModPackCrypto.cleanupDone) {
			finished = true;
			countdown = AUTO_CLOSE_DELAY;
			if (summaryText != null) summaryText.text = ModPackCrypto.cleanupSummary;
		}
		if (!finished) return;

		countdown -= elapsed;
		if (countdown <= 0) {
			quit();
			return;
		}
		if (hintText != null)
			hintText.text = "Closing in " + Math.ceil(countdown) + " second(s) - or press the button.";
	}

	function quit():Void {
		if (quitting) return;
		quitting = true;
		// the exit hook wipes the same things again; both passes are idempotent
		openfl.system.System.exit(0);
	}
}
