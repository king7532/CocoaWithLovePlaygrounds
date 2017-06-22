//
//  CwlCancellable.swift
//  CwlUtils
//
//  Created by Matt Gallagher on 2017/04/18.
//  Copyright © 2017 Matt Gallagher ( http://cocoawithlove.com ). All rights reserved.
//
//  Permission to use, copy, modify, and/or distribute this software for any
//  purpose with or without fee is hereby granted, provided that the above
//  copyright notice and this permission notice appear in all copies.
//
//  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
//  SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
//  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

import Foundation

/// This protocol exists to provide lifetime to asynchronous an ongoing tasks. Typically, this protocol is implemented by a `class` (so that releasing the type releases the underlying resource) but it may also be implemented by a `struct` which itself contains a `class` whose lifetime controls the underlying resource.
///
/// The pattern offered by this protocol is a rejection of patterns where an asynchronous or ongoing task is created without returning any lifetime object. In my opinion, such lifetime-less patterns are problematic since they fail to tie the lifetime of the asynchronous task to the context where the result is required. This failure to tie task to result context requires:
///	* vigilance to remember to check for the context on completion
///   * knowledge of the context to check if the task is still relevant
///   * overuse of resources by cancelled or unwanted tasks that continue to completion before checking if they're still needed
/// all of which are bad. Far better to return a lifetime object for *all* asynchronous or ongoing tasks.
public protocol Cancellable: class {
	/// Immediately cancel
	func cancel()
}

/// A simple class for aggregating a number of Cancellable instances into a single Cancellable.
public class ArrayOfCancellables: Cancellable {
	public init(cancellables: [Cancellable]) {
		self.cancellables = cancellables
	}
	private let cancellables: [Cancellable]
	public func cancel() { cancellables.forEach { $0.cancel() } }
}

//
//  CwlCollection.swift
//  CwlUtils
//
//  Created by Matt Gallagher on 2015/02/03.
//  Copyright © 2015 Matt Gallagher ( http://cocoawithlove.com ). All rights reserved.
//
//  Permission to use, copy, modify, and/or distribute this software for any
//  purpose with or without fee is hereby granted, provided that the above
//  copyright notice and this permission notice appear in all copies.
//
//  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
//  SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
//  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

import Foundation

extension Collection {
	/// Returns the element at the specified index iff it is within bounds, otherwise nil.
	public func at(_ i: Index) -> Iterator.Element? {
		return (i >= startIndex && i < endIndex) ? self[i] : nil
	}
}

extension RangeReplaceableCollection {
	public static func +=(s: inout Self, e: Iterator.Element) {
		s.append(e)
	}
}
//
//  CwlDebugContext.swift
//  CwlUtils
//
//  Created by Matt Gallagher on 2016/05/15.
//  Copyright © 2016 Matt Gallagher ( http://cocoawithlove.com ). All rights reserved.
//
//  Permission to use, copy, modify, and/or distribute this software for any
//  purpose with or without fee is hereby granted, provided that the above
//  copyright notice and this permission notice appear in all copies.
//
//  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
//  SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
//  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

import Foundation

/// A set of identifiers for the different queues in the DebugContextCoordinator
///
/// - unspecified: used when a initial DebugContextThread is not specified on startup (not used otherwise)
/// - main: used by `main` and `mainAsync` contexts
/// - `default`: used for a concurrent queues and for timers on direct
/// - custom: any custom queue
public enum DebugContextThread: Hashable {
	case unspecified
	case main
	case `default`
	case custom(String)

	/// Convenience test to determine if an `Exec` instance wraps a `DebugContext` identifying `self` as its `thread`.
	public func matches(_ exec: Exec) -> Bool {
		if case .custom(let debugContext as DebugContext) = exec, debugContext.thread ==
			self {
			return true
		} else {
			return false
		}
	}
	
	/// Implementation of Hashable property
	public var hashValue: Int {
		switch self {
		case .unspecified: return Int(0).hashValue
		case .main: return Int(1).hashValue
		case .default: return Int(2).hashValue
		case .custom(let s): return Int(3).hashValue ^ s.hashValue
		}
	}
}

/// Basic equality tests for `DebugContextThread`
///
/// - Parameters:
///   - left: a `DebugContextThread`
///   - right: another `DebugContextThread`
/// - Returns: true if they are equal value
public func ==(left: DebugContextThread, right: DebugContextThread) -> Bool {
	switch (left, right) {
	case (.custom(let l), .custom(let r)) where l == r: return true
	case (.unspecified, .unspecified): return true
	case (.main, .main): return true
	case (.default, .default): return true
	default: return false
	}
}

/// Simulates running a series of blocks across threads over time by instead queuing the blocks and running them serially in time priority order, incrementing the `currentTime` to reflect the time priority of the last run block.
/// The result is a deterministic simulation of time scheduled blocks, which is otherwise subject to thread scheduling non-determinism.
public class DebugContextCoordinator {
	// We use DispatchTime for time calculations but time 0 is treated as a special value ("now") so we start at time = 1, internally, and subtract 1 when returning through the public `currentTime` accessor.
	var internalTime: UInt64 = 1
	var queues: Dictionary<DebugContextThread, DebugContextQueue> = [:]
	var stopRequested: Bool = false
	
	/// Returns the current simulated time in nanoseconds
	public var currentTime: UInt64 { return internalTime - 1 }
	
	/// Returns the last runs simulated thread
	fileprivate (set) public var currentThread: DebugContextThread
	
	/// Constructs an empty instance
	public init() {
		currentThread = .unspecified
	}
	
	/// Implementation mimicking Exec.direct but returning an Exec.custom(DebugContext)
	public var direct: Exec {
		return .custom(DebugContext(type: .immediate, thread: .default, coordinator: self))
	}
	
	/// Implementation mimicking Exec.main but returning an Exec.custom(DebugContext)
	public var main: Exec {
		return .custom(DebugContext(type: .conditionallyAsync(true), thread: .main, coordinator: self))
	}
	
	/// Implementation mimicking Exec.mainAsync but returning an Exec.custom(DebugContext)
	public var mainAsync: Exec {
		return .custom(DebugContext(type: .serialAsync, thread: .main, coordinator: self))
	}
	
	/// Implementation mimicking Exec.default but returning an Exec.custom(DebugContext)
	public var `default`: Exec {
		return .custom(DebugContext(type: .concurrentAsync, thread: .default, coordinator: self))
	}
	
	/// Implementation mimicking Exec.syncQueue but returning an Exec.custom(DebugContext)
	public var syncQueue: Exec {
		let uuidString = CFUUIDCreateString(nil, CFUUIDCreate(nil)) as String? ?? ""
		return .custom(DebugContext(type: .mutex, thread: .custom(uuidString), coordinator: self))
	}
	
	/// Implementation mimicking Exec.asyncQueue but returning an Exec.custom(DebugContext)
	public var asyncQueue: Exec {
		let uuidString = CFUUIDCreateString(nil, CFUUIDCreate(nil)) as String? ?? ""
		return .custom(DebugContext(type: .serialAsync, thread: .custom(uuidString), coordinator: self))
	}
	
	/// Performs all scheduled actions in a serial loop.
	///
	/// - parameter stoppingAfter: If nil, loop will continue until `stop` invoked or until no actions remain. If non-nil, loop will abort after an action matching Cancellable is completed.
	public func runScheduledTasks(stoppingAfter: Cancellable? = nil) {
		stopRequested = false
		currentThread = .unspecified
		while !stopRequested, let nextTimer = runNextTask() {
			if stoppingAfter != nil, stoppingAfter === nextTimer {
				break
			}
		}
		if stopRequested {
			queues = [:]
		}
	}
	
	/// Performs all scheduled actions in a serial loop.
	///
	/// - parameter stoppingAfter: If nil, loop will continue until `stop` invoked or until no actions remain. If non-nil, loop will abort after an action matching Cancellable is completed.
	public func runScheduledTasks(untilTime: UInt64) {
		stopRequested = false
		currentThread = .unspecified
		while !stopRequested, let (threadIndex, time) = nextTask(), time <= untilTime {
			_ = runTask(threadIndex: threadIndex, time: time)
		}
		if stopRequested {
			queues = [:]
		}
	}
	
	/// Causes `runScheduledTasks` to exit as soon as possible, if it is running.
	public func stop() {
		stopRequested = true
	}
	
	/// Discards all scheduled actions and resets time to 1. Useful if the `DebugContextCoordinator` is to be reused.
	public func reset() {
		internalTime = 1
		queues = [:]
	}
	
	func getOrCreateQueue(forName: DebugContextThread) -> DebugContextQueue {
		if let t = queues[forName] {
			return t
		}
		let t = DebugContextQueue()
		queues[forName] = t
		return t
	}
	
	// Fundamental method for scheduling a block on the coordinator for later invocation.
	func schedule(block: @escaping () -> Void, thread: DebugContextThread, timeInterval interval: Int64, repeats: Bool) -> DebugContextTimer {
		let i = interval > 0 ? UInt64(interval) : 0 as UInt64
		let debugContextTimer = DebugContextTimer(thread: thread, rescheduleInterval: repeats ? i : nil, coordinator: self)
		getOrCreateQueue(forName: thread).schedule(pending: PendingBlock(time: internalTime + i, timer: debugContextTimer, block: block))
		return debugContextTimer
	}
	
	// Remove a block from the scheduler
	func cancelTimer(_ toCancel: DebugContextTimer) {
		if let t = queues[toCancel.thread]  {
			t.cancelTimer(toCancel)
		}
	}
	
	func nextTask() -> (DebugContextThread, UInt64)? {
		var lowestTime = UInt64.max
		var selectedIndex = DebugContextThread.unspecified
		
		// We want a deterministic ordering, so we'll iterate over the queues by key sorted by hashValue
		for index in queues.keys.sorted(by: { (left, right) -> Bool in left.hashValue < right.hashValue }) {
			if let t = queues[index], t.nextTime < lowestTime {
				selectedIndex = index
				lowestTime = t.nextTime
			}
		}
		if lowestTime == UInt64.max {
			return nil
		}
		
		return (selectedIndex, lowestTime)
	}
	
	func runTask(threadIndex: DebugContextThread, time: UInt64) -> DebugContextTimer? {
		(currentThread, internalTime) = (threadIndex, time)
		return queues[threadIndex]?.popAndInvokeNext()
	}
	
	// Run the next event. If nil is returned, no further events remain. If
	func runNextTask() -> DebugContextTimer? {
		if let (threadIndex, time) = nextTask() {
			return runTask(threadIndex: threadIndex, time: time)
		}
		return nil
	}
}

// This structure is used to represent scheduled actions in the DebugContextCoordinator.
struct PendingBlock {
	let time: UInt64
	weak var timer: DebugContextTimer?
	let block: () -> Void
	
	init(time: UInt64, timer: DebugContextTimer?, block: @escaping () -> Void) {
		self.time = time
		self.timer = timer
		self.block = block
	}
	
	var nextInterval: PendingBlock? {
		if let t = timer, let i = t.rescheduleInterval, t.coordinator != nil {
			return PendingBlock(time: time + i, timer: t, block: block)
		}
		return nil
	}
}

// A `DebugContextQueue` is just an array of `PendingBlock`, sorted by scheduled time. It represents the blocks queued for execution on a thread in the `DebugContextCoordinator`.
class DebugContextQueue {
	var pendingBlocks: Array<PendingBlock> = []
	
	init() {
	}
	
	// Insert a block in scheduled order
	func schedule(pending: PendingBlock) {
		var insertionIndex = 0
		while pendingBlocks.count > insertionIndex && pendingBlocks[insertionIndex].time <= pending.time {
			insertionIndex += 1
		}
		
		pendingBlocks.insert(pending, at: insertionIndex)
	}

	// Remove a block
	func cancelTimer(_ toCancel: DebugContextTimer) {
		if let index = pendingBlocks.index(where: { tuple -> Bool in tuple.timer === toCancel }) {
			pendingBlocks.remove(at: index)
		}
	}
	
	// Return the earliest scheduled time in the queue
	var nextTime: UInt64 {
		return pendingBlocks.first?.time ?? UInt64.max
	}
	
	// Runs the next block in the queue
	func popAndInvokeNext() -> DebugContextTimer? {
		if let next = pendingBlocks.first {
			pendingBlocks.remove(at: 0)
			next.block()
			if let nextInterval = next.nextInterval {
				schedule(pending: nextInterval)
			}
			
			// We ran a block, don't return nil (next.timer may return nil if it has self-cancelled)
			return next.timer ?? DebugContextTimer()
		}
		
		return nil
	}
}

/// An implementation of `ExecutionContext` that schedules its non-immediate actions on a `DebugContextCoordinator`. This type is constructed using the `Exec` mimicking properties and functions on `DebugContextCoordinator`.
public struct DebugContext: ExecutionContext {
	let underlyingType: ExecutionType
	let thread: DebugContextThread
	weak var coordinator: DebugContextCoordinator?

	init(type: ExecutionType, thread: DebugContextThread, coordinator: DebugContextCoordinator) {
		self.underlyingType = type
		self.thread = thread
		self.coordinator = coordinator
	}
	
	/// A description about how functions will be invoked on an execution context.
	public var type: ExecutionType {
		switch underlyingType {
		case .conditionallyAsync:
			if let ctn = coordinator?.currentThread, thread == ctn {
				return .conditionallyAsync(false)
			}
			fallthrough
		default: return underlyingType
		}
	}
	
	/// Run `execute` normally on the execution context
	public func invoke(_ execute: @escaping () -> Void) {
		guard let c = coordinator else { return }
		switch type {
		case .mutex:
			let previousThread = c.currentThread
			c.currentThread = thread
			execute()
			c.currentThread = previousThread
		case .immediate, .conditionallyAsync(false): execute()
		default: invokeAsync(execute)
		}
	}
	
	/// Run `execute` asynchronously on the execution context
	public func invokeAsync(_ execute: @escaping () -> Void) {
		_ = coordinator?.schedule(block: execute, thread: thread, timeInterval: 0, repeats: false)
	}
	
	/// Run `execute` on the execution context but don't return from this function until the provided function is complete.
	public func invokeAndWait(_ execute: @escaping () -> Void) {
		guard let c = coordinator else { return }
		switch type {
		case .mutex:
			let previousThread = c.currentThread
			c.currentThread = thread
			execute()
			c.currentThread = previousThread
		case .immediate, .conditionallyAsync(false):
			execute()
		default:
			c.runScheduledTasks(stoppingAfter: c.schedule(block: execute, thread: thread, timeInterval: 0, repeats: false))
		}
	}

	/// Run `execute` on the execution context after `interval` (plus `leeway`) unless the returned `Cancellable` is cancelled or released before running occurs.
	public func singleTimer(interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping () -> Void) -> Cancellable {
		guard let c = coordinator else { return DebugContextTimer() }
		return c.schedule(block: handler, thread: thread, timeInterval: interval.toNanoseconds(), repeats: false)
	}

	/// Run `execute` on the execution context after `interval` (plus `leeway`), passing the `parameter` value as an argument, unless the returned `Cancellable` is cancelled or released before running occurs.
	public func singleTimer<T>(parameter: T, interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping (T) -> Void) -> Cancellable {
		guard let c = coordinator else { return DebugContextTimer() }
		return c.schedule(block: { handler(parameter) }, thread: thread, timeInterval: interval.toNanoseconds(), repeats: false)
	}
	
	/// Run `execute` on the execution context after `interval` (plus `leeway`), and again every `interval` (within a `leeway` margin of error) unless the returned `Cancellable` is cancelled or released before running occurs.
	public func periodicTimer(interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping () -> Void) -> Cancellable {
		guard let c = coordinator else { return DebugContextTimer() }
		return c.schedule(block: handler, thread: thread, timeInterval: interval.toNanoseconds(), repeats: true)
	}

