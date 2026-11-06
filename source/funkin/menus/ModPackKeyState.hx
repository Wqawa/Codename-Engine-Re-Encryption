package funkin.menus;

import flixel.FlxG;
import funkin.backend.assets.ModPackCrypto;
import funkin.backend.system.MainState;
import funkin.editors.ui.UIButton;
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
class ModPackKeyState extends PopupScreen {
	/** Width of the little "empty the field again" button at the end of the input. */
	static inline var CLEAR_SIZE:Int = 32;
	/** Room kept for a rejected password, so the panel does not jump when one shows up. */
	static inline var ERROR_ROOM:Int = 52;

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
		bgType = 'lock';
		// barely there on purpose: the field is focused and being typed into, and anything
		// bigger makes the caret wander while the player reads their own input
		bobAmplitude = 1;
	}

	override function create() {
		super.create();

		var names = "";
		for (p in packs) {
			var n = Path.withoutExtension(Path.withoutDirectory(p));
			names += (names.length == 0 ? "" : ", ") + n;
		}
		if (packs.length > 4) names = packs.length + " mod packs";

		beginPanel(TU.translate('pack.key.title', null, "Encrypted mod pack"), 720);

		addText(TU.translate('pack.key.intro', null, "This mod pack is encrypted. Type the password the author gave you."), 15, PopupScreen.COLOR_TEXT, 6);
		addText(TU.translate('pack.key.tokenHint', null, "A key token works here as well - it usually starts with CNEK1-. A zip protected with a normal zip password (ZipCrypto or AES-256) also opens with that password."), 13, PopupScreen.COLOR_TEXT, 16);
		addText(TU.translate('pack.key.pack', [names], "Pack: " + names), 15, PopupScreen.COLOR_TEXT, 20);

		addText(TU.translate('pack.key.field', null, "Password or token"), 13, PopupScreen.COLOR_TEXT, 6);
		final fieldY = row(32, 8);
		final fieldW = contentW - CLEAR_SIZE - 8;
		place(box = new UITextBox(contentX, fieldY, "", fieldW));
		place(clearButton = new UIButton(contentX + fieldW + 8, fieldY, "X", clearBox, CLEAR_SIZE, CLEAR_SIZE));
		// the prompt is the only thing on screen, so the field starts ready to type in
		// (the engine's own input dialog does the same)
		box.focused = true;

		errorText = new UIText(contentX, row(ERROR_ROOM, 0), contentW, "", 13, PopupScreen.COLOR_ERROR);
		errorText.wordWrap = true;
		place(errorText);
		errorText.visible = false;

		setButtons([
			{label: TU.translate('pack.button.quit', null, "Quit"), onClick: function() Sys.exit(0), width: 140, color: PopupScreen.COLOR_DANGER},
			{label: TU.translate('pack.button.noMods', null, "Play without mods"), onClick: onDisableMods, width: 190},
			{label: TU.translate('pack.button.unlock', null, "Unlock and continue"), onClick: onSubmit, width: 200, color: PopupScreen.COLOR_OK}
		]);
		endPanel();

		if (errorMessage != null) showError(errorMessage);

		// A pack that already burned a full decryption attempt is not tried that way
		// again (see onSubmit), so say it right away instead of after three tries.
		if (errorMessage == null) {
			for (p in packs) {
				if (!ModPackCrypto.hasFailedBefore(p)) continue;
				showError(TU.translate('pack.key.errFailedAtStart', null, "This pack already failed a full unlock attempt in this session, so it will not be decrypted again. Use \"Play without mods\" if the password keeps being rejected."));
				break;
			}
		}
	}

	/** Empties the field again, for when a pasted token was the wrong one. */
	function clearBox() {
		if (box == null || box.label == null) return;
		box.label.text = "";
		box.position = 0;
	}

	override function destroy() {
		// the field switched system text input on when it took focus; leaving it on
		// would feed every later keystroke into a field nobody can see (UIWarningSubstate
		// clears the same flag for the same reason)
		if (FlxG.stage != null && FlxG.stage.window != null) FlxG.stage.window.textInputEnabled = false;
		// key sounds are muted while a field has focus, and the next state is usually not
		// a UIState, so nothing would switch them back on
		FlxG.sound.keysAllowed = true;
		super.destroy();
	}

	function showError(msg:String) {
		errorText.text = msg;
		errorText.visible = true;
	}

	function onSubmit() {
		var typed = box == null || box.label == null ? null : box.label.text;
		if (typed == null || StringTools.trim(typed).length == 0) {
			showError(TU.translate('pack.key.errEmpty', null, "Type a password or a key token first."));
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
			showError(TU.translate('pack.key.errWrong', [names], "Wrong password: " + names
					+ " could not be unlocked. Check the password and try again.")
				+ (triedInFull ? TU.translate('pack.key.errFailedOnce', null, "\nA full unlock attempt for this pack already failed, so it will not be decrypted again - use \"Play without mods\" if the password keeps being rejected.") : ""));
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
