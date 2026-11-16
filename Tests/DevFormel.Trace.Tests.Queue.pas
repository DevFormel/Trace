// DevFormel Trace, https://devformel.com/trace/
// Copyright (c) 2026 Dennis Powering.
// SPDX-License-Identifier: MPL-2.0
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

unit DevFormel.Trace.Tests.Queue;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TQueueTests = class
  public
    [Test]
    procedure Push_WhenFull_DiscardsNewEventBelowError;

    [Test]
    procedure Push_WhenFull_ErrorReplacesOldest;

    [Test]
    procedure Capacity_Reduced_KeepsNewest;

    [Test]
    procedure Capacity_Increased_KeepsAllAndAcceptsMore;

    // After wrap-around the oldest event is no longer at index 0 of the buffer
    [Test]
    procedure Capacity_ChangedAfterWrapAround_KeepsOrder;
  end;

implementation

uses
  System.SysUtils,
  DevFormel.Trace.Types,
  DevFormel.Trace.Engine;

function Item(const AText: string; ALevel: TDFLogLevel = TDFLogLevel.Info): TDFQueuedEvent;
begin
  Result.Event := TDFTraceEvent.Create(ALevel, AText);
  Result.Scrub := False;
end;

procedure PushAll(AQueue: TDFBoundedEventQueue; const ATexts: array of string);
var
  Text: string;
begin
  for Text in ATexts do
    AQueue.Push(Item(Text));
end;

// Messages of all queued events in queue order
function PopAll(AQueue: TDFBoundedEventQueue): string;
var
  Popped: TDFQueuedEvent;
begin
  Result := '';
  while AQueue.Pop(Popped) do
  begin
    Result := Result + Popped.Event.Message;
    AQueue.EndDispatch;
  end;
end;

procedure TQueueTests.Push_WhenFull_DiscardsNewEventBelowError;
var
  Queue: TDFBoundedEventQueue;
begin
  Queue := TDFBoundedEventQueue.Create(3);
  try
    PushAll(Queue, ['1', '2', '3', '4', '5']);
    Assert.AreEqual(3, Queue.Count);
    Assert.IsTrue(Queue.DroppedCount = 2, 'DroppedCount: ' + UIntToStr(Queue.DroppedCount));
    Assert.AreEqual('123', PopAll(Queue));
  finally
    Queue.Free;
  end;
end;

procedure TQueueTests.Push_WhenFull_ErrorReplacesOldest;
var
  Queue: TDFBoundedEventQueue;
begin
  Queue := TDFBoundedEventQueue.Create(3);
  try
    PushAll(Queue, ['1', '2', '3']);
    Queue.Push(Item('E', TDFLogLevel.Error));
    Assert.IsTrue(Queue.DroppedCount = 1, 'DroppedCount: ' + UIntToStr(Queue.DroppedCount));
    Assert.AreEqual('23E', PopAll(Queue));
  finally
    Queue.Free;
  end;
end;

procedure TQueueTests.Capacity_Reduced_KeepsNewest;
var
  Queue: TDFBoundedEventQueue;
begin
  Queue := TDFBoundedEventQueue.Create(5);
  try
    PushAll(Queue, ['1', '2', '3', '4', '5']);
    Queue.Capacity := 2;
    Assert.AreEqual(2, Queue.Count);
    Assert.IsTrue(Queue.DroppedCount = 3, 'DroppedCount: ' + UIntToStr(Queue.DroppedCount));
    Assert.AreEqual('45', PopAll(Queue));
  finally
    Queue.Free;
  end;
end;

procedure TQueueTests.Capacity_Increased_KeepsAllAndAcceptsMore;
var
  Queue: TDFBoundedEventQueue;
begin
  Queue := TDFBoundedEventQueue.Create(2);
  try
    PushAll(Queue, ['1', '2']);
    Queue.Capacity := 4;
    PushAll(Queue, ['3', '4']);
    Assert.AreEqual(4, Queue.Count);
    Assert.IsTrue(Queue.DroppedCount = 0, 'DroppedCount: ' + UIntToStr(Queue.DroppedCount));
    Assert.AreEqual('1234', PopAll(Queue));
  finally
    Queue.Free;
  end;
end;

procedure TQueueTests.Capacity_ChangedAfterWrapAround_KeepsOrder;
var
  Queue: TDFBoundedEventQueue;
  Popped: TDFQueuedEvent;
begin
  Queue := TDFBoundedEventQueue.Create(3);
  try
    PushAll(Queue, ['1', '2', '3']);
    // Taking one out and adding one makes the buffer wrap around
    Assert.IsTrue(Queue.Pop(Popped), 'Pop');
    Queue.EndDispatch;
    PushAll(Queue, ['4']);
    Queue.Capacity := 5;
    PushAll(Queue, ['5', '6']);
    Assert.IsTrue(Queue.DroppedCount = 0, 'DroppedCount: ' + UIntToStr(Queue.DroppedCount));
    Assert.AreEqual('23456', PopAll(Queue));
  finally
    Queue.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TQueueTests);

end.
