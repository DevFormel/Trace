// DevFormel Trace, https://devformel.com/trace/
// Copyright (c) 2026 Dennis Powering.
// SPDX-License-Identifier: MPL-2.0
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

unit DevFormel.Trace.Tests.Sinks;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TSentrySinkTests = class
  public
    [Test]
    [TestCase('Plain', 'https://abc123@sentry.example.com/42|https://sentry.example.com/api/42/envelope/', '|')]
    [TestCase('BelowPath', 'https://abc123@sentry.example.com/sentry/42|https://sentry.example.com/sentry/api/42/envelope/', '|')]
    [TestCase('OwnPort', 'http://abc123@localhost:8000/1|http://localhost:8000/api/1/envelope/', '|')]
    [TestCase('SecretAndDefaultPort', 'https://abc123:secret@sentry.example.com:443/42|https://sentry.example.com/api/42/envelope/', '|')]
    procedure ParseDSN_ValidDSN_GivesEndpointAndKey(const ADSN, AExpectedEndpoint: string);

    [Test]
    [TestCase('NoKey', 'https://sentry.example.com/42')]
    [TestCase('NoProject', 'https://abc123@sentry.example.com/')]
    procedure ParseDSN_IncompleteDSN_Fails(const ADSN: string);

    [Test]
    procedure BuildStackFrame_ResolvedLine_SplitsFunctionModuleAndLine;

    [Test]
    procedure BuildStackFrame_WithoutLine_HasNoLineNumber;

    [Test]
    procedure BuildStackFrame_DelphiUnit_IsNotInApp;

    [Test]
    procedure BuildStackFrame_ModuleOffset_KeepsTextAndSetsPackage;

    // Lines from another stack trace provider
    [Test]
    procedure BuildStackFrame_OtherFormat_KeepsLine;
  end;

  [TestFixture]
  THttpSinkTests = class
  public
    // Header value, pause without a usable header, expected pause
    [Test]
    [TestCase('Seconds', '120|30|120', '|')]
    [TestCase('Zero', '0|30|0', '|')]
    [TestCase('Missing', '|30|30', '|')]
    [TestCase('Date', 'Wed, 21 Oct 2026 07:28:00 GMT|30|30', '|')]
    [TestCase('Negative', '-5|30|30', '|')]
    [TestCase('MoreThanAnHour', '999999999|30|3600', '|')]
    procedure PauseFromRetryAfter_StaysWithinLimits(const AHeaderValue: string;
      ADefaultSeconds, AExpected: Integer);

    // Following a redirect sends the event and the key to another address
    [Test]
    procedure FollowRedirects_IsOffByDefault;
  end;

  [TestFixture]
  TFileSinkTests = class
  public
    [Test]
    procedure FormatEvent_ExtraAndTags_AreOnTheMessageLine;

    // A line break in a logged text must not start a line that looks like a new entry
    [Test]
    procedure FormatEvent_LineBreakInMessage_StaysOnOneLine;

    [Test]
    procedure FormatEvent_LineBreaksInValuesAndBreadcrumb_AreEscaped;

    [Test]
    procedure FormatEvent_MultiLineExceptionMessage_KeepsLinesWithPrefix;

    [Test]
    procedure FormatEvent_ControlCharacter_IsEscaped;

    [Test]
    procedure ActiveFileName_WithoutFileName_IsDefaultPath;

    [Test]
    procedure ActiveFileName_WithFileName_IsFileName;

    [Test]
    procedure Rotation_KeepsMaxArchivedFiles;

    [Test]
    procedure Rotation_NoArchives_StartsOver;

    // A file that another program keeps open cannot be renamed; that must not cost archives
    [Test]
    procedure Rotation_FileKeptOpenByOtherProgram_KeepsArchives;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.JSON,
  DevFormel.Trace.Types,
  DevFormel.Trace.Sinks.LogFile,
  DevFormel.Trace.Sinks.Seq,
  DevFormel.Trace.Sinks.Sentry;

type
  // Reaches the protected ParseDSN
  TSentrySinkAccess = class(TDFSentrySink);
  // Reaches the protected FormatEvent
  TFileSinkAccess = class(TDFFileSink);
  // Reaches the protected PauseFromRetryAfter
  TSeqSinkAccess = class(TDFSeqSink);

function FormatWithFileSink(const AEvent: TDFTraceEvent): string;
var
  Sink: TFileSinkAccess;
begin
  // Without a hub the sink opens no file
  Sink := TFileSinkAccess.Create(nil);
  try
    Result := Sink.FormatEvent(AEvent);
  finally
    Sink.Free;
  end;
end;

const
  // Two of these events exceed 1 MB, the smallest size MaxFileSizeMB allows
  LargeEventSize = 600 * 1024;

