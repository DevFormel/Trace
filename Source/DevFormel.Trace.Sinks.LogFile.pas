// DevFormel Trace, https://devformel.com/trace/
// Copyright (c) 2026 Dennis Powering.
// SPDX-License-Identifier: MPL-2.0
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

unit DevFormel.Trace.Sinks.LogFile;

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.IOUtils,
  DevFormel.Trace.Types,
  DevFormel.Trace.Hub;

type
  /// <summary>
  /// Writes events to a text file and starts a new file when the size limit is reached.
  /// </summary>
  /// <remarks>
  /// An event starts with a line holding local time, level, application, thread ID and
  /// message, followed by extra values in square brackets and tags in curly brackets.
  /// Exceptions add lines with class, message and stack trace, and the breadcrumbs attached
  /// to the event follow. The file is written in UTF-8 without BOM.
  /// Line breaks in messages, values and breadcrumbs are written as \n, other control
  /// characters as \uXXXX. An exception message keeps its lines; each further line starts
  /// with two spaces and a vertical bar. A logged text, for example from user input, can
  /// therefore not start a line that looks like an entry of its own. It can still contain
  /// characters such as ] or ; and so look like a further value on its line.
  /// The file stays open while events are written. Other processes can read it, but not write
  /// to it, so two running instances of an application need different file names.
  /// Write errors are ignored; the sink tries again with the next event.
  /// The default folder belongs to the current Windows user. A file set in FileName can be
  /// readable by other users, depending on the permissions of its folder.
  /// </remarks>
  // Only Windows is tested so far
  [ComponentPlatformsAttribute(pidWin32 or pidWin64)]
  TDFFileSink = class(TComponent, IDFTraceSink, IDFLocalSink)
  private
    FHub: TDFTraceHub;
    FEnabled: Boolean;
    FMinLevel: TDFLogLevel;
    FFileName: string;
    FMaxFileSizeMB: Integer;
    FMaxArchivedFiles: Integer;
    FIncludeUtcOffset: Boolean;
    FLock: TCriticalSection;
    FStream: TFileStream;
    FStreamPath: string;
    FStreamSize: Int64;
    FRetryRotationAt: Int64;

    procedure SetHub(const AValue: TDFTraceHub);
    function ResolveFilePath: string;
    procedure OpenStream(const AFilePath: string);
    procedure CloseStream;
    procedure RotateLogs(const AFilePath: string);
    function LevelToString(ALevel: TDFLogLevel): string;

    { IDFTraceSink implementation }
    function GetEnabled: Boolean;
    function GetMinLevel: TDFLogLevel;
    procedure Emit(const AEvent: TDFTraceEvent);
  protected
    /// <summary>Formats an event as the text that is appended to the file.</summary>
    /// <param name="AEvent">The event to format.</param>
    /// <returns>The lines of the entry, ending with a line break.</returns>
    function FormatEvent(const AEvent: TDFTraceEvent): string;
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
    /// <summary>Path of the file the sink writes to: FileName if set, otherwise the default
    /// path described at FileName.</summary>
    /// <remarks>Useful to show the log file or open its folder from the application. The
    /// file and its folder exist only after the first event has been written.</remarks>
    property ActiveFileName: string read ResolveFilePath;
  published
    /// <summary>Hub that passes events to this sink. Setting it registers the sink with the
    /// hub.</summary>
    property Hub: TDFTraceHub read FHub write SetHub;
    /// <summary>Turns the sink on or off.</summary>
    property Enabled: Boolean read FEnabled write FEnabled default True;
    /// <summary>Lowest level that is written; events below it are ignored.</summary>
    property MinLevel: TDFLogLevel read FMinLevel write FMinLevel default TDFLogLevel.Debug;
    /// <summary>Path of the log file.</summary>
    /// <remarks>If empty, the sink writes to Logs\trace.log in a folder named after the
    /// executable under the local application data folder, on Windows
    /// %LOCALAPPDATA%\&lt;exe name&gt;\Logs\trace.log. The application folder itself is often
    /// not writable, for example under Program Files.</remarks>
    property FileName: string read FFileName write FFileName;
    /// <summary>Size in megabytes at which a new file is started; MaxArchivedFiles decides how
    /// many old files are kept. 0: the file grows without limit.</summary>
    /// <remarks>If the file or an archive cannot be renamed or deleted, for example because
    /// another program keeps it open without allowing that, the sink keeps writing to the file
    /// and tries again after another MaxFileSizeMB.</remarks>
    property MaxFileSizeMB: Integer read FMaxFileSizeMB write FMaxFileSizeMB default 10;
    /// <summary>Number of rotated files kept (trace.log.1 to trace.log.N). 0 keeps none: the log
    /// starts over when it reaches MaxFileSizeMB.</summary>
    /// <remarks>Lowering the value does not delete archives with higher numbers that already
    /// exist.</remarks>
    property MaxArchivedFiles: Integer read FMaxArchivedFiles write FMaxArchivedFiles default 5;
    /// <summary>Appends the offset to UTC (for example +02:00) to each local timestamp.</summary>
    /// <remarks>Without the offset, entries written in the hour that repeats when daylight
    /// saving time ends cannot be told apart.</remarks>
    property IncludeUtcOffset: Boolean read FIncludeUtcOffset write FIncludeUtcOffset default True;
  end;

