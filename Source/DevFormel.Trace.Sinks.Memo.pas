// DevFormel Trace, https://devformel.com/trace/
// Copyright (c) 2026 Dennis Powering.
// SPDX-License-Identifier: MPL-2.0
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

unit DevFormel.Trace.Sinks.Memo;

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Rtti,
  DevFormel.Trace.Types,
  DevFormel.Trace.Hub;

type
  /// <summary>
  /// Shows one line per event in a memo, for example during development or in a support
  /// window of the application.
  /// </summary>
  /// <remarks>
  /// Works with VCL and FMX. The lines are added in the main thread with TThread.Queue, several
  /// events at once when they arrive quickly. An application without a message loop, such as
  /// a console program, has to call CheckSynchronize for the lines to appear.
  /// Stack traces and breadcrumbs are not shown; the log file sink writes them.
  /// </remarks>
  // Only Windows is tested so far
  [ComponentPlatformsAttribute(pidWin32 or pidWin64)]
  TDFMemoSink = class(TComponent, IDFTraceSink, IDFLocalSink)
  private type
    // Outlives the sink. Closures queued with TThread.Queue can run after the sink is freed,
    // for example while the hub waits for the worker thread during shutdown. They reach the
    // sink only through this object, and Destroy sets Sink to nil.
    // It also collects entries from the worker thread, so that a burst of events leads to one
    // update of the memo instead of one per event.
    TLink = class(TInterfacedObject)
    public
      Sink: TDFMemoSink;
      Lock: TCriticalSection;
      Pending: TStringList;
      UpdateQueued: Boolean;
      constructor Create;
      destructor Destroy; override;
      procedure Deliver;
    end;
  private
    FHub: TDFTraceHub;
    FEnabled: Boolean;
    FMinLevel: TDFLogLevel;
    FTargetMemo: TComponent;
    FTargetLines: TStrings;
    FMaxLines: Integer;
    FAutoScroll: Boolean;
    FLink: TLink;
    FLinkRef: IInterface;

    procedure SetHub(const AValue: TDFTraceHub);
    procedure SetTargetMemo(const AValue: TComponent);
    function ResolveLines: TStrings;
    procedure ScrollMemoToEnd(AMemo: TComponent);
    function FormatEvent(const AEvent: TDFTraceEvent): string;
    function LevelToString(ALevel: TDFLogLevel): string;
    procedure AppendEntries(AEntries: TStrings);

    { IDFTraceSink implementation }
    function GetEnabled: Boolean;
    function GetMinLevel: TDFLogLevel;
    procedure Emit(const AEvent: TDFTraceEvent);
  protected
    /// <summary>Clears Hub when the hub is freed and TargetMemo when the memo is freed.</summary>
    /// <param name="AComponent">Component that is inserted or removed.</param>
    /// <param name="Operation">opInsert or opRemove.</param>
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  public
    /// <summary>Creates the sink. It receives events once Hub is set.</summary>
    /// <param name="AOwner">Component that frees the sink, usually the form or data module
    /// that holds the hub.</param>
    constructor Create(AOwner: TComponent); override;
    /// <summary>Passes the queued events to all sinks, for at most Hub.ShutdownTimeoutMS, and
    /// removes the sink from the hub.</summary>
    destructor Destroy; override;

    /// <summary>TStrings object that receives the lines, for targets without a Lines
    /// property.</summary>
    /// <remarks>Takes precedence over TargetMemo. Unlike TargetMemo, the sink is not notified
    /// when the TStrings object is freed: set TargetLines to nil before freeing it.</remarks>
    property TargetLines: TStrings read FTargetLines write FTargetLines;
  published
    /// <summary>Hub that passes events to this sink. Setting it registers the sink with the
    /// hub.</summary>
    property Hub: TDFTraceHub read FHub write SetHub;
    /// <summary>Turns the sink on or off.</summary>
    property Enabled: Boolean read FEnabled write FEnabled default True;
    /// <summary>Lowest level that is shown; events below it are ignored.</summary>
    property MinLevel: TDFLogLevel read FMinLevel write FMinLevel default TDFLogLevel.Debug;
    /// <summary>Component whose Lines property receives the lines, such as a VCL or FMX
    /// TMemo.</summary>
    property TargetMemo: TComponent read FTargetMemo write SetTargetMemo;
    /// <summary>Maximum number of lines; the oldest are removed. 0: no limit.</summary>
    property MaxLines: Integer read FMaxLines write FMaxLines default 1000;
    /// <summary>Scrolls to the last line after new lines have been added.</summary>
    property AutoScroll: Boolean read FAutoScroll write FAutoScroll default True;
  end;

implementation

uses
  System.DateUtils;

{ TDFMemoSink.TLink }

