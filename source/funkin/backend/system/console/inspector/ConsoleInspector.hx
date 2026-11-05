package funkin.backend.system.console.inspector;

//WIP

import openfl.Lib;
import flixel.FlxState;
import flixel.group.FlxSpriteGroup;
import funkin.backend.scripting.HScript;
import funkin.backend.scripting.ScriptPack;
import funkin.game.Stage;

#if IMGUI_ENABLED
import lime.tools.imgui.ImGuiFlags;
import lime.tools.imgui.ImGuiTypes;
import lime.tools.imgui.ImGuiPtr;
#end
#if foxlite
import foxlite.FoxScene;
import foxlite.group.FoxTypedGroup;
import foxlite.group.FoxObjectGroup;
import foxlite.FoxBasic;
import foxlite.FoxObject;
import foxlite.FoxModel;
#end

using funkin.backend.utils.ImGuiUtil;

typedef InspectorObject = {
	var obj:Dynamic;
	var name:String;
	var type:String;
	var members:Array<InspectorObject>;
	var memberIndex:Int;
	var ?groupParent:InspectorObject;
	var ?uid:Int;
	var ?nodeID:String;
	var ?label:String;
}

class ConsoleInspector {

	var hscript:ConsoleHscript;
	var cachedInstanceFields:Map<String, Array<String>> = [];
	public function new(hscript:ConsoleHscript) {
		this.hscript = hscript;
	}

	#if IMGUI_ENABLED
	var selectedObject:Dynamic = null;
	var selectedObjectData:InspectorObject = null;
	var selectedObjectValidThisFrame:Bool = false;
	var justChangedObject:Bool = false;

	var objectProperties:InspectorObjectProperties = new InspectorObjectProperties();
	var gizmo:InspectorGizmo = new InspectorGizmo();
	#if foxlite
	var gizmo3D:InspectorGizmo3D = new InspectorGizmo3D();
	#end

	var currentStateObjects:Array<InspectorObject> = [];
	var nextObjectUID:Int = 0;

	/**
	 * Seconds between two rebuilds of the object tree.
	 *
	 * updateObjects() walks every state and every member list to notice objects that were
	 * added or removed, and the tree is drawn from that. Doing it on every frame is what
	 * made an open inspector cost a slice of the frame rate: the lists almost never change
	 * between two frames, and a big state (a running PlayState) has hundreds of members.
	 * The window itself is still drawn every frame, so it stays responsive; at 10 Hz a
	 * newly spawned object shows up long before the eye gets there.
	 */
	public var refreshInterval:Float = 1 / 10;
	private var __sinceRefresh:Float = 1;
	/** True on the frame the tree was rebuilt; the tree walk uses it to refresh groups. */
	private var treeRefreshed:Bool = false;
	/** The state the tree was last built for; a switch invalidates every node in it. */
	private var lastInspectedState:FlxState = null;

	function updateObjects() {
		var states:Array<FlxState> = [FlxG.state];
		var stateToCheck:FlxState = FlxG.state;
		while(stateToCheck.subState != null) {
			states.push(stateToCheck.subState);
			stateToCheck = stateToCheck.subState;
		}
		
		if (currentStateObjects.length > states.length) {
			currentStateObjects.resize(states.length);
		}
		for (index => state in states) {
			if (currentStateObjects[index] == null || currentStateObjects[index].obj != state) {

				var packageName = hscript.getFieldTypeName(state);
				if (!cachedInstanceFields.exists(packageName)) {
					cachedInstanceFields.set(packageName, Type.getInstanceFields(Type.getClass(state)));
				}
				var packageSplit = packageName.split(".");
				var stateName = packageSplit[packageSplit.length-1];
				var uid = nextObjectUID++;

				currentStateObjects[index] = {
					obj: state,
					name: stateName,
					type: packageName,
					memberIndex: index,
					members: [],
					uid: uid,
					nodeID: "##inspector" + uid,
					label: stateName + " (" + packageName + ")"
				};
			}
		}

		for (inspectorObject in currentStateObjects) {
			updateObjectMembers(inspectorObject);
		}
	}

	inline function isMemberGroup(obj:Dynamic):Bool {
		return obj is FlxTypedGroup || obj is FlxTypedSpriteGroup #if foxlite || obj is FoxScene || obj is FoxTypedGroup || obj is FoxObjectGroup #end;
	}

	function getMemberObjects(obj:Dynamic):Null<Array<Dynamic>> {
		#if foxlite
		if (obj is FoxScene) return obj.foxGroup != null ? obj.foxGroup.members : null;
		#end
		return obj.members;
	}

