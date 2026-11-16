// DevFormel Trace, https://devformel.com/trace/
// Copyright (c) 2026 Dennis Powering.
// SPDX-License-Identifier: MPL-2.0
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

unit DevFormel.Trace.Tests.Hub;

interface

uses
  DUnitX.TestFramework,
  DevFormel.Trace.Types,
  DevFormel.Trace.Hub;

type
  TCollectingSink = class;

  [TestFixture]
  THubTests = class
  private
    FHub: TDFTraceHub;
    FCollector: TCollectingSink;
    FSink: IDFTraceSink;
    function ReceivedEvents: TArray<TDFTraceEvent>;
    function FindPair(const APairs: TArray<TDFKeyValuePair>; const AKey: string;
      out APair: TDFKeyValuePair): Boolean;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure TrackEvent_WithExtra_KeepsValuesAndTypes;

    [Test]
    procedure SetTag_IsAttachedToEventsAndExceptions;

    [Test]
    procedure SetTag_SameKeyIgnoringCase_ReplacesValue;

    [Test]
    procedure RemoveTag_StopsAttachingTag;

    [Test]
    procedure TrackScope_SendsOneEventWithDurationOperationAndExtra;

    [Test]
    procedure ConsentNone_SendsNothing;

    [Test]
    procedure ConsentLocalOnly_PassesEventsOnlyToLocalSinks;

    [Test]
    procedure ConsentChange_ClearsBreadcrumbs;

    [Test]
    procedure ConsentSetToSameValue_KeepsBreadcrumbs;

    [Test]
    procedure MaxQueueSize_BelowOne_IsOne;

    [Test]
    procedure MaxBreadcrumbs_KeepsNewest;

    [Test]
    procedure MaxBreadcrumbs_Reduced_DropsOldestAtOnce;

    [Test]
    procedure MaxBreadcrumbs_Zero_RecordsNone;

    [Test]
    procedure Breadcrumbs_AttachedOnlyToErrors;

    [Test]
    procedure TrackEvent_LongMessage_IsCutAtEndOfWord;

    [Test]
    procedure TrackEvent_LongWordWithoutSpaces_IsCutAtLimit;

    // The cut must not leave the first half of an address that the sanitizer cannot detect
    [Test]
    procedure TrackEvent_AddressAtLimit_IsRemovedWithTheCut;

    [Test]
    procedure TrackEvent_LongExtraValue_IsCut;

    [Test]
    procedure AddBreadcrumb_LongMessage_IsCut;
  end;

  // Keeps events in memory. Emit runs in the worker thread; tests read after Flush.
  TCollectingSink = class(TInterfacedObject, IDFTraceSink)
  private
    FEvents: TArray<TDFTraceEvent>;
  public
    function GetEnabled: Boolean;
    function GetMinLevel: TDFLogLevel;
    procedure Emit(const AEvent: TDFTraceEvent);
    function Snapshot: TArray<TDFTraceEvent>;
  end;

  // Like TCollectingSink, but marked as a sink that keeps events on the machine
  TCollectingLocalSink = class(TCollectingSink, IDFLocalSink);

implementation

uses
  System.SysUtils,
  System.StrUtils;

// In 64-bit programs Length of a dynamic array is NativeInt, and Assert.AreEqual cannot
// compare it with an Integer literal; hence Integer(Length(...)) in the assertions.

const
  // As in TDFTraceEngine; repeated here so that a changed limit is noticed
  MaxTextLength = 8000;
  MaxBreadcrumbLength = 1000;
  TruncatedMark = ' [truncated]';

{ TCollectingSink }

function TCollectingSink.GetEnabled: Boolean;
begin
  Result := True;
end;

function TCollectingSink.GetMinLevel: TDFLogLevel;
begin
  Result := TDFLogLevel.Debug;
end;

procedure TCollectingSink.Emit(const AEvent: TDFTraceEvent);
begin
  TMonitor.Enter(Self);
  try
    FEvents := FEvents + [AEvent];
  finally
    TMonitor.Exit(Self);
  end;
end;

function TCollectingSink.Snapshot: TArray<TDFTraceEvent>;
begin
  TMonitor.Enter(Self);
  try
    Result := Copy(FEvents);
  finally
    TMonitor.Exit(Self);
  end;
end;

{ THubTests }

procedure THubTests.Setup;
begin
  FHub := TDFTraceHub.Create(nil);
  // No global exception hooks in the test process
  FHub.AutoHookExceptions := False;
  FCollector := TCollectingSink.Create;
  FSink := FCollector;
  FHub.RegisterSink(FSink);