implementation

uses
  System.DateUtils;

function FormatUtcOffset(ALocalTime, AUtcTime: TDateTime): string;
var
  OffsetMinutes: Integer;
  Sign: Char;
begin
  OffsetMinutes := Round((ALocalTime - AUtcTime) * MinsPerDay);
  if OffsetMinutes < 0 then
    Sign := '-'
  else
    Sign := '+';
  OffsetMinutes := Abs(OffsetMinutes);
  Result := Format('%s%.2d:%.2d', [Sign, OffsetMinutes div 60, OffsetMinutes mod 60]);
end;

function IsControlChar(AChar: Char): Boolean;
begin
  case AChar of
    // All control characters except tab, and the line separators of Unicode, which some
    // viewers also show as line breaks
    #0..#8, #10..#31, #$7F, #$85, #$2028, #$2029: Result := True;
  else
    Result := False;
  end;
end;

const
  // A line break inside a message, a value or a breadcrumb
  EscapedLineBreak = '\n';
  // Starts each further line of an exception message. An entry starts with [ and a stack
  // frame with "at", so such a line cannot be taken for either.
  ContinuationPrefix = '  | ';

// Writes control characters as \uXXXX and line breaks as ALineBreak, so that a logged text,
// for example from user input, cannot start a line that a reader takes for an entry of its
// own. Line breaks at the end are dropped.
function EscapeControlChars(const AText, ALineBreak: string): string;
var
  SB: TStringBuilder;
  I, First, Last: Integer;
  C: Char;
