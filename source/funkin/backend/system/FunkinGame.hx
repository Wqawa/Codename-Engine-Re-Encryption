package funkin.backend.system;

import flixel.FlxG;
import flixel.FlxGame;
import funkin.options.Options;

class FunkinGame extends FlxGame {
	var skipNextTickUpdate:Bool = false;
	var devCrashHold:Float = 0;
	public override function switchState() {
		super.switchState();
		// draw once to put all images in gpu then put the last update time to now to prevent lag spikes or whatever
		draw();
		_total = ticks = getTicks();
		skipNextTickUpdate = true;
	}

	public override function onEnterFrame(t) {
		if (skipNextTickUpdate != (skipNextTickUpdate = false))
			_total = ticks = getTicks();
		super.onEnterFrame(t);
		#if sys
		devCrashHotkey(FlxG.elapsed > 0 ? FlxG.elapsed : 0.016);
		#end
	}

	#if sys
	/**
	 * Debug helper: with developer mode on, holding Ctrl+Alt+Shift+Q for three
	 * seconds throws an uncaught error on purpose, so the crash screen can be
	 * tested without breaking the build.
	 */
	function devCrashHotkey(delta:Float) {
		if (!Options.devMode || FlxG.keys == null || !FlxG.keys.pressed.CONTROL
			|| !FlxG.keys.pressed.ALT || !FlxG.keys.pressed.SHIFT || !FlxG.keys.pressed.Q) {
			devCrashHold = 0;
			return;
		}
		devCrashHold += delta;
		if (devCrashHold >= 3) {
			devCrashHold = 0;
			throw 'Manual crash test: Ctrl+Alt+Shift+Q held for 3 seconds (developer mode)';
		}
	}
	#end
}