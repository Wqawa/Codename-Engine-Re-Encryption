package funkin.editors.ui;

import openfl.display.ShaderInput;
import openfl.display.ShaderParameter;
import openfl.filters.ShaderFilter;
import flixel.tweens.FlxEase;
import flixel.tweens.FlxTween;
import funkin.backend.shaders.CustomShader;

/**
 * The engine's modal dialog: a blurred backdrop, a title, a message and a row of buttons.
 *
 * `kind` picks both the icon and the tint, and the enum value doubles as the file name
 * under `editors/warnings/`, so a type and its picture cannot drift apart.
 */
class UIWarningSubstate extends MusicBeatSubstate {
	var camShaders:Array<FlxCamera> = [];
	var blurShader:CustomShader;

	public var bHeight:Int = 232;

	var title:String;
	var message:String;
	var buttons:Array<WarningButton>;
	var kind:UIWarningKind = ERROR;

	// Optional text field, built from the engine's own UITextBox. Null without one.
	var wantsInput:Bool = false;
	var inputBox:UITextBox;

	/** A button can set this to stay open, for input that failed its check. */
	public var keepOpen:Bool = false;

	/** What the player typed, or "" when the dialog has no field. */
	public function inputValue():String {
		return inputBox == null || inputBox.label == null ? "" : inputBox.label.text;
	}

	var titleSpr:UIText;
	var messageSpr:UIText;

	var warnCam:FlxCamera;

	public override function onSubstateOpen() {
		super.onSubstateOpen();
		parent.persistentUpdate = false;
		parent.persistentDraw = true;
	}

	public override function create() {
		// a row for the input field, above the buttons
		if (wantsInput) bHeight += 72;

		blurShader = makeBlurShader();
		for (c in FlxG.cameras.list) {
			if (hasBlur(c)) continue;
			camShaders.push(c);
			c.addShader(blurShader);
		}

		camera = warnCam = new FlxCamera();
		warnCam.bgColor = 0;
		warnCam.alpha = 0;
		warnCam.zoom = 0.1;
		FlxG.cameras.add(warnCam, false);

		var spr = new UISliceSprite(0, 0, CoolUtil.maxInt(560, 30 + (170 * buttons.length)), bHeight,
			'editors/ui/${kind == ERROR ? "normal" : "grayscale"}-popup');

		// built before the panel is centred: its height feeds the panel height. Placed and
		// added further down, once spr.x and spr.y are final.
		var sprIcon = new FlxSprite(0, 0).loadGraphic(Paths.image('editors/warnings/${kind}'));
		sprIcon.scale.set(1.4, 1.4);
		sprIcon.updateHitbox();

		messageSpr = new UIText(0, 0, spr.bWidth - 100 - (26 * 2), message);
		spr.bHeight = Std.int(bHeight + Math.abs(Math.min(sprIcon.height - messageSpr.height, 0)));

		spr.x = (FlxG.width - spr.bWidth) / 2;
		spr.y = (FlxG.height - spr.bHeight) / 2;
		spr.color = switch (kind) {
			case ERROR: 0xFFFF0000;
			case INFO: 0xFF4D9EFF;
			default: 0xFFFFFF00;
		};
		add(spr);

		if (title != null) {
			add(titleSpr = new UIText(spr.x + 25, spr.y, spr.bWidth - 50, title, 15, -1));
			titleSpr.y = spr.y + ((30 - titleSpr.height) / 2);
		}

		sprIcon.setPosition(spr.x + 18, spr.y + 28 + 26);
		sprIcon.antialiasing = true;
		add(sprIcon);

		messageSpr.x = sprIcon.x + 70 + 16 + 20;
		messageSpr.y = sprIcon.y;
		add(messageSpr);

		if (wantsInput) {
			var boxY = spr.y + spr.bHeight - (36 + 16) - 56;
			// UITextBox brings its own caret, selection and system text input; it only
			// needs the focus flag, which also flips window.textInputEnabled
			inputBox = new UITextBox(spr.x + 100, boxY, "", Std.int(spr.bWidth - 200), 36);
			inputBox.focused = true;
			add(inputBox);
		}

		var xPos = (FlxG.width - (30 + (170 * buttons.length))) / 2;
		for (k => b in buttons) {
			var button = new UIButton(xPos + 20 + (170 * k), spr.y + spr.bHeight - (36 + 16), b.label, function() {
				b.onClick(this);
				// a button that rejected the input keeps the dialog up
				if (!keepOpen) close();
				keepOpen = false;
			}, 160, 30);
			if (b.color != null) {
				button.frames = Paths.getFrames("editors/ui/grayscale-button");
				button.color = b.color;
			}
			add(button);
		}

		FlxTween.tween(camera, {alpha: 1}, 0.25, {ease: FlxEase.cubeOut});
		FlxTween.tween(camera, {zoom: 1}, 0.66, {ease: FlxEase.elasticOut});

		CoolUtil.playMenuSFX(WARNING);
	}

	/** True when this camera already runs the same blur; adding it twice stacks the effect. */
	function hasBlur(c:FlxCamera):Bool {
		var filters = @:privateAccess c._filters;
		if (filters == null) return false;
		for (filter in filters) {
			if (!(filter is ShaderFilter)) continue;
			var shader = (cast filter : ShaderFilter).shader;
			if (shader is CustomShader && (cast shader : CustomShader).path == blurShader.path) return true;
		}
		return false;
	}

	function makeBlurShader():CustomShader {
		var shader = new CustomShader(Options.intensiveBlur ? "engine/editorBlur" : "engine/editorBlurFast");
		if (!Options.intensiveBlur) {
			var noiseTexture:ShaderInput<openfl.display.BitmapData> = shader.data.noiseTexture;
			noiseTexture.input = Assets.getBitmapData("assets/shaders/noise256.png");
			noiseTexture.wrap = REPEAT;
			var noiseTextureSize:ShaderParameter<Float> = shader.data.noiseTextureSize;
			noiseTextureSize.value = [noiseTexture.input.width, noiseTexture.input.height];
		}
		return shader;
	}

	public override function destroy() {
		super.destroy();
		if (camShaders != null && blurShader != null)
			for (e in camShaders)
				e.removeShader(blurShader);

		// create() can throw before the camera exists - a missing icon is enough
		if (warnCam != null) {
			FlxTween.cancelTweensOf(warnCam);
			FlxG.cameras.remove(warnCam);
		}

		// the field switched system text input on when it took focus; leaving it on would
		// feed every later keystroke into a field nobody can see
		if (inputBox != null) {
			inputBox.focused = false;
			FlxG.stage.window.textInputEnabled = false;
		}
	}

	/**
	 * @param wantsInput Adds a native text field above the buttons; read it back with
	 *                   `inputValue()`. The dialog never acts on the text itself - the
	 *                   caller decides what it means.
	 */
	public function new(title:String, message:String, buttons:Array<WarningButton>, ?kind:UIWarningKind = ERROR,
			?wantsInput:Bool = false) {
		super();
		this.title = title;
		this.message = message;
		this.buttons = buttons;
		this.kind = kind;
		this.wantsInput = wantsInput;
	}
}

/**
 * What the dialog is for. The name doubles as the icon file under `editors/warnings/`:
 * a red exclamation, a yellow triangle or a blue question mark.
 */
enum abstract UIWarningKind(String) from String to String {
	var ERROR = 'error';
	var WARNING = 'warning';
	var INFO = 'info';
}

typedef WarningButton = {
	var label:String;
	var ?color:Int;
	var onClick:UIWarningSubstate->Void;
}