end;

procedure THubTests.TearDown;
begin
  FHub.UnregisterSink(FSink);
  FreeAndNil(FHub);
  FCollector := nil;
  FSink := nil;
end;

function THubTests.ReceivedEvents: TArray<TDFTraceEvent>;
begin
  Assert.IsTrue(FHub.Flush(5000), 'Events were not passed to the sink in time');
  Result := FCollector.Snapshot;
end;

function THubTests.FindPair(const APairs: TArray<TDFKeyValuePair>; const AKey: string;
  out APair: TDFKeyValuePair): Boolean;
var
  Pair: TDFKeyValuePair;
begin
  for Pair in APairs do
    if Pair.Key = AKey then
    begin
      APair := Pair;
      Exit(True);
    end;
  Result := False;
end;

procedure THubTests.TrackEvent_WithExtra_KeepsValuesAndTypes;
var
  Received: TArray<TDFTraceEvent>;
begin
  FHub.TrackEvent('Order saved', [TDFKeyValuePair.Create('OrderId', 4711),
    TDFKeyValuePair.Create('Table', 'Orders')], TDFLogLevel.Warning);

  Received := ReceivedEvents;
  Assert.AreEqual(1, Integer(Length(Received)));
  Assert.IsTrue(Received[0].Level = TDFLogLevel.Warning, 'Level');
  Assert.AreEqual(2, Integer(Length(Received[0].Extra)));
  Assert.AreEqual('OrderId', Received[0].Extra[0].Key);
  Assert.AreEqual('4711', Received[0].Extra[0].Value);
  Assert.IsTrue(Received[0].Extra[0].Kind = TDFValueKind.Integer, 'Kind');
  Assert.AreEqual('Orders', Received[0].Extra[1].Value);
end;

procedure THubTests.SetTag_IsAttachedToEventsAndExceptions;
var
  E: Exception;
  Received: TArray<TDFTraceEvent>;
  Pair: TDFKeyValuePair;
begin
  FHub.SetTag('Module', 'Billing');

  FHub.TrackEvent('Invoice printed');
  E := Exception.Create('Printer offline');
  try
    FHub.TrackException(E);
  finally
    E.Free;
  end;

  Received := ReceivedEvents;
  Assert.AreEqual(2, Integer(Length(Received)));
  Assert.IsTrue(FindPair(Received[0].Tags, 'Module', Pair), 'Tag missing on event');
  Assert.AreEqual('Billing', Pair.Value);
  Assert.IsTrue(FindPair(Received[1].Tags, 'Module', Pair), 'Tag missing on exception');
  Assert.AreEqual('Billing', Pair.Value);
end;

procedure THubTests.SetTag_SameKeyIgnoringCase_ReplacesValue;
var
  Received: TArray<TDFTraceEvent>;
begin
  FHub.SetTag('Module', 'Billing');
  FHub.SetTag('module', 'Shipping');
  FHub.TrackEvent('Parcel sent');

  Received := ReceivedEvents;
  Assert.AreEqual(1, Integer(Length(Received[0].Tags)));
  Assert.AreEqual('Shipping', Received[0].Tags[0].Value);
end;

procedure THubTests.RemoveTag_StopsAttachingTag;
var
  Received: TArray<TDFTraceEvent>;
begin
  FHub.SetTag('Module', 'Billing');
  FHub.RemoveTag('MODULE');
  FHub.TrackEvent('Invoice printed');

  Received := ReceivedEvents;
  Assert.AreEqual(0, Integer(Length(Received[0].Tags)));
end;

procedure THubTests.TrackScope_SendsOneEventWithDurationOperationAndExtra;
var
  Scope: IDFTraceScope;
  Received: TArray<TDFTraceEvent>;
  Pair: TDFKeyValuePair;
begin
  Scope := FHub.TrackScope('LoadCustomers', [TDFKeyValuePair.Create('Table', 'Customers')]);
  Scope.Stop;
  // Releasing the last reference after Stop must not send a second event
  Scope := nil;

  Received := ReceivedEvents;
  Assert.AreEqual(1, Integer(Length(Received)));
  Assert.IsTrue(FindPair(Received[0].Extra, 'DurationMS', Pair), 'DurationMS missing');
  Assert.IsTrue(Pair.Kind = TDFValueKind.Integer, 'DurationMS must be a number');
  Assert.IsTrue(FindPair(Received[0].Extra, 'Operation', Pair), 'Operation missing');
  Assert.AreEqual('LoadCustomers', Pair.Value);
  Assert.IsTrue(FindPair(Received[0].Extra, 'Table', Pair), 'Extra value missing');
  Assert.AreEqual('Customers', Pair.Value);
