// DevFormel Trace, https://devformel.com/trace/
// Copyright (c) 2026 Dennis Powering.
// SPDX-License-Identifier: MPL-2.0
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

unit DevFormel.Trace.Engine;

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  DevFormel.Trace.Types;

type
  /// <summary>
  /// Queue entry: a trace event plus the settings of the hub at the time it was submitted.
  /// </summary>
  /// <exclude/>
  TDFQueuedEvent = record
    /// <summary>The event to dispatch.</summary>
    Event: TDFTraceEvent;
    /// <summary>True if the worker thread must remove personal data before dispatching.</summary>
    Scrub: Boolean;
    /// <summary>True if only sinks that implement IDFLocalSink receive the event.</summary>
    LocalOnly: Boolean;
  end;

  /// <summary>
  /// Thread-safe bounded ring buffer for asynchronously queuing telemetry events.
  /// When full, a new event below Error is discarded; an Error or Fatal event replaces the oldest.
  /// </summary>
  /// <exclude/>
  TDFBoundedEventQueue = class
  private
    FBuffer: TArray<TDFQueuedEvent>;
    FCapacity: Integer;
    FHead: Integer;
    FTail: Integer;
    FCount: Integer;
    FInFlight: Integer;
    FDroppedCount: UInt64;
    FLock: TCriticalSection;
    FNotEmptyEvent: TEvent;
    FIsEmptyEvent: TEvent;
    function GetCount: Integer;
    function GetDroppedCount: UInt64;
    procedure SetCapacity(ACapacity: Integer);
  public
    /// <summary>
    /// Initializes a new instance of the bounded event queue.
    /// </summary>
    /// <param name="ACapacity">Maximum number of events allowed in buffer before dropping oldest items.</param>
    constructor Create(ACapacity: Integer = 10000);
    destructor Destroy; override;

    /// <summary>
    /// Pushes an event into the queue.
    /// </summary>
    /// <remarks>
    /// When the queue is full, a new event below Error is discarded; an Error or Fatal event
    /// replaces the oldest event instead. Both cases are counted in DroppedCount.
    /// </remarks>
    /// <param name="AItem">The queue entry to enqueue.</param>
    procedure Push(const AItem: TDFQueuedEvent);

    /// <summary>
    /// Attempts to dequeue the next event from the queue.
    /// </summary>
    /// <param name="AItem">Receives the popped queue entry if successful.</param>
    /// <returns>True if an item was retrieved; False if the queue was empty.</returns>
    /// <remarks>Every successful call must be followed by <c>EndDispatch</c>.</remarks>
    function Pop(out AItem: TDFQueuedEvent): Boolean;

    /// <summary>
    /// Marks the item returned by the last successful <c>Pop</c> as dispatched.
    /// </summary>
    /// <remarks>
    /// Without this step, <c>WaitForEmpty</c> would return as soon as the last item leaves the
    /// buffer, while it is still being written by the sinks.
    /// </remarks>
    procedure EndDispatch;

    /// <summary>
    /// Blocks execution until all queued events have been dispatched or timeout occurs.
    /// </summary>
    /// <param name="ATimeoutMS">Maximum duration in milliseconds to wait.</param>
    /// <returns>True if all events were dispatched; False if timed out.</returns>
    function WaitForEmpty(ATimeoutMS: Integer): Boolean;

    /// <summary>
    /// Waits for new items to arrive in the queue.
    /// </summary>
    /// <param name="ATimeoutMS">Maximum duration in milliseconds to wait.</param>
    /// <returns>Wait result status indicating whether signal occurred or timed out.</returns>
    function WaitForData(ATimeoutMS: Integer): TWaitResult;

    /// <summary>
    /// Signals waiting worker threads to wake up without enqueueing data (used during shutdown).
    /// </summary>
    procedure SignalWakeup;

    /// <summary>Clears all items currently held in the buffer.</summary>
    procedure Clear;

    /// <summary>Counts an event that was taken from the queue but not dispatched.</summary>
    procedure AddDropped;

    /// <summary>Maximum number of events in the queue.</summary>
    /// <value>Maximum allowed element count, at least 1.</value>
    /// <remarks>Can be changed while the queue is in use. When reduced below the current count,
    /// the oldest events are discarded and counted in DroppedCount, as Push does when full.</remarks>
    property Capacity: Integer read FCapacity write SetCapacity;

    /// <summary>Gets the current number of events pending in the queue.</summary>
    /// <value>Current queued element count.</value>
    property Count: Integer read GetCount;

    /// <summary>Gets the total count of events dropped due to buffer overflow since creation.</summary>
    /// <value>64-bit unsigned integer counter of dropped events.</value>
    property DroppedCount: UInt64 read GetDroppedCount;
  end;

  TDFTraceEngine = class;

  /// <summary>
  /// Dedicated background thread responsible for popping events from queue and dispatching to registered sinks.
  /// </summary>
  /// <exclude/>
  TDFWorkerThread = class(TThread)
  private
    FEngine: TDFTraceEngine;
    procedure ProcessQueue;
  protected
    procedure Execute; override;
  public
    /// <summary>
    /// Creates and immediately starts the worker thread instance.
    /// </summary>
    /// <param name="AEngine">The parent trace engine instance providing queue and sinks.</param>
    constructor Create(AEngine: TDFTraceEngine);
  end;

  /// <summary>
  /// Core orchestration engine coordinating asynchronous event queuing and multi-sink dispatching.
  /// </summary>
  /// <remarks>Used internally by <c>TDFTraceHub</c>.</remarks>
  /// <exclude/>
  TDFTraceEngine = class
  private
    FQueue: TDFBoundedEventQueue;
    FSinks: TList<IDFTraceSink>;
    FSinksLock: TCriticalSection;
    // Held by the worker while it dispatches one event. UnregisterSink takes it as well,
    // so a sink is never freed while the worker still holds a reference to it.
    FDispatchLock: TCriticalSection;
    FWorkerThread: TDFWorkerThread;
    FShutdownTimeoutMS: Integer;
    FShutdownDeadline: UInt64;
    procedure DispatchToSinks(const AEvent: TDFTraceEvent; ALocalOnly: Boolean);
    function ShutdownDeadlinePassed: Boolean;
    function GetQueueCount: Integer;
    function GetDroppedCount: UInt64;
    function GetMaxQueueSize: Integer;
    procedure SetMaxQueueSize(AValue: Integer);
  public const
    /// <summary>Longest message, exception message, tag value and extra value, in characters.</summary>
    MaxTextLength = 8000;
    /// <summary>Longest message and category of a breadcrumb, in characters.</summary>
    MaxBreadcrumbLength = 1000;
  public
    /// <summary>
    /// Cuts a text that is longer than the limit and marks it with [truncated].
    /// </summary>
    /// <param name="AText">The text to check.</param>
    /// <param name="AMaxLength">Number of characters to keep at most; the mark is added to it.</param>
    /// <returns>The text itself if it is short enough, otherwise its beginning and the mark.</returns>
    class function LimitText(const AText: string; AMaxLength: Integer): string; static;

    /// <summary>
    /// Applies MaxTextLength to message, exception message, tag values and extra values.
    /// </summary>
    /// <param name="AEvent">The event, changed in place.</param>
    class procedure LimitEventTexts(var AEvent: TDFTraceEvent); static;

    /// <summary>
    /// Initializes the trace engine and spawns the background dispatch thread.
    /// </summary>
    /// <param name="AMaxQueueSize">Maximum capacity of the internal ring buffer.</param>
    constructor Create(AMaxQueueSize: Integer = 10000);
    destructor Destroy; override;

    /// <summary>
    /// Enqueues an event for asynchronous processing.
    /// </summary>
    /// <param name="AEvent">The trace event structure to dispatch.</param>
    /// <param name="AScrub">True if the worker thread must remove personal data before dispatching.</param>
    /// <param name="ALocalOnly">True if only sinks that implement IDFLocalSink receive the event.</param>
    procedure PostEvent(const AEvent: TDFTraceEvent; AScrub, ALocalOnly: Boolean);

    /// <summary>
    /// Registers an output sink instance with the engine dispatch list.
    /// </summary>
    /// <param name="ASink">The sink interface implementation to add.</param>
    procedure RegisterSink(const ASink: IDFTraceSink);

    /// <summary>
    /// Removes an output sink instance from the engine dispatch list.
    /// </summary>
    /// <param name="ASink">The sink interface instance to remove.</param>
    /// <remarks>
    /// Waits until the worker has finished dispatching the current event, so the sink can be
    /// freed right afterwards. Because the calling thread is often the main thread, <c>Emit</c>
    /// must not wait for the main thread (for example with <c>TThread.Synchronize</c>).
    /// </remarks>
    procedure UnregisterSink(const ASink: IDFTraceSink);

    /// <summary>
    /// Blocks the calling thread until all queued events have been passed to the sinks or the timeout expires.
    /// </summary>
    /// <param name="ATimeoutMS">Maximum wait duration in milliseconds.</param>
    /// <returns>True if all events were dispatched within the timeout.</returns>
    function Flush(ATimeoutMS: Integer = 2000): Boolean;

    /// <summary>Gets the number of events waiting to be dispatched.</summary>
    property QueueCount: Integer read GetQueueCount;

    /// <summary>Maximum number of events waiting to be dispatched; see TDFBoundedEventQueue.Capacity.</summary>
    property MaxQueueSize: Integer read GetMaxQueueSize write SetMaxQueueSize;

    /// <summary>Gets the number of events discarded because the queue was full or the shutdown timeout expired.</summary>
    property DroppedCount: UInt64 read GetDroppedCount;

    /// <summary>
    /// Maximum time in milliseconds that Destroy spends passing queued events to the sinks.
    /// </summary>
    /// <remarks>
    /// Events still queued when the time is up are discarded and counted in <c>DroppedCount</c>.
    /// A sink call that is already running cannot be interrupted and may exceed the limit.
    /// </remarks>
    property ShutdownTimeoutMS: Integer read FShutdownTimeoutMS write FShutdownTimeoutMS;
  end;