	/// Run `execute` on the execution context after `interval` (plus `leeway`), passing the `parameter` value as an argument, and again every `interval` (within a `leeway` margin of error) unless the returned `Cancellable` is cancelled or released before running occurs.
	public func periodicTimer<T>(parameter: T, interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping (T) -> Void) -> Cancellable {
		guard let c = coordinator else { return DebugContextTimer() }
		return c.schedule(block: { handler(parameter) }, thread: thread, timeInterval: interval.toNanoseconds(), repeats: true)
	}
	
	/// Gets a timestamp representing the host uptime the in the current context
	public func timestamp() -> DispatchTime {
		guard let c = coordinator else { return DispatchTime.now() }
		return DispatchTime(uptimeNanoseconds: c.currentTime)
	}
}

// All actions scheduled with a `DebugContextCoordinator` are referenced by a DebugContextTimer (even those actions that are simply asynchronous invocations without a delay).
class DebugContextTimer: Cancellable {
	let thread: DebugContextThread
	let rescheduleInterval: UInt64?
	weak var coordinator: DebugContextCoordinator?
	
	init() {
		thread = .unspecified
		coordinator = nil
		rescheduleInterval = nil
	}
	
	init(thread: DebugContextThread, rescheduleInterval: UInt64?, coordinator: DebugContextCoordinator) {
		self.thread = thread
		self.coordinator = coordinator
		self.rescheduleInterval = rescheduleInterval
	}
	
	/// Cancellable implementation
	public func cancel() {
		coordinator?.cancelTimer(self)
		coordinator = nil
	}
	
	deinit {
		cancel()
	}
}
//
//  CwlDeferredWork.swift
//  CwlUtils
//
//  Created by Matt Gallagher on 5/10/2015.
//  Copyright © 2015 Matt Gallagher ( http://cocoawithlove.com ). All rights reserved.
//
//  Permission to use, copy, modify, and/or distribute this software for any
//  purpose with or without fee is hereby granted, provided that the above
//  copyright notice and this permission notice appear in all copies.
//
//  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
//  SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
//  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

// This type is designed for guarding against mutex re-entrancy by following two simple rules:
//
//  1. No user "work" (functions or closures) should be invoked inside a private mutex
//  2. No user supplied data should be released inside a private mutex
//
// To facilitate these requirements, any user "work" or data ownership should be handled inside `DeferredWork` blocks. These blocks allow this user code to be queued in the desired order but since the `runWork` function should only be called outside the mutex, these blocks run safely outside the mutex.
//
// This pattern has two associated risks:
//  1. If the deferred work calls back into the mutex, it must be able to ensure that it is still relevant (hasn't been superceded by an action that may have occurred between the end of the mutex and the performing of the `DeferredWork`. This may involve a token (inside the mutex, only the most recent token is accepted) or the mutex queueing further requests until the most recent `DeferredWork` completes.
//  2. The `runWork` must be manually invoked. Automtic invocation (e.g in the `deinit` of a lifetime managed `class` instance) would add heap allocation overhead and would also be easy to accidentally release at the wrong point (inside the mutex) causing erratic problems. Instead, the `runWork` is guarded with a `DEBUG`-only `OnDelete` check that ensures that the `runWork` has been correctly invoked by the time the `DeferredWork` falls out of scope.
public struct DeferredWork {
	enum PossibleWork {
	case none
	case single(() -> Void)
	case multiple(ContiguousArray<() -> Void>)
	}
	
	var work: PossibleWork

#if CHECK_DEFERRED_WORK
	let invokeCheck: OnDelete = { () -> OnDelete in
		var sourceStack = callStackReturnAddresses(skip: 2)
		return OnDelete {
			preconditionFailure("Failed to perform work deferred at location:\n" + symbolsForCallStack(addresses: sourceStack).joined(separator: "\n"))
		}
	}()
#endif

	public init() {
		work = .none
	}
	
	public init(initial: @escaping () -> Void) {
		work = .single(initial)
	}
	
	public mutating func append(_ other: DeferredWork) {
#if CHECK_DEFERRED_WORK
		precondition(invokeCheck.isValid && other.invokeCheck.isValid, "Work appended to an already cancelled/invoked DeferredWork")
		other.invokeCheck.invalidate()
#endif
		switch other.work {
		case .none: break
		case .single(let otherWork): self.append(otherWork)
		case .multiple(let otherWork):
			switch work {
			case .none: work = .multiple(otherWork)
			case .single(let existing):
				var newWork: ContiguousArray<() -> Void> = [existing]
				newWork.append(contentsOf: otherWork)
				work = .multiple(newWork)
			case .multiple(var existing):
				work = .none
				existing.append(contentsOf: otherWork)
				work = .multiple(existing)
			}
		}
	}
	
	public mutating func append(_ additionalWork: @escaping () -> Void) {
#if CHECK_DEFERRED_WORK
		precondition(invokeCheck.isValid, "Work appended to an already cancelled/invoked DeferredWork")
#endif
		switch work {
		case .none: work = .single(additionalWork)
		case .single(let existing): work = .multiple([existing, additionalWork])
		case .multiple(var existing):
			work = .none
			existing.append(additionalWork)
			work = .multiple(existing)
		}
	}
	
	public mutating func runWork() {
#if CHECK_DEFERRED_WORK
		precondition(invokeCheck.isValid, "Work run multiple times")
		invokeCheck.invalidate()
#endif
		switch work {
		case .none: break
		case .single(let w): w()
		case .multiple(let ws):
			for w in ws {
				w()
			}
		}
		work = .none
	}
}
//
//  CwlDeque.swift
//  CwlUtils
//
//  Created by Matt Gallagher on 2016/09/13.
//  Copyright © 2016 Matt Gallagher ( http://cocoawithlove.com ). All rights reserved.
//
//  Permission to use, copy, modify, and/or distribute this software for any
//  purpose with or without fee is hereby granted, provided that the above
//  copyright notice and this permission notice appear in all copies.
//
//  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
//  SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
//  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

import Foundation

let DequeOverAllocateFactor = 2
let DequeDownsizeTriggerFactor = 16
let DequeDefaultMinimumCapacity = 0

/// This is a basic "circular-buffer" style Double-Ended Queue.
public struct Deque<T>: RandomAccessCollection, RangeReplaceableCollection, ExpressibleByArrayLiteral, CustomDebugStringConvertible {
	public typealias Index = Int
	public typealias Indices = CountableRange<Int>
	public typealias Element = T
	
	var buffer: DequeBuffer<T>? = nil
	let minCapacity: Int
	
	/// Implementation of RangeReplaceableCollection function
	public init() {
		self.minCapacity = DequeDefaultMinimumCapacity
	}
	
	/// Allocate with a minimum capacity
	public init(minCapacity: Int) {
		self.minCapacity = minCapacity
	}
	
	/// Implementation of ExpressibleByArrayLiteral function
	public init(arrayLiteral: T...) {
		self.minCapacity = DequeDefaultMinimumCapacity
		replaceSubrange(0..<0, with: arrayLiteral)
	}
	
	/// Implementation of CustomDebugStringConvertible function
	public var debugDescription: String {
		var result = "\(type(of: self))(["
		var iterator = makeIterator()
		if let next = iterator.next() {
			debugPrint(next, terminator: "", to: &result)
			while let n = iterator.next() {
				result += ", "
				debugPrint(n, terminator: "", to: &result)
			}
		}
		result += "])"
		return result
	}
	
	public subscript(bounds: Range<Index>) -> RangeReplaceableRandomAccessSlice<Deque<T>> {
      return RangeReplaceableRandomAccessSlice<Deque<T>>(base: self, bounds: bounds)
	}

	/// Implementation of RandomAccessCollection function
	public subscript(_ at: Index) -> T {
		get {
			if let b = buffer {
				precondition(at < b.unsafeHeader.pointee.count)
				var offset = b.unsafeHeader.pointee.offset + at
				if offset >= b.unsafeHeader.pointee.capacity {
					offset -= b.unsafeHeader.pointee.capacity
				}
				return b.unsafeElements[offset]
			} else {
				preconditionFailure("Index beyond end of queue")
			}
		}
	}
	
	/// Implementation of Collection function
	public var startIndex: Index {
		return 0
	}
	
	/// Implementation of Collection function
	public var endIndex: Index {
		if let b = buffer {
			return b.unsafeHeader.pointee.count
		}
		
		return 0
	}
	
	/// Implementation of Collection function
	public var isEmpty: Bool {
      if let b = buffer {
         return b.unsafeHeader.pointee.count == 0
      }
      
      return true
	}
   
	/// Implementation of Collection function
	public var count: Int {
		return endIndex
	}
	
	/// Optimized implementation of RangeReplaceableCollection function
	public mutating func append(_ newElement: T) {
		if let b = buffer {
			if b.unsafeHeader.pointee.capacity >= b.unsafeHeader.pointee.count + 1 {
				var index = b.unsafeHeader.pointee.offset + b.unsafeHeader.pointee.count
				if index >= b.unsafeHeader.pointee.capacity {
					index -= b.unsafeHeader.pointee.capacity
				}
				b.unsafeElements.advanced(by: index).initialize(to: newElement)
				b.unsafeHeader.pointee.count += 1
				return
			}
		}
		
		let index = endIndex
		return replaceSubrange(index..<index, with: CollectionOfOne(newElement))
	}
	
	/// Optimized implementation of RangeReplaceableCollection function
	public mutating func insert(_ newElement: T, at: Int) {
		if let b = buffer {
			if at == 0, b.unsafeHeader.pointee.capacity >= b.unsafeHeader.pointee.count + 1 {
				var index = b.unsafeHeader.pointee.offset - 1
				if index < 0 {
					index += b.unsafeHeader.pointee.capacity
				}
				b.unsafeElements.advanced(by: index).initialize(to: newElement)
				b.unsafeHeader.pointee.count += 1
				b.unsafeHeader.pointee.offset = index
				return
			}
		}
		
		return replaceSubrange(at..<at, with: CollectionOfOne(newElement))
	}
	
	/// Optimized implementation of RangeReplaceableCollection function
	public mutating func remove(at: Int) {
		if let b = buffer {
			if at == b.unsafeHeader.pointee.count - 1 {
				b.unsafeHeader.pointee.count -= 1
				return
			} else if at == 0, b.unsafeHeader.pointee.count > 0 {
				b.unsafeHeader.pointee.offset += 1
				if b.unsafeHeader.pointee.offset >= b.unsafeHeader.pointee.capacity {
					b.unsafeHeader.pointee.offset -= b.unsafeHeader.pointee.capacity
				}
				b.unsafeHeader.pointee.count -= 1
				return
			}
		}
		
		return replaceSubrange(at...at, with: EmptyCollection())
	}
	
	/// Optimized implementation of RangeReplaceableCollection function
	public mutating func removeFirst() -> T {
		if let b = buffer {
			precondition(b.unsafeHeader.pointee.count > 0, "Index beyond bounds")
			let result = b.unsafeElements[b.unsafeHeader.pointee.offset]
			b.unsafeElements.advanced(by: b.unsafeHeader.pointee.offset).deinitialize()
			b.unsafeHeader.pointee.offset += 1
			if b.unsafeHeader.pointee.offset >= b.unsafeHeader.pointee.capacity {
				b.unsafeHeader.pointee.offset -= b.unsafeHeader.pointee.capacity
			}
			b.unsafeHeader.pointee.count -= 1
			return result
		}
		preconditionFailure("Index beyond bounds")
	}
	
	// Used when removing a range from the collection or deiniting self.
	fileprivate static func deinitialize(range: CountableRange<Int>, header: UnsafeMutablePointer<DequeHeader>, body: UnsafeMutablePointer<T>) {
		let splitRange = Deque.mapIndices(inRange: range, header: header)
		body.advanced(by: splitRange.low.startIndex).deinitialize(count: splitRange.low.count)
		body.advanced(by: splitRange.high.startIndex).deinitialize(count: splitRange.high.count)
	}
	
	// Move from an initialized to an uninitialized location, deinitializing the source.
	//
	// NOTE: the terms "preMapped" and "postMapped" are used. "preMapped" refer to the public indices exposed by this type (zero based, contiguous), and "postMapped" refers to internal offsets within the buffer (not necessarily zero based and may wrap around). This function will only handle a single, contiguous block of "postMapped" indices so the caller must ensure that this function is invoked separately for each contiguous block.
	fileprivate static func moveInitialize(preMappedSourceRange: CountableRange<Int>, postMappedDestinationRange: CountableRange<Int>, sourceHeader: UnsafeMutablePointer<DequeHeader>, sourceBody: UnsafeMutablePointer<T>, destinationBody: UnsafeMutablePointer<T>) {
		let sourceSplitRange = Deque.mapIndices(inRange: preMappedSourceRange, header: sourceHeader)
		
		assert(sourceSplitRange.low.startIndex >= 0 && (sourceSplitRange.low.startIndex < sourceHeader.pointee.capacity || sourceSplitRange.low.startIndex == sourceSplitRange.low.endIndex))
		assert(sourceSplitRange.low.endIndex >= 0 && sourceSplitRange.low.endIndex <= sourceHeader.pointee.capacity)
		
		assert(sourceSplitRange.high.startIndex >= 0 && (sourceSplitRange.high.startIndex < sourceHeader.pointee.capacity || sourceSplitRange.high.startIndex == sourceSplitRange.high.endIndex))
		assert(sourceSplitRange.high.endIndex >= 0 && sourceSplitRange.high.endIndex <= sourceHeader.pointee.capacity)
		
		destinationBody.advanced(by: postMappedDestinationRange.startIndex).moveInitialize(from: sourceBody.advanced(by: sourceSplitRange.low.startIndex), count: sourceSplitRange.low.count)
		destinationBody.advanced(by: postMappedDestinationRange.startIndex + sourceSplitRange.low.count).moveInitialize(from: sourceBody.advanced(by: sourceSplitRange.high.startIndex), count: sourceSplitRange.high.count)
	}
	
	// Copy from an initialized to an uninitialized location, leaving the source initialized.
	//
	// NOTE: the terms "preMapped" and "postMapped" are used. "preMapped" refer to the public indices exposed by this type (zero based, contiguous), and "postMapped" refers to internal offsets within the buffer (not necessarily zero based and may wrap around). This function will only handle a single, contiguous block of "postMapped" indices so the caller must ensure that this function is invoked separately for each contiguous block.
	fileprivate static func copyInitialize(preMappedSourceRange: CountableRange<Int>, postMappedDestinationRange: CountableRange<Int>, sourceHeader: UnsafeMutablePointer<DequeHeader>, sourceBody: UnsafeMutablePointer<T>, destinationBody: UnsafeMutablePointer<T>) {
		let sourceSplitRange = Deque.mapIndices(inRange: preMappedSourceRange, header: sourceHeader)
		
		assert(sourceSplitRange.low.startIndex >= 0 && (sourceSplitRange.low.startIndex < sourceHeader.pointee.capacity || sourceSplitRange.low.startIndex == sourceSplitRange.low.endIndex))
		assert(sourceSplitRange.low.endIndex >= 0 && sourceSplitRange.low.endIndex <= sourceHeader.pointee.capacity)
		
		assert(sourceSplitRange.high.startIndex >= 0 && (sourceSplitRange.high.startIndex < sourceHeader.pointee.capacity || sourceSplitRange.high.startIndex == sourceSplitRange.high.endIndex))
		assert(sourceSplitRange.high.endIndex >= 0 && sourceSplitRange.high.endIndex <= sourceHeader.pointee.capacity)
		
		destinationBody.advanced(by: postMappedDestinationRange.startIndex).initialize(from: sourceBody.advanced(by: sourceSplitRange.low.startIndex), count: sourceSplitRange.low.count)
		destinationBody.advanced(by: postMappedDestinationRange.startIndex + sourceSplitRange.low.count).initialize(from: sourceBody.advanced(by: sourceSplitRange.high.startIndex), count: sourceSplitRange.high.count)
	}
	