end;

procedure THubTests.ConsentNone_SendsNothing;
var
  E: Exception;
begin
  FHub.Consent := TDFConsent.None;

  FHub.TrackEvent('Order saved', [TDFKeyValuePair.Create('OrderId', 4711)]);
  E := Exception.Create('Printer offline');
  try
    FHub.TrackException(E);
  finally
    E.Free;
  end;
  FHub.TrackScope('LoadCustomers').Stop;
  FHub.TrackSystemInfo;

  Assert.AreEqual(0, Integer(Length(ReceivedEvents)));
end;

procedure THubTests.ConsentLocalOnly_PassesEventsOnlyToLocalSinks;
var
  LocalCollector: TCollectingLocalSink;
  LocalSink: IDFTraceSink;
begin
  LocalCollector := TCollectingLocalSink.Create;
  LocalSink := LocalCollector;
  FHub.RegisterSink(LocalSink);
  try
    FHub.Consent := TDFConsent.LocalOnly;
    FHub.TrackEvent('Order saved');

    Assert.AreEqual(0, Integer(Length(ReceivedEvents)), 'Sink without IDFLocalSink received the event');
    Assert.AreEqual(1, Integer(Length(LocalCollector.Snapshot)), 'Local sink did not receive the event');
  finally
    FHub.UnregisterSink(LocalSink);
  end;
end;

procedure THubTests.ConsentChange_ClearsBreadcrumbs;
var
  Received: TArray<TDFTraceEvent>;
begin
  FHub.Consent := TDFConsent.LocalOnly;
  FHub.AddBreadcrumb('recorded for local sinks only');
  FHub.Consent := TDFConsent.Full;
  FHub.TrackEvent('Order failed', TDFLogLevel.Error);

  Received := ReceivedEvents;
  Assert.AreEqual(1, Integer(Length(Received)));
  Assert.AreEqual(0, Integer(Length(Received[0].Breadcrumbs)));
end;

procedure THubTests.ConsentSetToSameValue_KeepsBreadcrumbs;
var
  Received: TArray<TDFTraceEvent>;
begin
  FHub.AddBreadcrumb('crumb1');
  FHub.Consent := TDFConsent.Full;
  FHub.TrackEvent('Order failed', TDFLogLevel.Error);

  Received := ReceivedEvents;
  Assert.AreEqual(1, Integer(Length(Received[0].Breadcrumbs)));
end;

procedure THubTests.MaxQueueSize_BelowOne_IsOne;
begin
  FHub.MaxQueueSize := 0;
  Assert.AreEqual(1, FHub.MaxQueueSize);
end;

procedure THubTests.MaxBreadcrumbs_KeepsNewest;
var
  Received: TArray<TDFTraceEvent>;
begin
  FHub.MaxBreadcrumbs := 2;
  FHub.AddBreadcrumb('crumb1');
  FHub.AddBreadcrumb('crumb2');
  FHub.AddBreadcrumb('crumb3');
  FHub.TrackEvent('Order failed', TDFLogLevel.Error);

  Received := ReceivedEvents;
  Assert.AreEqual(2, Integer(Length(Received[0].Breadcrumbs)));
  Assert.AreEqual('crumb2', Received[0].Breadcrumbs[0].Message);
  Assert.AreEqual('crumb3', Received[0].Breadcrumbs[1].Message);
end;

procedure THubTests.MaxBreadcrumbs_Reduced_DropsOldestAtOnce;
var
  Received: TArray<TDFTraceEvent>;
begin
  FHub.AddBreadcrumb('crumb1');
  FHub.AddBreadcrumb('crumb2');
  FHub.AddBreadcrumb('crumb3');
  FHub.MaxBreadcrumbs := 1;
  FHub.TrackEvent('Order failed', TDFLogLevel.Error);

  Received := ReceivedEvents;
  Assert.AreEqual(1, Integer(Length(Received[0].Breadcrumbs)));
  Assert.AreEqual('crumb3', Received[0].Breadcrumbs[0].Message);
end;

procedure THubTests.MaxBreadcrumbs_Zero_RecordsNone;
var
  Received: TArray<TDFTraceEvent>;
