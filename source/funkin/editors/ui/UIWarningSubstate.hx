package funkin.editors.ui;

import openfl.display.ShaderParameter;
import openfl.display.ShaderInput;
import openfl.events.KeyboardEvent;
import openfl.filters.ShaderFilter;
import openfl.Lib;
import flixel.tweens.FlxEase;
import flixel.tweens.FlxTween;
import funkin.backend.shaders.CustomShader;
import openfl.filters.ShaderFilter;

class UIWarningSubstate extends MusicBeatSubstate {
	var camShaders:Array<FlxCamera> = [];
	var blurShader:CustomShader = {
		var _ = new CustomShader(Options.intensiveBlur ? "engine/editorBlur" : "engine/editorBlurFast");
		if(!Options.intensiveBlur) {
			var noiseTexture:ShaderInput<openfl.display.BitmapData> = _.data.noiseTexture;
			noiseTexture.input = Assets.getBitmapData("assets/shaders/noise256.png");
			noiseTexture.wrap = REPEAT;
			var noiseTextureSize:ShaderParameter<Float> = _.data.noiseTextureSize;
			noiseTextureSize.value = [noiseTexture.input.width, noiseTexture.input.height];
		}
		_;
	};

	public var bHeight:Int = 232;

	var title:String;
	var message:String;
	var buttons:Array<WarningButton>;
	var isError:Bool = true;

	// Optional text field, built from the engine's own UITextBox. Null when the dialog was
	// created without one.
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

		for(c in FlxG.cameras.list) {
			// Prevent adding a shader if it already has one
			@:privateAccess if(c._filters != null) {
				var shouldSkip = false;
				for(filter in c._filters) {
					if(filter is ShaderFilter) {
						var filter:ShaderFilter = cast filter;
						if(filter.shader is CustomShader) {
							var shader:CustomShader = cast filter.shader;

							if(shader.path == blurShader.path) {
								shouldSkip = true;
								break;
							}
						}
					}
				}
				if(shouldSkip)
					continue;
			}
			camShaders.push(c);
			c.addShader(blurShader);
		}

		camera = warnCam = new FlxCamera();
		warnCam.bgColor = 0;
		warnCam.alpha = 0;
		warnCam.zoom = 0.1;
		FlxG.cameras.add(warnCam, false);


		var spr = new UISliceSprite(0, 0, CoolUtil.maxInt(560, 30 + (170 * buttons.length)), bHeight, 'editors/ui/${isError ? "normal" : "grayscale"}-popup');

		var sprIcon:FlxSprite = new FlxSprite(spr.x + 18, spr.y + 28 + 26).loadGraphic(Paths.image('editors/warnings/${isError ? "error" : "warning"}'));
		sprIcon.scale.set(1.4, 1.4);
		sprIcon.updateHitbox();

		messageSpr = new UIText(0,0, spr.bWidth - 100 - (26 * 2), message);
		spr.bHeight = Std.int(bHeight + Math.abs(Math.min(sprIcon.height-messageSpr.height, 0)));

		spr.x = (FlxG.width - spr.bWidth) / 2;
		spr.y = (FlxG.height - spr.bHeight) / 2;
		spr.color = isError ? 0xFFFF0000 : 0xFFFFFF00;
		add(spr);

		if(title != null) {
			add(titleSpr = new UIText(spr.x + 25, spr.y, spr.bWidth - 50, title, 15, -1));
			titleSpr.y = spr.y + ((30 - titleSpr.height) / 2);
		}

		var sprIcon:FlxSprite = new FlxSprite(spr.x + 18, spr.y + 28 + 26).loadGraphic(Paths.image('editors/warnings/${isError ? "error" : "warning"}'));
		sprIcon.scale.set(1.4, 1.4);
		sprIcon.updateHitbox();
		sprIcon.antialiasing = true;
		add(sprIcon);

		messageSpr.x = sprIcon.x + 70 + 16 + 20;
		messageSpr.y = sprIcon.y;
		add(messageSpr);

		if (wantsInput) {
			var boxY = spr.y + spr.bHeight - (36 + 16) - 56;
			// UITextBox brings its own caret, selection and system text input; it just
			// needs the focus flag, which also flips window.textInputEnabled on
			inputBox = new UITextBox(spr.x + 100, boxY, "", Std.int(spr.bWidth - 200), 36);
			inputBox.focused = true;
			add(inputBox);
		}

		var xPos = (FlxG.width - (30 + (170 * buttons.length))) / 2;
		for(k=>b in buttons) {
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

	public override function destroy() {
		super.destroy();
		for(e in camShaders)
			e.removeShader(blurShader);

		FlxTween.cancelTweensOf(warnCam);
		FlxG.cameras.remove(warnCam);

		// the field switched system text input on when it took focus; leaving it on would
		// feed every later keystroke into a text field nobody can see
		if (inputBox != null) {
			inputBox.focused = false;
			FlxG.stage.window.textInputEnabled = false;
		}
	}

	/**
	 * @param wantsInput Adds a native text field above the buttons; read it back with
	 *                   `inputValue()`. The dialog never acts on the text itself - the
	 *                   caller decides what it means, since the same field serves a
	 *                   password and, later, any other value a dialog has to ask for.
	 */
	public function new(title:String, message:String, buttons:Array<WarningButton>, ?isError:Bool = true, ?wantsInput:Bool = false) {
		super();
		this.title = title;
		this.message = message;
		this.buttons = buttons;
		this.isError = isError;
		this.wantsInput = wantsInput;
	}
}

typedef WarningButton = {
	var label:String;
	var ?color:Int;
	var onClick:UIWarningSubstate->Void;
}