	// Translate from preMapped to postMapped indices.
	//
	// "preMapped" refer to the public indices exposed by this type (zero based, contiguous), and "postMapped" refers to internal offsets within the buffer (not necessarily zero based and may wrap around).
	//
	// Since "postMapped" indices are not necessarily contiguous, two separate, contiguous ranges are returned. Both `startIndex` and `endIndex` in the `high` range will equal the `endIndex` in the `low` range if the range specified by `inRange` is continuous after mapping.
	fileprivate static func mapIndices(inRange: CountableRange<Int>, header: UnsafeMutablePointer<DequeHeader>) -> (low: CountableRange<Int>, high: CountableRange<Int>) {
		let limit = header.pointee.capacity - header.pointee.offset
		if inRange.startIndex >= limit {
			return (low: (inRange.startIndex - limit)..<(inRange.endIndex - limit), high: (inRange.endIndex - limit)..<(inRange.endIndex - limit))
		} else if inRange.endIndex > limit {
			return (low: (inRange.startIndex + header.pointee.offset)..<header.pointee.capacity, high: 0..<(inRange.endIndex - limit))
		}
		return (low: (inRange.startIndex + header.pointee.offset)..<(inRange.endIndex + header.pointee.offset), high: (inRange.endIndex + header.pointee.offset)..<(inRange.endIndex + header.pointee.offset))
	}
	
	// Internal implementation of replaceSubrange<C>(_:with:) when no reallocation
	// of the underlying buffer is required
	private static func mutateWithoutReallocate<C>(info: DequeMutationInfo, elements newElements: C, header: UnsafeMutablePointer<DequeHeader>, body: UnsafeMutablePointer<T>) where C: Collection, C.Iterator.Element == T {
		if info.removed > 0 {
			Deque.deinitialize(range: info.start..<(info.start + info.removed), header: header, body: body)
		}
		
		if info.removed != info.inserted {
			if info.start < header.pointee.count - (info.start + info.removed) {
				let oldOffset = header.pointee.offset
				header.pointee.offset -= info.inserted - info.removed
				if header.pointee.offset < 0 {
					header.pointee.offset += header.pointee.capacity
				} else if header.pointee.offset >= header.pointee.capacity {
					header.pointee.offset -= header.pointee.capacity
				}
				let delta = oldOffset - header.pointee.offset
				if info.start != 0 {
					let destinationSplitIndices = Deque.mapIndices(inRange: 0..<info.start, header: header)
					let lowCount = destinationSplitIndices.low.count
					Deque.moveInitialize(preMappedSourceRange: delta..<(delta + lowCount), postMappedDestinationRange: destinationSplitIndices.low, sourceHeader: header, sourceBody: body, destinationBody: body)
					if lowCount != info.start {
						Deque.moveInitialize(preMappedSourceRange: (delta + lowCount)..<(info.start + delta), postMappedDestinationRange: destinationSplitIndices.high, sourceHeader: header, sourceBody: body, destinationBody: body)
					}
				}
			} else {
				if (info.start + info.removed) != header.pointee.count {
					let start = info.start + info.removed
					let end = header.pointee.count
					let destinationSplitIndices = Deque.mapIndices(inRange: (info.start + info.inserted)..<(end - info.removed + info.inserted), header: header)
					let lowCount = destinationSplitIndices.low.count
				
					Deque.moveInitialize(preMappedSourceRange: start..<end, postMappedDestinationRange: destinationSplitIndices.low, sourceHeader: header, sourceBody: body, destinationBody: body)
					if lowCount != end - start {
						Deque.moveInitialize(preMappedSourceRange: (start + lowCount)..<end, postMappedDestinationRange: destinationSplitIndices.high, sourceHeader: header, sourceBody: body, destinationBody: body)
					}
				}
			}
			header.pointee.count = header.pointee.count - info.removed + info.inserted
		}
		
		if info.inserted == 1, let e = newElements.first {
			if info.start >= header.pointee.capacity - header.pointee.offset {
				body.advanced(by: info.start - header.pointee.capacity + header.pointee.offset).initialize(to: e)
			} else {
				body.advanced(by: header.pointee.offset + info.start).initialize(to: e)
			}
		} else if info.inserted > 0 {
			let inserted = Deque.mapIndices(inRange: info.start..<(info.start + info.inserted), header: header)
			var iterator = newElements.makeIterator()
			for i in inserted.low {
				if let n = iterator.next() {
					body.advanced(by: i).initialize(to: n)
				}
			}
			for i in inserted.high {
				if let n = iterator.next() {
					body.advanced(by: i).initialize(to: n)
				}
			}
		}
	}
	
	// Internal implementation of replaceSubrange<C>(_:with:) when reallocation
	// of the underlying buffer is required. Can handle no previous buffer or
	// previous buffer too small or previous buffer too big or previous buffer
	// non-unique.
	private mutating func reallocateAndMutate<C>(info: DequeMutationInfo, elements newElements: C, header: UnsafeMutablePointer<DequeHeader>?, body: UnsafeMutablePointer<T>?, deletePrevious: Bool) where C: Collection, C.Iterator.Element == T {
		if info.newCount == 0 {
			// Let the regular deallocation handle the deinitialize
			buffer = nil
		} else {
			let newCapacity: Int
			let oldCapacity = header?.pointee.capacity ?? 0
			if info.newCount > oldCapacity || info.newCount <= oldCapacity / DequeDownsizeTriggerFactor {
				newCapacity = Swift.max(minCapacity, info.newCount * DequeOverAllocateFactor)
			} else {
				newCapacity = oldCapacity
			}
			
			let newBuffer = DequeBuffer<T>.create(capacity: newCapacity, count: info.newCount)
			if let headerPtr = header, let bodyPtr = body {
				if deletePrevious, info.removed > 0 {
					Deque.deinitialize(range: info.start..<(info.start + info.removed), header: headerPtr, body: bodyPtr)
				}
				
				let newBody = newBuffer.unsafeElements
				if info.start != 0 {
					if deletePrevious {
						Deque.moveInitialize(preMappedSourceRange: 0..<info.start, postMappedDestinationRange: 0..<info.start, sourceHeader: headerPtr, sourceBody: bodyPtr, destinationBody: newBody)
					} else {
						Deque.copyInitialize(preMappedSourceRange: 0..<info.start, postMappedDestinationRange: 0..<info.start, sourceHeader: headerPtr, sourceBody: bodyPtr, destinationBody: newBody)
					}
				}
				
				let oldCount = header?.pointee.count ?? 0
				if info.start + info.removed != oldCount {
					if deletePrevious {
						Deque.moveInitialize(preMappedSourceRange: (info.start + info.removed)..<oldCount, postMappedDestinationRange: (info.start + info.inserted)..<info.newCount, sourceHeader: headerPtr, sourceBody: bodyPtr, destinationBody: newBody)
					} else {
						Deque.copyInitialize(preMappedSourceRange: (info.start + info.removed)..<oldCount, postMappedDestinationRange: (info.start + info.inserted)..<info.newCount, sourceHeader: headerPtr, sourceBody: bodyPtr, destinationBody: newBody)
					}
				}
				
				// Make sure the old buffer doesn't deinitialize when it deallocates.
				if deletePrevious {
					headerPtr.pointee.count = 0
				}
			}
			
			if info.inserted > 0 {
				#if swift(>=3.1)
					let umbp = UnsafeMutableBufferPointer(start: newBuffer.unsafeElements.advanced(by: info.start), count: info.inserted)
					_ = umbp.initialize(from: newElements)
				#else
					// Insert the new subrange
					newBuffer.unsafeElements.advanced(by: info.start).initialize(from: newElements)
				#endif
			}
			
			buffer = newBuffer
		}
	}
	
	/// Implemetation of the RangeReplaceableCollection function. Internally
	/// implemented using either mutateWithoutReallocate or reallocateAndMutate.
	public mutating func replaceSubrange<C>(_ subrange: Range<Int>, with newElements: C) where C: Collection, C.Iterator.Element == T {
		precondition(subrange.lowerBound >= 0, "Subrange lowerBound is negative")
		
		if isKnownUniquelyReferenced(&buffer), let b = buffer {
			let (header, body) = (b.unsafeHeader, b.unsafeElements)
			let info = DequeMutationInfo(subrange: subrange, previousCount: header.pointee.count, insertedCount: numericCast(newElements.count))
			if info.newCount <= header.pointee.capacity && (info.newCount < minCapacity || info.newCount > header.pointee.capacity / DequeDownsizeTriggerFactor) {
				Deque.mutateWithoutReallocate(info: info, elements: newElements, header: header, body: body)
			} else {
				reallocateAndMutate(info: info, elements: newElements, header: header, body: body, deletePrevious: true)
			}
		} else if let b = buffer {
			let (header, body) = (b.unsafeHeader, b.unsafeElements)
			let info = DequeMutationInfo(subrange: subrange, previousCount: header.pointee.count, insertedCount: numericCast(newElements.count))
			reallocateAndMutate(info: info, elements: newElements, header: header, body: body, deletePrevious: false)
		} else {
			let info = DequeMutationInfo(subrange: subrange, previousCount: 0, insertedCount: numericCast(newElements.count))
			reallocateAndMutate(info: info, elements: newElements, header: nil, body: nil, deletePrevious: true)
		}
	}
}

// Internal state for the Deque
struct DequeHeader {
	var offset: Int
	var count: Int
	var capacity: Int
}

// Private type used to communicate parameters between replaceSubrange<C>(_:with:)
// and reallocateAndMutate or mutateWithoutReallocate
struct DequeMutationInfo {
	let start: Int
	let removed: Int
	let inserted: Int
	let newCount: Int
	
	init(subrange: Range<Int>, previousCount: Int, insertedCount: Int) {
		precondition(subrange.upperBound <= previousCount, "Subrange upperBound is out of range")
		
		self.start = subrange.lowerBound
		self.removed = subrange.count
		self.inserted = insertedCount
		self.newCount = previousCount - self.removed + self.inserted
	}
}

// An implementation of DequeBuffer using ManagedBufferPointer to allocate the
// storage and then using raw pointer offsets into self to access contents
// (avoiding the ManagedBufferPointer accessors which are a performance problem
// in Swift 3).
final class DequeBuffer<T> {
	typealias ValueType = T
	
	class func create(capacity: Int, count: Int) -> DequeBuffer<T> {
		let p = ManagedBufferPointer<DequeHeader, T>(bufferClass: self, minimumCapacity: capacity) { buffer, capacityFunction in
			DequeHeader(offset: 0, count: count, capacity: capacity)
		}
		
		let result = unsafeDowncast(p.buffer, to: DequeBuffer<T>.self)
		
		// We need to assert this in case some of our dirty assumptions stop being true
		assert(ManagedBufferPointer<DequeHeader, T>(unsafeBufferObject: result).withUnsafeMutablePointers { (header, body) in result.unsafeHeader == header && result.unsafeElements == body })
		
		return result
	}
	
	static var headerOffset: Int {
		return Int(roundUp(UInt(MemoryLayout<HeapObject>.size), toAlignment: MemoryLayout<DequeHeader>.alignment))
	}
	
	static var elementOffset: Int {
		return Int(roundUp(UInt(headerOffset) + UInt(MemoryLayout<DequeHeader>.size), toAlignment: MemoryLayout<T>.alignment))
	}
	
	var unsafeElements: UnsafeMutablePointer<T> {
		return Unmanaged<DequeBuffer<T>>.passUnretained(self).toOpaque().advanced(by: DequeBuffer<T>.elementOffset).assumingMemoryBound(to: T.self)
	}
	
	var unsafeHeader: UnsafeMutablePointer<DequeHeader> {
		return Unmanaged<DequeBuffer<T>>.passUnretained(self).toOpaque().advanced(by: DequeBuffer<T>.headerOffset).assumingMemoryBound(to: DequeHeader.self)
	}
	
	static func debugPrint(unsafeHeader: UnsafeMutablePointer<DequeHeader>, unsafeElements: UnsafeMutablePointer<T>) {
		print("Header: \(unsafeHeader.pointee)")
		print("Body: ", terminator: "")
		for i in 0..<unsafeHeader.pointee.capacity {
			print(unsafeElements[i], terminator: " ")
		}
		print()
	}
	
	deinit {
		let h = unsafeHeader
		if h.pointee.count > 0 {
			Deque<T>.deinitialize(range: 0..<h.pointee.count, header: h, body: unsafeElements)
		}
	}
}

// Private reimplementation of function with same name from stdlib/public/core/BuiltIn.swift
func roundUp(_ offset: UInt, toAlignment alignment: Int) -> UInt {
	let x = offset + UInt(bitPattern: alignment) &- 1
	return x & ~(UInt(bitPattern: alignment) &- 1)
}

// Private reimplementation of definition from stdlib/public/SwiftShims/HeapObject.h
struct HeapObject {
	let metadata: Int = 0
	let strongRefCount: UInt32 = 0
	let weakRefCount: UInt32 = 0
}
//
//  CwlDispatch.swift
//  CwlUtils
//
//  Created by Matt Gallagher on 2016/07/29.
//  Copyright © 2016 Matt Gallagher ( http://cocoawithlove.com ). All rights reserved.
//
//  Permission to use, copy, modify, and/or distribute this software for any
//  purpose with or without fee is hereby granted, provided that the above
//  copyright notice and this permission notice appear in all copies.
//
//  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
//  SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
//  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

import Foundation

public extension DispatchSource {
	// An overload of timer that immediately sets the handler and schedules the timer
	public class func singleTimer(interval: DispatchTimeInterval, leeway: DispatchTimeInterval = .nanoseconds(0), queue: DispatchQueue, handler: @escaping () -> Void) -> DispatchSourceTimer {
		let result = DispatchSource.makeTimerSource(queue: queue)
		result.setEventHandler(handler: handler)
		result.scheduleOneshot(deadline: DispatchTime.now() + interval, leeway: leeway)
		result.resume()
		return result
	}
	
	// An overload of timer that always uses the default global queue (because it is intended to enter the appropriate mutex as a separate step) and passes a user-supplied Int to the handler function to allow ignoring callbacks if cancelled or rescheduled before mutex acquisition.
	public class func singleTimer<T>(parameter: T, interval: DispatchTimeInterval, leeway: DispatchTimeInterval = .nanoseconds(0), queue: DispatchQueue = DispatchQueue.global(), handler: @escaping (T) -> Void) -> DispatchSourceTimer {
		let result = DispatchSource.makeTimerSource(queue: queue)
		result.scheduleOneshot(parameter: parameter, interval: interval, leeway: leeway, handler: handler)
		result.resume()
		return result
	}

	// An overload of timer that immediately sets the handler and schedules the timer
	public class func repeatingTimer(interval: DispatchTimeInterval, leeway: DispatchTimeInterval = .nanoseconds(0), queue: DispatchQueue = DispatchQueue.global(), handler: @escaping () -> Void) -> DispatchSourceTimer {
		let result = DispatchSource.makeTimerSource(queue: queue)
		result.setEventHandler(handler: handler)
		result.scheduleRepeating(deadline: DispatchTime.now() + interval, interval: interval, leeway: leeway)
		result.resume()
		return result
	}
	
