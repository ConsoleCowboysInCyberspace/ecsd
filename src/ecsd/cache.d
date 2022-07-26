///
module ecsd.cache;

import core.time;
import std.algorithm;
import std.array;
import std.conv;
import std.meta;
import std.string;
import std.traits;
import std.typecons;

import ecsd.entity;
import ecsd.storage;
import ecsd.universe;

/// Controls whether `ComponentCache.refresh` ignores timestamps.
alias ForceRefresh = Flag!"ForceRefresh";

/// Return value of `ComponentCache.refresh`.
alias DidRefresh = Flag!"DidRefresh";

/++
	A cache of entities which have all (or some) of the given components, and pointers to those
	components.
	
	If a component type is specified as a pointer, that component type is considered optional.
	Entities which do not have such a component will still be included, with a null pointer cached
	in their `Set`.
	
	Examples:
	------
	auto physicsBodies = new ComponentCache!(Transform, RigidBody, KinematicController*)(universe);
	physicsBodies.refresh();
	foreach(ent, ref transform, ref rigidBody, controllerPtr; physicsBodies)
	{
		if(controllerPtr !is null)
			rigidBody.velocity += controllerPtr.acceleration;
		transform.position += rigidBody.velocity;
	}
	------
	
	------
	auto quads = new ComponentCache!(Transform, QuadRender)(universe);
	quads.refresh();
	// may iterate directly on the list of pointer sets
	foreach(ent; quads)
	{
		auto rect = Rect(ent.transform.pos, ent.quadRender.size);
		fillRect(rect);
	}
	------
+/
class ComponentCache(Raw...)
{
	private alias nullable = staticMap!(isPointer, Raw);
	private alias Components = staticMap!(targetOf, Raw);
	
	static assert(
		is(Components == NoDuplicates!Components),
		"Types in a ComponentCache must not be duplicated"
	);
	static assert(
		is(Components == staticMap!(targetOf, Components)),
		"Types in a ComponentCache must not contain pointers to pointers"
	);
	static assert(
		is(Components == staticMap!(Unqual, Components)),
		"Types in a ComponentCache must not have qualifiers"
	);
	static assert(allSatisfy!(isComponent, Components)); // error given by isComponent
	
	/++
		A set of pointers to each of the given component types, for a single entity.
		
		The name of each field is derived from the name of the component type.
		E.g. `Transform` => `transform`, `RenderComponent` => `render`.
	+/
	static struct Set
	{
		static foreach(i, Ptr; staticMap!(pointerOf, Raw))
			mixin("Ptr ", componentIdentifier!(Components[i]), ";");
		EntityID id; // The id of the entity which owns these components.
		alias id this;
	}
	
	private Universe universe;
	private Appender!(Set[]) _entities;
	private MonoTime lastRefreshed = MonoTime.zero;
	private staticMap!(Storage, Components) storages;
	
	/// Constructor. Entities will be queried from the given universe.
	this(Universe uni)
	{
		universe = uni;
		
		static foreach(i, T; Components)
			storages[i] = uni.getStorage!T;
	}
	
	/// Returns whether this cache is outdated, and needs to be `refresh`ed.
	bool stale() const
	{
		if(universe.lastAnyInvalidated < lastRefreshed)
			return false;
		
		static auto types = typeids!Components;
		return types
			.map!(ti => universe.getInvalidationTimestamp(ti) >= lastRefreshed)
			.any
		;
	}
	
	/++
		Refreshes list of entities and component pointers in this cache.
		
		This method $(B must) be called (every iteration of the game loop) before using the cache.
		
		Returns: whether a refresh was actually performed. This can be used in user code to elide
		work that needs to happen when the cache is invalidated, e.g. sorting `entities`.
	+/
	DidRefresh refresh(ForceRefresh forceRefresh = ForceRefresh.no)
	{
		if(forceRefresh != ForceRefresh.yes && !stale)
			return DidRefresh.no;
		lastRefreshed = MonoTime.currTime;
		
		_entities.clear;
		outer: foreach(ent; universe)
		{
			Set set;
			set.id = ent.id;
			static foreach(i; 0 .. storages.length)
			{{
				if(storages[i].has(ent))
					set.tupleof[i] = storages[i].get(ent);
				else static if(!nullable[i])
					continue outer;
			}}
			_entities.put(set);
		}
		
		return DidRefresh.yes;
	}
	
