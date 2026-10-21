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
	public var packs:Array<String> = [];
	public var box:UITextBox;
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

		add(new UIText(40, 40, FlxG.width - 80, "Encrypted mod pack detected", 26, 0xFFFFE066, false));
		add(new UIText(40, 84, FlxG.width - 80, "Pack: " + names, 16, 0xFFFFFFFF, false));
		add(new UIText(40, 118, FlxG.width - 80,
			"This mod pack is encrypted. Type the password the author gave you.\n"
			+ "A key token (it usually starts with CNEK1-) works here as well.\n"
			+ "A zip protected with a normal zip password also works (ZipCrypto or AES-256): type that password.",
			14, 0xFFB0B0BE, false));

		add(new UIText(40, 180, 200, "Password / token:", 16, 0xFFFFFFFF, false));
		add(box = new UITextBox(40, 206, "", FlxG.width - 80));

		add(new UIButton(40, 262, "Unlock and continue", onSubmit, 260, 36));
		add(new UIButton(320, 262, "Play without mods", onDisableMods, 240, 36));
		add(new UIButton(580, 262, "Quit", function() Sys.exit(0), 160, 36));

		add(errorText = new UIText(40, 316, FlxG.width - 80, "", 16, 0xFFFF5A5A, false));
		errorText.visible = false;

		if (errorMessage != null) showError(errorMessage);

		for (p in packs) {
			var problem = ModPackCrypto.packProblem(p);
			if (problem != null) {
				showError(problem);
				break;
			}
		}
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

		// Verify the key before the loading screen starts: a wrong password would
		// otherwise decrypt the whole pack for nothing and then silently come back
		// here without saying what went wrong.
		var bad:Array<String> = [];
		for (p in packs) {
			ModPackCrypto.setSessionKey(p, key);
			if (!ModPackCrypto.keyWorks(p, key)) bad.push(p);
		}
		if (bad.length > 0 && attempts < 3) {
			for (p in packs) ModPackCrypto.clearSessionKey(p);
			var names = "";
			for (p in bad)
				names += (names.length == 0 ? "" : ", ") + Path.withoutExtension(Path.withoutDirectory(p));
			showError("Wrong password: " + names + " could not be unlocked. Check the password and try again.");
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