	// An overload of timer that always uses the default global queue (because it is intended to enter the appropriate mutex as a separate step) and passes a user-supplied Int to the handler function to allow ignoring callbacks if cancelled or rescheduled before mutex acquisition.
	public class func repeatingTimer<T>(parameter: T, interval: DispatchTimeInterval, leeway: DispatchTimeInterval = .nanoseconds(0), queue: DispatchQueue = DispatchQueue.global(), handler: @escaping (T) -> Void) -> DispatchSourceTimer {
		let result = DispatchSource.makeTimerSource(queue: queue)
		result.scheduleRepeating(parameter: parameter, interval: interval, leeway: leeway, handler: handler)
		result.resume()
		return result
	}
}

public extension DispatchSourceTimer {
	// An overload of scheduleOneshot that updates the handler function with a new user-supplied parameter when it changes the expiry deadline
	public func scheduleOneshot<T>(parameter: T, interval: DispatchTimeInterval, leeway: DispatchTimeInterval = .nanoseconds(0), handler: @escaping (T) -> Void) {
		suspend()
		setEventHandler { handler(parameter) }
		scheduleOneshot(deadline: DispatchTime.now() + interval, leeway: leeway)
		resume()
	}
	
	// An overload of scheduleOneshot that updates the handler function with a new user-supplied parameter when it changes the expiry deadline
	public func scheduleRepeating<T>(parameter: T, interval: DispatchTimeInterval, leeway: DispatchTimeInterval = .nanoseconds(0), handler: @escaping (T) -> Void) {
		suspend()
		setEventHandler { handler(parameter) }
		scheduleRepeating(deadline: DispatchTime.now() + interval, interval: interval, leeway: leeway)
		resume()
	}
}

public extension DispatchTime {
	public func since(_ previous: DispatchTime) -> DispatchTimeInterval {
		return .nanoseconds(Int(uptimeNanoseconds - previous.uptimeNanoseconds))
	}
}

public extension DispatchTimeInterval {
	public static func fromSeconds(_ seconds: Double) -> DispatchTimeInterval {
		if MemoryLayout<Int>.size < 8 {
			return .milliseconds(Int(seconds * Double(NSEC_PER_SEC / NSEC_PER_MSEC)))
		} else {
			return .nanoseconds(Int(seconds * Double(NSEC_PER_SEC)))
		}
	}

	public func toSeconds() -> Double {
		switch self {
		case .seconds(let t): return Double(t)
		case .milliseconds(let t): return (1.0 / Double(NSEC_PER_MSEC)) * Double(t)
		case .microseconds(let t): return (1.0 / Double(NSEC_PER_USEC)) * Double(t)
		case .nanoseconds(let t): return (1.0 / Double(NSEC_PER_SEC)) * Double(t)
		}
	}

	public func toNanoseconds() -> Int64 {
		switch self {
		case .seconds(let t): return Int64(NSEC_PER_SEC) * Int64(t)
		case .milliseconds(let t): return Int64(NSEC_PER_MSEC) * Int64(t)
		case .microseconds(let t): return Int64(NSEC_PER_USEC) * Int64(t)
		case .nanoseconds(let t): return Int64(t)
		}
	}
}
//
//  CwlExec.swift
//  CwlUtils
//
//  Created by Matt Gallagher on 2015/02/03.
//  Copyright © 2015 Matt Gallagher ( http://cocoawithlove.com ). All rights reserved.
//
//  Permission to use, copy, modify, and/or distribute this software for any
//  purpose with or without fee is hereby granted, provided that the above
//  copyright notice and this permission notice appear in all copies.
//
//  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
//  SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
//  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

import Foundation

/// A description about how functions will be invoked on an execution context.
public enum ExecutionType {
	/// Any function provided to `invoke` will be completed before the call to `invoke` returns. There is no inherent mutex (simultaneous invocations from multiple threads may run concurrently).
	case immediate
	
	/// Any function provided to `invoke` will be completed before the call to `invoke` returns. Mutual exclusion is applied preventing invocations from multiple threads running concurrently.
	case mutex
	
	/// Completion of the provided function is independent of the return from `invoke`. Subsequent functions provided to `invoke`, before completion if preceeding provided functions will be serialized and run after the preceeding calls have completed.
	case serialAsync
	
	/// If the current scope is already inside the context, the wrapped value will be `false` and the invocation will be `immediate`.
	/// If the current scope is not inside the context, the wrapped value will be `true` and the invocation will be like `serialAsync`.
	case conditionallyAsync(Bool)

	/// Completion of the provided function is independent of the return from `invoke`. Subsequent functions provided to `invoke` will be run concurrently.
	case concurrentAsync
	
	/// Returns true if an invoked function is guaranteed to complete before the `invoke` returns.
	public var isImmediate: Bool {
		switch self {
		case .immediate: return true
		case .mutex: return true
		case .conditionallyAsync(let async): return !async
		default: return false
		}
	}
	
	/// Returns true if simultaneous uses of the context from separate threads will run concurrently.
	public var isConcurrent: Bool {
		switch self {
		case .immediate: return true
		case .concurrentAsync: return true
		default: return false
		}
	}
}

/// An abstraction of common execution context concepts
public protocol ExecutionContext {
	/// A description about how functions will be invoked on an execution context.
	var type: ExecutionType { get }
	
	/// Run `execute` normally on the execution context
	func invoke(_ execute: @escaping () -> Void)
	
	/// Run `execute` asynchronously on the execution context
	func invokeAsync(_ execute: @escaping () -> Void)
	
	/// Run `execute` on the execution context but don't return from this function until the provided function is complete.
	func invokeAndWait(_ execute: @escaping () -> Void)

	/// Run `execute` on the execution context after `interval` (plus `leeway`) unless the returned `Cancellable` is cancelled or released before running occurs.
	func singleTimer(interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping () -> Void) -> Cancellable

	/// Run `execute` on the execution context after `interval` (plus `leeway`), passing the `parameter` value as an argument, unless the returned `Cancellable` is cancelled or released before running occurs.
	func singleTimer<T>(parameter: T, interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping (T) -> Void) -> Cancellable
	
	/// Run `execute` on the execution context after `interval` (plus `leeway`), and again every `interval` (within a `leeway` margin of error) unless the returned `Cancellable` is cancelled or released before running occurs.
	func periodicTimer(interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping () -> Void) -> Cancellable

	/// Run `execute` on the execution context after `interval` (plus `leeway`), passing the `parameter` value as an argument, and again every `interval` (within a `leeway` margin of error) unless the returned `Cancellable` is cancelled or released before running occurs.
	func periodicTimer<T>(parameter: T, interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping (T) -> Void) -> Cancellable
	
	/// Run `execute` on the execution context after `interval` (plus `leeway`) unless the returned `Cancellable` is cancelled or released before running occurs.
	func singleTimer(interval: DispatchTimeInterval, handler: @escaping () -> Void) -> Cancellable

	/// Run `execute` on the execution context after `interval` (plus `leeway`), passing the `parameter` value as an argument, unless the returned `Cancellable` is cancelled or released before running occurs.
	func singleTimer<T>(parameter: T, interval: DispatchTimeInterval, handler: @escaping (T) -> Void) -> Cancellable
	
	/// Run `execute` on the execution context after `interval` (plus `leeway`), and again every `interval` (within a `leeway` margin of error) unless the returned `Cancellable` is cancelled or released before running occurs.
	func periodicTimer(interval: DispatchTimeInterval, handler: @escaping () -> Void) -> Cancellable

	/// Run `execute` on the execution context after `interval` (plus `leeway`), passing the `parameter` value as an argument, and again every `interval` (within a `leeway` margin of error) unless the returned `Cancellable` is cancelled or released before running occurs.
	func periodicTimer<T>(parameter: T, interval: DispatchTimeInterval, handler: @escaping (T) -> Void) -> Cancellable
	
	/// Gets a timestamp representing the host uptime the in the current context
	func timestamp() -> DispatchTime
}

// Since it's not possible to have default parameters in protocols (yet) the "leeway" free functions are all default-implemented to call the "leeway" functions with a 0 second leeway.
extension ExecutionContext {
	public func singleTimer(interval: DispatchTimeInterval, handler: @escaping () -> Void) -> Cancellable {
		return singleTimer(interval: interval, leeway: .seconds(0), handler: handler)
	}
	public func singleTimer<T>(parameter: T, interval: DispatchTimeInterval, handler: @escaping (T) -> Void) -> Cancellable {
		return singleTimer(parameter: parameter, interval: interval, leeway: .seconds(0), handler: handler)
	}
	public func periodicTimer(interval: DispatchTimeInterval, handler: @escaping () -> Void) -> Cancellable {
		return periodicTimer(interval: interval, leeway: .seconds(0), handler: handler)
	}
	public func periodicTimer<T>(parameter: T, interval: DispatchTimeInterval, handler: @escaping (T) -> Void) -> Cancellable {
		return periodicTimer(parameter: parameter, interval: interval, leeway: .seconds(0), handler: handler)
	}
}

/// Slightly annoyingly, a `DispatchSourceTimer` is an existential, so we can't extend it to conform to `Cancellable`. Instead, we dynamically downcast to `DispatchSource` and use this extension.
extension DispatchSource: Cancellable {
}

@available(*, deprecated, message:"Use DispatchQueueContext instead")
public typealias CustomDispatchQueue = DispatchQueueContext

/// Combines a `DispatchQueue` and an `ExecutionType` to create an `ExecutionContext`.
public struct DispatchQueueContext: ExecutionContext {
	/// The underlying DispatchQueue
	public let queue: DispatchQueue

	/// A description about how functions will be invoked on an execution context.
	public let type: ExecutionType

	public init(sync: Bool = true, concurrent: Bool = false, qos: DispatchQoS = .default) {
		self.type = sync ? .mutex : (concurrent ? .concurrentAsync : .serialAsync)
		queue = DispatchQueue(label: "", qos: qos, attributes: concurrent ? DispatchQueue.Attributes.concurrent : DispatchQueue.Attributes(), autoreleaseFrequency: .inherit, target: nil)
	}

	/// Run `execute` normally on the execution context
	public func invoke(_ execute: @escaping () -> Void) {
		if case .mutex = type {
			queue.sync(execute: execute)
		} else {
			queue.async(execute: execute)
		}
	}
	
	/// Run `execute` asynchronously on the execution context
	public func invokeAsync(_ execute: @escaping () -> Void) {
		queue.async(execute: execute)
	}
	
	/// Run `execute` on the execution context but don't return from this function until the provided function is complete.
	public func invokeAndWait(_ execute: @escaping () -> Void) {
		queue.sync(execute: execute)
	}

	/// Run `execute` on the execution context after `interval` (plus `leeway`) unless the returned `Cancellable` is cancelled or released before running occurs.
	public func singleTimer(interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping () -> Void) -> Cancellable {
		return DispatchSource.singleTimer(interval: interval, leeway: leeway, queue: queue, handler: handler) as! DispatchSource
	}
	
	/// Run `execute` on the execution context after `interval` (plus `leeway`), passing the `parameter` value as an argument, unless the returned `Cancellable` is cancelled or released before running occurs.
	public func singleTimer<T>(parameter: T, interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping (T) -> Void) -> Cancellable {
		return DispatchSource.singleTimer(parameter: parameter, interval: interval, leeway: leeway, queue: queue, handler: handler) as! DispatchSource
	}
	
	/// Run `execute` on the execution context after `interval` (plus `leeway`), and again every `interval` (within a `leeway` margin of error) unless the returned `Cancellable` is cancelled or released before running occurs.
	public func periodicTimer(interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping () -> Void) -> Cancellable {
		return DispatchSource.repeatingTimer(interval: interval, leeway: leeway, queue: queue, handler: handler) as! DispatchSource
	}
	
	/// Run `execute` on the execution context after `interval` (plus `leeway`), passing the `parameter` value as an argument, and again every `interval` (within a `leeway` margin of error) unless the returned `Cancellable` is cancelled or released before running occurs.
	public func periodicTimer<T>(parameter: T, interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping (T) -> Void) -> Cancellable {
		return DispatchSource.repeatingTimer(parameter: parameter, interval: interval, leeway: leeway, queue: queue, handler: handler) as! DispatchSource
	}

	/// Gets a timestamp representing the host uptime the in the current context
	public func timestamp() -> DispatchTime {
		return DispatchTime.now()
	}
}

/// A wrapper around Cancellable that applies a mutex on the cancel operation.
/// This is a class so that `SerializingContext` can hold pass it weakly to the timer closure, avoiding having the timer keep itself alive.
private class MutexWrappedCancellable: Cancellable {
	var timer: Cancellable? = nil
	let mutex: PThreadMutex
	
	init(mutex: PThreadMutex) {
		self.mutex = mutex
	}
	
	func cancel() {
		mutex.sync {
			timer?.cancel()
			timer = nil
		}
	}
	
	deinit {
		cancel()
	}
}

/// An `ExecutionContext` wraps a mutex around calls invoked by an underlying execution context. The effect is to serialize concurrent contexts (immediate or concurrent).
public struct SerializingContext: ExecutionContext {
	public let underlying: ExecutionContext
	public let mutex = PThreadMutex(type: .recursive)
	
	public init(concurrentContext: ExecutionContext) {
		underlying = concurrentContext
	}

	public var type: ExecutionType {
		switch underlying.type {
		case .immediate: return .mutex
		case .concurrentAsync: return .serialAsync
		default: return underlying.type
		}
	}
	
	/// Run `execute` normally on the execution context
	public func invoke(_ execute: @escaping () -> Void) {
		if case .some(.direct) = underlying as? Exec {
			mutex.sync(execute: execute)
		} else {
			underlying.invoke { [mutex] in mutex.sync(execute: execute) }
		}
	}
	
	/// Run `execute` asynchronously on the execution context
	public func invokeAsync(_ execute: @escaping () -> Void) {
		underlying.invokeAsync { [mutex] in mutex.sync(execute: execute) }
	}
	
	/// Run `execute` on the execution context but don't return from this function until the provided function is complete.
	public func invokeAndWait(_ execute: @escaping () -> Void) {
		if case .some(.direct) = underlying as? Exec {
			mutex.sync(execute: execute)
		} else {
			underlying.invokeAndWait { [mutex] in mutex.sync(execute: execute) }
		}
	}

	/// Run `execute` on the execution context after `interval` (plus `leeway`) unless the returned `Cancellable` is cancelled or released before running occurs.
	public func singleTimer(interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping () -> Void) -> Cancellable {
		return mutex.sync { () -> Cancellable in
			let wrapper = MutexWrappedCancellable(mutex: mutex)
			let cancellableTimer = underlying.singleTimer(interval: interval, leeway: leeway) { [weak wrapper] in
				if let w = wrapper {
					w.mutex.sync {
						// Need to perform this double check since the timer may have been cancelled/changed before we
						if w.timer != nil {
							handler()
						}
					}
				}
			}
			wrapper.timer = cancellableTimer
			return wrapper
		}
	}
	
	/// Run `execute` on the execution context after `interval` (plus `leeway`), passing the `parameter` value as an argument, unless the returned `Cancellable` is cancelled or released before running occurs.
	public func singleTimer<T>(parameter: T, interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping (T) -> Void) -> Cancellable {
		return mutex.sync { () -> Cancellable in
			let wrapper = MutexWrappedCancellable(mutex: mutex)
			let cancellableTimer = underlying.singleTimer(parameter: parameter, interval: interval, leeway: leeway) { [weak wrapper] p in
				if let w = wrapper {
					w.mutex.sync {
						if w.timer != nil {
							handler(p)
						}
					}
				}
			}
			wrapper.timer = cancellableTimer
			return wrapper
		}
	}
	
