package funkin.menus;

import flixel.FlxG;
import flixel.FlxState;
import funkin.backend.system.IntegrityCheck;
import funkin.editors.ui.UIText;
import funkin.editors.ui.UIWarningSubstate;
import funkin.editors.ui.UIWarningSubstate.UIWarningKind;
import funkin.editors.ui.UIWarningSubstate.WarningLine;

/**
 * Runs the file check before anything else is shown, with a progress bar.
 *
 * It sits in front of the key prompt on purpose: a pack that wants a password should
 * not be the first thing on screen while the shipped files are in doubt. When the
 * check finishes, the result (if any) is shown and the screen hands over to whatever
 * would have come next.
 */
class IntegrityScreen extends PopupScreen {
	/** Names shown per section before it turns into "... and N more". */
	static inline var NAMES_PER_SECTION:Int = 4;

	// one colour per kind of finding: red is gone, amber is not what shipped, blue is new
	static inline var COLOR_MISSING:Int = 0xFFFF6B6B;
	static inline var COLOR_CHANGED:Int = 0xFFFFD24D;
	static inline var COLOR_EXTRA:Int = 0xFF5BB0FF;
	/** Explanations and the intro; the names carry the colour instead. */
	static inline var COLOR_HINT:Int = 0xFF9C9CAA;

	var work:Array<String>;
	var locked:Array<String>;

	var bar:PopupProgress;
	var info:UIText;

	var movingOn:Bool = false;

	public function new(work:Array<String>, locked:Array<String>) {
		super();
		this.work = work == null ? [] : work;
		this.locked = locked == null ? [] : locked;
	}

	override function create() {
		super.create();

		beginPanel("Checking game files", 640);
		addText("Every shipped file is compared against the manifest before anything else starts. "
			+ "The game keeps running either way.", 13, PopupScreen.COLOR_TEXT, 16);
		bar = addProgress(14);
		info = addText("0 / 0", 13, PopupScreen.COLOR_TEXT, 0);
		endPanel();

		// already running when the window opened; the call is a no-op then
		IntegrityCheck.startVerify();
	}

	override function update(elapsed:Float) {
		super.update(elapsed);

		final total = IntegrityCheck.total;
		final fraction = total <= 0 ? 0 : Math.max(0, Math.min(1, IntegrityCheck.checked / total));
		bar.value = fraction;
		if (progressLabel != null) progressLabel.text = Std.int(fraction * 100) + "%";
		info.text = IntegrityCheck.done ? IntegrityCheck.summary() : '${IntegrityCheck.checked} / $total';

		if (movingOn || !IntegrityCheck.done) return;

		if (!IntegrityCheck.reported) {
			if (!IntegrityCheck.hasProblems()) {
				next();
				return;
			}
			IntegrityCheck.markReported();
			openSubState(resultDialog());
			return;
		}

		// the dialog is up; wait for the player to close it
		if (subState != null) return;
		next();
	}

	/**
	 * Shows the result on the main menu.
	 *
	 * The startup screen only exists when a pack has to be unlocked, so a plain build
	 * would otherwise run the check and never tell anyone about it. `reported` keeps
	 * the dialog to one per run, however often the menu is rebuilt.
	 */
	public static function reportOnMenu(state:FlxState):Void {
		if (!IntegrityCheck.done || IntegrityCheck.reported || !IntegrityCheck.hasProblems()) return;
		if (state.subState != null) return;
		IntegrityCheck.markReported();
		state.openSubState(resultDialog());
	}

	static function resultDialog():UIWarningSubstate {
		var lines:Array<WarningLine> = [];

		if (IntegrityCheck.manifestProblem != null) {
			lines.push({text: IntegrityCheck.manifestProblem, color: COLOR_MISSING, size: 13});
			lines.push({text: "The check could not run, so nothing was verified.", color: COLOR_HINT, size: 12, gap: 10});
		} else {
			lines.push({
				text: '${IntegrityCheck.checked} file(s) were compared against the manifest shipped with this build.',
				color: COLOR_HINT, size: 12});
			addSection(lines, "Missing", "Listed in the manifest, no longer on disk.",
				IntegrityCheck.missing, COLOR_MISSING);
			addSection(lines, "Modified", "On disk, but not what this build shipped.",
				IntegrityCheck.changed, COLOR_CHANGED);
			addSection(lines, "Unlisted", "Under assets/, but not in the manifest.",
				IntegrityCheck.extra, COLOR_EXTRA);
			lines.push({
				text: "The game keeps running; anything loaded from the files above may not be what was shipped.",
				color: COLOR_HINT, size: 12, gap: 16});
		}

		return new UIWarningSubstate(
			"Files Do Not Match This Build",
			"",
			[{label: "Continue", color: 0x969533, onClick: function(_) {}}],
			UIWarningKind.INFO, false, lines);
	}

	/**
	 * One block of the report: a coloured heading with the count, a one line explanation,
	 * then the first few names. A list that found nothing is skipped entirely, so the
	 * dialog only shows what is actually wrong.
	 */
	static function addSection(lines:Array<WarningLine>, title:String, hint:String, list:Array<String>, color:Int):Void {
		if (list.length == 0) return;
		lines.push({text: '${title.toUpperCase()}  (${list.length})', color: color, size: 13, gap: 16});
		lines.push({text: hint, color: COLOR_HINT, size: 11, gap: 2});
		for (i in 0...list.length) {
			if (i >= NAMES_PER_SECTION) {
				lines.push({text: '  ... and ${list.length - NAMES_PER_SECTION} more', color: color, size: 11, gap: 2});
				break;
			}
			lines.push({text: '  ' + list[i], color: color, size: 11, gap: 2});
		}
	}

	function next():Void {
		if (movingOn) return;
		movingOn = true;
		if (locked.length > 0) FlxG.switchState(new ModPackKeyState(locked));
		else FlxG.switchState(new ModPackLoadingState(work));
	}
}
