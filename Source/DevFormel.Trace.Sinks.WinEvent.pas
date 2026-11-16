// DevFormel Trace, https://devformel.com/trace/
// Copyright (c) 2026 Dennis Powering.
// SPDX-License-Identifier: MPL-2.0
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

unit DevFormel.Trace.Sinks.WinEvent;

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  DevFormel.Trace.Types,
  DevFormel.Trace.Hub;

type
  /// <summary>
  /// Writes events to the Application log of the Windows event log.
  /// </summary>
  /// <remarks>
  /// Each event becomes one entry with message, extra values, tags, exception, stack trace and
  /// breadcrumbs. Debug and Info become information entries, Warning a warning, Error and
  /// Fatal an error. Errors while writing are ignored.
  /// On a default Windows installation, every user logged on to the computer can read the
  /// Application log, and many companies forward event logs to a central server. Consent
  /// LocalOnly does not prevent that. Scrubbing is based on patterns and does not guarantee
  /// that all personal data is removed.
  /// </remarks>
  [ComponentPlatformsAttribute(pidWin32 or pidWin64)]
  TDFWinEventSink = class(TComponent, IDFTraceSink, IDFLocalSink)
  private
    FHub: TDFTraceHub;
    FEnabled: Boolean;
    FMinLevel: TDFLogLevel;
    FSource: string;
    FLock: TCriticalSection;

    procedure SetHub(const AValue: TDFTraceHub);
    function FormatEvent(const AEvent: TDFTraceEvent): string;

    { IDFTraceSink implementation }
    function GetEnabled: Boolean;
    function GetMinLevel: TDFLogLevel;
    procedure Emit(const AEvent: TDFTraceEvent);
  protected
    /// <summary>Clears Hub when the hub is freed.</summary>
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
  published
    /// <summary>Hub that passes events to this sink. Setting it registers the sink with the
    /// hub.</summary>
    property Hub: TDFTraceHub read FHub write SetHub;
    /// <summary>Turns the sink on or off.</summary>
    property Enabled: Boolean read FEnabled write FEnabled default True;
    /// <summary>Lowest level that is written; events below it are ignored.</summary>
    property MinLevel: TDFLogLevel read FMinLevel write FMinLevel default TDFLogLevel.Warning;
    /// <summary>Source name shown in the event log, usually the name of the application.</summary>
    /// <remarks>If empty, the application name of the hub is used. Unless the source is
    /// registered with a message file, the Event Viewer cannot format the entry: it shows a
    /// note about the missing description or an unrelated system text such as "The operation
    /// completed successfully", and the message itself only on the Details tab. Register the
    /// source once during setup, for example with Windows PowerShell as administrator:
    /// New-EventLog -LogName Application -Source MyApp</remarks>
    property Source: string read FSource write FSource;
  end;

implementation

uses
  {$IFDEF MSWINDOWS}Winapi.Windows,{$ENDIF}
  System.DateUtils;

{ TDFWinEventSink }

constructor TDFWinEventSink.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FEnabled := True;
  FMinLevel := TDFLogLevel.Warning;
  // Empty, so that the application name of the hub is used
  FSource := '';
  FLock := TCriticalSection.Create;
end;

destructor TDFWinEventSink.Destroy;
begin
  if Assigned(FHub) then
  begin
    // Forms free their sinks before the hub. Flushing here passes queued events to all
    // sinks while they still exist.
    FHub.Flush(FHub.ShutdownTimeoutMS);
    FHub.UnregisterSink(Self);
  end;

  FreeAndNil(FLock);
  inherited Destroy;
end;

procedure TDFWinEventSink.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent = FHub) then
    FHub := nil;
end;

procedure TDFWinEventSink.SetHub(const AValue: TDFTraceHub);
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

function TDFWinEventSink.GetEnabled: Boolean;
begin
  Result := FEnabled;
end;

function TDFWinEventSink.GetMinLevel: TDFLogLevel;
begin
  Result := FMinLevel;
end;

function TDFWinEventSink.FormatEvent(const AEvent: TDFTraceEvent): string;
var
  SB: TStringBuilder;
  Crumb: TDFBreadcrumb;
  Pair: TDFKeyValuePair;