// A path in a new folder below the temp folder, so that files of earlier runs do not count
function NewTempLogFile: string;
begin
  Result := TPath.Combine(TPath.Combine(TPath.GetTempPath,
    'DFTraceTests-' + TGUID.NewGuid.ToString), 'trace.log');
end;

function CreateRotatingSink(const AFileName: string; AMaxArchivedFiles: Integer): TDFFileSink;
begin
  Result := TDFFileSink.Create(nil);
  Result.FileName := AFileName;
  Result.MaxFileSizeMB := 1;
  Result.MaxArchivedFiles := AMaxArchivedFiles;
end;

function FileSizeOf(const AFileName: string): Int64;
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  try
    Result := Stream.Size;
  finally
    Stream.Free;
  end;
end;

// Emit is reached through the interface; the sink writes without a hub
procedure EmitText(const ASink: IDFTraceSink; ALength: Integer);
begin
  ASink.Emit(TDFTraceEvent.Create(TDFLogLevel.Info, StringOfChar('x', ALength)));
end;

// Number of lines that start at the first column like an entry does
function CountLineStarts(const AText: string): Integer;
var
  Line: string;
begin
  Result := 0;
  for Line in AText.Split([sLineBreak]) do
    if Line.StartsWith('[') then
      Inc(Result);
end;

procedure TSentrySinkTests.ParseDSN_ValidDSN_GivesEndpointAndKey(const ADSN, AExpectedEndpoint: string);
var
  Endpoint, PublicKey: string;
begin
  Assert.IsTrue(TSentrySinkAccess.ParseDSN(ADSN, Endpoint, PublicKey), 'Result');
  Assert.AreEqual(AExpectedEndpoint, Endpoint);
  Assert.AreEqual('abc123', PublicKey);
end;

procedure TSentrySinkTests.ParseDSN_IncompleteDSN_Fails(const ADSN: string);
var
  Endpoint, PublicKey: string;
begin
  Assert.IsFalse(TSentrySinkAccess.ParseDSN(ADSN, Endpoint, PublicKey), 'Result');
  Assert.AreEqual('', Endpoint);
  Assert.AreEqual('', PublicKey);
end;

procedure TSentrySinkTests.BuildStackFrame_ResolvedLine_SplitsFunctionModuleAndLine;
var
  Frame: TJSONObject;
begin
  Frame := TSentrySinkAccess.BuildStackFrame('  at uMainForm.TFormMain.btnSaveClick in uMainForm:line 42');
  try
    Assert.AreEqual('uMainForm.TFormMain.btnSaveClick', Frame.GetValue<string>('function'));
    Assert.AreEqual('uMainForm', Frame.GetValue<string>('module'));
    Assert.AreEqual(42, Frame.GetValue<Integer>('lineno'));
    Assert.IsTrue(Frame.GetValue<Boolean>('in_app'), 'in_app');
  finally
    Frame.Free;
  end;
end;

procedure TSentrySinkTests.BuildStackFrame_WithoutLine_HasNoLineNumber;
var
  Frame: TJSONObject;
begin
  Frame := TSentrySinkAccess.BuildStackFrame('at uMainForm.TFormMain.Helper in uMainForm');
  try
    Assert.AreEqual('uMainForm.TFormMain.Helper', Frame.GetValue<string>('function'));
    Assert.AreEqual('uMainForm', Frame.GetValue<string>('module'));
    Assert.IsNull(Frame.GetValue('lineno'), 'lineno');
  finally
    Frame.Free;
  end;
end;

procedure TSentrySinkTests.BuildStackFrame_DelphiUnit_IsNotInApp;
var
  Frame: TJSONObject;
begin
  Frame := TSentrySinkAccess.BuildStackFrame('at System.SysUtils.Abort in System.SysUtils:line 100');
  try
    Assert.IsFalse(Frame.GetValue<Boolean>('in_app'), 'in_app');
  finally
    Frame.Free;
  end;
end;

procedure TSentrySinkTests.BuildStackFrame_ModuleOffset_KeepsTextAndSetsPackage;
var
  Frame: TJSONObject;
begin
  Frame := TSentrySinkAccess.BuildStackFrame('at user32.dll+$1A2B');
  try
    Assert.AreEqual('user32.dll+$1A2B', Frame.GetValue<string>('function'));
    Assert.AreEqual('user32.dll', Frame.GetValue<string>('package'));
    Assert.IsFalse(Frame.GetValue<Boolean>('in_app'), 'in_app');
  finally
    Frame.Free;
  end;
end;

procedure TSentrySinkTests.BuildStackFrame_OtherFormat_KeepsLine;
var
  Frame: TJSONObject;
