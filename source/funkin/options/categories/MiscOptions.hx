package funkin.options.categories;

import funkin.savedata.FunkinSave;

class MiscOptions extends TreeMenuScreen {
	public function new() {
		super('optionsTree.miscellaneous-name', 'optionsTree.miscellaneous-desc', 'MiscOptions.');

		// Locked while a pack asks for protection mode: the value is already forced off,
		// and a box that can be ticked would look like the setting still works.
		var dev = new Checkbox(getNameID('devMode'), getDescID('devMode'), 'devMode');
		dev.locked = funkin.backend.assets.ProtectionState.isLocked();
		add(dev);

		// Sits next to devMode because it is what switches devMode off. A pack carrying a
		// protection marker locks it; clicking asks for that pack's password.
		var protect:Checkbox = null;
		protect = new Checkbox(getNameID('protectionMode'), getDescID('protectionMode'), 'protectionMode', function() {
			var state = funkin.backend.assets.ProtectionState;
			// select() already flipped the box, so every branch puts it back first
			protect.checked = true;
			Options.protectionMode = true;

			Logs.trace('Protection option clicked: active=' + state.active + ' available=' + state.available
				+ ' boxOpen=' + funkin.menus.ProtectionUnlockSubstate.isOpen, INFO);

			if (!state.active || FlxG.state == null) return;
			// a second click used to stack another box on top, and the one underneath kept
			// its key listeners alive after being closed
			if (funkin.menus.ProtectionUnlockSubstate.isOpen) return;

			FlxG.state.openSubState(new funkin.menus.ProtectionUnlockSubstate(function(ok:Bool) {
				if (!ok) return;
				protect.checked = false;
				Options.protectionMode = false;
				// unlocked for this session; the box goes grey because turning it back on
				// would need the password again
				protect.locked = true;
			}));
		});
		// Only clickable while actually locked: with no marker there is nothing to unlock,
		// and once unlocked the pack cannot turn it back on without the password.
		protect.locked = !(funkin.backend.assets.ProtectionState.available && funkin.backend.assets.ProtectionState.active);
		add(protect);

		add(new Checkbox(getNameID('allowConfigWarning'), getDescID('allowConfigWarning'), 'allowConfigWarning'));
		add(new Checkbox(getNameID('wrapDecryptedPacks'), getDescID('wrapDecryptedPacks'), 'wrapDecryptedPacks'));
		#if UPDATE_CHECKING
		add(new Checkbox(getNameID('betaUpdates'), getDescID('betaUpdates'), 'betaUpdates'));
		add(new TextOption(getNameID('checkForUpdates'), getDescID('checkForUpdates'), () -> {
			var report = funkin.backend.system.updating.UpdateUtil.checkForUpdates(true);
			if (report.newUpdate) FlxG.switchState(new funkin.backend.system.updating.UpdateAvailableScreen(report));
			else {
				CoolUtil.playMenuSFX(CANCEL);
				//updateDescText(translate('checkForUpdates-noUpdateFound'));
			}
		}));
		#end

		add(new Separator());
		add(new TextOption(getNameID('resetSaveData'), getDescID('resetSaveData'), () -> {
			FunkinSave.save.erase();
			FunkinSave.highscores.clear();
			FunkinSave.flush();
		}));
	}
}