constructor TDFMemoSink.TLink.Create;
begin
  inherited Create;
  Lock := TCriticalSection.Create;
  Pending := TStringList.Create;
end;

destructor TDFMemoSink.TLink.Destroy;
begin
  FreeAndNil(Pending);
  FreeAndNil(Lock);
  inherited Destroy;
end;

procedure TDFMemoSink.TLink.Deliver;
var
  Entries: TStringList;
begin
  // Runs in the main thread. Swap the buffer so the worker can keep adding while the memo updates.
  Lock.Enter;
  try
    Entries := Pending;
    Pending := TStringList.Create;
    UpdateQueued := False;
  finally
    Lock.Leave;
  end;

  try
    if Assigned(Sink) then
      Sink.AppendEntries(Entries);
  finally
    Entries.Free;
  end;
end;

{ TDFMemoSink }

constructor TDFMemoSink.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FEnabled := True;
  FMinLevel := TDFLogLevel.Debug;
  FTargetMemo := nil;
  FTargetLines := nil;
  FMaxLines := 1000;
  FAutoScroll := True;
  FLink := TLink.Create;
  FLink.Sink := Self;
  FLinkRef := FLink;
end;

destructor TDFMemoSink.Destroy;
begin
  // First, so that entries queued from now on are discarded instead of reaching a freed sink
  FLink.Sink := nil;

  if Assigned(FHub) then
  begin
    // Forms free their sinks before the hub. Flushing here passes queued events to all
    // sinks while they still exist.
    FHub.Flush(FHub.ShutdownTimeoutMS);
    FHub.UnregisterSink(Self);
  end;

  inherited Destroy;
end;

procedure TDFMemoSink.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if Operation = opRemove then
  begin
    if AComponent = FHub then
      FHub := nil
    else if AComponent = FTargetMemo then
      FTargetMemo := nil;
  end;
end;

procedure TDFMemoSink.SetHub(const AValue: TDFTraceHub);
begin
  if FHub <> AValue then
  begin
    if Assigned(FHub) then
    begin
      FHub.UnregisterSink(Self);
      FHub.RemoveFreeNotification(Self);
    end;

    FHub := AValue;

    if Assigned(FHub) then
    begin
      FHub.FreeNotification(Self);
      FHub.RegisterSink(Self);
    end;
  end;
end;

procedure TDFMemoSink.SetTargetMemo(const AValue: TComponent);
begin
  if FTargetMemo <> AValue then
  begin
    if Assigned(FTargetMemo) then
      FTargetMemo.RemoveFreeNotification(Self);

    FTargetMemo := AValue;

    if Assigned(FTargetMemo) then
      FTargetMemo.FreeNotification(Self);
  end;
end;

function TDFMemoSink.GetEnabled: Boolean;
begin
  Result := FEnabled;
end;

function TDFMemoSink.GetMinLevel: TDFLogLevel;
begin
  Result := FMinLevel;
end;

function TDFMemoSink.ResolveLines: TStrings;
var
  Ctx: TRttiContext;
  RttiType: TRttiType;
  Prop: TRttiProperty;
  Val: TValue;
begin
  Result := FTargetLines;
  if Assigned(Result) then Exit;

  if Assigned(FTargetMemo) then
  begin
    RttiType := Ctx.GetType(FTargetMemo.ClassType);
    if Assigned(RttiType) then
    begin
      Prop := RttiType.GetProperty('Lines');
      if Assigned(Prop) and Prop.IsReadable then
      begin
        Val := Prop.GetValue(FTargetMemo);
        if Val.IsObject and (Val.AsObject is TStrings) then
          Result := TStrings(Val.AsObject);
      end;
    end;
  end;
end;

procedure TDFMemoSink.ScrollMemoToEnd(AMemo: TComponent);
const
  EM_SCROLLCARET = $00B7;
  WM_VSCROLL     = $0115;
  SB_BOTTOM      = 7;
var
  Ctx: TRttiContext;
  RttiType: TRttiType;
  Method: TRttiMethod;
  PropSelStart, PropText: TRttiProperty;
  TextVal: TValue;
  PerformMethod: TRttiMethod;
begin
  if not Assigned(AMemo) then Exit;

  RttiType := Ctx.GetType(AMemo.ClassType);
  if not Assigned(RttiType) then Exit;

  // FMX memos can do it themselves
  Method := RttiType.GetMethod('GoToTextEnd');
  if Assigned(Method) then
  begin
    try
      Method.Invoke(AMemo, []);
      Exit;
    except
      // Try the VCL way below
    end;
  end;

  // VCL memos: move the caret to the end. Setting SelStart alone does not scroll the view.
  PropText := RttiType.GetProperty('Text');
  PropSelStart := RttiType.GetProperty('SelStart');
  PerformMethod := RttiType.GetMethod('Perform');

  if Assigned(PropText) and Assigned(PropSelStart) and PropSelStart.IsWritable then
  begin
    try
      TextVal := PropText.GetValue(AMemo);
      PropSelStart.SetValue(AMemo, Length(TextVal.AsString));

      if Assigned(PerformMethod) then
      begin
        PerformMethod.Invoke(AMemo, [EM_SCROLLCARET, 0, 0]);
        PerformMethod.Invoke(AMemo, [WM_VSCROLL, SB_BOTTOM, 0]);
      end;
    except
      // Scrolling is a convenience and must not stop the next update
    end;
  end;
