package funkin.options.categories;

import funkin.savedata.FunkinSave;

class MiscOptions extends TreeMenuScreen {
	public function new() {
		super('optionsTree.miscellaneous-name', 'optionsTree.miscellaneous-desc', 'MiscOptions.');

		add(new Checkbox(getNameID('devMode'), getDescID('devMode'), 'devMode'));

		// Sits next to devMode because it is what switches devMode off. A pack carrying a
		// protection marker locks it; clicking it cannot unlock - that needs the pack's
		// password (see docs/PROTECTION.md), so the box snaps back.
		var protect:Checkbox = null;
		protect = new Checkbox(getNameID('protectionMode'), getDescID('protectionMode'), 'protectionMode', function() {
			if (funkin.backend.assets.ProtectionState.active) {
				protect.checked = true;
				Options.protectionMode = true;
			}
		});
		protect.locked = !funkin.backend.assets.ProtectionState.available;
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