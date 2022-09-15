///
module ecsd.event.pubsub;

import std.algorithm;
import std.functional: toDelegate;
import std.typecons: Flag;

import ecsd.event: isEvent;

/++
	Register the given function to be called whenever an event of the corresponding type is
	`publish`ed.
	
	Params:
	priority = dispatch order of event handlers, descending (larger priorities execute first)
	
	Returns: the `delegate` that has been stored for use by `publish`. This can be used to reliably
	`unsubscribe` the given function.
	
	Bugs:
	Passing struct methods will lead to dangling pointers and undefined behavior upon `publish`ing,
	unless such structs have been (stably) heap allocated (e.g. with `new`, or in a dynamic array
	that is never resized, etc.)
+/
void delegate(ref Event) subscribe(Event)(void delegate(ref Event) fn, int priority = 0)
if(isEvent!Event)
{
	alias evs = storage!Event;
	evs ~= EventHandler!Event(fn, priority);
	evs.sort!"a.priority > b.priority";
	return fn;
}

/// ditto
void delegate(ref Event) subscribe(Event)(void function(ref Event) fn, int priority = 0)
if(isEvent!Event)
{
	return subscribe(fn.toDelegate, priority);
}

/// Return type for transient subscribers. See `subscribeTransient`.
alias Unsubscribe = Flag!"Unsubscribe";

/++
	A version of `subscribe` accepting subscribers which may request an unsubscribe simply via
	return value, avoiding having to cache somewhere the returned delegate.
+/
void delegate(ref Event) subscribeTransient(Event)(Unsubscribe delegate(ref Event) fn, int priority = 0)
{
	// FIXME: investigate whether this can be optimized, even if only taking pressure off the array
	// of non-transients with another array; std.algrithm.merge can be used to recombine them
	void delegate(ref Event) subscriber;
	subscriber = subscribe((ref Event ev) {
		if(fn(ev) == Unsubscribe.yes)
			unsubscribe(subscriber);
	}, priority);
	return subscriber;
}

/// ditto
void delegate(ref Event) subscribeTransient(Event)(Unsubscribe function(ref Event) fn, int priority = 0)
{
	return subscribeTransient(fn.toDelegate, priority);
}

/++
	A `subscribeTransient` optimized for subscribers which wish to receive only a fixed number of
	events before unsubscribing.
	
	Params:
	numEvents = number of events to process before unsubscribing, clamped to a minimum of 1
+/
void delegate(ref Event) subscribeCounting(Event)(void delegate(ref Event) fn, size_t numEvents, int priority = 0)
{
	size_t eventsProcessed;
	void delegate(ref Event) subscriber;
	subscriber = subscribe((ref Event ev) {
		fn(ev);
		if(++eventsProcessed >= numEvents)
			unsubscribe(subscriber);
	}, priority);
	return subscriber;
}

/// ditto
void delegate(ref Event) subscribeCounting(Event)(void function(ref Event) fn, size_t numEvents, int priority = 0)
{
	return subscribeCounting(fn.toDelegate, numEvents, priority);
}

/++
	Removes the given function from the list of subscribers. Does nothing if the given
	function/delegate has already been unsubscribed, or hadn't been subscribed at all.
	
	Bugs:
	When unsubscribing closures, you $(B must) pass the return value of `subscribe` or this function
	will do nothing. This is because the context pointer for closures will be different every call
	to its enclosing function, even with the same arguments.
+/
void unsubscribe(Event)(void delegate(ref Event) fn)
if(isEvent!Event)
{
	alias evs = storage!Event;
	size_t index = evs.countUntil!(eh => eh.fn == fn);
	if(index == -1) return;
	evs = evs.remove(index);
}

/// ditto
void unsubscribe(Event)(void function(ref Event) fn)
if(isEvent!Event)
{
	unsubscribe(fn.toDelegate);
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
	Generates a module constructor (and destructor) that will automatically subscribe (and later
	unsubscribe) all top-level functions in the module marked with `EventSubscriber`.
	
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
	void delegate()[] _ecsd_registerSubscribers_unsubHooks;
	static this()
	{
		import std.traits;
		import std.meta;
		import ecsd.event.pubsub;
		
		mixin("import mod = ", _targetModule, ";");
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
			auto fn = subscribe(&symbol, inst.priority);
			_ecsd_registerSubscribers_unsubHooks ~= { unsubscribe(fn); };
		}}
	}
	
	static ~this()
	{
		foreach(fn; _ecsd_registerSubscribers_unsubHooks)
			fn();
		_ecsd_registerSubscribers_unsubHooks.length = 0;
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
	auto degF1 = subscribe(&f1);
	auto degF2 = subscribe(&f2, 1);
	
	bool calledTrans1, calledTrans2;
	subscribeTransient((ref TestEvent _) {
		assert(calledf1);
		assert(calledf2);
		calledTrans1 = true;
		return Unsubscribe.yes;
	}, -1);
	subscribeCounting((ref TestEvent _) {
		assert(calledf1);
		assert(calledf2);
		assert(calledTrans1);
		calledTrans2 = true;
	}, 1, -2);
	
	static struct Bar {}
	static void f3(ref Bar) { assert(false); }
	subscribe(&f3); // @suppress(dscanner.unused_result)
	
	TestEvent ev = { 1 };
	publish(ev);
	assert(calledf1);
	assert(calledf2);
	assert(calledTrans1);
	assert(calledTrans2);
	assert(calledf1Toplevel);
	assert(calledf2Toplevel);
	assert(ev.x == 2);
	
	static assert(__traits(compiles, { publish(TestEvent()); }));
	static assert(__traits(compiles, { publish!TestEvent; }));
	
	calledf1 = calledf2 = false;
	calledTrans1 = calledTrans2 = false;
	calledf1Toplevel = calledf2Toplevel = false;
	ev.x = 1;
	unsubscribe(degF1);
	unsubscribe(degF2);
	unsubscribe(&toplevelF1);
	unsubscribe(&toplevelF2);
	publish(ev);
	assert(!calledf1);
	assert(!calledf2);
	assert(!calledTrans1);
	assert(!calledTrans2);
	assert(!calledf1Toplevel);
	assert(!calledf2Toplevel);
	assert(ev.x == 1);
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