	/// Returns all currently cached `Set`s of pointers.
	inout(Set[]) entities() inout
	{
		return _entities.data[];
	}
	
	/// Iterate over this cache, taking each entity's entire pointer `Set`.
	int opApply(scope int delegate(Set) dg)
	{
		foreach(set; entities)
			if(auto res = dg(set) != 0)
				return res;
		return 0;
	}
	
	/++
		Iterate over this cache, taking each cached pointer as a separate loop variable.
		
		$(B Note:) for each $(I required) component the loop variable must be taken by ref, otherwise
		any component mutations will be upon a copy within the loop.
	+/
	int opApply(scope componentsDelegate!(int, Raw) dg)
	{
		enum string derefs = componentDerefs!(typeof(this));
		foreach(set; entities)
		{
			mixin("auto res = dg(Entity(set.id, universe), ", derefs, ");");
			if(res != 0)
				return res;
		}
		return 0;
	}
}

unittest
{
	static struct C1 {}
	static struct C2 {}
	
	auto uni = allocUniverse();
	scope(exit) freeUniverse(uni);
	uni.registerComponent!C1;
	uni.registerComponent!C2;
	
	auto e1 = Entity(uni.allocEntity, uni);
	e1.add!C1;
	
	auto e2 = Entity(uni.allocEntity, uni);
	e2.add!C2;
	
	alias idSort = (l, r) => l.id < r.id;
	alias entityIDs = (cache) => cache
		.entities
		.map!"a.id"
		.array
		.sort!idSort
	;
	
	struct Invalid { ~this() {} }
	static assert(!__traits(compiles, { ComponentCache!int x; }));
	static assert(!__traits(compiles, { ComponentCache!Invalid x; }));
	static assert(!__traits(compiles, { ComponentCache!(C1, C1) x; }));
	static assert(!__traits(compiles, { ComponentCache!(const C1) x; }));
	static assert(!__traits(compiles, { ComponentCache!(C1**) x; }));
	
	auto cache1 = new ComponentCache!C1(uni);
	cache1.refresh;
	assert(entityIDs(cache1).equal([e1.id]));
	
	auto e3 = Entity(uni.allocEntity, uni);
	assert(!cache1.stale);
	assert(cache1.refresh == DidRefresh.no);
	e3.add!C1;
	assert(cache1.stale);
	assert(cache1.refresh == DidRefresh.yes);
	e3.free;
	
	auto cache2 = new ComponentCache!C2(uni);
	cache2.refresh;
	assert(entityIDs(cache2).equal([e2.id]));
	
	auto cache3 = new ComponentCache!(C1*, C2*)(uni);
	cache3.refresh;
	assert(entityIDs(cache3).equal([e1.id, e2.id].sort!idSort));
}

private:

alias id(alias x) = x;
alias seq(xs...) = xs;

string componentIdentifier(Component)()
{
	const ident = __traits(identifier, Component).chomp("Component");
	return ident[0 .. 1].toLower ~ ident[1 .. $];
}

template pointerOf(T)
{
	static if(isPointer!T)
		alias pointerOf = T;
	else
		alias pointerOf = T*;
}

template targetOf(T)
{
	static if(isPointer!T)
		alias targetOf = PointerTarget!T;
	else
		alias targetOf = T;
}

template componentsDelegate(Ret, Components...)
{
	string inner()
	{
		auto res = "Ret delegate(Entity";
		static foreach(i, T; Components)
		{
			res ~= ", ";
			static if(!isPointer!T)
				res ~= "ref ";
			res ~= "Components[" ~ i.to!string ~ "]";
		}
		return res ~ ")";
	}
	
	alias componentsDelegate = mixin(inner());
}

string componentDerefs(Cache: ComponentCache!Components, Components...)()
{
	string res;
	static foreach(i, T; Components)
	{
		static if(i > 0)
			res ~= ", ";
		static if(!Cache.nullable[i])
			res ~= "*";
		res ~= "set.tupleof[" ~ i.to!string ~ "]";
	}
	return res;
}

TypeInfo[] typeids(Components...)()
{
	typeof(return) result;
	static foreach(T; Components)
		result ~= typeid(T);
	return result;
}
