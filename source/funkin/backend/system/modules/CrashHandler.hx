package funkin.backend.system.modules;

import flixel.FlxG;
import funkin.backend.utils.NativeAPI;
import funkin.menus.CrashScreenState;
import haxe.CallStack;
import openfl.Lib;
import openfl.errors.Error;
import openfl.events.ErrorEvent;
import openfl.events.UncaughtErrorEvent;

final class CrashHandler {
	public static function init() {
		Lib.current.loaderInfo.uncaughtErrorEvents.addEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, onUncaughtError);
		#if cpp
		untyped __global__.__hxcpp_set_critical_error_handler(onError);
		#elseif hl
		hl.Api.setErrorHandler(onError);
		#end
	}

	public static function onUncaughtError(e:UncaughtErrorEvent) {
		var m:String = e.error;
		if (Std.isOfType(e.error, Error)) {
			var err:Error = cast e.error;
			m = '${err.message}';
		} else if (Std.isOfType(e.error, ErrorEvent)) {
			var err:ErrorEvent = cast e.error;
			m = '${err.text}';
		}
		var stack = CallStack.exceptionStack();
		var stackLabel:String = "";
		for(e in stack) {
			switch(e) {
				case CFunction: stackLabel += "Non-Haxe (C) Function";
				case Module(c): stackLabel += 'Module ${c}';
				case FilePos(parent, file, line, col):
					switch(parent) {
						case Method(cla, func):
							stackLabel += '(${file}) ${cla.split(".").last()}.$func() - line $line';
						case _:
							stackLabel += '(${file}) - line $line';
					}
				case LocalFunction(v):
					stackLabel += 'Local Function ${v}';
				case Method(cl, m):
					stackLabel += '${cl} - ${m}';
			}
			stackLabel += "\r\n";
		}

		e.preventDefault();
		e.stopPropagation();
		e.stopImmediatePropagation();

		// Show the in-game blue screen instead of the native dialog, so the player can
		// read and copy the stack trace. A crash inside the crash screen (or before
		// the stage exists) still falls back to the message box and quits.
		if (!CrashScreenState.shown && CrashScreenState.show(m, stackLabel))
			return;

		NativeAPI.showMessageBox("Codename Engine Crash Handler", 'Uncaught Error:$m\n\n$stackLabel', MSG_ERROR);
		#if sys
		Sys.exit(1);
		#end
	}

	#if (cpp || hl)
	private static function onError(message:Dynamic):Void
	{
		var text = Std.string(message);
		if (!CrashScreenState.shown && CrashScreenState.show(text, CrashScreenState.formatStack()))
			return;
		throw text;
	}
	#end
}