implementation

uses
  System.Math,
  DevFormel.Trace.Sanitizer;

{ TDFBoundedEventQueue }

constructor TDFBoundedEventQueue.Create(ACapacity: Integer);
begin
  inherited Create;
  FCapacity := Max(1, ACapacity);
  SetLength(FBuffer, FCapacity);
  FHead := 0;
  FTail := 0;
  FCount := 0;
  FInFlight := 0;
  FDroppedCount := 0;
  FLock := TCriticalSection.Create;
  // Auto-reset event for signaling available data
  FNotEmptyEvent := TEvent.Create(nil, False, False, '');
  // Manual-reset event for signaling empty state (Initial state: Signaled)
  FIsEmptyEvent := TEvent.Create(nil, True, True, '');
end;

destructor TDFBoundedEventQueue.Destroy;
begin
  Clear;
  FreeAndNil(FLock);
  FreeAndNil(FNotEmptyEvent);
  FreeAndNil(FIsEmptyEvent);
  inherited Destroy;
end;

procedure TDFBoundedEventQueue.SetCapacity(ACapacity: Integer);
var
  NewBuffer: TArray<TDFQueuedEvent>;
  Keep, Skip, I: Integer;
begin
  ACapacity := Max(1, ACapacity);

  FLock.Enter;
  try
    if ACapacity = FCapacity then
      Exit;

    // Keep the newest events, as Push does when the queue is full
    Keep := Min(FCount, ACapacity);
    Skip := FCount - Keep;

    SetLength(NewBuffer, ACapacity);
    for I := 0 to Keep - 1 do
      NewBuffer[I] := FBuffer[(FHead + Skip + I) mod FCapacity];

    // Releasing the old buffer also releases the strings of the discarded events
    FBuffer := NewBuffer;
    FCapacity := ACapacity;
    FHead := 0;
    FTail := Keep mod ACapacity;
    FCount := Keep;
    Inc(FDroppedCount, Skip);
  finally
    FLock.Leave;
  end;
