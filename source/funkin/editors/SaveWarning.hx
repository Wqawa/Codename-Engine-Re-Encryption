package funkin.editors;

/**
 * The "unsaved changes" prompt.
 *
 * Shared by the editors and by anything else that has to ask before work is thrown
 * away: a packed mod with staged edits (ZipEditCache), the window closing, and a mod
 * switch.
 *
 * Every label goes through TU.translate with an English fallback. The editors'
 * language file is not guaranteed to be loaded when this prompt is shown - closing
 * the window from the title screen is one case - and a missing key used to render as
 * a literal "{saveWarning.warningTitle}" on screen.
 */
class SaveWarning {
	public static var showWarning(default, set):Bool;
	public static function set_showWarning(warning:Bool):Bool
		return WindowUtils.preventClosing = showWarning = warning;

	public static var selectionClass:Class<EditorTreeMenu> = null;
	public static var saveFunc:Void->Void = null;

	public static function init() {
		showWarning = false;

		// WindowUtils treats a second close request as "the player insists" and lets it
		// through, which is fine for a plain exit but not while this prompt is up: the
		// question would be skipped and the game would close with the work unsaved. Hold
		// the window here until the prompt is answered (its buttons clear the flag).
		WindowUtils.addCloseVeto(function() return showWarning && FlxG.state != null);

		WindowUtils.onClosing = function () {
			if (SaveWarning.showWarning) triggerWarning(true);
		}
	}

	public static function triggerWarning(?closingWindow:Bool = false) {
		// Not limited to UIState: the window can be closed from any state, and callers
		// other than the editors (a pending mod merge, for one) rely on this prompt too.
		if (FlxG.state == null) return;

		// The save warning labels live in the editors' language file. When that file did
		// not make it into the language map the dialog used to render the raw keys -
		// "{saveWarning.warningTitle}" and friends - with nothing in the log to explain it.
		// Say it once; the English fallbacks below keep the dialog readable.
		if (!TU.exists("saveWarning.cancel"))
			Logs.warn("The save warning labels are missing from the language map, showing English.", "Language");

		var title = TU.translate("saveWarning.warningTitle", null, "Unsaved Changes!");
		var message = TU.translate("saveWarning.warningDesc", null,
			"Your changes will be lost if you don't save them. (Can't be recovered)\n\n\nWould you like to Cancel?");

		// Stack the prompt on whatever is already open instead of replacing it.
		// openSubState() on the state destroys the substate that is already there, so
		// asking this while the pause menu was up threw the pause menu away: Cancel then
		// closed the prompt with nothing underneath, and the song simply carried on
		// unpaused. Same walk as UIState.openContextMenu() does for context menus.
		var host = FlxG.state;
		while (host.subState != null)
			host = host.subState;

		// The close button stays available while this is up (it is the OS's, not ours), so
		// pressing it again used to stack a second prompt on top of the first one - each
		// copy holding every click it got. One prompt at a time.
		if (host is UIWarningSubstate) return;

		host.openSubState(new UIWarningSubstate(title, message, [
			{
				label: TU.translate("saveWarning.cancel", null, "Cancel"),
				color: 0x969533,
				onClick: function(_) {
					if (closingWindow) WindowUtils.resetClosing();
				}
			},
			{
				label: closingWindow
					? TU.translate("saveWarning.exitGame", null, "Exit Game")
					: TU.translate("saveWarning.exitToMenu", null, "Exit To Menu"),
				color: 0x969533,
				onClick: function(_) {
					if (closingWindow) exitGame(false);
					else leaveWithoutSaving();
				}
			},
			{
				label: closingWindow
					? TU.translate("saveWarning.saveAndExitGame", null, "Save & Exit Game")
					: TU.translate("saveWarning.saveAndExitToMenu", null, "Save & Exit To Menu"),
				color: 0x969533,
				onClick: function(_) {
					if (saveFunc != null) saveFunc();
					if (closingWindow) exitGame(true);
					else leaveWithoutSaving();
				}
			}
		], funkin.editors.ui.UIWarningSubstate.UIWarningKind.WARNING));
	}

	static function leaveWithoutSaving():Void {
		if (selectionClass != null) FlxG.switchState(Type.createInstance(SaveWarning.selectionClass, []));
	}

	/**
	 * Closes the game, through the mod cleanup screen when a decrypted pack is still
	 * held.
	 *
	 * `saved` says the player answered "save". An editor's save writes into the staging
	 * folder of a packed mod, and inside an editor the merge into the pack is left to the
	 * next close - but this close is the one that ends the process, so there is no next
	 * one: the files stayed in `.cne/mods/<mod>/` and the pack was never touched, while
	 * the player had just been told their work was saved. Playtesting a chart and
	 * closing the window from the pause menu was the usual way to hit it.
	 *
	 * The merge goes through ModPackMergeState, the same screen a mod switch uses: a
	 * rewrite re-encrypts the whole archive and takes seconds on a big mod, which is too
	 * long to freeze the window for. Its callback comes back here with nothing left to
	 * merge, and the wipe screen (if one is due) runs after the pack is in one piece
	 * rather than while it is being rewritten.
	 */
	static function exitGame(saved:Bool = false):Void {
		// Asked while the close veto is still up: pendingMod() compares the staged files
		// against the pack to drop the ones that never changed, and the window must not be
		// able to go away halfway through that.
		var staged = saved ? funkin.backend.assets.ZipEditCache.pendingMod() : null;

		// The prompt is answered, so it stops holding preventClosing - the merge and cleanup
		// screens own the close from here. Keeping it on would also leave the dialog armed:
		// the next close request would pop the save warning again, on top of whatever screen
		// is running by then.
		showWarning = false;
		WindowUtils.resetClosing();

		if (staged != null) {
			// ...and the merge screen hands the close back with nothing left to merge
			FlxG.switchState(new funkin.menus.ModPackMergeState(staged, function() exitGame(false)));
			return;
		}

		if (funkin.backend.assets.ModPackCrypto.needsCleanup() && FlxG.state != null) {
			FlxG.switchState(new funkin.menus.ModPackCleanupState());
			return;
		}
		openfl.system.System.exit(0);
	}

	public static inline function reset() {
		SaveWarning.showWarning = false;
		SaveWarning.selectionClass = null;
		SaveWarning.saveFunc = null;
	}
}
