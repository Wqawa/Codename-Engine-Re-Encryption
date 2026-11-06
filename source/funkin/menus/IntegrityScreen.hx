package funkin.menus;

import flixel.FlxG;
import flixel.FlxState;
import flixel.text.FlxText.FlxTextAlign;
import funkin.backend.system.IntegrityCheck;
import funkin.editors.ui.UISliceSprite;
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

	// Severity, not kind: the same three colours the dialog is tinted with, so a red
	// heading and a red panel always mean the same thing. Modified is the worst finding,
	// a missing file after that, an added one only worth a note.
	static inline var COLOR_ERROR:Int = 0xFFFF6B6B;
	static inline var COLOR_WARN:Int = 0xFFFFD24D;
	static inline var COLOR_INFO:Int = 0xFF5BB0FF;
	/** Explanations and the intro; the names carry the colour instead. */
	static inline var COLOR_HINT:Int = 0xFF9C9CAA;

	/** How often the labels are rebuilt. A text field re-shapes its glyphs on every change. */
	static inline var LABEL_INTERVAL:Float = 1 / 10;

	static inline var COUNTER_W:Int = 208;
	static inline var COUNTER_H:Int = 118;
	static inline var COUNTER_GAP:Int = 14;

	var work:Array<String>;
	var locked:Array<String>;

	var bar:PopupProgress;
	var info:UIText;

	/** The number in the side window; everything else there is laid out once and never read. */
	var counterNumber:UIText;
	var shownProblems:Int = -1;

	var movingOn:Bool = false;
	var labelTimer:Float = 0;
	/** Set once the check is over and the final numbers have been written. */
	var finalShown:Bool = false;

	public function new(work:Array<String>, locked:Array<String>) {
		super();
		this.work = work == null ? [] : work;
		this.locked = locked == null ? [] : locked;
		bgType = 'cmd';
		// The crash overlay's idle bob, same amplitude and speed: a frame that keeps moving
		// hides the hitch of a check that reads every shipped file.
		bobAmplitude = 5;
	}

	override function create() {
		super.create();

		beginPanel("Checking game files", 640);
		addText("Every shipped file is compared against the manifest before anything else starts. "
			+ "The game keeps running either way.", 13, PopupScreen.COLOR_TEXT, 16);
		bar = addProgress(14);
		info = addText("0 / 0", 13, PopupScreen.COLOR_TEXT, 0);
		endPanel();

		buildCounter();

		// already running when the window opened; the call is a no-op then
		IntegrityCheck.startVerify();
	}

	/**
	 * The small window beside the panel, with how many findings there are so far.
	 *
	 * The check reads a thousand files and the bar alone barely moves, which reads as a
	 * frozen screen; the counter is the thing that actually ticks while it grinds.
	 */
	function buildCounter():Void {
		// bWidth/bHeight are the panel's real size: resize() only sets those, width/height
		// still report the size of the 9-slice frame
		final panelW = panel.bWidth;
		var x = panel.x + panelW + COUNTER_GAP;
		// centred against the panel, so the two read as one row
		var y = Math.round(panel.y + ((panel.bHeight - COUNTER_H) / 2));
		if (x + COUNTER_W > FlxG.width - 12) {
			// no room on the right: mirror it to the left
			x = panel.x - COUNTER_GAP - COUNTER_W;
			if (x < 12) {
				// neither side fits: sit under the panel, right aligned, rather than on top of it
				x = Math.min(panel.x + panelW - COUNTER_W, FlxG.width - COUNTER_W - 12);
				y = Math.round(panel.y + panel.bHeight + COUNTER_GAP);
			}
		}

		final pad = PopupScreen.PAD;
		final textW = COUNTER_W - pad * 2;

		placeSide(new UISliceSprite(x, y, COUNTER_W, COUNTER_H, 'editors/ui/normal-popup'));

		final title = placeSide(new UIText(x + pad, 0, textW, "Problems", 15, PopupScreen.COLOR_TEXT));
		title.y = y + ((PopupScreen.TITLE_H - title.height) / 2);

		counterNumber = placeSide(new UIText(x + pad, y + PopupScreen.TITLE_H + 12, textW, "0", 30, COLOR_HINT));
		counterNumber.alignment = FlxTextAlign.CENTER;

		final hint = placeSide(new UIText(x + pad, 0, textW, "found so far", 11, COLOR_HINT));
		hint.alignment = FlxTextAlign.CENTER;
		hint.y = counterNumber.y + counterNumber.height + 2;
	}

	override function update(elapsed:Float) {
		super.update(elapsed);

		// the panel bobs from PopupScreen.update (bobAmplitude); the counter rides that same
		// clock out of phase on purpose - two windows moving in lockstep read as one block
		// being dragged around, not as two panes
		setSideOffset(Math.sin(bobTime * PopupScreen.BOB_SPEED + 2.1) * 5);

		final total = IntegrityCheck.total;
		final fraction = total <= 0 ? 0 : Math.max(0, Math.min(1, IntegrityCheck.checked / total));
		bar.value = fraction;

		// The counter runs every frame. It only writes when the number actually changes, and
		// it is the one thing the player watches; held to the 10 Hz budget it was still a tick
		// behind when the scan ended, and the dialog that opened on that same frame froze the
		// stale number on screen for good.
		updateCounter();

		// The percentage and the N / M line stay at 10 Hz: the bar is a rect, but every text
		// change re-shapes its glyphs and both of these change on nearly every frame.
		if ((labelTimer += elapsed) >= LABEL_INTERVAL) {
			labelTimer = 0;
			if (progressLabel != null) progressLabel.text = Std.int(fraction * 100) + "%";
			info.text = IntegrityCheck.done ? IntegrityCheck.summary() : '${IntegrityCheck.checked} / $total';
		}

		if (movingOn || !IntegrityCheck.done) return;

		// the counts are final; write them once, whatever the last 10 Hz tick missed
		if (!finalShown) {
			finalShown = true;
			if (progressLabel != null) progressLabel.text = Std.int(fraction * 100) + "%";
			info.text = IntegrityCheck.summary();
			updateCounter();
		}

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

	function updateCounter():Void {
		if (counterNumber == null) return;
		final found = IntegrityCheck.problemCount();
		if (found == shownProblems) return;
		shownProblems = found;
		counterNumber.text = Std.string(found);
		counterNumber.color = severityColor();
	}

	/** The colour of the counter, from the worst finding so far. */
	static function severityColor():Int {
		if (IntegrityCheck.changed.length > 0) return COLOR_ERROR;
		if (IntegrityCheck.missing.length > 0) return COLOR_WARN;
		if (IntegrityCheck.extra.length > 0) return COLOR_INFO;
		return COLOR_HINT;
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
			lines.push({text: IntegrityCheck.manifestProblem, color: COLOR_ERROR, size: 13});
			lines.push({text: "The check could not run, so nothing was verified.", color: COLOR_HINT, size: 12, gap: 10});
		} else {
			lines.push({
				text: '${IntegrityCheck.checked} file(s) were compared against the manifest shipped with this build.',
				color: COLOR_HINT, size: 12});
			addSection(lines, "Missing", "Listed in the manifest, no longer on disk.",
				IntegrityCheck.missing, COLOR_WARN);
			addSection(lines, "Added", "Under assets/, but not in the manifest.",
				IntegrityCheck.extra, COLOR_INFO);
			addSection(lines, "Modified", "On disk, but not what this build shipped.",
				IntegrityCheck.changed, COLOR_ERROR);
			lines.push({
				text: "The game keeps running; anything loaded from the files above may not be what was shipped.",
				color: COLOR_HINT, size: 12, gap: 16});
		}

		return new UIWarningSubstate(
			"Files Do Not Match This Build",
			"",
			[{label: "Continue", color: 0x969533, onClick: function(_) {}}],
			severityKind(), false, lines);
	}

	/**
	 * How the dialog itself is drawn, from the worst finding: a modified file is an error,
	 * a missing one a warning, an added one only a note. The panel tint and the icon
	 * follow this, so the colour of the whole dialog says how bad it is.
	 */
	static function severityKind():UIWarningKind {
		if (IntegrityCheck.manifestProblem != null || IntegrityCheck.changed.length > 0) return UIWarningKind.ERROR;
		if (IntegrityCheck.missing.length > 0) return UIWarningKind.WARNING;
		return UIWarningKind.INFO;
	}

	/**
	 * One block of the report: a coloured heading with the count, a one line explanation,
	 * then the first few names. A list that found nothing is skipped entirely, so the
	 * dialog only shows what is actually wrong.
	 */
	static function addSection(lines:Array<WarningLine>, title:String, hint:String, list:Array<String>, color:Int):Void {
		if (list.length == 0) return;
		lines.push({text: '${title}  (${list.length})', color: color, size: 13, gap: 16});
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
