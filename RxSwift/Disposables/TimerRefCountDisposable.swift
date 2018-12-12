//
//  TimerRefCountDisposable.swift
//  RxSwift
//
//

open class TimerRefCountDisposable : DisposeBase, Cancelable {
    private var _lock = SpinLock()
    private var _disposable = nil as Disposable?
    private var _primaryDisposed = false
    private var _isWaitingDisposal = false
    private var _count = 0

    public var count: Int {
        _lock.lock(); defer { _lock.unlock() }
        return _count
    }

    /// - returns: Was resource disposed.
    public var isDisposed: Bool {
        _lock.lock(); defer { _lock.unlock() }
        return _disposable == nil
    }

    private var isWaitingDisposal: Bool {
        _lock.lock(); defer { _lock.unlock() }
        return _isWaitingDisposal
    }

    /// Initializes a new instance of the `TimerRefCountDisposable`.
    public init(disposable: Disposable) {
        _disposable = disposable
        super.init()
    }

    /**
     Holds a dependent disposable that when disposed decreases the refcount on the underlying disposable.

     When getter is called, a dependent disposable contributing to the reference count that manages the underlying disposable's lifetime is returned.
     */
    public func retain() -> Disposable {
        return _lock.calculateLocked {
            if let disposable = _disposable {

                do {
                    let _ = try incrementChecked(&_count)
                    print("Count at \(self._count)")
                } catch (_) {
                    rxFatalError("TimerRefCountDisposable increment failed")
                }

                return TimerRefCountInnerDisposable(self)
            } else {
                return Disposables.create()
            }
        }
    }

    private var _disposeTimer: Timer?

    fileprivate func getOldDisposable() -> Disposable? {
        let oldDisposable: Disposable? = self._lock.calculateLocked({ () in
            if let oldDisposable = self._disposable, !self._primaryDisposed
            {
                self._primaryDisposed = true

                if (self._count == 0) {
                    return oldDisposable
                }
            }

            return nil
        })

        return oldDisposable
    }

    /// Disposes the underlying disposable only when all dependent disposables have been disposed.
    public func dispose() {
        if #available(iOS 10.0, *) {
            self._disposeTimer?.invalidate()
            let oldDisposable: Disposable? = self.getOldDisposable()

            if let oldDisposable = oldDisposable {
                self._disposeTimer = Timer.scheduledTimer(withTimeInterval: 120.0, repeats: false, block: { (timer) in
                    let oldDisposable: Disposable? = self.getOldDisposable()

                    if let oldDisposable = oldDisposable {
                        self._disposable = nil
                        oldDisposable.dispose()
                    }
                })
            }
        }
    }

    private var _releaseTimer: Timer?

    fileprivate func getReleaseOldDisposable() -> Disposable? {
        let oldDisposable: Disposable? = self._lock.calculateLocked {
            if let oldDisposable = self._disposable {
                if self._count == 0 {
                    return oldDisposable
                }
            }

            return nil
        }

        return oldDisposable
    }

    fileprivate func release() {
        if #available(iOS 10.0, *) {
            self._releaseTimer?.invalidate()

            if self._disposable != nil {
                do {
                    let _ = try decrementChecked(&self._count)
                } catch (_) {
                    rxFatalError("TimerRefCountDisposable decrement on release failed")
                }

                guard self._count >= 0 else {
                    rxFatalError("TimerRefCountDisposable counter is lower than 0")
                }
            }

            var initalOldDisposable = self.getReleaseOldDisposable()

            if let initalDisposable = initalOldDisposable {
                self._releaseTimer = Timer.scheduledTimer(withTimeInterval: 120.0, repeats: false, block: { (timer) in
                    var currentOldDisposable = self.getReleaseOldDisposable()
                    if let currentDisposable = currentOldDisposable {
                        print("Count at \(self._count)")

                        if !self._primaryDisposed {
                            if let oldDisposable = self._disposable {
                                oldDisposable.dispose()
                            }
                        }

                        self._disposable = nil
                        currentDisposable.dispose()
                    }
                })
            }
        }
    }
}

internal final class TimerRefCountInnerDisposable: DisposeBase, Disposable
{
    private let _parent: TimerRefCountDisposable
    private var _isDisposed: AtomicInt = 0

    init(_ parent: TimerRefCountDisposable)
    {
        _parent = parent
        super.init()
    }

    internal func dispose()
    {
        if AtomicCompareAndSwap(0, 1, &_isDisposed) {
            _parent.release()
        }
    }
}
