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
	
	package static dispatch(string hookName, Component, Args...)(Component* inst, auto ref Args args)
	{
		import core.lifetime: forward;
		import std.format;
		import std.traits;
		
		ComponentHooks dummy; // static reference, etc. yield functions, not delegates -_-
		alias HookFn = typeof(mixin("&dummy.onComponent", hookName));
		
		static if(__traits(compiles, { HookFn fn = mixin("&inst.onComponent", hookName); }))
		{
			HookFn fn = mixin("&(inst.onComponent", hookName, ")");
			fn(forward!args);
		}
		else static if(__traits(hasMember, Component, "onComponent" ~ hookName))
			static assert(false,
				"%s.onComponent%s does not match the expected signature (`%s`) and will not be called".format(
					Component.stringof,
					hookName,
					"%s onComponent%s(%s)".format(
						ReturnType!HookFn.stringof,
						hookName,
						Parameters!HookFn.stringof[1 .. $ - 1],
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