end;

procedure TDFBoundedEventQueue.Push(const AItem: TDFQueuedEvent);
begin
  FLock.Enter;
  try
    if FCount = FCapacity then
    begin
      // A flood of debug messages must not push out the error that matters, so only errors
      // make room for themselves
      if AItem.Event.Level < TDFLogLevel.Error then
      begin
        Inc(FDroppedCount);
        Exit;
      end;

      // Drop oldest element: Overwriting or re-assigning releases reference-counted fields automatically
      FBuffer[FHead] := Default(TDFQueuedEvent);
      FHead := (FHead + 1) mod FCapacity;
      Dec(FCount);
      Inc(FDroppedCount);
    end;

    if FCount = 0 then
      FIsEmptyEvent.ResetEvent;

    FBuffer[FTail] := AItem;
    FTail := (FTail + 1) mod FCapacity;
    Inc(FCount);

    FNotEmptyEvent.SetEvent;
  finally
    FLock.Leave;
  end;
end;

function TDFBoundedEventQueue.Pop(out AItem: TDFQueuedEvent): Boolean;
begin
  FLock.Enter;
  try
    if FCount = 0 then
    begin
      Result := False;
      Exit;
    end;

    AItem := FBuffer[FHead];
    // Free dynamic strings/arrays held by the record immediately
    FBuffer[FHead] := Default(TDFQueuedEvent);
    FHead := (FHead + 1) mod FCapacity;
    Dec(FCount);
    Inc(FInFlight);

    if FCount = 0 then
      FNotEmptyEvent.ResetEvent;

    Result := True;
  finally
    FLock.Leave;
  end;
