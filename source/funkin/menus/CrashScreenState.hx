package funkin.menus;

import flixel.FlxG;
import flixel.FlxSprite;
import flixel.FlxState;
import flixel.text.FlxText;
import flixel.text.FlxText.FlxTextAlign;
import funkin.backend.assets.ModPackCrypto;
import funkin.backend.system.Flags;
import funkin.backend.system.MainState;
import haxe.CallStack;
import lime.system.Clipboard;

/**
 * Windows 10 style blue screen used instead of the native crash dialog.
 *
 * The engine routes uncaught errors here (see CrashHandler): the message and the
 * call stack are typed out line by line like a real bluescreen, the "N% complete"
 * counter follows that typing, and the whole report can be copied with C.
 * Enter restarts the game with every mod disabled, so a broken mod pack can never
 * lock the game out of the main menu again.
 */
class CrashScreenState extends FlxState {
	/** Set while the screen is up, so a second crash does not loop forever. */
	public static var shown:Bool = false;

	public static var lastReport:String = null;

	/** Characters written per second while the report is typed out. */
	static inline var TYPE_SPEED:Float = 320;

	public var report:String = "";
	public var header:String = "";

	public var detailsText:FlxText;
	public var titleText:FlxText;
	public var percentText:FlxText;
	public var hintText:FlxText;
	public var copyButton:FlxSprite;
	public var copyLabel:FlxText;
	public var restartLabel:FlxText;

	/** Number of characters of 'report' already on screen. */
	public var typed:Float = 0;
	public var lastShown:String = "";
	public var scroll:Int = 0;
	public var visibleLines:Int = 16;
	public var copied:Bool = false;

	public function new(?message:String, ?stack:String) {
		super();
		var msg = message == null ? "Unknown error" : message;
		var trace = stack == null ? "" : stack;
		header = msg;

		report = "Codename Engine crash report\n"
			+ "Version: " + Flags.VERSION_MESSAGE + "\n"
			+ "Error: " + msg + "\n"
			+ (trace.length > 0 ? "\nCall stack:\n" + trace : "");
		lastReport = report;
	}

	override function create() {
		super.create();
		shown = true;

		var bg = new FlxSprite(0, 0).makeGraphic(Std.int(FlxG.width), Std.int(FlxG.height), 0xFF0078D7);
		add(bg);

		var left = Std.int(FlxG.width * 0.08);
		var width = Std.int(FlxG.width * 0.84);

		var face = new FlxText(left, Std.int(FlxG.height * 0.09), width, ":(");
		face.setFormat(null, 92, 0xFFFFFFFF, FlxTextAlign.LEFT);
		add(face);

		titleText = new FlxText(left, Std.int(FlxG.height * 0.09) + 116, width,
			"Your game ran into a problem and needs to restart. The error report is being written below.");
		titleText.setFormat(null, 22, 0xFFFFFFFF, FlxTextAlign.LEFT);
		titleText.wordWrap = true;
		titleText.fieldWidth = width;
		add(titleText);

		percentText = new FlxText(left, titleText.y + 74, width, "0% complete");
		percentText.setFormat(null, 16, 0xFFFFFFFF, FlxTextAlign.LEFT);
		add(percentText);

		detailsText = new FlxText(left, percentText.y + 40, width, "");
		detailsText.setFormat(null, 12, 0xFFE6F2FF, FlxTextAlign.LEFT);
		detailsText.wordWrap = true;
		detailsText.fieldWidth = width;
		add(detailsText);

		hintText = new FlxText(left, Std.int(FlxG.height) - 62, width, "");
		hintText.setFormat(null, 12, 0xFFCFE9FF, FlxTextAlign.LEFT);
		add(hintText);

		// a copy and a restart button, drawn without any game asset
		copyButton = new FlxSprite(left, Std.int(FlxG.height) - 36).makeGraphic(240, 26, 0xFF1C5FA8);
		add(copyButton);
		copyLabel = new FlxText(left + 8, Std.int(FlxG.height) - 33, 240, "Copy report (C)");
		copyLabel.setFormat(null, 13, 0xFFFFFFFF, FlxTextAlign.LEFT);
		add(copyLabel);

		restartLabel = new FlxText(left + 264, Std.int(FlxG.height) - 33, FlxG.width,
			"Restart without mods (ENTER)");
		restartLabel.setFormat(null, 13, 0xFFFFFFFF, FlxTextAlign.LEFT);
		add(restartLabel);

		refreshDetails(true);
	}

	function typedLength():Int {
		return Std.int(Math.min(typed, report.length));
	}

	function typingDone():Bool {
		return typedLength() >= report.length;
	}