end;

function TDFMemoSink.LevelToString(ALevel: TDFLogLevel): string;
begin
  case ALevel of
    TDFLogLevel.Debug:   Result := 'DEBUG';
    TDFLogLevel.Info:    Result := 'INFO ';
    TDFLogLevel.Warning: Result := 'WARN ';
    TDFLogLevel.Error:   Result := 'ERROR';
    TDFLogLevel.Fatal:   Result := 'FATAL';
  else
    Result := 'UNK  ';
  end;
end;

function TDFMemoSink.FormatEvent(const AEvent: TDFTraceEvent): string;
var
  SB: TStringBuilder;
  I: Integer;
begin
  SB := TStringBuilder.Create;
  try
    SB.AppendFormat('[%s] [%s] ', [
      FormatDateTime('hh:nn:ss.zzz', TTimeZone.Local.ToLocalTime(AEvent.TimestampUtc)),
      LevelToString(AEvent.Level)
    ]);

    if not AEvent.Message.IsEmpty then
      SB.Append(AEvent.Message);

    if not AEvent.ExceptionClassName.IsEmpty then
    begin
      if not AEvent.Message.IsEmpty then
        SB.Append(' | ');
      SB.AppendFormat('Exception: %s (%s)', [AEvent.ExceptionClassName, AEvent.ExceptionMessage]);
    end;

    if Length(AEvent.Extra) > 0 then
    begin
      SB.Append(' [');
      for I := 0 to High(AEvent.Extra) do
      begin
        if I > 0 then
          SB.Append('; ');
        SB.AppendFormat('%s: %s', [AEvent.Extra[I].Key, AEvent.Extra[I].Value]);
      end;
      SB.Append(']');
    end;

    if Length(AEvent.Tags) > 0 then
    begin
      SB.Append(' {');
      for I := 0 to High(AEvent.Tags) do
      begin
        if I > 0 then
          SB.Append('; ');
        SB.AppendFormat('%s: %s', [AEvent.Tags[I].Key, AEvent.Tags[I].Value]);
      end;
      SB.Append('}');
    end;

    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

procedure TDFMemoSink.AppendEntries(AEntries: TStrings);
var
  Lines: TStrings;
  Combined: TStringList;
begin
  if AEntries.Count = 0 then Exit;

  Lines := ResolveLines;
  if not Assigned(Lines) then Exit;

  Lines.BeginUpdate;
  try
    if (FMaxLines > 0) and (Lines.Count + AEntries.Count > FMaxLines) then
    begin
      // Deleting the first lines one by one is slow in a memo control: each delete
      // re-layouts the whole text. Building the result separately needs one assignment.
      Combined := TStringList.Create;
      try
        Combined.Text := Lines.Text;
        Combined.AddStrings(AEntries);
        while Combined.Count > FMaxLines do
          Combined.Delete(0);
        Lines.Text := Combined.Text;
      finally
        Combined.Free;
      end;
    end
    else
      Lines.AddStrings(AEntries);
  finally
    Lines.EndUpdate;
  end;

  if FAutoScroll and Assigned(FTargetMemo) then
    ScrollMemoToEnd(FTargetMemo);
end;

procedure TDFMemoSink.Emit(const AEvent: TDFTraceEvent);
var
  FormattedEntry: string;
  QueueUpdate: Boolean;
  Link: IInterface;
begin
  if not FEnabled then Exit;

  FormattedEntry := FormatEvent(AEvent);
  if FormattedEntry.IsEmpty then Exit;

  FLink.Lock.Enter;
  try
    FLink.Pending.Add(FormattedEntry);
    // Entries beyond MaxLines would be removed from the memo right after adding them
    if FMaxLines > 0 then
      while FLink.Pending.Count > FMaxLines do
        FLink.Pending.Delete(0);
    QueueUpdate := not FLink.UpdateQueued;
    FLink.UpdateQueued := True;
  finally
    FLink.Lock.Leave;
  end;

  // At most one update waits in the main thread's queue; it takes all pending entries.
  // The closure keeps the link alive, not the sink.
  if QueueUpdate then
  begin
    Link := FLinkRef;
    TThread.Queue(nil,
      procedure
      begin
        TLink(Link as TObject).Deliver;
      end);
  end;
end;

end.
