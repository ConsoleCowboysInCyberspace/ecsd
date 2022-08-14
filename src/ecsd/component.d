///
module ecsd.component;

/++
	Description of methods that components may optionally implement, to be notified of component
	lifecycle events. Not to be used as an actual interface, this is defined purely for documentation.
	
	Examples:
	------
	struct SomeComponent
	{
		Entity owner;
		void onComponentAdded(Universe, EntityID owner)
		{
			this.owner = Entity(owner);
		}
	}
	------
+/
final interface ComponentHooks
{
	import vibe.data.bson;
	
	import ecsd.universe: Universe;
	import ecsd.entity;
	
	/++
		Hook called just after this component is added to `owner`.
	+/
	void onComponentAdded(Universe uni, EntityID owner);
	
	/++
		Hook called just before this component is removed from `owner`.
	+/
	void onComponentRemoved(Universe uni, EntityID owner);
	
	/++
		Hook called just after this component has been serialized to BSON.
		
		Allows massaging this component's BSON before it is written to the array of component BSONs.
	+/
	void onComponentSerialized(Universe uni, EntityID owner, ref Bson destBson);
	
	/++
		Hook called just after this component has been deserialized from BSON.
		
		Note that when deserializing into a new entity `onComponentAdded` will be called before this.
	+/
	void onComponentDeserialized(Universe uni, EntityID owner, Bson bson);
	
	package static dispatch(string hookNamePartial, Component, Args...)(Component* inst, auto ref Args args)
	{
		import core.lifetime: forward;
		import std.algorithm: canFind;
		import std.format: format;
		import std.traits: Parameters, ReturnType, fullyQualifiedName;
		
		enum hookName = "onComponent%s".format(hookNamePartial);
		ComponentHooks dummy; // static reference, etc. yield functions, not delegates -_-
		alias HookFn = typeof(mixin("&dummy.", hookName));
		
		static if(__traits(compiles, { HookFn fn = mixin("&inst.", hookName); }))
		{
			HookFn fn = mixin("&(inst.", hookName, ")");
			fn(forward!args);
		}
		// hasMember can be fooled by opDispatch / alias this
		else static if((cast(string[])[__traits(allMembers, Component)]).canFind(hookName))
			static assert(false,
				"%s.%s does not match the expected signature (`%s`) and would not be called".format(
					fullyQualifiedName!Component,
					hookName,
					"%s %s%s".format(
						ReturnType!HookFn.stringof,
						hookName,
						Parameters!HookFn.stringof,
					),
				)
			);
	}
}

package template isComponent(T)
{
	enum errPreamble = "Component type " ~ T.stringof ~ " must ";
	static assert(
		is(T == struct),
		errPreamble ~ "be a struct"
	);
	static assert(
		__traits(isPOD, T),
		errPreamble ~ "not have copy ctors/destructors"
	);
	static assert(
		__traits(compiles, { T x; }),
		errPreamble ~ "have a default constructor"
	);
	static assert(
		__traits(compiles, { T x; x = T.init; }),
		errPreamble ~ "be reassignable"
	);
	
	enum isComponent = true;
}