end;

procedure TDFBoundedEventQueue.EndDispatch;
begin
  FLock.Enter;
  try
    if FInFlight > 0 then
      Dec(FInFlight);

    if (FCount = 0) and (FInFlight = 0) then
      FIsEmptyEvent.SetEvent;
  finally
    FLock.Leave;
  end;
end;

function TDFBoundedEventQueue.WaitForEmpty(ATimeoutMS: Integer): Boolean;
begin
  Result := FIsEmptyEvent.WaitFor(ATimeoutMS) = wrSignaled;
end;

function TDFBoundedEventQueue.WaitForData(ATimeoutMS: Integer): TWaitResult;
begin
  Result := FNotEmptyEvent.WaitFor(ATimeoutMS);
end;

procedure TDFBoundedEventQueue.SignalWakeup;
begin
  FNotEmptyEvent.SetEvent;
end;

procedure TDFBoundedEventQueue.Clear;
var
  I: Integer;
begin
  FLock.Enter;
  try
    for I := 0 to FCapacity - 1 do
      FBuffer[I] := Default(TDFQueuedEvent);

    FHead := 0;
    FTail := 0;
    FCount := 0;
    FNotEmptyEvent.ResetEvent;
    if FInFlight = 0 then
      FIsEmptyEvent.SetEvent;
  finally
    FLock.Leave;
  end;
end;

procedure TDFBoundedEventQueue.AddDropped;
begin
  FLock.Enter;
  try
    Inc(FDroppedCount);
  finally
    FLock.Leave;
  end;
end;

function TDFBoundedEventQueue.GetCount: Integer;
begin
  FLock.Enter;
  try
    Result := FCount;
  finally
    FLock.Leave;
  end;
end;

function TDFBoundedEventQueue.GetDroppedCount: UInt64;
begin
  FLock.Enter;
  try
    Result := FDroppedCount;
  finally
    FLock.Leave;
  end;