begin
  Last := Length(AText);
  while (Last > 0) and ((AText[Last] = #13) or (AText[Last] = #10)) do
    Dec(Last);

  First := 0;
  for I := 1 to Last do
    if IsControlChar(AText[I]) then
    begin
      First := I;
      Break;
    end;
  // Most texts have nothing to replace
  if First = 0 then
  begin
    if Last = Length(AText) then
      Exit(AText);
    Exit(Copy(AText, 1, Last));
  end;

  SB := TStringBuilder.Create(Last + 16);
  try
    SB.Append(Copy(AText, 1, First - 1));
    I := First;
    while I <= Last do
    begin
      C := AText[I];
      if C = #13 then
      begin
        // CR LF is one line break
        if (I < Last) and (AText[I + 1] = #10) then
          Inc(I);
        SB.Append(ALineBreak);
      end
      else if C = #10 then
        SB.Append(ALineBreak)
      else if IsControlChar(C) then
        SB.Append('\u').Append(IntToHex(Ord(C), 4))
      else
        SB.Append(C);
      Inc(I);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function SingleLine(const AText: string): string;
begin
  Result := EscapeControlChars(AText, EscapedLineBreak);
end;

{ TDFFileSink }

constructor TDFFileSink.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FEnabled := True;
  FMinLevel := TDFLogLevel.Debug;
  FMaxFileSizeMB := 10;
  FMaxArchivedFiles := 5;
  FIncludeUtcOffset := True;
  FFileName := '';
  FLock := TCriticalSection.Create;
end;

destructor TDFFileSink.Destroy;
begin
  if Assigned(FHub) then
  begin
    // Forms free their sinks before the hub. Flushing here passes queued events to all
    // sinks while they still exist.
    FHub.Flush(FHub.ShutdownTimeoutMS);
    FHub.UnregisterSink(Self);
  end;

  CloseStream;
  FreeAndNil(FLock);
  inherited Destroy;
end;

procedure TDFFileSink.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent = FHub) then
    FHub := nil;
end;

procedure TDFFileSink.SetHub(const AValue: TDFTraceHub);
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

function TDFFileSink.GetEnabled: Boolean;
begin
  Result := FEnabled;
end;

function TDFFileSink.GetMinLevel: TDFLogLevel;
begin
  Result := FMinLevel;
end;

function TDFFileSink.ResolveFilePath: string;
begin
  if not FFileName.IsEmpty then
    Result := FFileName
  else
    // GetCachePath is %LOCALAPPDATA% on Windows: per user, writable, not roamed
    Result := TPath.Combine(TPath.Combine(TPath.Combine(TPath.GetCachePath,
      ChangeFileExt(ExtractFileName(ParamStr(0)), '')), 'Logs'), 'trace.log');
end;

function TDFFileSink.LevelToString(ALevel: TDFLogLevel): string;
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

function TDFFileSink.FormatEvent(const AEvent: TDFTraceEvent): string;
var
  SB: TStringBuilder;
  Crumb: TDFBreadcrumb;
  LocalTime: TDateTime;
  TimeText: string;

  procedure AppendPairs(const APairs: TArray<TDFKeyValuePair>; const AOpen, AClose: string);
  var
    I: Integer;
  begin
    if Length(APairs) = 0 then
      Exit;
    SB.Append(AOpen);
    for I := 0 to High(APairs) do
    begin
      if I > 0 then
        SB.Append('; ');
      SB.Append(SingleLine(APairs[I].Key)).Append('=').Append(SingleLine(APairs[I].Value));
    end;
    SB.Append(AClose);
  end;

begin
  LocalTime := TTimeZone.Local.ToLocalTime(AEvent.TimestampUtc);
  TimeText := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', LocalTime);
  if FIncludeUtcOffset then
    TimeText := TimeText + ' ' + FormatUtcOffset(LocalTime, AEvent.TimestampUtc);

  SB := TStringBuilder.Create;
  try
    SB.AppendFormat('[%s] [%s] [%s] [TID:%d] ', [
      TimeText,
      LevelToString(AEvent.Level),
      SingleLine(AEvent.AppName),
      AEvent.ThreadID
    ]);

    if not AEvent.Message.IsEmpty then
      SB.Append(SingleLine(AEvent.Message));

    // On the line of the message, so a search for a value such as Tenant=3 finds the
    // message itself and not a separate line
    AppendPairs(AEvent.Extra, ' [', ']');
    AppendPairs(AEvent.Tags, ' {', '}');

    if not AEvent.ExceptionClassName.IsEmpty then
    begin
      SB.AppendLine;
      // Database errors often have several lines and are easier to read that way
      SB.AppendFormat('Exception: %s - Message: %s', [SingleLine(AEvent.ExceptionClassName),
        EscapeControlChars(AEvent.ExceptionMessage, sLineBreak + ContinuationPrefix)]);
    end;

    if not AEvent.StackTrace.IsEmpty then
    begin
      SB.AppendLine;
      SB.AppendLine('Stack Trace:');
      SB.Append(AEvent.StackTrace);
    end;

    if Length(AEvent.Breadcrumbs) > 0 then
    begin
      SB.AppendLine;
      SB.AppendLine('Breadcrumbs:');
      for Crumb in AEvent.Breadcrumbs do
      begin
        SB.AppendFormat('  [%s] [%s] %s', [
          FormatDateTime('hh:nn:ss.zzz', TTimeZone.Local.ToLocalTime(Crumb.TimestampUtc)),
          SingleLine(Crumb.Category),
          SingleLine(Crumb.Message)
        ]).AppendLine;
      end;
    end;

    SB.AppendLine;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

procedure TDFFileSink.OpenStream(const AFilePath: string);
var
  LogDir: string;
begin
  LogDir := TPath.GetDirectoryName(AFilePath);
  if not LogDir.IsEmpty and not TDirectory.Exists(LogDir) then
    TDirectory.CreateDirectory(LogDir);

  if not TFile.Exists(AFilePath) then
    TFileStream.Create(AFilePath, fmCreate).Free;

  // Readers such as a log viewer may open the file while it is in use
  FStream := TFileStream.Create(AFilePath, fmOpenWrite or fmShareDenyWrite);
  FStreamSize := FStream.Seek(0, soEnd);
  FStreamPath := AFilePath;
end;

procedure TDFFileSink.CloseStream;
begin
  FreeAndNil(FStream);
  FStreamPath := '';
  FStreamSize := 0;
  FRetryRotationAt := 0;
end;

procedure TDFFileSink.RotateLogs(const AFilePath: string);
var
  I: Integer;
  SrcPath, DstPath: string;
begin
  // Each step on its own: a locked archive file must not stop the rotation of the others
  if FMaxArchivedFiles <= 0 then
  begin
    try
      TFile.Delete(AFilePath);
    except
    end;
    Exit;
  end;

  DstPath := Format('%s.%d', [AFilePath, FMaxArchivedFiles]);
  if TFile.Exists(DstPath) then
  begin
    try
      TFile.Delete(DstPath);
    except
    end;
  end;

  for I := FMaxArchivedFiles - 1 downto 1 do
  begin
    SrcPath := Format('%s.%d', [AFilePath, I]);
    DstPath := Format('%s.%d', [AFilePath, I + 1]);
    if TFile.Exists(SrcPath) then
    begin
      try
        TFile.Move(SrcPath, DstPath);
      except
      end;
    end;
  end;

  try
    TFile.Move(AFilePath, AFilePath + '.1');
  except
  end;
end;

procedure TDFFileSink.Emit(const AEvent: TDFTraceEvent);
var
  FilePath: string;
  Bytes: TBytes;
  MaxBytes: Int64;
begin
  if not FEnabled then Exit;

  FLock.Enter;
  try
    try
      FilePath := ResolveFilePath;
      if Assigned(FStream) and not SameFileName(FilePath, FStreamPath) then
        CloseStream;

      if not Assigned(FStream) then
        OpenStream(FilePath);

      MaxBytes := Int64(FMaxFileSizeMB) * 1024 * 1024;
      if (MaxBytes > 0) and (FStreamSize >= MaxBytes) and (FStreamSize >= FRetryRotationAt) then
      begin
        CloseStream;
        RotateLogs(FilePath);
        OpenStream(FilePath);
        // The file could not be moved or deleted, for example because another program keeps
        // it open without allowing that. Each attempt deletes the oldest archive, so trying
        // with every event would delete them all; the next attempt waits until the file has
        // grown by another MaxFileSizeMB, as between normal rotations.
        if FStreamSize >= MaxBytes then
          FRetryRotationAt := FStreamSize + MaxBytes;
      end;

      Bytes := TEncoding.UTF8.GetBytes(FormatEvent(AEvent));
      FStream.WriteBuffer(Bytes, Length(Bytes));
      Inc(FStreamSize, Length(Bytes));
    except
      // A full disk or a deleted folder must not stop the other sinks. Closing lets the next
      // event try again, for example after the folder has been recreated.
      CloseStream;
    end;
  finally
    FLock.Leave;
  end;
end;

end.
