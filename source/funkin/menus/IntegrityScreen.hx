package funkin.menus;

import flixel.FlxG;
import flixel.FlxSprite;
import flixel.FlxState;
import flixel.text.FlxText;
import funkin.backend.MusicBeatState;
import funkin.backend.system.IntegrityCheck;
import funkin.editors.ui.UIWarningSubstate;
import funkin.editors.ui.UIWarningSubstate.UIWarningKind;

/**
 * Runs the file check before anything else is shown, with a progress bar.
 *
 * It sits in front of the key prompt on purpose: a pack that wants a password should
 * not be the first thing on screen while the shipped files are in doubt. When the
 * check finishes, the result (if any) is shown and the screen hands over to whatever
 * would have come next.
 */
class IntegrityScreen extends MusicBeatState {
	var work:Array<String>;
	var locked:Array<String>;

	var fill:FlxSprite;
	var info:FlxText;

	var movingOn:Bool = false;

	public function new(work:Array<String>, locked:Array<String>) {
		super();
		this.work = work == null ? [] : work;
		this.locked = locked == null ? [] : locked;
	}

	override function create() {
		super.create();

		add(new FlxSprite(0, 0).makeGraphic(FlxG.width, FlxG.height, 0xFF101014));

		var title = new FlxText(0, FlxG.height * 0.5 - 58, FlxG.width, "Checking game files", 22);
		title.alignment = 'center';
		add(title);

		var barW = 420;
		var barX = (FlxG.width - barW) * 0.5;
		var barY = FlxG.height * 0.5 + 4;

		add(new FlxSprite(barX, barY).makeGraphic(barW, 6, 0xFF2A2A33));

		fill = new FlxSprite(barX, barY).makeGraphic(barW, 6, 0xFF4D9EFF);
		fill.scale.x = 0;
		add(fill);

		info = new FlxText(0, barY + 20, FlxG.width, "", 13);
		info.alignment = 'center';
		info.color = 0xFF8A8A96;
		add(info);

		// already running when the window opened; the call is a no-op then
		IntegrityCheck.startVerify();
	}

	override function update(elapsed:Float) {
		super.update(elapsed);

		var total = IntegrityCheck.total;
		fill.scale.x = total <= 0 ? 0 : Math.max(0, Math.min(1, IntegrityCheck.checked / total));
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
		var detail = IntegrityCheck.manifestProblem;
		if (detail == null) {
			var listed = IntegrityCheck.missing.length > 0
				? IntegrityCheck.missing
				: (IntegrityCheck.changed.length > 0 ? IntegrityCheck.changed : IntegrityCheck.extra);
			detail = IntegrityCheck.sample(listed);
		}

		return new UIWarningSubstate(
			"Files Do Not Match This Build",
			IntegrityCheck.summary() + "\n\n" + detail
			+ "\n\nThese were changed, are missing, or are not part of this build. The game "
			+ "keeps running, but anything loaded from them may not be what was shipped.",
			[{label: "Continue", color: 0x969533, onClick: function(_) {}}],
			UIWarningKind.INFO);
	}

	function next():Void {
		if (movingOn) return;
		movingOn = true;
		if (locked.length > 0) FlxG.switchState(new ModPackKeyState(locked));
		else FlxG.switchState(new ModPackLoadingState(work));
	}
}