end;

{ TDFWorkerThread }

constructor TDFWorkerThread.Create(AEngine: TDFTraceEngine);
begin
  inherited Create(False); // Start immediately
  FEngine := AEngine;
  FreeOnTerminate := False;
end;

procedure TDFWorkerThread.ProcessQueue;
var
  Item: TDFQueuedEvent;
begin
  while FEngine.FQueue.Pop(Item) do
  begin
    try
      if FEngine.ShutdownDeadlinePassed then
        FEngine.FQueue.AddDropped
      else
      begin
        // Before scrubbing and for every event: the limit bounds the time the patterns
        // need, the memory of waiting events and the size of what the sinks send.
        TDFTraceEngine.LimitEventTexts(Item.Event);
        // Scrubbing runs here and not in the calling thread: the sanitizer then runs on
        // one thread only, and callers do not wait for the regular expressions.
        if Item.Scrub then
          TDFPIISanitizer.ScrubEvent(Item.Event);
        FEngine.DispatchToSinks(Item.Event, Item.LocalOnly);
      end;
    finally
      FEngine.FQueue.EndDispatch;
    end;
  end;
end;

procedure TDFWorkerThread.Execute;
begin
  while not Terminated do
  begin
    if FEngine.FQueue.WaitForData(100) = wrSignaled then
      ProcessQueue;
  end;

  // Finalization drain loop: Process remaining queued items before shutting down
  ProcessQueue;
end;

{ TDFTraceEngine }

function TDFTraceEngine.GetMaxQueueSize: Integer;
begin
  Result := FQueue.Capacity;
end;

procedure TDFTraceEngine.SetMaxQueueSize(AValue: Integer);
begin
  FQueue.Capacity := AValue;
end;

constructor TDFTraceEngine.Create(AMaxQueueSize: Integer);
begin
  inherited Create;
  FQueue := TDFBoundedEventQueue.Create(AMaxQueueSize);
  FSinks := TList<IDFTraceSink>.Create;
  FSinksLock := TCriticalSection.Create;
  FDispatchLock := TCriticalSection.Create;
  FShutdownTimeoutMS := 2000;
  FShutdownDeadline := 0;
  FWorkerThread := TDFWorkerThread.Create(Self);
end;

destructor TDFTraceEngine.Destroy;
begin
  // 1. Terminate background worker thread cleanly
  if Assigned(FWorkerThread) then
  begin
    // Set before Terminate, so the final drain loop already runs against the deadline.
    FShutdownDeadline := TThread.GetTickCount64 + UInt64(Max(0, FShutdownTimeoutMS));
    FWorkerThread.Terminate;
    FQueue.SignalWakeup;
    FWorkerThread.WaitFor;
    FreeAndNil(FWorkerThread);
  end;

  // 2. Clean up collections and locks
  FreeAndNil(FSinks);
  FreeAndNil(FSinksLock);
  FreeAndNil(FDispatchLock);
  FreeAndNil(FQueue);

  inherited Destroy;
end;

class function TDFTraceEngine.LimitText(const AText: string; AMaxLength: Integer): string;
const
  Marker = ' [truncated]';
  // How far the cut may move back to reach the end of a word
  MaxStepBack = 200;
var
  Cut, I: Integer;