begin
  FHub.MaxBreadcrumbs := 0;
  FHub.AddBreadcrumb('crumb1');
  FHub.TrackEvent('Order failed', TDFLogLevel.Error);

  Received := ReceivedEvents;
  Assert.AreEqual(0, Integer(Length(Received[0].Breadcrumbs)));
end;

procedure THubTests.Breadcrumbs_AttachedOnlyToErrors;
var
  Received: TArray<TDFTraceEvent>;
begin
  FHub.AddBreadcrumb('crumb1');
  FHub.TrackEvent('Order saved', TDFLogLevel.Warning);
  FHub.TrackEvent('Order failed', TDFLogLevel.Error);

  Received := ReceivedEvents;
  Assert.AreEqual(2, Integer(Length(Received)));
  Assert.AreEqual(0, Integer(Length(Received[0].Breadcrumbs)), 'Warning must not carry breadcrumbs');
  Assert.AreEqual(1, Integer(Length(Received[1].Breadcrumbs)), 'Error must carry breadcrumbs');
end;

procedure THubTests.TrackEvent_LongMessage_IsCutAtEndOfWord;
var
  Received: TArray<TDFTraceEvent>;
begin
  // The prefix shifts the words, so that the limit of 8000 falls inside a word
  FHub.TrackEvent('ab ' + DupeString('word ', 4000));

  Received := ReceivedEvents;
  Assert.AreEqual(1, Integer(Length(Received)));
  Assert.IsTrue(Received[0].Message.EndsWith('word' + TruncatedMark), 'Must end with a whole word and the mark');
  Assert.IsTrue(Length(Received[0].Message) <= MaxTextLength + Length(TruncatedMark), 'Length');
  Assert.IsTrue(Length(Received[0].Message) > MaxTextLength - 10, 'Cut too early');
end;

procedure THubTests.TrackEvent_LongWordWithoutSpaces_IsCutAtLimit;
var
  Received: TArray<TDFTraceEvent>;
begin
  FHub.TrackEvent(StringOfChar('x', 20000));

  Received := ReceivedEvents;
  Assert.AreEqual(1, Integer(Length(Received)));
  Assert.AreEqual(StringOfChar('x', MaxTextLength) + TruncatedMark, Received[0].Message);
end;

procedure THubTests.TrackEvent_AddressAtLimit_IsRemovedWithTheCut;
var
  Received: TArray<TDFTraceEvent>;
begin
  // The address starts 10 characters before the limit and ends behind it
  FHub.TrackEvent(StringOfChar('x', MaxTextLength - 11) + ' someone@example.com ' +
    StringOfChar('y', 500));

  Received := ReceivedEvents;
  Assert.AreEqual(1, Integer(Length(Received)));
  Assert.AreEqual(StringOfChar('x', MaxTextLength - 11) + TruncatedMark, Received[0].Message);
end;

procedure THubTests.TrackEvent_LongExtraValue_IsCut;
var
  Received: TArray<TDFTraceEvent>;
  Pair: TDFKeyValuePair;
begin
  FHub.TrackEvent('Import failed', [
    TDFKeyValuePair.Create('Response', StringOfChar('x', 20000)),
    TDFKeyValuePair.Create('Table', 'Customers')]);

  Received := ReceivedEvents;
  Assert.AreEqual(1, Integer(Length(Received)));
  Assert.IsTrue(FindPair(Received[0].Extra, 'Response', Pair), 'Response');
  Assert.AreEqual(MaxTextLength + Length(TruncatedMark), Length(Pair.Value));
  Assert.IsTrue(FindPair(Received[0].Extra, 'Table', Pair), 'Table');
  Assert.AreEqual('Customers', Pair.Value, 'Short values must stay');
end;

procedure THubTests.AddBreadcrumb_LongMessage_IsCut;
var
  Received: TArray<TDFTraceEvent>;
begin
  FHub.AddBreadcrumb(StringOfChar('x', 5000));
  FHub.TrackEvent('Order failed', TDFLogLevel.Error);

  Received := ReceivedEvents;
  Assert.AreEqual(1, Integer(Length(Received)));
  Assert.AreEqual(1, Integer(Length(Received[0].Breadcrumbs)));
  Assert.AreEqual(StringOfChar('x', MaxBreadcrumbLength) + TruncatedMark, Received[0].Breadcrumbs[0].Message);
end;

initialization
  TDUnitX.RegisterTestFixture(THubTests);

end.
