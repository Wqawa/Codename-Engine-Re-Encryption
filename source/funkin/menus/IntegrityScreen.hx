package funkin.menus;

import flixel.FlxG;
import flixel.FlxSprite;
import flixel.text.FlxText;
import funkin.backend.MusicBeatState;
import funkin.backend.system.IntegrityCheck;
import funkin.editors.ui.UIWarningSubstate;
import funkin.editors.ui.UIWarningSubstate.UIWarningKind;

/**
 * Runs the file check before anything else is shown, with a progress bar.
 *
 * It sits in front of the key prompt on purpose: if the files do not match the build,
 * that is worth knowing before the player is asked for a password. Once the check
 * finishes it shows the result (if any) and hands over to whichever screen would have
 * come next.
 */
class IntegrityScreen extends MusicBeatState {
	var work:Array<String>;
	var locked:Array<String>;

	var fill:FlxSprite;
	var info:FlxText;

	var reported:Bool = false;
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

		// a no-op when the check already ran or is already going
		IntegrityCheck.startVerify();
	}

	override function update(elapsed:Float) {
		super.update(elapsed);

		var total = IntegrityCheck.total;
		var progress = total <= 0 ? 0.0 : IntegrityCheck.checked / total;
		fill.scale.x = Math.max(0, Math.min(1, progress));
		info.text = IntegrityCheck.done ? IntegrityCheck.summary() : '${IntegrityCheck.checked} / ${total}';

		if (movingOn || !IntegrityCheck.done) return;

		if (!reported) {
			if (!IntegrityCheck.hasProblems()) {
				next();
				return;
			}
			reported = true;
			showResult();
			return;
		}

		// the dialog is up; wait for the player to close it
		if (subState != null) return;
		next();
	}

	function showResult():Void {
		var check = IntegrityCheck;
		var detail = check.manifestProblem;
		if (detail == null) {
			var listed = check.missing.length > 0 ? check.missing
				: (check.changed.length > 0 ? check.changed : check.extra);
			detail = check.sample(listed);
		}

		openSubState(new UIWarningSubstate(
			"Files Do Not Match This Build",
			check.summary() + "\n\n" + detail
			+ "\n\nThese were changed, are missing, or are not part of this build. The game "
			+ "keeps running, but anything loaded from them may not be what was shipped.",
			[{label: "Continue", color: 0x969533, onClick: function(_) {}}],
			UIWarningKind.INFO));
	}

	function next():Void {
		if (movingOn) return;
		movingOn = true;
		if (locked.length > 0) FlxG.switchState(new ModPackKeyState(locked));
		else FlxG.switchState(new ModPackLoadingState(work));
	}
}
