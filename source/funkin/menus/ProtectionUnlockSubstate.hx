package funkin.menus;

import flixel.FlxG;
import flixel.FlxSprite;
import flixel.FlxSubState;
import flixel.text.FlxText;
import funkin.backend.assets.ProtectionState;
import openfl.Lib;
import openfl.events.KeyboardEvent;

/**
 * Asks for the password that unlocks protection mode.
 *
 * The engine has no text input dialog - UIWarningSubstate only takes buttons - and the
 * editor's UITextBox pulls in its own resource set and focus system. This is a small
 * self contained box instead: characters come from the stage keyboard event, so no
 * per-key FlxKeys table is needed, and the buttons are plain sprites.
 *
 * Input is masked. A typo means retyping, which is the usual trade for not showing a
 * password on screen.
 */
class ProtectionUnlockSubstate extends FlxSubState {
	static inline var MAX_LEN:Int = 64;

	var entered:String = "";
	var field:FlxText;
	var hint:FlxText;
	var unlockBtn:FlxSprite;
	var cancelBtn:FlxSprite;
	var onDone:Bool->Void;
	var blink:Float = 0;
	var closed:Bool = false;

	// Held as fields on purpose: `this.onKeyDown` produces a fresh bound closure every
	// time it is evaluated, so add/removeEventListener with that expression removes
	// nothing. The listener then outlives the box and fires into destroyed sprites.
	var keyHandler:KeyboardEvent->Void;
	var textHandler:String->Void;

	public function new(onDone:Bool->Void) {
		super();
		this.onDone = onDone;
	}

	override function create() {
		super.create();

		final w = 560.0;
		final h = 250.0;
		final x = (FlxG.width - w) * 0.5;
		final y = (FlxG.height - h) * 0.5;

		add(new FlxSprite(0, 0).makeGraphic(FlxG.width, FlxG.height, 0xCC000000));
		add(new FlxSprite(x, y).makeGraphic(Std.int(w), Std.int(h), 0xFF17171F));
		add(new FlxSprite(x, y).makeGraphic(Std.int(w), 2, 0xFF3A3A48));

		add(new FlxText(x + 24, y + 20, w - 48, "Unlock Protection Mode", 20).setFormat(null, 20, 0xFFFFE066, "left"));
		add(new FlxText(x + 24, y + 52, w - 48, 'Type the password for "${ProtectionState.owner()}".', 13)
			.setFormat(null, 13, 0xFFB0B0BE, "left"));

		// input box
		add(new FlxSprite(x + 24, y + 84).makeGraphic(Std.int(w - 48), 40, 0xFF0E0E14));
		field = new FlxText(x + 34, y + 94, w - 68, "", 16);
		field.setFormat(null, 16, 0xFFFFFFFF, "left");
		add(field);

		hint = new FlxText(x + 24, y + 132, w - 48, "Enter to confirm, Esc to cancel.", 12);
		hint.setFormat(null, 12, 0xFF7A7A88, "left");
		add(hint);

		unlockBtn = new FlxSprite(x + 24, y + 176).makeGraphic(180, 44, 0xFF2F6B3A);
		add(unlockBtn);
		add(new FlxText(x + 24, y + 190, 180, "Unlock", 16).setFormat(null, 16, 0xFFFFFFFF, "center"));

		cancelBtn = new FlxSprite(x + 224, y + 176).makeGraphic(180, 44, 0xFF2A2A34);
		add(cancelBtn);
		add(new FlxText(x + 224, y + 190, 180, "Cancel", 16).setFormat(null, 16, 0xFFB0B0BE, "center"));

		refresh();

		// Characters come from lime's text input, not from key events: on native,
		// KeyboardEvent.charCode is not filled in, so a key listener would receive
		// nothing printable. Key down is only used for the three control keys.
		keyHandler = onKeyDown;
		textHandler = onTextInput;
		Lib.application.window.onTextInput.add(textHandler);
		FlxG.stage.addEventListener(KeyboardEvent.KEY_DOWN, keyHandler);
	}

	override function update(elapsed:Float) {
		super.update(elapsed);
		if (closed || field == null) return;
		blink += elapsed;

		// caret, so an empty field still looks like something you can type into
		var caret = Std.int(blink * 2) % 2 == 0 ? "|" : " ";
		field.text = mask(entered) + (entered.length < MAX_LEN ? caret : "");

		unlockBtn.alpha = FlxG.mouse.overlaps(unlockBtn) ? 1 : 0.85;
		cancelBtn.alpha = FlxG.mouse.overlaps(cancelBtn) ? 1 : 0.85;

		if (FlxG.mouse.justPressed) {
			if (FlxG.mouse.overlaps(unlockBtn)) submit();
			else if (FlxG.mouse.overlaps(cancelBtn)) finish(false);
		}
	}

	function onTextInput(text:String):Void {
		if (closed || text == null) return;
		for (i in 0...text.length) {
			if (entered.length >= MAX_LEN) break;
			// drop control characters that some keyboards send along
			if (text.charCodeAt(i) >= 32) entered += text.charAt(i);
		}
	}

	function onKeyDown(e:KeyboardEvent):Void {
		if (closed || e == null) return;
		switch (e.keyCode) {
			case 8: // backspace
				if (entered.length > 0) entered = entered.substr(0, entered.length - 1);
			case 13: // enter
				submit();
			case 27: // escape
				finish(false);
		}
		e.stopPropagation();
	}

	function submit():Void {
		if (closed || hint == null) return;
		if (entered.length == 0) {
			hint.text = "Type the password first.";
			hint.color = 0xFFFFB0B0;
			return;
		}
		if (ProtectionState.unlock(entered)) {
			finish(true);
			return;
		}
		hint.text = "That password does not match.";
		hint.color = 0xFFFF6B6B;
		entered = "";
	}

	function finish(ok:Bool):Void {
		if (closed) return;
		closed = true;
		Lib.application.window.onTextInput.remove(textHandler);
		FlxG.stage.removeEventListener(KeyboardEvent.KEY_DOWN, keyHandler);
		if (onDone != null) onDone(ok);
		close();
	}

	function refresh():Void {
		field.text = mask(entered);
		hint.color = 0xFF7A7A88;
		hint.text = "Enter to confirm, Esc to cancel.";
	}

	static function mask(text:String):String {
		var out = "";
		for (i in 0...text.length) out += "*";
		return out;
	}
}
