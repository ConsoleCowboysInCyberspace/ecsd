module ecsd.cache;

import std.algorithm;
import std.array;
import std.conv;
import std.meta;
import std.string;
import std.traits;

import ecsd.entity;
import ecsd.universe;

class ComponentCache(Components...)
{
	static struct Set
	{
		static foreach(i, Ptr; staticMap!(pointerOf, Components))
			mixin("Ptr ", componentIdentifier!(targetOf!(Components[i])), ";");
		EntityID id;
		alias id this;
	}
	
	private alias nullable = staticMap!(isPointer, Components);
	private Universe universe;
	private Appender!(Set[]) _entities;
	
	this(Universe uni)
	{
		universe = uni;
	}
	
	void refresh()
	{
		_entities.clear;
		outer: foreach(ent; universe)
		{
			Set set;
			set.id = ent.id;
			static foreach(i, T; Components)
			{{
				alias Component = targetOf!T;
				if(ent.has!Component)
					set.tupleof[i] = &ent.get!Component();
				else static if(!nullable[i])
					continue outer;
			}}
			_entities.put(set);
		}
	}
	
	Set[] entities()
	{
		return _entities.data[];
	}
	
	int opApply(scope int delegate(Set) dg)
	{
		foreach(set; entities)
			if(auto res = dg(set) != 0)
				return res;
		return 0;
	}
	
	int opApply(scope componentsDelegate!(int, Components) dg)
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
	
	auto cache1 = new ComponentCache!C1(uni);
	cache1.refresh;
	assert(entityIDs(cache1).equal([e1.id]));
	
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
