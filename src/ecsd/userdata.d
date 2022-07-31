///
module ecsd.userdata;

import ecsd.entity: EntityID;
import ecsd.universe;

/++
	Set/get arbitrary data on a `Universe`.
	
	Allows passing user-defined data between game code via (often readily available) universes.
	Each universe may have only up to one value of any given type; but of course a `T[]` can be set
	instead, or each value can be disambiguated with a `std.typecons.Typedef`.
+/
void setUserdata(T)(Universe uni, T datum)
{
	alias data = storage!T;
	if(data.length <= uni.id)
		data.length = uni.id + 1;
	data[uni.id] = datum;
}

/// ditto
T getUserdata(T)(Universe uni)
{
	alias data = storage!T;
	if(data.length <= uni.id)
		return T.init;
	return data[uni.id];
}

// TODO: it would be nice to clear storage when a universe is freed, but could be (too) expensive
// (would have to store a list of functions, one for each T)

private template storage(T)
{
	T[] storage;
}

unittest
{
	auto uni = allocUniverse;
	scope(exit) freeUniverse(uni);
	
	static struct Foo
	{
		int x;
	}
	
	assert(uni.getUserdata!Foo == Foo.init);
	uni.setUserdata(Foo(42));
	assert(uni.getUserdata!Foo == Foo(42));
}
