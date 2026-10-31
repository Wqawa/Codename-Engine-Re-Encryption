package funkin.menus;

import flixel.FlxG;
import funkin.backend.assets.ModPackCrypto;
import funkin.backend.system.MainState;
import funkin.editors.ui.UIButton;
import funkin.editors.ui.UIState;
import funkin.editors.ui.UIText;
import funkin.editors.ui.UITextBox;
import haxe.io.Path;

/**
 * Shown before a mod is loaded when the mod pack is encrypted.
 *
 * The player types either the publisher's key or a key token (the token is
 * turned back into the key automatically). A wrong key keeps the same screen
 * open with an error and the option to play without mods instead.
 */
class ModPackKeyState extends UIState {
	static inline var MARGIN:Int = 40;
	static inline var RULE:Int = 0xFF2A2A34;
	/** Width of the little "empty the field again" button at the end of the input. */
	static inline var CLEAR_SIZE:Int = 32;

	public var packs:Array<String> = [];
	public var box:UITextBox;
	public var clearButton:UIButton;
	public var errorText:UIText;
	public var attempts:Int = 0;
	/** Shown right away, e.g. when the previous key was rejected by the loader. */
	public var errorMessage:String = null;

	public function new(packs:Array<String>, ?errorMessage:String) {
		super();
		this.packs = packs == null ? [] : packs;
		this.errorMessage = errorMessage;
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

		// title first, then what it is about, then the instructions: the screen used
		// to be a block of small text pinned to the top corner with the rest empty
		add(new UIText(MARGIN, 176, w, "Encrypted mod pack detected", 40, 0xFFFFE066, false));
		add(new UIText(MARGIN, 258, w, "Pack: " + names, 16, 0xFFFFFFFF, false));
		add(new UIText(MARGIN, 286, w,
			"This mod pack is encrypted. Type the password the author gave you.\n"
			+ "A key token (it usually starts with CNEK1-) works here as well.\n"
			+ "A zip protected with a normal zip password also works (ZipCrypto or AES-256): type that password.",
			14, 0xFFB0B0BE, false));

		add(new UIText(MARGIN, 350, 300, "Password / token:", 16, 0xFFFFFFFF, false));

		// the clear button sits inside the same row, right after the field, so the two
		// read as one control instead of the button floating somewhere else
		final boxWidth = w - CLEAR_SIZE - 8;
		add(box = new UITextBox(MARGIN, 378, "", boxWidth));
		add(clearButton = new UIButton(MARGIN + boxWidth + 8, 378, "X", clearBox, CLEAR_SIZE, CLEAR_SIZE));

		// where a rejected key is reported: between the field and the buttons
		add(errorText = new UIText(MARGIN, 448, w, "", 16, 0xFFFF5A5A, false));
		errorText.visible = false;

		addButtons();

		add(new FlxSprite(MARGIN, FlxG.height - 40).makeGraphic(w, 2, RULE));

		if (errorMessage != null) showError(errorMessage);

		// A pack that already burned a full decryption attempt is not tried that way
		// again (see onSubmit), so say it right away instead of after three tries.
		if (errorMessage == null) {
			for (p in packs) {
				if (!ModPackCrypto.hasFailedBefore(p)) continue;
				showError("This pack already failed a full unlock attempt in this session, so it will not be"
					+ " decrypted again. Use \"Play without mods\" if the password keeps being rejected.");
				break;
			}
		}
	}

	/**
	 * One row along the bottom right, all three the same height so they line up:
	 * unlocking is the main action, quitting the one that ends the game, so it is
	 * the coloured one.
	 */
	function addButtons() {
		final y = 512;
		final h = 40;
		final gap = 12;
		final unlockWidth = 260;
		final playWidth = 240;
		final quitWidth = 160;

		var x = FlxG.width - MARGIN - quitWidth;
		var quit = new UIButton(x, y, "Quit", function() Sys.exit(0), quitWidth, h);
		quit.color = 0xFFFF5555;
		if (quit.field != null) quit.field.color = 0xFFFFE8E8;
		add(quit);

		x -= gap + playWidth;
		add(new UIButton(x, y, "Play without mods", onDisableMods, playWidth, h));

		x -= gap + unlockWidth;
		add(new UIButton(x, y, "Unlock and continue", onSubmit, unlockWidth, h));
	}

	/** Empties the field again, for when a pasted token was the wrong one. */
	function clearBox() {
		if (box == null || box.label == null) return;
		box.label.text = "";
		box.position = 0;
	}

	function showError(msg:String) {
		errorText.text = msg;
		errorText.visible = true;
	}

	function onSubmit() {
		var typed = box == null || box.label == null ? null : box.label.text;
		if (typed == null || StringTools.trim(typed).length == 0) {
			showError("Type a password or a key token first.");
			return;
		}
		var key = StringTools.trim(typed);
		attempts++;

		// A pack that already failed a full decryption attempt this session must
		// never be decrypted again without a good reason: that is what turned a
		// wrong password into an endless "loading screen -> prompt" loop.
		var triedInFull = false;
		var wasFailed:Map<String, Bool> = new Map<String, Bool>();
		for (p in packs) {
			if (ModPackCrypto.hasFailedBefore(p)) {
				triedInFull = true;
				wasFailed.set(p, true);
			}
		}

		// Verify the key before the loading screen starts: a wrong password would
		// otherwise decrypt the whole pack for nothing and then silently come back
		// here without saying what went wrong.
		var bad:Array<String> = [];
		for (p in packs) {
			ModPackCrypto.setSessionKey(p, key);
			if (!ModPackCrypto.keyWorks(p, key)) bad.push(p);
		}
		if (bad.length > 0 && (attempts < 3 || triedInFull)) {
			for (p in packs) {
				ModPackCrypto.clearSessionKey(p);
				// setSessionKey() drops the failure mark so a freshly typed key may be
				// tried; without restoring it here the next prompt would retry the
				// full decryption again on the third wrong password.
				if (wasFailed.exists(p)) ModPackCrypto.markFailed(p);
			}
			var names = "";
			for (p in bad)
				names += (names.length == 0 ? "" : ", ") + Path.withoutExtension(Path.withoutDirectory(p));
			showError("Wrong password: " + names + " could not be unlocked. Check the password and try again."
				+ (triedInFull ? "\nA full unlock attempt for this pack already failed, so it will not be "
					+ "decrypted again - use \"Play without mods\" if the password keeps being rejected." : ""));
			return;
		}
		// Rejected three times in a row: let the loader do a real decryption attempt
		// anyway, in case this particular pack cannot be probed up front. It now
		// reports a failed decryption on this screen instead of coming back silently.

		// Decompressing happens on the loading screen (a worker thread), so a big
		// pack no longer freezes this prompt.
		FlxG.switchState(new ModPackLoadingState(packs));
	}

	function onDisableMods() {
		ModPackCrypto.disableMods = true;
		FlxG.switchState(new MainState());
	}
}
