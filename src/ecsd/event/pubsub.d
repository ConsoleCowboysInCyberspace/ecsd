///
module ecsd.event.pubsub;

import ecsd.event: isEvent;

/++
	Register the given function to be called whenever an event of the corresponding type is
	`publish`ed.
	
	Params:
		priority = dispatch order of event handlers, descending (larger priorities execute first)
+/
void subscribe(Event)(void delegate(ref Event) fn, int priority = 0)
if(isEvent!Event)
{
	import std.algorithm: sort;
	alias evs = storage!Event;
	evs ~= EventHandler!Event(fn, priority);
	evs.sort!"a.priority > b.priority";
}

/// ditto
void subscribe(Event)(void function(ref Event) fn, int priority = 0)
if(isEvent!Event)
{
	import std.functional: toDelegate;
	subscribe(fn.toDelegate, priority);
}

/++
	Immediately dispatches the given event, passing it to all registered subscribers.
+/
void publish(Event)(auto ref Event ev)
if(isEvent!Event)
{
	foreach(handler; storage!Event)
		handler.fn(ev);
}

/// ditto
void publish(Event)()
if(isEvent!Event)
{
	publish(Event.init);
}

/// Attribute applied to functions that should be discovered by `registerSubscribers`.
struct EventSubscriber
{
	int priority = 0;
}

/++
	Generates a module constructor that will automatically subscribe all top-level functions (in
	that module) marked with `EventSubscriber`.
	
	Examples:
	---
	mixin registerSubscribers;
	
	@EventSubscriber
	private void subscriber1(ref Event ev) {}
	
	@EventSubscriber(-100)
	private void subscriber2(ref Event ev) {}
	---
+/
mixin template registerSubscribers(string _targetModule = __MODULE__)
{
	static this()
	{
		import std.traits;
		import std.meta;
		import ecsd.event.pubsub;
		
		alias mod = mixin(_targetModule);
		static foreach(symbol; getSymbolsByUDA!(mod, EventSubscriber))
		{{
			enum symbolName = fullyQualifiedName!symbol;
			static assert(
				isFunction!symbol,
				"EventSubscriber attribute is restricted to function declarations, " ~
				"but appears on " ~ symbolName
			);
			alias attrs = getUDAs!(symbol, EventSubscriber);
			static assert(
				attrs.length == 1,
				"Duplicate EventSubscriber attribute on " ~ symbolName
			);
			
			EventSubscriber inst;
			static if(!is(attrs[0]))
				inst = attrs[0];
			subscribe(&symbol, inst.priority);
		}}
	}
}

private:

struct EventHandler(Event)
{
	void delegate(ref Event) fn;
	int priority = 0;
}

template storage(Event)
{
	EventHandler!Event[] storage;
}

version(unittest):

struct TestEvent
{
	int x = -1;
}

unittest
{
	bool calledf1, calledf2;
	void f1(ref TestEvent)
	{
		assert(!calledf1);
		assert(calledf2);
		calledf1 = true;
	}
	void f2(ref TestEvent ev)
	{
		assert(!calledf1);
		assert(!calledf2);
		calledf2 = true;
		assert(ev.x == -1 || ev.x == 1);
		ev.x = 2;
	}
	subscribe(&f1);
	subscribe(&f2, 1);
	
	static struct Bar {}
	static void f3(ref Bar) { assert(false); }
	subscribe(&f3);
	
	TestEvent ev = { 1 };
	publish(ev);
	assert(calledf1);
	assert(calledf2);
	assert(calledf1Toplevel);
	assert(calledf2Toplevel);
	assert(ev.x == 2);
	calledf1 = calledf2 = false;
	calledf1Toplevel = calledf2Toplevel = false;
	
	publish(TestEvent());
	assert(calledf1);
	assert(calledf2);
	assert(calledf1Toplevel);
	assert(calledf2Toplevel);
	calledf1 = calledf2 = false;
	calledf1Toplevel = calledf2Toplevel = false;
	
	publish!TestEvent;
	assert(calledf1);
	assert(calledf2);
	assert(calledf1Toplevel);
	assert(calledf2Toplevel);
}

bool calledf1Toplevel, calledf2Toplevel;

@EventSubscriber
void toplevelF1(ref TestEvent)
{
	assert(!calledf1Toplevel);
	assert(calledf2Toplevel);
	calledf1Toplevel = true;
}

@EventSubscriber(1)
void toplevelF2(ref TestEvent ev)
{
	assert(!calledf1Toplevel);
	assert(!calledf2Toplevel);
	calledf2Toplevel = true;
}

mixin registerSubscribers;