	/// Run `execute` on the execution context after `interval` (plus `leeway`), and again every `interval` (within a `leeway` margin of error) unless the returned `Cancellable` is cancelled or released before running occurs.
	public func periodicTimer(interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping () -> Void) -> Cancellable {
		return mutex.sync { () -> Cancellable in
			let wrapper = MutexWrappedCancellable(mutex: mutex)
			let cancellableTimer = underlying.periodicTimer(interval: interval, leeway: leeway) { [weak wrapper] in
				if let w = wrapper {
					w.mutex.sync {
						if w.timer != nil {
							handler()
						}
					}
				}
			}
			wrapper.timer = cancellableTimer
			return wrapper
		}
	}
	
	/// Run `execute` on the execution context after `interval` (plus `leeway`), passing the `parameter` value as an argument, and again every `interval` (within a `leeway` margin of error) unless the returned `Cancellable` is cancelled or released before running occurs.
	public func periodicTimer<T>(parameter: T, interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping (T) -> Void) -> Cancellable {
		return mutex.sync { () -> Cancellable in
			let wrapper = MutexWrappedCancellable(mutex: mutex)
			let cancellableTimer = underlying.periodicTimer(parameter: parameter, interval: interval, leeway: leeway) { [weak wrapper] p in
				if let w = wrapper {
					w.mutex.sync {
						if w.timer != nil {
							handler(p)
						}
					}
				}
			}
			wrapper.timer = cancellableTimer
			return wrapper
		}
	}

	/// Gets a timestamp representing the host uptime the in the current context
	public func timestamp() -> DispatchTime {
		return underlying.timestamp()
	}
}

/// While `Exec` is an implementation of `ExecutionContext`, it is intended to be more transparent – allowing a context to be asked if it is a specific context like `sync` or `main`, so that the user of the `Exec` can perform appropriate optimizations.
public enum Exec: ExecutionContext {
	/// Invoked directly from the caller's context
	case direct
	
	/// Invoked on the main thread, directly if the current thread is the main thread, otherwise asynchronously
	case main
	
	/// Invoked on the main thread, always asynchronously
	case mainAsync
	
	/// Invoked asynchronously in the global queue with QOS_CLASS_USER_INTERACTIVE priority
	case interactive

	/// Invoked asynchronously in the global queue with QOS_CLASS_USER_INITIATED priority
	case user

	/// Invoked asynchronously in the global queue with QOS_CLASS_DEFAULT priority
	case `default`

	/// Invoked asynchronously in the global queue with QOS_CLASS_UTILITY priority
	case utility

	/// Invoked asynchronously in the global queue with QOS_CLASS_BACKGROUND priority
	case background

	/// Invoked using the wrapped existential.
	case custom(ExecutionContext)

	var dispatchQueue: DispatchQueue {
		switch self {
		case .direct: return DispatchQueue.global()
		case .main: return DispatchQueue.main
		case .mainAsync: return DispatchQueue.main
		case .custom: return DispatchQueue.global()
		case .interactive: return DispatchQueue.global(qos: .userInteractive)
		case .user: return DispatchQueue.global(qos: .userInitiated)
		case .default: return DispatchQueue.global()
		case .utility: return DispatchQueue.global(qos: .utility)
		case .background: return DispatchQueue.global(qos: .background)
		}
	}
	
	/// A description about how functions will be invoked on an execution context.
	public var type: ExecutionType {
		switch self {
		case .direct: return .immediate
		case .main where Thread.isMainThread: return .conditionallyAsync(false)
		case .main: return .conditionallyAsync(true)
		case .mainAsync: return .serialAsync
		case .custom(let c): return c.type
		case .interactive: return .concurrentAsync
		case .user: return .concurrentAsync
		case .default: return .concurrentAsync
		case .utility: return .concurrentAsync
		case .background: return .concurrentAsync
		}
	}
	
	/// Run `execute` normally on the execution context
	public func invoke(_ execute: @escaping () -> Void) {
		switch self {
		case .direct: execute()
		case .custom(let c): c.invoke(execute)
		case .main where Thread.isMainThread: execute()
		default: dispatchQueue.async(execute: execute)
		}
	}
	
	/// Run `execute` asynchronously on the execution context
	public func invokeAsync(_ execute: @escaping () -> Void) {
		switch self {
		case .custom(let c): c.invokeAsync(execute)
		default: dispatchQueue.async(execute: execute)
		}
	}

	/// Run `execute` on the execution context but don't return from this function until the provided function is complete.
	public func invokeAndWait(_ execute: @escaping () -> Void) {
		switch self {
		case .custom(let c): c.invokeAndWait(execute)
		case .main where Thread.isMainThread: execute()
		case .main: DispatchQueue.main.sync(execute: execute)
		case .mainAsync where Thread.isMainThread: execute()
		case .mainAsync: DispatchQueue.main.sync(execute: execute)
		case .direct: fallthrough
		case .interactive: fallthrough
		case .user: fallthrough
		case .default: fallthrough
		case .utility: fallthrough
		case .background:
			// For all other cases, assume the queue isn't actually required (and was only provided for asynchronous behavior). Just invoke the provided function directly.
			execute()
		}
	}
	
	/// If this context is concurrent, returns a serialization around this context, otherwise returns this context.
	public func serialized() -> Exec {
		if self.type.isConcurrent {
			return Exec.custom(SerializingContext(concurrentContext: self))
		}
		return self
	}
	
	/// Constructs an `Exec.custom` wrapping a synchronous `DispatchQueue`
	public static func syncQueue() -> Exec {
		return Exec.custom(DispatchQueueContext())
	}
	
	/// Constructs an `Exec.custom` wrapping a synchronous `DispatchQueue` with a `DispatchSpecificKey` set for the queue (so that it can be identified when active).
	public static func syncQueueWithSpecificKey() -> (Exec, DispatchSpecificKey<()>) {
		let cdq = DispatchQueueContext()
		let specificKey = DispatchSpecificKey<()>()
		cdq.queue.setSpecific(key: specificKey, value: ())
		return (Exec.custom(cdq), specificKey)
	}
	
	/// Constructs an `Exec.custom` wrapping an asynchronous `DispatchQueue`
	public static func asyncQueue(qos: DispatchQoS = .default) -> Exec {
		return Exec.custom(DispatchQueueContext(sync: false, qos: qos))
	}
	
	/// Constructs an `Exec.custom` wrapping an asynchronous `DispatchQueue` with a `DispatchSpecificKey` set for the queue (so that it can be identified when active).
	public static func asyncQueueWithSpecificKey(qos: DispatchQoS = .default) -> (Exec, DispatchSpecificKey<()>) {
		let cdq = DispatchQueueContext(sync: false, qos: qos)
		let specificKey = DispatchSpecificKey<()>()
		cdq.queue.setSpecific(key: specificKey, value: ())
		return (Exec.custom(cdq), specificKey)
	}
	
	/// Run `execute` on the execution context after `interval` (plus `leeway`) unless the returned `Cancellable` is cancelled or released before running occurs.
	public func singleTimer(interval: DispatchTimeInterval, leeway: DispatchTimeInterval = .nanoseconds(0), handler: @escaping () -> Void) -> Cancellable {
		if case .custom(let c) = self {
			return c.singleTimer(interval: interval, leeway: leeway, handler: handler)
		}
		return DispatchSource.singleTimer(interval: interval, leeway: leeway, queue: dispatchQueue, handler: handler) as! DispatchSource
	}
	
	/// Run `execute` on the execution context after `interval` (plus `leeway`), passing the `parameter` value as an argument, unless the returned `Cancellable` is cancelled or released before running occurs.
	public func singleTimer<T>(parameter: T, interval: DispatchTimeInterval, leeway: DispatchTimeInterval = .nanoseconds(0), handler: @escaping (T) -> Void) -> Cancellable {
		if case .custom(let c) = self {
			return c.singleTimer(parameter: parameter, interval: interval, leeway: leeway, handler: handler)
		}
		return DispatchSource.singleTimer(parameter: parameter, interval: interval, leeway: leeway, queue: dispatchQueue, handler: handler) as! DispatchSource
	}
	
	/// Run `execute` on the execution context after `interval` (plus `leeway`), and again every `interval` (within a `leeway` margin of error) unless the returned `Cancellable` is cancelled or released before running occurs.
	public func periodicTimer(interval: DispatchTimeInterval, leeway: DispatchTimeInterval = .nanoseconds(0), handler: @escaping () -> Void) -> Cancellable {
		if case .custom(let c) = self {
			return c.periodicTimer(interval: interval, leeway: leeway, handler: handler)
		}
		return DispatchSource.repeatingTimer(interval: interval, leeway: leeway, queue: dispatchQueue, handler: handler) as! DispatchSource
	}
	
	/// Run `execute` on the execution context after `interval` (plus `leeway`), passing the `parameter` value as an argument, and again every `interval` (within a `leeway` margin of error) unless the returned `Cancellable` is cancelled or released before running occurs.
	public func periodicTimer<T>(parameter: T, interval: DispatchTimeInterval, leeway: DispatchTimeInterval = .nanoseconds(0), handler: @escaping (T) -> Void) -> Cancellable {
		if case .custom(let c) = self {
			return c.periodicTimer(parameter: parameter, interval: interval, leeway: leeway, handler: handler)
		}
		return DispatchSource.repeatingTimer(parameter: parameter, interval: interval, leeway: leeway, queue: dispatchQueue, handler: handler) as! DispatchSource
	}

	/// Gets a timestamp representing the host uptime the in the current context
	public func timestamp() -> DispatchTime {
		if case .custom(let c) = self {
			return c.timestamp()
		}
		return DispatchTime.now()
	}
}
//
//  CwlKeyValueObserver.swift
//  CwlUtils
//
//  Created by Matt Gallagher on 2015/02/03.
//  Copyright © 2015 Matt Gallagher ( http://cocoawithlove.com ). All rights reserved.
//
//  Permission to use, copy, modify, and/or distribute this software for any
//  purpose with or without fee is hereby granted, provided that the above
//  copyright notice and this permission notice appear in all copies.
//
//  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
//  SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
//  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

import Foundation

/// A wrapper around key-value observing so that you:
///	1. don't need to implement `observeValue` yourself, you can instead handle changes in a closure
///	2. you get a `CallbackReason` for each change which includes `valueChanged`, `pathChanged`, `sourceDeleted`.
///	3. observation is automatically cancelled if you release the KeyValueObserver or the source is released
///
/// A majority of the complexity in this class comes from the fact that we turn key-value observing on keyPaths into a series of chained KeyValueObservers that we manage ourselves. This gives us more information when things change but we're re-implementing a number of things that Cococa key-value observing normally gives us for free. Generally in this class, anything involving the `tailPath` is managing observations of the path.
///
/// THREAD SAFETY:
/// This class is memory safe even when observations are triggered concurrently from different threads.
/// Do note though that while all changes are registered under the mutex, callbacks are invoked *outside* the mutex, so it is possible for callbacks to be invoked in a different order than the internal synchronized order.
/// In general, this shouldn't be a problem (since key-value observing is not itself synchronized so there *isn't* an authoritative ordering). However, this may cause unexpected behavior if you invoke `cancel` on this class. If you `cancel` the `KeyValueObserver` while it is concurrently processing changes on another thread, this might result in callback invocations occurring *after* the call to `cancel`. This will only happen if the changes associated with those callbacks were received *before* the `cancel` - it's just the callback that's getting invoked later.
public class KeyValueObserver: NSObject {
	public typealias Callback = (_ change: [NSKeyValueChangeKey: Any], _ reason: CallbackReason) -> Void

	// This is the user-supplied callback function
	private var callback: Callback?
	
	// When observing a keyPath, we use a separate KeyValueObserver for each component of the path. The `tailObserver` is the `KeyValueObserver` for the *next* element in the path.
	private var tailObserver: KeyValueObserver?
	
	// This is the key that we're observing on `source`
	private let key: String
	
	// This is any path beyond the key.
	private let tailPath: String?
	
	// This is the set of options passed on construction
	private let options: NSKeyValueObservingOptions
	
	// Used to ensure memory safety for the callback and tailObserver.
	private let mutex = DispatchQueue(label: "")
	
	// Our "deletionBlock" is called to notify us that the source is being deallocated (so we can remove the key value observation before a warning is logged) and this happens during the source's "objc_destructinstance" function. At this point, a `weak` var will be `nil` and an `unowned` will trigger a `_swift_abortRetainUnowned` failure.
	// So we're left with `Unmanaged`. Careful cancellation before the source is deallocated is necessary to ensure we don't access an invalid memory location.
	private let source: Unmanaged<NSObject>
	
	/// The `CallbackReason` explains the location in the path where the change occurred.
	///
	/// - valueChanged: the observed value changed
	/// - pathChanged: one of the connected elements in the path changed
	/// - sourceDeleted: the observed source was deallocated
	/// - cancelled: will never be sent
	public enum CallbackReason {
		case valueChanged
		case pathChanged
		case sourceDeleted
		case cancelled
	}
	
	/// Establish the key value observing.
	///
	/// - Parameters:
	///   - source: object on which there's a property we wish to observe
	///   - keyPath: a key or keyPath identifying the property we wish to observe
	///   - options: same as for the normal `addObserver` method
	///   - callback: will be invoked on each change with the change dictionary and the change reason
	public init(source: NSObject, keyPath: String, options: NSKeyValueObservingOptions = NSKeyValueObservingOptions.new.union(NSKeyValueObservingOptions.initial), callback: @escaping Callback) {
		self.callback = callback
		self.source = Unmanaged.passUnretained(source)
		self.options = options
		
		// Look for "." indicating a key path
		var range = keyPath.range(of: ".")
		
		// If we have a collection operator, consider the next path component as part of this key
		if let r = range, keyPath.hasPrefix("@") {
			range = keyPath.range(of: ".", range: keyPath.index(after: r.lowerBound)..<keyPath.endIndex, locale: nil)
		}
		
		// Set the key and tailPath based on whether we detected multiple path components
		if let r = range {
			self.key = keyPath.substring(to: r.lowerBound)
			self.tailPath = keyPath.substring(from: keyPath.index(after: r.lowerBound))
		} else {
			self.key = keyPath
			
			// If we're observing a weak property, add an observer on self to the source to detect when it may be set to nil without going through the property setter
			var p: String? = nil
			if let propertyName = keyPath.cString(using: String.Encoding.utf8) {
				let property = class_getProperty(type(of: source), propertyName)
				// Look for both the "id" and "weak" attributes.
				if let prop = property, let attributes = property_getAttributes(prop), let attrsString = String(validatingUTF8: attributes)?.components(separatedBy: ","), attrsString.filter({ $0.hasPrefix("T@") || $0 == "W" }).count == 2 {
					p = "self"
				}
			}
			self.tailPath = p
		}
		
		super.init()
		
		// Detect if the source is deleted
		let deletionBlock = OnDelete { [weak self] in self?.cancel(.sourceDeleted) }
		objc_setAssociatedObject(source, Unmanaged.passUnretained(self).toOpaque(), deletionBlock, objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN)
		
		// Start observing the source
		if key != "self" {
			var currentOptions = options
			if !isObservingTail {
				currentOptions = NSKeyValueObservingOptions.new.union(options.intersection(NSKeyValueObservingOptions.prior))
			}
			
			source.addObserver(self, forKeyPath: key, options: currentOptions, context: Unmanaged.passUnretained(self).toOpaque())
		}
		
		// Start observing the value of the source
		if tailPath != nil {
			updateTailObserver(onValue: source.value(forKeyPath: self.key) as? NSObject, isInitial: true)
		}
	}
	
	deinit {
		cancel()
	}
	
