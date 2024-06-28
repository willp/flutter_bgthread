# flutter_bgthread
Run app logic code entirely in a background Isolate (thread) and provide state management actions and streams for flutter widgets

# Purpose
Move app logic code into a background thread, while also providing an RPC-like method of invoking methods in that background thread to retrieve state, and support streaming state snapshots from background thread's methods to the parent for use in StreamBuilder wrappers for UI updates.  This will enable CPU-isolation _by default_ between the UI thread and app logic.  As well, the background thread may spread out compute-heavy tasks onto more cores using `compute()`, or another instance of `BgThread`, raw `Isolate.run`, or even other Isolate pool management libraries, all without impacting the main UI thread, helping to avoid jank _by default_.

I'm still pretty new to Dart and Flutter, but when I bumped up against the need for state management in my first app, as well as pondering how I could most efficiently use multiple cores, it seemed like the _limitations_ of passing data between Isolates aligned elegantly with the ephemeral nature of UI Widgets that need state data to render themselves (aka "at build time").  I didn't like the expansive and opinionated impact of the various state management libraries currently (2024 Q2) available, so I chose to write my own, using only the built-in Dart standard libraries and the flutter library.  The code _initially_ had no dependency on Flutter at all, until I needed to support plugin imports, which required the flutter dependency (to pass the rootIsolateToken from parent to child thread.)

# Production Ready?  No.
Currently this is not production ready.  I'm still working out its API, testing it and trying to find any edge cases. I don't think it has any memory (reference) leaks, but I haven't exhaustively tested it.

Don't use this in production yet.  I'll update this README when I think it's good enough for me, but as always: be careful with introducing dependencies into your code.

# Original Inspiration: agents by G. Clarke
I was inspired by the Agents package, https://github.com/gaaclarke/agents by G. Clarke.  I've followed a nearly identical method for wrapping closures to communicate from parent to child thread, but I did *not* follow the Actor model at all.  Instead, this package follows a simpler OOP model where a single instance of a class is wrapped by the background thread (aka Isolate).

# Interesting features
## Separate Memory Means Separate Memory
Because the background Isolate/thread has its own private memory space for _everything_, it's impossible to accidentally create a data coupling _outside_ of the BgThread API for communicating between parent and child threads.  It's sometimes a little hard to remember that even though the child thread has a _copy_ of everything from the parent, none of its changes _affect_ the parent's memory.  I'm still working out how to best make it more obvious for debugging, since it's perfectly valid code to have a child modifying mutable state that originated from the parent.
## Exceptions are Propagated Back to the Parent
All exceptions thrown by wrapped methods in a background thread are caught, and both the exception object (of any type) and the StackTrace are propagated up from child to parent, where it is effectively *rethrown* by using `Error.throwWithStackTrace(error, stackTrace)` so the error surfaces at the call-site in the parent thread, rather than being reported through a back-channel.  This differs _significantly_ from the agents library and other isolate wrapping libraries.

# Design Goals
* Avoid external dependencies as much as possible
* Keep client (parent) code simple but still flexible (wrapping closures)
* Be efficient and take the shortest path for data flows
* Give myself a fun problem to solve!  :-)

# To Do List
* Add example program
* Expand test suite to explore more edge-cases
* Attempt to track memory references in profiler mode to ensure no memory/reference leaks under all conditions (normal and exceptional)
* Reconsider the API in the Threadlike abstract class
* Add more helper methods to Threadlike to make it easier to extend for real use
* Document everything
* Measure performance improvements using async vs. BgThread instances (not a "fair" benchmark, but a practical comparison for migration)
* Determine necessary type flavors for Dart's reference reassignment to avoid copying data from child to parent (how to measure this?)
* Consider wrapping or extending StreamBuilder to simplify the case for caching last results
* Think about how to use it without statics in the target class.
* Probably a bunch more after I get more experience with using this code in my first app. :-)
* Finally... prepare the library to publish to pub.dev

  

  
  