	/**
	 * Rebuilds the small window of lines that is visible. While the report is
	 * still being typed the window follows the last line, afterwards the player
	 * can scroll with the wheel or the arrow keys.
	 */
	function refreshDetails(follow:Bool = false) {
		var shownText = report.substr(0, typedLength());
		var lines = shownText.split("\n");

		var maxScroll = Std.int(Math.max(0, lines.length - visibleLines));
		if (follow) scroll = maxScroll;
		if (scroll < 0) scroll = 0;
		if (scroll > maxScroll) scroll = maxScroll;

		var out = "";
		for (i in 0...visibleLines) {
			var idx = scroll + i;
			if (idx >= lines.length) break;
			out += lines[idx] + "\n";
		}
		if (out != lastShown) {
			detailsText.text = out;
			lastShown = out;
		}

		percentText.text = Std.int(Math.min(1, report.length == 0 ? 1 : typedLength() / report.length) * 100) + "% complete";

		var info = "";
		if (lines.length > visibleLines)
			info = "lines " + (scroll + 1) + "-" + Std.int(Math.min(lines.length, scroll + visibleLines)) + " of " + lines.length + "    ";
		if (!typingDone())
			info += "Writing the report" + ".".repeat(1 + Std.int(TYPE_SPEED > 0 ? (typed / 64) % 3 : 0));
		else
			info += (copied ? "Copied to the clipboard." : "Tip: C copies the whole report, paste it when reporting the crash.");
		hintText.text = info;
	}

	override function update(elapsed:Float) {
		super.update(elapsed);

		if (!typingDone()) {
			typed += elapsed * TYPE_SPEED;
			refreshDetails(true);
		}

		if (!copied && FlxG.keys.justPressed.C) copyDetails();

		if (FlxG.mouse.justPressed && copyButton != null
			&& FlxG.mouse.x >= copyButton.x && FlxG.mouse.x <= copyButton.x + copyButton.width
			&& FlxG.mouse.y >= copyButton.y && FlxG.mouse.y <= copyButton.y + copyButton.height)
			copyDetails();

		var wheel = FlxG.mouse.wheel;
		if (wheel != 0) {
			scroll -= wheel;
			refreshDetails();
		}

		if (FlxG.keys.justPressed.DOWN || FlxG.keys.justPressed.PAGEUP || FlxG.keys.justPressed.PAGEDOWN || FlxG.keys.justPressed.UP) {
			if (FlxG.keys.justPressed.DOWN) scroll += 1;
			if (FlxG.keys.justPressed.UP) scroll -= 1;
			if (FlxG.keys.justPressed.PAGEDOWN) scroll += visibleLines;
			if (FlxG.keys.justPressed.PAGEUP) scroll -= visibleLines;
			refreshDetails();
		}

		if (FlxG.keys.justPressed.ENTER) {
			// first Enter skips the typing so the log can be read at once, the
			// second one restarts without mods
			if (!typingDone()) {
				typed = report.length;
				refreshDetails(true);
			} else
				restartSafe();
		}
	}

	function copyDetails() {
		try {
			Clipboard.text = report;
			copied = true;
		} catch (e:Dynamic) {}
		refreshDetails();
	}

	public static function restartSafe() {
		shown = false;
		ModPackCrypto.disableMods = true;
		ModPackCrypto.prepareDone = false;
		ModPackCrypto.preparing = false;
		FlxG.switchState(new MainState());
	}

	// ------------------------------------------------------------- helpers

	/** Formats an exception the way the crash screen wants it. */
	public static function describe(e:Dynamic):{message:String, stack:String} {
		var message = Std.string(e);
		if (Std.isOfType(e, openfl.errors.Error)) message = cast(e, openfl.errors.Error).message;
		return {message: message, stack: formatStack()};
	}

	public static function formatStack():String {
		var out = "";
		try {
			for (entry in CallStack.exceptionStack()) {
				switch (entry) {
					case CFunction:
						out += "Non-Haxe (C) Function";
					case Module(c):
						out += "Module " + c;
					case FilePos(parent, file, line, col):
						switch (parent) {
							case Method(cla, func):
								out += "(" + file + ") " + cla.split(".").last() + "." + func + "() - line " + line;
							case _:
								out += "(" + file + ") - line " + line;
						}
					case LocalFunction(v):
						out += "Local Function " + v;
					case Method(cl, m):
						out += cl + " - " + m;
				}
				out += "\n";
			}
		} catch (e:Dynamic) {}
		return out;
	}

	/** Switches to the crash screen, or returns false when that is not possible. */
	public static function show(message:String, ?stack:String):Bool {
		try {
			FlxG.switchState(new CrashScreenState(message, stack));
			return true;
		} catch (e:Dynamic) {
			return false;
		}
	}
}