	// This method is called when the key path between the source and the observed property changes. This will recursively create KeyValueObservers along the path.
	//
	// Mutex notes: Method must be called from *INSIDE* mutex (although, it must be *OUTSIDE* the tailObserver's mutex).
	private func updateTailObserver(onValue: NSObject?, isInitial: Bool) {
		tailObserver?.cancel()
		tailObserver = nil
		
		if let _ = self.callback, let tp = tailPath, let currentValue = onValue {
			let currentOptions = isInitial ? self.options : self.options.subtracting(NSKeyValueObservingOptions.initial)
			self.tailObserver = KeyValueObserver(source: currentValue, keyPath: tp, options: currentOptions, callback: self.tailCallback)
		}
	}
	
	// This method is called from the `tailObserver` (representing a change in the key path, not the observed property)
	//
	// Mutex notes: Method is called *OUTSIDE* mutex since it is used as a callback function for the `tailObserver`
	private func tailCallback(_ change: [NSKeyValueChangeKey: Any], reason: CallbackReason) {
		switch reason {
		case .cancelled:
			return
		case .sourceDeleted:
			let c = mutex.sync(execute: { () -> Callback? in
				updateTailObserver(onValue: nil, isInitial: false)
				return self.callback
			})
			c?(change, self.isObservingTail ? .valueChanged : .pathChanged)
		default:
			let c = mutex.sync { self.callback }
			c?(change, reason)
		}
	}
	
	// The method returns `false` if there are subsequent `KeyValueObserver`s observing part of the path between us and the observed property and `true` if we are directly observing the property.
	//
	// Mutex notes: Safe for invocation in or out of mutex
	private var isObservingTail: Bool {
		return tailPath == nil || tailPath == "self"
	}
	
	// Weak properties need `self` observed, as well as the property, to correctly detect changes.
	//
	// Mutex notes: Safe for invocation in or out of mutex
	private var needsWeakTailObserver: Bool {
		return tailPath == "self"
	}
	
	// Accessor for the observed property value. This will correctly get the value from the end of the key path if we are using a tailObserver.
	//
	// Mutex notes: Method must be called from *INSIDE* mutex.
	private func sourceValue() -> Any? {
		if let t = tailObserver, !isObservingTail {
			return t.sourceValue()
		} else {
			return source.takeUnretainedValue().value(forKeyPath: key)
		}
	}
	
	// If we're observing a key path, then we need to update our chain of KeyValueObservers when part of the path changes. This starts that process from the change point.
	//
	// Mutex notes: Method must be called from *INSIDE* mutex.
	private func updateTailObserverGivenChangeDictionary(change: [NSKeyValueChangeKey: Any]) {
		if let newValue = change[NSKeyValueChangeKey.newKey] as? NSObject {
			let value: NSObject? = newValue == NSNull() ? nil : newValue
			updateTailObserver(onValue: value, isInitial: false)
		} else {
			updateTailObserver(onValue: sourceValue() as? NSObject, isInitial: false)
		}
	}
	
	// Implementation of standard key-value observing method.
	public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
		if context != Unmanaged.passUnretained(self).toOpaque() {
			super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
		}
		
		guard let c = change else {
			assertionFailure("Expected change dictionary")
			return
		}
		
		if self.isObservingTail {
			let cb = mutex.sync { () -> Callback? in
				if needsWeakTailObserver {
					updateTailObserverGivenChangeDictionary(change: c)
				}
				return self.callback
			}
			cb?(c, .valueChanged)
			
		} else {
			let tuple = mutex.sync { () -> (Callback, [NSKeyValueChangeKey: Any])? in
				var transmittedChange: [NSKeyValueChangeKey: Any] = [:]
				if !options.intersection(NSKeyValueObservingOptions.old).isEmpty {
					transmittedChange[NSKeyValueChangeKey.oldKey] = tailObserver?.sourceValue()
				}
				if let _ = c[NSKeyValueChangeKey.notificationIsPriorKey] as? Bool {
					transmittedChange[NSKeyValueChangeKey.notificationIsPriorKey] = true
				}
				updateTailObserverGivenChangeDictionary(change: c)
				if !options.intersection(NSKeyValueObservingOptions.new).isEmpty {
					transmittedChange[NSKeyValueChangeKey.newKey] = tailObserver?.sourceValue()
				}
				if let c = callback {
					return (c, transmittedChange)
				}
				return nil
			}
			if let (cb, tc) = tuple {
				cb(tc, .pathChanged)
			}
		}
	}
	
	/// Stop observing.
	public func cancel() {
		cancel(.cancelled)
	}
	
	// Mutex notes: Method is called *OUTSIDE* mutex
	private func cancel(_ reason: CallbackReason) {
		let cb = mutex.sync { () -> Callback? in
			guard let c = callback else { return nil }
			
			// Flag as inactive
			callback = nil
			
			// Remove the observations from this object
			if key != "self" {
				source.takeUnretainedValue().removeObserver(self, forKeyPath: key, context: Unmanaged.passUnretained(self).toOpaque())
			}
			
			// Cancel the OnDelete object
			let unknown = objc_getAssociatedObject(source, Unmanaged.passUnretained(self).toOpaque())
			if let deletionObject = unknown as? OnDelete {
				deletionObject.cancel()
			}

			// And clear the associated object
			objc_setAssociatedObject(source, Unmanaged.passUnretained(self).toOpaque(), nil, objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN);
			
			// Remove tail observers
			updateTailObserver(onValue: nil, isInitial: false)
			
			// Send notifications
			return reason != .cancelled ? c : nil
		}
		
		cb?([:], reason)
	}
}
//
//  CwlMutex.swift
//  CwlUtils
//
//  Created by Matt Gallagher on 2015/02/03.
//  Copyright © 2015 Matt Gallagher ( http://cocoawithlove.com ). All rights reserved.
//
//  Permission to use, copy, modify, and/or distribute this software for any
//  purpose with or without fee is hereby granted, provided that the above
//  copyright notice and this permission notice appear in all copies.
//
//  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
//  SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
//  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

import Foundation

/// A basic mutex protocol that requires nothing more than "performing work inside the mutex".
public protocol ScopedMutex {
	/// Perform work inside the mutex
	func sync<R>(execute work: () throws -> R) rethrows -> R
	func trySync<R>(execute work: () throws -> R) rethrows -> R?
}

/// A more specific kind of mutex that assume an underlying primitive and unbalanced lock/trylock/unlock operators
public protocol RawMutex: ScopedMutex {
	associatedtype MutexPrimitive

	/// The raw primitive is exposed as an "unsafe" public property for faster access in some cases
	var unsafeMutex: MutexPrimitive { get set }

	func unbalancedLock()
	func unbalancedTryLock() -> Bool
	func unbalancedUnlock()
}

extension RawMutex {
	/** RECOMMENDATION: until Swift can inline between modules or at least optimize @noescape closures to the stack, if this file is linked into another compilation unit (i.e. linked as part of the CwlUtils.framework but used from another module) it might be a good idea to copy and paste the relevant `fastsync` implementation code into your file (or module and delete `private` if whole module optimization is enabled) and use it instead, allowing the function to be inlined.
~~~
private extension UnfairLock {
	func fastsync<R>(execute work: @noescape () throws -> R) rethrows -> R {
		os_unfair_lock_lock(&unsafeLock)
		defer { os_unfair_lock_unlock(&unsafeLock) }
		return try work()
	}
}
private extension PThreadMutex {
	func fastsync<R>(execute work: @noescape () throws -> R) rethrows -> R {
		pthread_mutex_lock(&unsafeMutex)
		defer { pthread_mutex_unlock(&unsafeMutex) }
		return try work()
	}
}
~~~
	*/
	public func sync<R>(execute work: () throws -> R) rethrows -> R {
		unbalancedLock()
		defer { unbalancedUnlock() }
		return try work()
	}
	public func trySync<R>(execute work: () throws -> R) rethrows -> R? {
		guard unbalancedTryLock() else { return nil }
		defer { unbalancedUnlock() }
		return try work()
	}
}

/// A basic wrapper around the "NORMAL" and "RECURSIVE" `pthread_mutex_t` (a safe, general purpose FIFO mutex). This type is a "class" type to take advantage of the "deinit" method and prevent accidental copying of the `pthread_mutex_t`.
public final class PThreadMutex: RawMutex {
	public typealias MutexPrimitive = pthread_mutex_t

	// Non-recursive "PTHREAD_MUTEX_NORMAL" and recursive "PTHREAD_MUTEX_RECURSIVE" mutex types.
	public enum PThreadMutexType {
		case normal
		case recursive
	}

	public var unsafeMutex = pthread_mutex_t()
	
	/// Default constructs as ".Normal" or ".Recursive" on request.
	public init(type: PThreadMutexType = .normal) {
		var attr = pthread_mutexattr_t()
		guard pthread_mutexattr_init(&attr) == 0 else {
			preconditionFailure()
		}
		switch type {
		case .normal:
			pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_NORMAL)
		case .recursive:
			pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE)
		}
		guard pthread_mutex_init(&unsafeMutex, &attr) == 0 else {
			preconditionFailure()
		}
	}
	
	deinit {
		pthread_mutex_destroy(&unsafeMutex)
	}
	
	public func unbalancedLock() {
		pthread_mutex_lock(&unsafeMutex)
	}
	
	public func unbalancedTryLock() -> Bool {
		return pthread_mutex_trylock(&unsafeMutex) == 0
	}
	
	public func unbalancedUnlock() {
		pthread_mutex_unlock(&unsafeMutex)
	}
}

/// A basic wrapper around `os_unfair_lock` (a non-FIFO, high performance lock that offers safety against priority inversion). This type is a "class" type to prevent accidental copying of the `os_unfair_lock`.
/// NOTE: due to the behavior of the lock (non-FIFO) a single thread might drop and reacquire the lock without giving waiting threads a chance to resume (leading to potential starvation of waiters). For this reason, it is only recommended in situations where contention is expected to be rare or the interaction between contenders is otherwise known.
@available(OSX 10.12, iOS 10, *)
public final class UnfairLock: RawMutex {
	public typealias MutexPrimitive = os_unfair_lock
	
	public init() {
	}
	
	/// Exposed as an "unsafe" public property so non-scoped patterns can be implemented, if required.
	public var unsafeMutex = os_unfair_lock()
	
	public func unbalancedLock() {
		os_unfair_lock_lock(&unsafeMutex)
	}
	
	public func unbalancedTryLock() -> Bool {
		return os_unfair_lock_trylock(&unsafeMutex)
	}
	
	public func unbalancedUnlock() {
		os_unfair_lock_unlock(&unsafeMutex)
	}
}
//
//  CwlOnDelete.swift
//  CwlUtils
//
//  Created by Matt Gallagher on 2015/02/03.
//  Copyright © 2015 Matt Gallagher ( http://cocoawithlove.com ). All rights reserved.
//
//  Permission to use, copy, modify, and/or distribute this software for any
//  purpose with or without fee is hereby granted, provided that the above
//  copyright notice and this permission notice appear in all copies.
//
//  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
//  SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
//  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

import Swift

public final class OnDelete: Cancellable {
	var block: (() -> Void)?
	
	public init(_ b: @escaping () -> Void) {
		block = b
	}
	
	public func invalidate() {
		block = nil
	}
	
	public func cancel() {
		block?()
	}
	
	public var isValid: Bool {
		return block != nil
	}
	
	deinit {
		cancel()
	}
}
//
//  CwlRandom.swift
//  CwlUtils
//
//  Created by Matt Gallagher on 2016/05/17.
//  Copyright © 2016 Matt Gallagher ( http://cocoawithlove.com ). All rights reserved.
//
//  Permission to use, copy, modify, and/or distribute this software for any
//  purpose with or without fee is hereby granted, provided that the above
//  copyright notice and this permission notice appear in all copies.
//
//  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
//  SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
//  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

import Foundation

public protocol RandomGenerator {
	init()
	
	/// Initializes the provided buffer with randomness
	mutating func randomize(buffer: UnsafeMutableRawPointer, size: Int)
	
	// Generates 64 bits of randomness
	mutating func random64() -> UInt64

	// Generates 32 bits of randomness
	mutating func random32() -> UInt32

	// Generates a uniform distribution with a maximum value no more than `max`
	mutating func random64(max: UInt64) -> UInt64

	// Generates a uniform distribution with a maximum value no more than `max`
	mutating func random32(max: UInt32) -> UInt32

	/// Generates a double with a random 52 bit significand on the half open range [0, 1)
	mutating func randomHalfOpen() -> Double

	/// Generates a double with a random 52 bit significand on the closed range [0, 1]
	mutating func randomClosed() -> Double

	/// Generates a double with a random 51 bit significand on the open range (0, 1)
	mutating func randomOpen() -> Double
}

public extension RandomGenerator {
	mutating func random64() -> UInt64 {
		var bits: UInt64 = 0
		randomize(buffer: &bits, size: MemoryLayout<UInt64>.size)
		return bits
	}
	
	mutating func random32() -> UInt32 {
		var bits: UInt32 = 0
		randomize(buffer: &bits, size: MemoryLayout<UInt32>.size)
		return bits
	}
	
	mutating func random64(max: UInt64) -> UInt64 {
		switch max {
		case UInt64.max: return random64()
		case 0: return 0
		default:
			var result: UInt64
			repeat {
				result = random64()
			} while result < UInt64.max % (max + 1)
			return result % (max + 1)
		}
	}
	
	mutating func random32(max: UInt32) -> UInt32 {
		switch max {
		case UInt32.max: return random32()
		case 0: return 0
		default:
			var result: UInt32
			repeat {
				result = random32()
			} while result < UInt32.max % (max + 1)
			return result % (max + 1)
		}
	}
	
	mutating func randomHalfOpen() -> Double {
		return halfOpenDoubleFrom64(bits: random64())
	}
	
	mutating func randomClosed() -> Double {
		return closedDoubleFrom64(bits: random64())
	}
	
	mutating func randomOpen() -> Double {
		return openDoubleFrom64(bits: random64())
	}
}

public func halfOpenDoubleFrom64(bits: UInt64) -> Double {
	return Double(bits & 0x001f_ffff_ffff_ffff) * (1.0 / 9007199254740992.0)
}

public func closedDoubleFrom64(bits: UInt64) -> Double {
	return Double(bits & 0x001f_ffff_ffff_ffff) * (1.0 / 9007199254740991.0)
}

public func openDoubleFrom64(bits: UInt64) -> Double {
	return (Double(bits & 0x000f_ffff_ffff_ffff) + 0.5) * (1.0 / 9007199254740991.0)
}

public protocol RandomWordGenerator: RandomGenerator {
	associatedtype WordType
	mutating func randomWord() -> WordType
}

extension RandomWordGenerator {
	public mutating func randomize(buffer: UnsafeMutableRawPointer, size: Int) {
		let b = buffer.assumingMemoryBound(to: WordType.self)
		for i in 0..<(size / MemoryLayout<WordType>.size) {
			b[i] = randomWord()
		}
		let remainder = size % MemoryLayout<WordType>.size
		if remainder > 0 {
			var final = randomWord()
			let b2 = buffer.assumingMemoryBound(to: UInt8.self)
			withUnsafePointer(to: &final) { (fin: UnsafePointer<WordType>) in
				fin.withMemoryRebound(to: UInt8.self, capacity: remainder) { f in
					for i in 0..<remainder {
						b2[size - i - 1] = f[i]
					}
				}
			}
		}
	}
}

public struct DevRandom: RandomGenerator {
	class FileDescriptor {
		let value: CInt
		init() {
			value = open("/dev/urandom", O_RDONLY)
			precondition(value >= 0)
		}
		deinit {
			close(value)
		}
	}
	
	let fd: FileDescriptor
	public init() {
		fd = FileDescriptor()
	}
	