begin
  Frame := TSentrySinkAccess.BuildStackFrame('0040A1B2 Unit1 42 TForm1.Button1Click');
  try
    Assert.AreEqual('0040A1B2 Unit1 42 TForm1.Button1Click', Frame.GetValue<string>('function'));
    Assert.IsNull(Frame.GetValue('module'), 'module');
  finally
    Frame.Free;
  end;
end;

{ THttpSinkTests }

procedure THttpSinkTests.PauseFromRetryAfter_StaysWithinLimits(const AHeaderValue: string;
  ADefaultSeconds, AExpected: Integer);
begin
  Assert.AreEqual(AExpected, TSeqSinkAccess.PauseFromRetryAfter(AHeaderValue, ADefaultSeconds), 'Seq');
  Assert.AreEqual(AExpected, TSentrySinkAccess.PauseFromRetryAfter(AHeaderValue, ADefaultSeconds), 'Sentry');
end;

procedure THttpSinkTests.FollowRedirects_IsOffByDefault;
var
  Seq: TDFSeqSink;
  Sentry: TDFSentrySink;
begin
  Seq := TDFSeqSink.Create(nil);
  try
    Assert.IsFalse(Seq.FollowRedirects, 'Seq');
  finally
    Seq.Free;
  end;

  Sentry := TDFSentrySink.Create(nil);
  try
    Assert.IsFalse(Sentry.FollowRedirects, 'Sentry');
  finally
    Sentry.Free;
  end;
end;

{ TFileSinkTests }

procedure TFileSinkTests.FormatEvent_ExtraAndTags_AreOnTheMessageLine;
var
  Event: TDFTraceEvent;
  Text: string;
begin
  Event := TDFTraceEvent.Create(TDFLogLevel.Info, 'Order saved');
  Event.Extra := [TDFKeyValuePair.Create('OrderId', 4711)];
  Event.Tags := [TDFKeyValuePair.Create('Module', 'Demo')];

  Text := FormatWithFileSink(Event);

  Assert.IsTrue(Text.EndsWith('Order saved [OrderId=4711] {Module=Demo}' + sLineBreak), Text);
  Assert.AreEqual(1, CountLineStarts(Text));
end;

procedure TFileSinkTests.FormatEvent_LineBreakInMessage_StaysOnOneLine;
const
  Forged = '[2026-11-14 10:00:00.000 +01:00] [INFO ] [App] [TID:1] Login succeeded for admin';
var
  Text: string;