begin
  SB := TStringBuilder.Create;
  try
    if not AEvent.AppName.IsEmpty then
      SB.AppendFormat('Application: %s', [AEvent.AppName]);
    if not AEvent.AppVersion.IsEmpty then
      SB.AppendFormat(' (v%s)', [AEvent.AppVersion]);
    SB.AppendLine;

    SB.AppendFormat('Environment: %s | Thread-ID: %d | Event-ID: %s', [
      AEvent.Environment,
      AEvent.ThreadID,
      AEvent.EventID.ToString
    ]).AppendLine;

    SB.AppendLine('--------------------------------------------------');

    if not AEvent.Message.IsEmpty then
    begin
      SB.AppendLine('Message:');
      SB.AppendLine(AEvent.Message);
    end;

    if not AEvent.ExceptionClassName.IsEmpty then
    begin
      SB.AppendLine;
      SB.AppendFormat('Exception Class: %s', [AEvent.ExceptionClassName]).AppendLine;
      SB.AppendFormat('Exception Message: %s', [AEvent.ExceptionMessage]).AppendLine;
    end;

    if not AEvent.StackTrace.IsEmpty then
    begin
      SB.AppendLine;
      SB.AppendLine('Stack Trace:');
      SB.AppendLine(AEvent.StackTrace);
    end;

    if Length(AEvent.Breadcrumbs) > 0 then
    begin
      SB.AppendLine;
      SB.AppendLine('Breadcrumbs:');
      for Crumb in AEvent.Breadcrumbs do
      begin
        SB.AppendFormat('  [%s] [%s] %s', [
          FormatDateTime('hh:nn:ss.zzz', TTimeZone.Local.ToLocalTime(Crumb.TimestampUtc)),
          Crumb.Category,
          Crumb.Message
        ]).AppendLine;
      end;
    end;

    if Length(AEvent.Tags) > 0 then
    begin
      SB.AppendLine;
      SB.AppendLine('Tags:');
      for Pair in AEvent.Tags do
        SB.AppendFormat('  %s = %s', [Pair.Key, Pair.Value]).AppendLine;
    end;

    if Length(AEvent.Extra) > 0 then
    begin
      SB.AppendLine;
      SB.AppendLine('Extra:');
      for Pair in AEvent.Extra do
        SB.AppendFormat('  %s = %s', [Pair.Key, Pair.Value]).AppendLine;
    end;

    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

procedure TDFWinEventSink.Emit(const AEvent: TDFTraceEvent);
{$IFDEF MSWINDOWS}
var
  EventLogHandle: THandle;
  EventType: WORD;
  FormattedMsg: string;
  PStr: PWideChar;
  SourceName: string;
{$ENDIF}
begin
  if not FEnabled then Exit;

{$IFDEF MSWINDOWS}
  // A source set at the sink wins over the application name; ReportEvent needs some name
  FLock.Enter;
  try
    SourceName := FSource;
    if SourceName.IsEmpty then
      SourceName := AEvent.AppName;
    if SourceName.IsEmpty then
      SourceName := 'Application';
  finally
    FLock.Leave;
  end;

  try
    case AEvent.Level of
      TDFLogLevel.Debug,
      TDFLogLevel.Info:    EventType := EVENTLOG_INFORMATION_TYPE;
      TDFLogLevel.Warning: EventType := EVENTLOG_WARNING_TYPE;
      TDFLogLevel.Error,
      TDFLogLevel.Fatal:   EventType := EVENTLOG_ERROR_TYPE;
    else
      EventType := EVENTLOG_INFORMATION_TYPE;
    end;

    FormattedMsg := FormatEvent(AEvent);
    if FormattedMsg.IsEmpty then Exit;

    PStr := PWideChar(FormattedMsg);

    EventLogHandle := RegisterEventSource(nil, PWideChar(SourceName));
    if EventLogHandle <> 0 then
    begin
      try
        ReportEvent(
          EventLogHandle,
          EventType,
          0,          // wCategory
          0,          // dwEventID
          nil,        // lpUserSid
          1,          // wNumStrings
          0,          // dwDataSize
          @PStr,      // lpStrings
          nil         // lpRawData
        );
      finally
        DeregisterEventSource(EventLogHandle);
      end;
    end;
  except
    // An event log that is full or not accessible must not stop the other sinks
  end;
{$ENDIF}
end;

end.