	public mutating func randomize(buffer: UnsafeMutableRawPointer, size: Int) {
		let result = read(fd.value, buffer, size)
		precondition(result == size)
	}
	
	public static func random64() -> UInt64 {
		var r = DevRandom()
		return r.random64()
	}
	
	public static func randomize(buffer: UnsafeMutableRawPointer, size: Int) {
		var r = DevRandom()
		r.randomize(buffer: buffer, size: size)
	}
}

public struct Arc4Random: RandomGenerator {
	public init() {
	}
	
	public mutating func randomize(buffer: UnsafeMutableRawPointer, size: Int) {
		arc4random_buf(buffer, size)
	}
	
	public mutating func random64() -> UInt64 {
		// Generating 2x32-bit appears to be faster than using arc4random_buf on a 64-bit value
		var value: UInt64 = 0
		arc4random_buf(&value, MemoryLayout<UInt64>.size)
		return value
	}

	public mutating func random32() -> UInt32 {
		return arc4random()
	}
}

public struct Xoroshiro: RandomWordGenerator {
	public typealias WordType = UInt64
	public typealias StateType = (UInt64, UInt64)

	var state: StateType = (0, 0)

	public init() {
		DevRandom.randomize(buffer: &state, size: MemoryLayout<StateType>.size)
	}
	
	public init(seed: StateType) {
		self.state = seed
	}
	
	public mutating func random64() -> UInt64 {
		return randomWord()
	}

	public mutating func randomWord() -> UInt64 {
		// Directly inspired by public domain implementation here:
		// http://xoroshiro.di.unimi.it
		// by David Blackman and Sebastiano Vigna
		let (l, k0, k1, k2): (UInt64, UInt64, UInt64, UInt64) = (64, 55, 14, 36)
		
		let result = state.0 &+ state.1
		let x = state.0 ^ state.1
		state.0 = ((state.0 << k0) | (state.0 >> (l - k0))) ^ x ^ (x << k1)
		state.1 = (x << k2) | (x >> (l - k2))
		return result
	}
}

public struct MersenneTwister: RandomWordGenerator {
	public typealias WordType = UInt64
	
	// 312 is 13 x 6 x 4
	private var state_internal: (
		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,

		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,

		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,

		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
		UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64
	) = (
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,

		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,

		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,

		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
	)
	private var index: Int
	private static let stateCount: Int = 312
	
	public init() {
		self.init(seed: DevRandom.random64())
	}
	
	public init(seed: UInt64) {
		index = MersenneTwister.stateCount
		withUnsafeMutablePointer(to: &state_internal) { $0.withMemoryRebound(to: UInt64.self, capacity: MersenneTwister.stateCount) { state in
			state[0] = seed
			for i in 1..<MersenneTwister.stateCount {
				state[i] = 6364136223846793005 &* (state[i &- 1] ^ (state[i &- 1] >> 62)) &+ UInt64(i)
			}
		} }
	}

	public mutating func randomWord() -> UInt64 {
		return random64()
	}
	
	public mutating func random64() -> UInt64 {
		if index == MersenneTwister.stateCount {
			withUnsafeMutablePointer(to: &state_internal) { $0.withMemoryRebound(to: UInt64.self, capacity: MersenneTwister.stateCount) { state in
				let n = MersenneTwister.stateCount
				let m = n / 2
				let a: UInt64 = 0xB5026F5AA96619E9
				let lowerMask: UInt64 = (1 << 31) - 1
				let upperMask: UInt64 = ~lowerMask
				var (i, j, stateM) = (0, m, state[m])
				repeat {
					let x1 = (state[i] & upperMask) | (state[i &+ 1] & lowerMask)
					state[i] = state[i &+ m] ^ (x1 >> 1) ^ ((state[i &+ 1] & 1) &* a)
					let x2 = (state[j] & upperMask) | (state[j &+ 1] & lowerMask)
					state[j] = state[j &- m] ^ (x2 >> 1) ^ ((state[j &+ 1] & 1) &* a)
					(i, j) = (i &+ 1, j &+ 1)
				} while i != m &- 1
				
				let x3 = (state[m &- 1] & upperMask) | (stateM & lowerMask)
				state[m &- 1] = state[n &- 1] ^ (x3 >> 1) ^ ((stateM & 1) &* a)
				let x4 = (state[n &- 1] & upperMask) | (state[0] & lowerMask)
				state[n &- 1] = state[m &- 1] ^ (x4 >> 1) ^ ((state[0] & 1) &* a)
			} }
			
			index = 0
		}
		
		var result = withUnsafePointer(to: &state_internal) { $0.withMemoryRebound(to: UInt64.self, capacity: MersenneTwister.stateCount) { ptr in
			return ptr[index]
		} }
		index = index &+ 1

		result ^= (result >> 29) & 0x5555555555555555
		result ^= (result << 17) & 0x71D67FFFEDA60000
		result ^= (result << 37) & 0xFFF7EEE000000000
		result ^= result >> 43

		return result
	}
}
//
//  CwlResult.swift
//  CwlUtils
//
//  Created by Matt Gallagher on 2015/02/03.
//  Copyright © 2015 Matt Gallagher ( http://cocoawithlove.com ). All rights reserved.
//
//  Permission to use, copy, modify, and/or distribute this software for any
//  purpose with or without fee is hereby granted, provided that the above
//  copyright notice and this permission notice appear in all copies.
//
//  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
//  SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
//  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

import Foundation

/// Either a Value value or an ErrorType
public enum Result<Value> {
	/// Success wraps a Value value
	case success(Value)
	
	/// Failure wraps an ErrorType
	case failure(Error)
	
	/// Construct a result from a `throws` function
	public init(_ capturing: () throws -> Value) {
		do {
			self = .success(try capturing())
		} catch {
			self = .failure(error)
		}
	}
	
	/// Convenience tester/getter for the value
	public var value: Value? {
		switch self {
		case .success(let v): return v
		case .failure: return nil
		}
	}
	
	/// Convenience tester/getter for the error
	public var error: Error? {
		switch self {
		case .success: return nil
		case .failure(let e): return e
		}
	}

	/// Test whether the result is an error.
	public var isError: Bool {
		switch self {
		case .success: return false
		case .failure: return true
		}
	}
	
	/// Adapter method used to convert a Result to a value while throwing on error.
	public func unwrap() throws -> Value {
		switch self {
		case .success(let v): return v
		case .failure(let e): throw e
		}
	}

	/// Chains another Result to this one. In the event that this Result is a .Success, the provided transformer closure is used to generate another Result (wrapping a potentially new type). In the event that this Result is a .Failure, the next Result will have the same error as this one.
	public func flatMap<U>(_ transform: (Value) -> Result<U>) -> Result<U> {
		switch self {
		case .success(let val): return transform(val)
		case .failure(let e): return .failure(e)
		}
	}

	/// Chains another Result to this one. In the event that this Result is a .Success, the provided transformer closure is used to transform the value into another value (of a potentially new type) and a new Result is made from that value. In the event that this Result is a .Failure, the next Result will have the same error as this one.
	public func map<U>(_ transform: (Value) throws -> U) -> Result<U> {
		switch self {
		case .success(let val): return Result<U> { try transform(val) }
		case .failure(let e): return .failure(e)
		}
	}
}
//
//  CwlScalarScanner.swift
//  CwlWhitespace
//
//  Created by Matt Gallagher on 2016/01/05.
//  Copyright © 2016 Matt Gallagher ( http://cocoawithlove.com ). All rights reserved.
//
//  Permission to use, copy, modify, and/or distribute this software for any
//  purpose with or without fee is hereby granted, provided that the above
//  copyright notice and this permission notice appear in all copies.
//
//  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
//  SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
//  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

import Swift

/// A type for representing the different possible failure conditions when using ScalarScanner
public enum ScalarScannerError: Error {
	/// The scalar at the specified index doesn't match the expected grammar
	case unexpected(at: Int)
	
	/// Expected `wanted` at offset `at`
	case matchFailed(wanted: String, at: Int)
	
	/// Expected numerals at offset `at`
	case expectedInt(at: Int)
	
	/// Attempted to read `count` scalars from position `at` but hit the end of the sequence
	case endedPrematurely(count: Int, at: Int)
	
	/// Unable to find search patter `wanted` at or after `after` in the sequence
	case searchFailed(wanted: String, after: Int)
}

/// A structure for traversing a `String.UnicodeScalarView`.
///
/// **UNICODE WARNING**: this struct ignores all Unicode combining rules and parses each scalar individually. The rules for parsing must allow combined characters to be parsed separately or better yet, forbid combining characters at critical parse locations. If your data structure does not include these types of rule then you should be iterating over the `Character` elements in a `String` rather than using this struct.
public struct ScalarScanner<C: Collection> where C.Iterator.Element == UnicodeScalar {
	/// The underlying storage
	public let scalars: C
	
	/// Current scanning index
	public var index: C.Index
	
	/// Number of scalars consumed up to `index` (since String.UnicodeScalarView.Index is not a RandomAccessIndex, this makes determining the position *much* easier)
	public var consumed: Int
	
	/// Construct from a String.UnicodeScalarView and a context value
	public init(scalars: C) {
		self.scalars = scalars
		self.index = self.scalars.startIndex
		self.consumed = 0
	}
	
	/// Throw if the scalars at the current `index` don't match the scalars in `value`. Advance the `index` to the end of the match.
	/// WARNING: `string` is used purely for its `unicodeScalars` property and matching is purely based on direct scalar comparison (no decomposition or normalization is performed).
	public mutating func match(string: String) throws {
		let (newIndex, newConsumed) = try string.unicodeScalars.reduce((index: index, count: 0)) { (tuple: (index: C.Index, count: Int), scalar: UnicodeScalar) in
			if tuple.index == self.scalars.endIndex || scalar != self.scalars[tuple.index] {
				throw ScalarScannerError.matchFailed(wanted: string, at: consumed)
			}
			return (index: self.scalars.index(after: tuple.index), count: tuple.count + 1)
		}
		index = newIndex
		consumed += newConsumed
	}
	
	/// Throw if the scalars at the current `index` don't match the scalars in `value`. Advance the `index` to the end of the match.
	public mutating func match(scalar: UnicodeScalar) throws {
		if index == scalars.endIndex || scalars[index] != scalar {
			throw ScalarScannerError.matchFailed(wanted: String(scalar), at: consumed)
		}
		index = self.scalars.index(after: index)
		consumed += 1
	}
	
	/// Consume scalars from the contained collection, up to but not including the first instance of `scalar` found. `index` is advanced to immediately before `scalar`. Returns all scalars consumed prior to `scalar` as a `String`. Throws if `scalar` is never found.
	public mutating func readUntil(scalar: UnicodeScalar) throws -> String {
		var i = index
		let previousConsumed = consumed
		try skipUntil(scalar: scalar)
		
		var result = ""
		result.reserveCapacity(consumed - previousConsumed)
		while i != index {
			result.unicodeScalars.append(scalars[i])
			i = scalars.index(after: i)
		}
		
		return result
	}
	
	/// Consume scalars from the contained collection, up to but not including the first instance of `string` found. `index` is advanced to immediately before `string`. Returns all scalars consumed prior to `string` as a `String`. Throws if `string` is never found.
	/// WARNING: `string` is used purely for its `unicodeScalars` property and matching is purely based on direct scalar comparison (no decomposition or normalization is performed).
	public mutating func readUntil(string: String) throws -> String {
		var i = index
		let previousConsumed = consumed
		try skipUntil(string: string)
		
		var result = ""
		result.reserveCapacity(consumed - previousConsumed)
		while i != index {
			result.unicodeScalars.append(scalars[i])
			i = scalars.index(after: i)
		}
		
		return result
	}
	
	/// Consume scalars from the contained collection, up to but not including the first instance of any character in `set` found. `index` is advanced to immediately before `string`. Returns all scalars consumed prior to `string` as a `String`. Throws if no matching characters are ever found.
	public mutating func readUntil(set inSet: Set<UnicodeScalar>) throws -> String {
		var i = index
		let previousConsumed = consumed
		try skipUntil(set: inSet)
		
		var result = ""
		result.reserveCapacity(consumed - previousConsumed)
		while i != index {
			result.unicodeScalars.append(scalars[i])
			i = scalars.index(after: i)
		}
		
		return result
	}
	
	/// Peeks at the scalar at the current `index`, testing it with function `f`. If `f` returns `true`, the scalar is appended to a `String` and the `index` increased. The `String` is returned at the end.
	public mutating func readWhile(true test: (UnicodeScalar) -> Bool) -> String {
		var string = ""
		while index != scalars.endIndex {
			if !test(scalars[index]) {
				break
			}
			string.unicodeScalars.append(scalars[index])
			index = self.scalars.index(after: index)
			consumed += 1
		}
		return string
	}
	
	/// Repeatedly peeks at the scalar at the current `index`, testing it with function `f`. If `f` returns `true`, the `index` increased. If `false`, the function returns.
	public mutating func skipWhile(true test: (UnicodeScalar) -> Bool) {
		while index != scalars.endIndex {
			if !test(scalars[index]) {
				return
			}
			index = self.scalars.index(after: index)
			consumed += 1
		}
	}
	
	/// Consume scalars from the contained collection, up to but not including the first instance of `scalar` found. `index` is advanced to immediately before `scalar`. Throws if `scalar` is never found.
	public mutating func skipUntil(scalar: UnicodeScalar) throws {
		var i = index
		var c = 0
		while i != scalars.endIndex && scalars[i] != scalar {
			i = self.scalars.index(after: i)
			c += 1
		}
		if i == scalars.endIndex {
			throw ScalarScannerError.searchFailed(wanted: String(scalar), after: consumed)
		}
		index = i
		consumed += c
	}
	
	/// Consume scalars from the contained collection, up to but not including the first instance of any scalar from `set` is found. `index` is advanced to immediately before `scalar`. Throws if `scalar` is never found.
	public mutating func skipUntil(set inSet: Set<UnicodeScalar>) throws {
		var i = index
		var c = 0
		while i != scalars.endIndex && !inSet.contains(scalars[i]) {
			i = self.scalars.index(after: i)
			c += 1
		}
		if i == scalars.endIndex {
			throw ScalarScannerError.searchFailed(wanted: "One of: \(inSet.sorted())", after: consumed)
		}
		index = i
		consumed += c
	}
	
	/// Consume scalars from the contained collection, up to but not including the first instance of `string` found. `index` is advanced to immediately before `string`. Throws if `string` is never found.
	/// WARNING: `string` is used purely for its `unicodeScalars` property and matching is purely based on direct scalar comparison (no decomposition or normalization is performed).
	public mutating func skipUntil(string: String) throws {
		let match = string.unicodeScalars
		guard let first = match.first else { return }
		if match.count == 1 {
			return try skipUntil(scalar: first)
		}
		var i = index
		var j = index
		var c = 0
		var d = 0
		let remainder = match[match.index(after: match.startIndex)..<match.endIndex]
		outerLoop: repeat {
			while scalars[i] != first {
				if i == scalars.endIndex {
					throw ScalarScannerError.searchFailed(wanted: String(match), after: consumed)
				}
				i = self.scalars.index(after: i)
				c += 1
				
				// Track the last index and consume count before hitting the match
				j = i
				d = c
			}
			i = self.scalars.index(after: i)
			c += 1
			for s in remainder {
				if i == self.scalars.endIndex {
					throw ScalarScannerError.searchFailed(wanted: String(match), after: consumed)
				}
				if scalars[i] != s {
					continue outerLoop
				}
				i = self.scalars.index(after: i)
				c += 1
			}
			break
		} while true
		index = j
		consumed += d
	}
	