begin
  Text := FormatWithFileSink(TDFTraceEvent.Create(TDFLogLevel.Warning,
    'Login failed for bob' + #13#10 + Forged));

  Assert.AreEqual(1, CountLineStarts(Text), Text);
  Assert.IsTrue(Text.Contains('Login failed for bob\n' + Forged), Text);
end;

procedure TFileSinkTests.FormatEvent_LineBreaksInValuesAndBreadcrumb_AreEscaped;
var
  Event: TDFTraceEvent;
  Text: string;
begin
  Event := TDFTraceEvent.Create(TDFLogLevel.Error, 'Import failed');
  Event.Extra := [TDFKeyValuePair.Create('File', 'a.csv' + #10 + '[forged extra')];
  Event.Tags := [TDFKeyValuePair.Create('Module', 'Import' + #13 + '[forged tag')];
  Event.Breadcrumbs := [TDFBreadcrumb.Create('Clicked' + #10 + '[forged crumb', 'ui')];

  Text := FormatWithFileSink(Event);

  Assert.AreEqual(1, CountLineStarts(Text), Text);
  Assert.IsTrue(Text.Contains('File=a.csv\n[forged extra'), 'Extra');
  Assert.IsTrue(Text.Contains('Module=Import\n[forged tag'), 'Tag');
  Assert.IsTrue(Text.Contains('Clicked\n[forged crumb'), 'Breadcrumb');
end;

procedure TFileSinkTests.FormatEvent_MultiLineExceptionMessage_KeepsLinesWithPrefix;
var
  Event: TDFTraceEvent;
  Text: string;
begin
  Event := TDFTraceEvent.Create(TDFLogLevel.Error, 'Import failed');
  Event.ExceptionClassName := 'EDatabaseError';
  // CR LF, a single LF and a line break at the end, which must not add an empty line
  Event.ExceptionMessage := 'Incorrect syntax' + #13#10 + '[forged entry' + #10 + 'Stack Trace:' + #13#10;

  Text := FormatWithFileSink(Event);

  Assert.AreEqual(1, CountLineStarts(Text), Text);
  Assert.IsTrue(Text.EndsWith(
    'Exception: EDatabaseError - Message: Incorrect syntax' + sLineBreak +
    '  | [forged entry' + sLineBreak +
    '  | Stack Trace:' + sLineBreak), Text);
end;

procedure TFileSinkTests.FormatEvent_ControlCharacter_IsEscaped;
var
  Text: string;
begin
  // ESC starts the sequences that change colors or move the cursor in a terminal
  Text := FormatWithFileSink(TDFTraceEvent.Create(TDFLogLevel.Info, 'a' + #27 + '[31mb' + #9 + 'c'));

  Assert.IsTrue(Text.Contains('a\u001B[31mb' + #9 + 'c'), Text);
end;

procedure TFileSinkTests.ActiveFileName_WithoutFileName_IsDefaultPath;
var
  Sink: TDFFileSink;
begin
  Sink := TDFFileSink.Create(nil);
  try
    Assert.AreEqual(TPath.Combine(TPath.GetCachePath,
      TPath.GetFileNameWithoutExtension(ParamStr(0)) + '\Logs\trace.log'), Sink.ActiveFileName);
  finally
    Sink.Free;
  end;
end;

procedure TFileSinkTests.ActiveFileName_WithFileName_IsFileName;
var
  Sink: TDFFileSink;
begin
  Sink := TDFFileSink.Create(nil);
  try
    Sink.FileName := 'C:\Logs\app.log';
    Assert.AreEqual('C:\Logs\app.log', Sink.ActiveFileName);
  finally
    Sink.Free;
  end;
end;

procedure TFileSinkTests.Rotation_KeepsMaxArchivedFiles;
var
  LogFile: string;
  Sink: TDFFileSink;
  SinkIntf: IDFTraceSink;
  I: Integer;
begin
  LogFile := NewTempLogFile;
  Sink := CreateRotatingSink(LogFile, 2);
  try
    SinkIntf := Sink;
    // Rotations at the 3rd, 5th and 7th event; the third one drops the oldest archive
    for I := 1 to 7 do
      EmitText(SinkIntf, LargeEventSize);
    SinkIntf := nil;
  finally
    Sink.Free;
  end;

  try
    Assert.IsTrue(TFile.Exists(LogFile), 'trace.log');
    Assert.IsTrue(TFile.Exists(LogFile + '.1'), 'trace.log.1');
    Assert.IsTrue(TFile.Exists(LogFile + '.2'), 'trace.log.2');
    Assert.IsFalse(TFile.Exists(LogFile + '.3'), 'trace.log.3');
  finally
    TDirectory.Delete(TPath.GetDirectoryName(LogFile), True);
  end;
end;

procedure TFileSinkTests.Rotation_NoArchives_StartsOver;
var
  LogFile: string;
  Sink: TDFFileSink;
  SinkIntf: IDFTraceSink;
  I: Integer;
begin
  LogFile := NewTempLogFile;
  Sink := CreateRotatingSink(LogFile, 0);
  try
    SinkIntf := Sink;
    for I := 1 to 3 do
      EmitText(SinkIntf, LargeEventSize);
    SinkIntf := nil;
  finally
    Sink.Free;
  end;

  try
    Assert.IsFalse(TFile.Exists(LogFile + '.1'), 'trace.log.1');
    Assert.IsTrue(FileSizeOf(LogFile) < 1024 * 1024, 'The file did not start over');
  finally
    TDirectory.Delete(TPath.GetDirectoryName(LogFile), True);
  end;
end;

procedure TFileSinkTests.Rotation_FileKeptOpenByOtherProgram_KeepsArchives;
var
  LogFile: string;
  Sink: TDFFileSink;
  SinkIntf: IDFTraceSink;
  Reader: TFileStream;
  I: Integer;
begin
  LogFile := NewTempLogFile;
  Sink := CreateRotatingSink(LogFile, 2);
  try
    SinkIntf := Sink;
    // Afterwards: trace.log above 1 MB, trace.log.1 and trace.log.2
    for I := 1 to 6 do
      EmitText(SinkIntf, LargeEventSize);

    // Reading and writing allowed, renaming not, as with many log viewers
    Reader := TFileStream.Create(LogFile, fmOpenRead or fmShareDenyNone);
    try
      // The first event tries to rotate and fails; the following ones must not try again
      for I := 1 to 3 do
        EmitText(SinkIntf, 100);
    finally
      Reader.Free;
    end;
    SinkIntf := nil;
  finally
    Sink.Free;
  end;

  try
    Assert.IsTrue(TFile.Exists(LogFile + '.2'),
      'Events that could not rotate deleted further archives');
  finally
    TDirectory.Delete(TPath.GetDirectoryName(LogFile), True);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TSentrySinkTests);
  TDUnitX.RegisterTestFixture(THttpSinkTests);
  TDUnitX.RegisterTestFixture(TFileSinkTests);

end.