begin
  if Length(AText) <= AMaxLength then
    Exit(AText);

  Cut := Max(AMaxLength, 1);
  // A cut inside a word could leave half of an e-mail or IP address, which the sanitizer
  // would no longer recognize. Whitespace right after the cut means the last word is
  // complete; otherwise the cut moves back to the end of the word before.
  for I := Cut + 1 downto Max(Cut + 2 - MaxStepBack, 2) do
    if AText[I] <= ' ' then
    begin
      Cut := I - 1;
      Break;
    end;

  // One long word without whitespace is cut at the limit; half a surrogate pair would
  // be invalid text
  if (Cut > 1) and (AText[Cut] >= #$D800) and (AText[Cut] <= #$DBFF) then
    Dec(Cut);

  Result := Copy(AText, 1, Cut) + Marker;
end;

class procedure TDFTraceEngine.LimitEventTexts(var AEvent: TDFTraceEvent);
var
  I: Integer;
begin
  // The stack trace is left alone: its size is bounded by the number of frames, and a cut
  // would remove the callers. Breadcrumbs are limited when they are added.
  AEvent.Message := LimitText(AEvent.Message, MaxTextLength);
  AEvent.ExceptionMessage := LimitText(AEvent.ExceptionMessage, MaxTextLength);
  for I := 0 to High(AEvent.Tags) do
    AEvent.Tags[I].Value := LimitText(AEvent.Tags[I].Value, MaxTextLength);
  for I := 0 to High(AEvent.Extra) do
    AEvent.Extra[I].Value := LimitText(AEvent.Extra[I].Value, MaxTextLength);
end;

procedure TDFTraceEngine.PostEvent(const AEvent: TDFTraceEvent; AScrub, ALocalOnly: Boolean);
var
  Item: TDFQueuedEvent;
begin
  Item.Event := AEvent;
  Item.Scrub := AScrub;
  Item.LocalOnly := ALocalOnly;
  FQueue.Push(Item);
end;

procedure TDFTraceEngine.RegisterSink(const ASink: IDFTraceSink);
begin
  if not Assigned(ASink) then Exit;

  FSinksLock.Enter;
  try
    if not FSinks.Contains(ASink) then
      FSinks.Add(ASink);
  finally
    FSinksLock.Leave;
  end;
end;

procedure TDFTraceEngine.UnregisterSink(const ASink: IDFTraceSink);
begin
  if not Assigned(ASink) then Exit;

  FDispatchLock.Enter;
  try
    FSinksLock.Enter;
    try
      FSinks.Remove(ASink);
    finally
      FSinksLock.Leave;
    end;
  finally
    FDispatchLock.Leave;
  end;
end;

function TDFTraceEngine.Flush(ATimeoutMS: Integer): Boolean;
begin
  Result := FQueue.WaitForEmpty(ATimeoutMS);
end;

function TDFTraceEngine.ShutdownDeadlinePassed: Boolean;
begin
  Result := (FShutdownDeadline > 0) and (TThread.GetTickCount64 >= FShutdownDeadline);
end;

function TDFTraceEngine.GetQueueCount: Integer;
begin
  Result := FQueue.Count;
end;

function TDFTraceEngine.GetDroppedCount: UInt64;
begin
  Result := FQueue.DroppedCount;
end;

procedure TDFTraceEngine.DispatchToSinks(const AEvent: TDFTraceEvent; ALocalOnly: Boolean);
var
  LocalSinks: TArray<IDFTraceSink>;
  Sink: IDFTraceSink;
begin
  FDispatchLock.Enter;
  try
    // Copy, so that RegisterSink does not have to wait for a slow sink
    FSinksLock.Enter;
    try
      LocalSinks := FSinks.ToArray;
    finally
      FSinksLock.Leave;
    end;

    try
      for Sink in LocalSinks do
      begin
        // A sink without the marker counts as remote, so a forgotten marker withholds data
        // instead of sending it
        if Assigned(Sink) and Sink.Enabled and (AEvent.Level >= Sink.MinLevel) and
          (not ALocalOnly or Supports(Sink, IDFLocalSink)) then
        begin
          try
            Sink.Emit(AEvent);
          except
            // A faulty sink must neither end the worker thread nor keep the event from the
            // other sinks
          end;
        end;
      end;
    finally
      // Release the references while the lock is still held: once UnregisterSink
      // returns, the sink may already be freed.
      Sink := nil;
      LocalSinks := nil;
    end;
  finally
    FDispatchLock.Leave;
  end;
end;

end.