	/// Attempt to advance the `index` by count, returning `false` and `index` unchanged if `index` would advance past the end, otherwise returns `true` and `index` is advanced.
	public mutating func skip(count: Int = 1) throws {
		if count == 1 && index != scalars.endIndex {
			index = scalars.index(after: index)
			consumed += 1
		} else {
			var i = index
			var c = count
			while c > 0 {
				if i == scalars.endIndex {
					throw ScalarScannerError.endedPrematurely(count: count, at: consumed)
				}
				i = self.scalars.index(after: i)
				c -= 1
			}
			index = i
			consumed += count
		}
	}
	
	/// Attempt to advance the `index` by count, returning `false` and `index` unchanged if `index` would advance past the end, otherwise returns `true` and `index` is advanced.
	public mutating func backtrack(count: Int = 1) throws {
		if count <= consumed {
			if count == 1 {
				index = scalars.index(index, offsetBy: -1)
				consumed -= 1
			} else {
				let limit = consumed - count
				while consumed != limit {
					index = scalars.index(index, offsetBy: -1)
					consumed -= 1
				}
			}
		} else {
			throw ScalarScannerError.endedPrematurely(count: -count, at: consumed)
		}
	}
	
	/// Returns all content after the current `index`. `index` is advanced to the end.
	public mutating func remainder() -> String {
		var string: String = ""
		while index != scalars.endIndex {
			string.unicodeScalars.append(scalars[index])
			index = scalars.index(after: index)
			consumed += 1
		}
		return string
	}
	
	/// If the next scalars after the current `index` match `value`, advance over them and return `true`, otherwise, leave `index` unchanged and return `false`.
	/// WARNING: `string` is used purely for its `unicodeScalars` property and matching is purely based on direct scalar comparison (no decomposition or normalization is performed).
	public mutating func conditional(string: String) -> Bool {
		var i = index
		var c = 0
		for s in string.unicodeScalars {
			if i == scalars.endIndex || s != scalars[i] {
				return false
			}
			i = self.scalars.index(after: i)
			c += 1
		}
		index = i
		consumed += c
		return true
	}
	
	/// If the next scalar after the current `index` match `value`, advance over it and return `true`, otherwise, leave `index` unchanged and return `false`.
	public mutating func conditional(scalar: UnicodeScalar) -> Bool {
		if index == scalars.endIndex || scalar != scalars[index] {
			return false
		}
		index = self.scalars.index(after: index)
		consumed += 1
		return true
	}
	
	/// If the `index` is at the end, throw, otherwise, return the next scalar at the current `index` without advancing `index`.
	public func requirePeek() throws -> UnicodeScalar {
		if index == scalars.endIndex {
			throw ScalarScannerError.endedPrematurely(count: 1, at: consumed)
		}
		return scalars[index]
	}
	
	/// If `index` + `ahead` is within bounds, return the scalar at that location, otherwise return `nil`. The `index` will not be changed in any case.
	public func peek(skipCount: Int = 0) -> UnicodeScalar? {
		var i = index
		var c = skipCount
		while c > 0 && i != scalars.endIndex {
			i = self.scalars.index(after: i)
			c -= 1
		}
		if i == scalars.endIndex {
			return nil
		}
		return scalars[i]
	}
	
	/// If the `index` is at the end, throw, otherwise, return the next scalar at the current `index`, advancing `index` by one.
	public mutating func readScalar() throws -> UnicodeScalar {
		if index == scalars.endIndex {
			throw ScalarScannerError.endedPrematurely(count: 1, at: consumed)
		}
		let result = scalars[index]
		index = self.scalars.index(after: index)
		consumed += 1
		return result
	}
	
	/// Throws if scalar at the current `index` is not in the range `"0"` to `"9"`. Consume scalars `"0"` to `"9"` until a scalar outside that range is encountered. Return the integer representation of the value scanned, interpreted as a base 10 integer. `index` is advanced to the end of the number.
	public mutating func readInt() throws -> Int {
		var result = 0
		var i = index
		var c = 0
		while i != scalars.endIndex && scalars[i] >= "0" && scalars[i] <= "9" {
			result = result * 10 + Int(scalars[i].value - UnicodeScalar("0").value)
			i = self.scalars.index(after: i)
			c += 1
		}
		if i == index {
			throw ScalarScannerError.expectedInt(at: consumed)
		}
		index = i
		consumed += c
		return result
	}
	
	/// Consume and return `count` scalars. `index` will be advanced by count. Throws if end of `scalars` occurs before consuming `count` scalars.
	public mutating func readScalars(count: Int) throws -> String {
		var result = String()
		result.reserveCapacity(count)
		var i = index
		for _ in 0..<count {
			if i == scalars.endIndex {
				throw ScalarScannerError.endedPrematurely(count: count, at: consumed)
			}
			result.unicodeScalars.append(scalars[i])
			i = self.scalars.index(after: i)
		}
		index = i
		consumed += count
		return result
	}
	
	/// Returns a throwable error capturing the current scanner progress point.
	public func unexpectedError() -> ScalarScannerError {
		return ScalarScannerError.unexpected(at: consumed)
	}
	
	public var isAtEnd: Bool {
		return index == scalars.endIndex
	}
}
//
//  CwlSysctl.swift
//  CwlUtils
//
//  Created by Matt Gallagher on 2016/02/03.
//  Copyright © 2016 Matt Gallagher ( http://cocoawithlove.com ). All rights reserved.
//
//  Permission to use, copy, modify, and/or distribute this software for any
//  purpose with or without fee is hereby granted, provided that the above
//  copyright notice and this permission notice appear in all copies.
//
//  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
//  SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
//  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

import Foundation

public enum SysctlError: Error {
	case unknown
	case malformedUTF8
	case invalidSize
	case posixError(POSIXErrorCode)
}

/// Wrapper around `sysctl` that preflights and allocates an [Int8] for the result and throws a Swift error if anything goes wrong.
public func sysctl(levels: [Int32]) throws -> [Int8] {
	return try levels.withUnsafeBufferPointer() { levelsPointer throws -> [Int8] in
		// Preflight the request to get the required data size
		var requiredSize = 0
		let preFlightResult = Darwin.sysctl(UnsafeMutablePointer<Int32>(mutating: levelsPointer.baseAddress), UInt32(levels.count), nil, &requiredSize, nil, 0)
		if preFlightResult != 0 {
			throw POSIXErrorCode(rawValue: errno).map { SysctlError.posixError($0) } ?? SysctlError.unknown
		}
		
		// Run the actual request with an appropriately sized array buffer
		let data = Array<Int8>(repeating: 0, count: requiredSize)
		let result = data.withUnsafeBufferPointer() { dataBuffer -> Int32 in
			return Darwin.sysctl(UnsafeMutablePointer<Int32>(mutating: levelsPointer.baseAddress), UInt32(levels.count), UnsafeMutableRawPointer(mutating: dataBuffer.baseAddress), &requiredSize, nil, 0)
		}
		if result != 0 {
			throw POSIXErrorCode(rawValue: errno).map { SysctlError.posixError($0) } ?? SysctlError.unknown
		}
		
		return data
	}
}

/// Generate an array of name levels (as can be used with the previous sysctl function) from a sysctl name string.
public func sysctlLevels(fromName: String) throws -> [Int32] {
	var levelsBufferSize = Int(CTL_MAXNAME)
	var levelsBuffer = Array<Int32>(repeating: 0, count: levelsBufferSize)
	try levelsBuffer.withUnsafeMutableBufferPointer { (lbp: inout UnsafeMutableBufferPointer<Int32>) throws in
		try fromName.withCString { (nbp: UnsafePointer<Int8>) throws in
			guard sysctlnametomib(nbp, lbp.baseAddress, &levelsBufferSize) == 0 else {
				throw POSIXErrorCode(rawValue: errno).map { SysctlError.posixError($0) } ?? SysctlError.unknown
			}
		}
	}
	if levelsBuffer.count > levelsBufferSize {
		levelsBuffer.removeSubrange(levelsBufferSize..<levelsBuffer.count)
	}
	return levelsBuffer
}

// Helper function used by the various int from sysctl functions, below
private func intFromSysctl(levels: [Int32]) throws -> Int64 {
	let buffer = try sysctl(levels: levels)
	switch buffer.count {
	case 4: return buffer.withUnsafeBufferPointer() { $0.baseAddress.map { $0.withMemoryRebound(to: Int32.self, capacity: 1) { Int64($0.pointee) } } ?? 0 }
	case 8: return buffer.withUnsafeBufferPointer() { $0.baseAddress.map {$0.withMemoryRebound(to: Int64.self, capacity: 1) { $0.pointee } } ?? 0 }
	default: throw SysctlError.invalidSize
	}
}

// Helper function used by the string from sysctl functions, below
private func stringFromSysctl(levels: [Int32]) throws -> String {
	let optionalString = try sysctl(levels: levels).withUnsafeBufferPointer() { dataPointer -> String? in
		dataPointer.baseAddress.flatMap { String(validatingUTF8: $0) }
	}
	guard let s = optionalString else {
		throw SysctlError.malformedUTF8
	}
	return s
}

/// Get an arbitrary sysctl value and interpret the bytes as a UTF8 string
public func sysctlString(levels: Int32...) throws -> String {
	return try stringFromSysctl(levels: levels)
}

/// Get an arbitrary sysctl value and interpret the bytes as a UTF8 string
public func sysctlString(name: String) throws -> String {
	return try stringFromSysctl(levels: sysctlLevels(fromName: name))
}

/// Get an arbitrary sysctl value and cast it to an Int64
public func sysctlInt(levels: Int32...) throws -> Int64 {
	return try intFromSysctl(levels: levels)
}

/// Get an arbitrary sysctl value and cast it to an Int64
public func sysctlInt(name: String) throws -> Int64 {
	return try intFromSysctl(levels: sysctlLevels(fromName: name))
}

public struct Sysctl {
	/// e.g. "MyComputer.local" (from System Preferences -> Sharing -> Computer Name) or
	/// "My-Name-iPhone" (from Settings -> General -> About -> Name)
	public static var hostName: String { return try! sysctlString(levels: CTL_KERN, KERN_HOSTNAME) }
	
	/// e.g. "x86_64" or "N71mAP"
	/// NOTE: this is *corrected* on iOS devices to fetch hw.model
	public static var machine: String {
		#if os(iOS) && !arch(x86_64) && !arch(i386)
			return try! sysctlString(levels: CTL_HW, HW_MODEL)
		#else
			return try! sysctlString(levels: CTL_HW, HW_MACHINE)
		#endif
	}
	
	/// e.g. "MacPro4,1" or "iPhone8,1"
	/// NOTE: this is *corrected* on iOS devices to fetch hw.machine
	public static var model: String {
		#if os(iOS) && !arch(x86_64) && !arch(i386)
			return try! sysctlString(levels: CTL_HW, HW_MACHINE)
		#else
			return try! sysctlString(levels: CTL_HW, HW_MODEL)
		#endif
	}
	
	/// e.g. "8" or "2"
	public static var activeCPUs: Int64 { return try! sysctlInt(levels: CTL_HW, HW_AVAILCPU) }
	
	/// e.g. "15.3.0" or "15.0.0"
	public static var osRelease: String { return try! sysctlString(levels: CTL_KERN, KERN_OSRELEASE) }
	
	/// e.g. 199506 or 199506
	public static var osRev: Int64 { return try! sysctlInt(levels: CTL_KERN, KERN_OSREV) }
	
	/// e.g. "Darwin" or "Darwin"
	public static var osType: String { return try! sysctlString(levels: CTL_KERN, KERN_OSTYPE) }
	
	/// e.g. "15D21" or "13D20"
	public static var osVersion: String { return try! sysctlString(levels: CTL_KERN, KERN_OSVERSION) }
	
	/// e.g. "Darwin Kernel Version 15.3.0: Thu Dec 10 18:40:58 PST 2015; root:xnu-3248.30.4~1/RELEASE_X86_64" or
	/// "Darwin Kernel Version 15.0.0: Wed Dec  9 22:19:38 PST 2015; root:xnu-3248.31.3~2/RELEASE_ARM64_S8000"
	public static var version: String { return try! sysctlString(levels: CTL_KERN, KERN_VERSION) }
	
	#if os(macOS)
		/// e.g. 2659000000 (not available on iOS)
		public static var cpuFreq: Int64 { return try! sysctlInt(name: "hw.cpufrequency") }

		/// e.g. 25769803776 (not available on iOS)
		public static var memSize: Int64 { return try! sysctlInt(levels: CTL_HW, HW_MEMSIZE) }
	#endif
}
//
//  CwlWrappers.swift
//  CwlUtils
//
//  Created by Matt Gallagher on 2015/02/03.
//  Copyright © 2015 Matt Gallagher ( http://cocoawithlove.com ). All rights reserved.
//
//  Permission to use, copy, modify, and/or distribute this software for any
//  purpose with or without fee is hereby granted, provided that the above
//  copyright notice and this permission notice appear in all copies.
//
//  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
//  SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
//  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

import Foundation

/// A class wrapper around a type (usually a value type) so it can be moved without copying but also so that it can be passed through Objective-C parameters.
public class Box<T> {
	public let value: T
	public init(_ t: T) {
		value = t
	}
}

//// A class wrapper around a type (usually a value type) so changes to it can be shared (usually as an ad hoc communication channel). NOTE: this version is *not* threadsafe, use AtomicBox for that.
public final class MutableBox<T> {
	public var value: T
	public init(_ t: T) {
		value = t
	}
}

// A class wrapper around a type (usually a value type) so changes to it can be shared in a thread-safe manner (usually as an ad hoc communication channel).
/// "Atomic" in this sense refers to the semantics, not the implementation. This uses a pthread mutex, not CAS-style atomic operations.
public final class AtomicBox<T> {
	private var mutex = PThreadMutex()
	private var internalValue: T
	
	public init(_ t: T) {
		internalValue = t
	}
	
	public var value: T {
		get {
			mutex.unbalancedLock()
			defer { mutex.unbalancedUnlock() }
			return internalValue
		}
		set {
			mutex.unbalancedLock()
			defer { mutex.unbalancedUnlock() }
			internalValue = newValue
		}
	}

	@discardableResult
	public func mutate(_ f: (inout T) throws -> Void) rethrows -> T {
		mutex.unbalancedLock()
		defer { mutex.unbalancedUnlock() }
		try f(&internalValue)
		return internalValue
	}
}

/// A wrapper around a type (usually a class type) so it can be weakly referenced from an Array or other strong container.
public struct Weak<T: AnyObject> {
	public weak var value: T?
	
	public init(_ value: T?) {
		self.value = value
	}
	
	public func contains(_ other: T) -> Bool {
		if let v = value {
			return v === other
		} else {
			return false
		}
	}
}

/// A wrapper around a type (usually a class type) so it can be referenced unowned from an Array or other strong container.
public struct Unowned<T: AnyObject> {
	public unowned let value: T
	public init(_ value: T) {
		self.value = value
	}
}

/// A enum wrapper around a type (usually a class type) so its ownership can be set at runtime.
public enum PossiblyWeak<T: AnyObject> {
	case strong(T)
	case weak(Weak<T>)
	
	public init(strong value: T) {
		self = PossiblyWeak<T>.strong(value)
	}
	
	public init(weak value: T) {
		self = PossiblyWeak<T>.weak(Weak(value))
	}
	
	public var value: T? {
		switch self {
		case .strong(let t): return t
		case .weak(let weakT): return weakT.value
		}
	}
	
	public func contains(_ other: T) -> Bool {
		switch self {
		case .strong(let t): return t === other
		case .weak(let weakT):
			if let wt = weakT.value {
				return wt === other
			}
			return false
		}
	}
}