	function updateObjectMembers(inspectorObject:InspectorObject, fromGroup:Bool = false) {
		var objMembers:Array<Dynamic> = getMemberObjects(inspectorObject.obj);
		if (objMembers == null) {
			return;
		}

		var cached = inspectorObject.members;

		if (cached.length == objMembers.length) {
			var unchanged = true;
			for (i in 0...cached.length) {
				if (cached[i].obj != objMembers[i]) { unchanged = false; break; }
			}
			if (unchanged) return;
		}

		var cachedByObject = new Map<Dynamic, InspectorObject>();
		for (member in cached) if (member.obj != null && !cachedByObject.exists(member.obj)) cachedByObject.set(member.obj, member);

		var newList:Array<InspectorObject> = [];
		for (i in 0...objMembers.length) {
			var member:Dynamic = objMembers[i];
			var memberData = member != null ? cachedByObject.get(member) : null;
			if (memberData != null) {
				cachedByObject.remove(member);
			} else {
				var memberPackage = hscript.getFieldTypeName(member);
				var memberPackageSplit = memberPackage != null ? memberPackage.split(".") : null;
				var memberType = memberPackageSplit != null ? memberPackageSplit[memberPackageSplit.length-1] : "Null";
				var memberName:String = fromGroup ? inspectorObject.name + ".members[" + i + "]" : figureOutObjectName(inspectorObject.type, inspectorObject.obj, member);
				var uid = nextObjectUID++;
				memberData = {
					obj: member,
					name: memberName,
					type: memberType,
					memberIndex: i,
					members: [],
					groupParent: fromGroup ? inspectorObject : null,
					uid: uid,
					nodeID: "##inspector" + uid,
					label: memberName + " (" + memberType + ")"
				};
			}
			memberData.memberIndex = i;
			newList.push(memberData);
		}
		inspectorObject.members = newList;
	}

	public function displayUI() {

		// nothing to inspect while the game is between states (or already tearing down)
		if (FlxG.state == null) return;

		// A state switch destroys everything the tree points at, cameras included, so a
		// selection from the old state has to go with it: drawing its gizmo asked the object
		// for a screen position and hit a null camera (leaving a playtest, closing the game).
		var state = FlxG.state;
		if (state != lastInspectedState) {
			lastInspectedState = state;
			selectedObject = null;
			selectedObjectData = null;
			__sinceRefresh = refreshInterval; // rebuild now, not up to a tick later
		}

		treeRefreshed = (__sinceRefresh += FlxG.rawElapsed) >= refreshInterval;
		if (treeRefreshed) __sinceRefresh = 0;

		if (!FlxG.mouse.visible) FlxG.mouse.visible = true; //TODO: rework this, temp force on
		
		ImGui.setNextWindowPos(ImGuiUtil.getWindowSpaceX(), ImGuiUtil.getWindowSpaceY(), ImGuiCond.FirstUseEver);
		ImGui.setNextWindowSize(300, Lib.application.window.height, ImGuiCond.FirstUseEver);
		if (ImGui.begin("Inspector")) {
			// keeps the panel above the game window once it is dragged out of it
			ImGuiUtil.pinCurrentWindowOnTop();
			// inside the begin on purpose: a collapsed Inspector draws no rows, so there is
			// nothing to rebuild either - walking the tree for a panel rolled up to its title
			// bar was pure cost
			if (treeRefreshed) updateObjects();
			ImGui.separatorText("Tools/Gizmo");
			ImGui.indent();
			if (ImGui.selectable("None (Q)", gizmo.gizmoMode == -1)) gizmo.gizmoMode = -1;
			if (ImGui.selectable("Position (W)", gizmo.gizmoMode == 0)) gizmo.gizmoMode = 0;
			if (ImGui.selectable("Rotation (E)", gizmo.gizmoMode == 1)) gizmo.gizmoMode = 1;
			if (ImGui.selectable("Scale (R)", gizmo.gizmoMode == 2)) gizmo.gizmoMode = 2;
			ImGui.unindent();
			ImGui.separatorText("States");
			for (member in currentStateObjects) {
				var flags = ImGuiTreeNodeFlags.DefaultOpen;
				if (member.obj == selectedObject) flags |= ImGuiTreeNodeFlags.Selected;
				if (ImGui.treeNodeEx(member.nodeID, flags, member.label)) {
					if (ImGui.isItemClicked()) {
						selectObject(member.obj);
					}
					if (member.members.length > 0) {
						generateTreeForMembers(member);
					}
					ImGui.treePop();
				}
			}
			//ImGui.separatorText("Cameras");
		}
		ImGui.end();

		if (selectedObject != null) {
			selectedObjectValidThisFrame = false;
			for (member in currentStateObjects) {
				if (member.obj == selectedObject) {
					selectedObjectValidThisFrame = true;
					selectedObjectData = member;
					break;
				}
				checkForSelectedObjectThisFrame(member);
			}

			if (selectedObjectValidThisFrame) {
				objectProperties.show(selectedObjectData, justChangedObject);
				if (selectedObject is FlxObject) {
					gizmo.show(selectedObjectData, cast selectedObject, justChangedObject);
				} #if foxlite else if (selectedObject is FoxObject) {
					gizmo3D.show(selectedObjectData, cast selectedObject, justChangedObject);
				}
				#end
				justChangedObject = false;
			} else {
				selectedObject = null;
				selectedObjectData = null;
			}
		}
	}

	function checkForSelectedObjectThisFrame(object:InspectorObject) {
		if (selectedObjectValidThisFrame) return;
		for (member in object.members) {
			if (member.obj == selectedObject) {
				selectedObjectValidThisFrame = true;
				selectedObjectData = member;
				return;
			}
			if (member.members.length > 0) {
				checkForSelectedObjectThisFrame(member);
			}
		}
	}

	function generateTreeForMembers(object:InspectorObject) {
		for (member in object.members) {
			var valid = member.obj != null;
			var isGroup:Bool = valid && isMemberGroup(member.obj);
			var groupMembers:Null<Array<Dynamic>> = isGroup ? getMemberObjects(member.obj) : null;
			var flags = ImGuiTreeNodeFlags.None;
			if (member.members.length == 0 && (groupMembers == null || groupMembers.length == 0)) flags |= ImGuiTreeNodeFlags.Leaf;
			if (valid && member.obj == selectedObject) flags |= ImGuiTreeNodeFlags.Selected;
			if (ImGui.treeNodeEx(member.nodeID, flags, valid ? member.label : member.name)) {
				if (valid && ImGui.isItemClicked()) {
					selectObject(member.obj);
				}
				if (isGroup) {
					// same 10 Hz budget as the roots: an open group of notes is the most
					// expensive list in the tree, and it is rebuilt for nothing on most frames
					if (treeRefreshed) updateObjectMembers(member, true);
					if (member.members.length > 0) {
						generateTreeForMembers(member);
					}
				}
				ImGui.treePop();
			}
		}
	}

	function selectObject(obj:Dynamic) {
		if (selectedObject != obj) {
			selectedObject = obj;
			justChangedObject = true;
		}
	}

	public function figureOutObjectName(packageName:String, parent:Dynamic, object:FlxBasic) {
		if (object == null) return "Null Member";
		if (!cachedInstanceFields.exists(packageName)) {
			cachedInstanceFields.set(packageName, Type.getInstanceFields(Type.getClass(parent)));
		}
		var instanceFields:Array<String> = cachedInstanceFields.get(packageName);
		var uselessFields:Array<String> = [];
		for (field in instanceFields) {
			if (field == "members") {
				uselessFields.push(field);
				continue;
			}

			var fieldObj:Dynamic = Reflect.getProperty(parent, field);
			if (fieldObj != null) {
				if (fieldObj is FlxBasic) {
					if (object == fieldObj) {
						return field;
					} else if (fieldObj is Stage) {
						var stage:Stage = cast fieldObj;
						for (name => stageObj in stage.stageSprites) {
							if (object == stageObj) return name;
						}
						for (name => posObj in stage.characterPoses) {
							if (object == posObj) return name;
						}
					}
				} else if (fieldObj is Array) {
					var arr:Array<Dynamic> = cast fieldObj;
					var firstMember = arr[0];
					if (firstMember != null && firstMember is FlxBasic) {
						for (index => arrayObj in arr) {
							if (object == arrayObj) {
								return field + "[" + index + "]";
							}
						}
					}
				} else {
					uselessFields.push(field);
				}
			}
		}
		if (uselessFields.length > 0) { //these aren't flxbasic
			for (field in uselessFields) {
				instanceFields.remove(field);
			}
			cachedInstanceFields.set(packageName, instanceFields);
		}

		var scriptPacksToCheck:Array<ScriptPack> = [];
		if (parent is MusicBeatState) {
			var state:MusicBeatState = cast parent;
			scriptPacksToCheck.push(state.stateScripts);
		}
		if (parent is PlayState) {
			var playstate:PlayState = cast parent;
			for (strumLineIndex => strumLine in playstate.strumLines.members) {
				for (charIndex => char in strumLine.characters) {
					if (object == char) {
						return "strumLines[" + strumLineIndex + "].characters[" + charIndex + "] (" + char.curCharacter + ")";
					}
				}
			}
			scriptPacksToCheck.push(playstate.scripts);
		}
		
		for (pack in scriptPacksToCheck) {
			
			for (script in pack.scripts) {
				if (script is HScript) {
					var hscript:HScript = cast script;
					if (hscript.interp == null) continue;
					for (name => scriptObj in hscript.interp.variables) {
						if (scriptObj is FlxBasic) {
							if (scriptObj == object) return name;
						} else if (scriptObj is Array) {
							var arr:Array<Dynamic> = cast scriptObj;
							var firstMember = arr[0];
							if (firstMember != null && firstMember is FlxBasic) {
								for (index => arrayObj in arr) {
									if (object == arrayObj) {
										return name + "[" + index + "]";
									}
								}
							}
						}
					}
				}
			}
		}

		return "Unknown" + object.ID;
	}
	#end
}
