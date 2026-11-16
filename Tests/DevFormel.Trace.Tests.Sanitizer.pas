// DevFormel Trace, https://devformel.com/trace/
// Copyright (c) 2026 Dennis Powering.
// SPDX-License-Identifier: MPL-2.0
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

unit DevFormel.Trace.Tests.Sanitizer;

interface

uses
  System.Classes,
  DUnitX.TestFramework;

type
  [TestFixture]
  TSanitizerTests = class
  private
    FFailures: Integer;
    function CreateWorker(const AInput, AExpected: string): TThread;
  public
    // Patterns the sanitizer already handles
    [Test]
    [TestCase('Email', 'Contact admin@company.local now|Contact [EMAIL_REDACTED] now', '|')]
    [TestCase('IPv4', 'Connection from 192.168.1.100 refused|Connection from [IP_REDACTED] refused', '|')]
    [TestCase('WindowsUserPath', 'Cannot open C:\Users\mmueller\Documents\a.txt|Cannot open C:\Users\[USER_REDACTED]\Documents\a.txt', '|')]
    [TestCase('UnixUserPath', 'Cannot open /home/mmueller/app.log|Cannot open /home/[USER_REDACTED]/app.log', '|')]
    [TestCase('JoinedEmails', 'From a@b.de-c@d.org|From [EMAIL_REDACTED][EMAIL_REDACTED]', '|')]
    [TestCase('NothingToRedact', 'Order 4711 shipped|Order 4711 shipped', '|')]
    // Gaps found in the review: expected to fail until the sanitizer is extended
    [TestCase('EmailWithUmlauts', 'Mail to jürgen.müller@bäckerei-müller.de|Mail to [EMAIL_REDACTED]', '|')]
    [TestCase('UrlEncodedEmail', 'GET /api?email=max%40example.com|GET /api?email=[EMAIL_REDACTED]', '|')]
    [TestCase('PasswordInConnectionString', 'Server=SQL01;User ID=sa;Password=Sommer2026!|Server=SQL01;User ID=sa;Password=[REDACTED]', '|')]
    [TestCase('AccessTokenInUrl', 'https://api.example.com/v1?access_token=eyJabc.def&user=42|https://api.example.com/v1?access_token=[REDACTED]&user=42', '|')]
    [TestCase('BearerToken', 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc|Authorization: Bearer [REDACTED]', '|')]
    [TestCase('GermanPasswort', 'Anmeldung: Benutzer=mm; Passwort=Sommer2026|Anmeldung: Benutzer=mm; Passwort=[REDACTED]', '|')]
    [TestCase('GermanKennwort', 'Kennwort: Sommer2026|Kennwort: [REDACTED]', '|')]
    procedure ScrubText_RedactsPersonalData(const AInput, AExpected: string);

    [Test]
    procedure ScrubText_EmptyInput_ReturnsEmpty;

    // Gap: the current user name appears in paths the path patterns do not know
    [Test]
    procedure ScrubText_CurrentUserNameInUncPath_IsRedacted;

    // Gap: values under secret keys are not recognizable by their content
    [Test]
    procedure ScrubEvent_SecretKeysInExtraAndTags_AreRedacted;

    [Test]
    procedure ScrubEvent_UnchangedNumber_KeepsKind;

    [Test]
    procedure ScrubEvent_RedactedNumber_BecomesText;

    [Test]
    procedure ScrubText_ParallelCalls_GiveSameResultAsSingleThread;

    // Long repetitive texts are where a pattern may start over at every character. Each
    // text stops at the first size that takes too long, so the test cannot block the run.
    [Test]
    procedure ScrubText_LongRepetitiveText_IsRedactedInTime;

    // AddSecretKey and AddScrubRule change global state; the keys and patterns used here
    // appear in no other test.
    [Test]
    procedure AddSecretKey_RedactsValueInTextAndExtra;

    [Test]
    procedure AddScrubRule_ReplacesMatches;

    [Test]
    procedure AddScrubRule_InvalidPattern_Raises;
  end;

implementation

uses
  System.SysUtils,
  System.SyncObjs,
  System.StrUtils,
  System.Diagnostics,
  DevFormel.Trace.Types,
  DevFormel.Trace.Sanitizer;

const
  ParallelThreads = 8;
  ParallelIterations = 2000;

procedure TSanitizerTests.ScrubText_RedactsPersonalData(const AInput, AExpected: string);
begin
  Assert.AreEqual(AExpected, TDFPIISanitizer.ScrubText(AInput));
end;

procedure TSanitizerTests.ScrubText_EmptyInput_ReturnsEmpty;
begin
  Assert.AreEqual('', TDFPIISanitizer.ScrubText(''));
end;

procedure TSanitizerTests.ScrubText_CurrentUserNameInUncPath_IsRedacted;
var
  UserName: string;
begin
  UserName := GetEnvironmentVariable('USERNAME');
  Assert.IsNotEmpty(UserName, 'USERNAME is not set');

  Assert.AreEqual('Cannot open \\fileserver\home$\[USER_REDACTED]\Angebot.docx',
    TDFPIISanitizer.ScrubText(Format('Cannot open \\fileserver\home$\%s\Angebot.docx', [UserName])));
end;

procedure TSanitizerTests.ScrubEvent_SecretKeysInExtraAndTags_AreRedacted;
var
  Event: TDFTraceEvent;
begin
  Event := TDFTraceEvent.Create(TDFLogLevel.Info, 'test');
  Event.Extra := [
    TDFKeyValuePair.Create('Password', 'Sommer2026!'),
    TDFKeyValuePair.Create('Table', 'Customers')];
  Event.Tags := [TDFKeyValuePair.Create('api_key', 'abc123')];

  TDFPIISanitizer.ScrubEvent(Event);

  Assert.AreEqual('[REDACTED]', Event.Extra[0].Value);
  Assert.AreEqual('Customers', Event.Extra[1].Value, 'Ordinary values must stay');
  Assert.AreEqual('[REDACTED]', Event.Tags[0].Value);
end;

procedure TSanitizerTests.ScrubEvent_UnchangedNumber_KeepsKind;
var
  Event: TDFTraceEvent;
begin
  Event := TDFTraceEvent.Create(TDFLogLevel.Info, 'test');
  Event.Extra := [TDFKeyValuePair.Create('DurationMS', 1250)];

  TDFPIISanitizer.ScrubEvent(Event);

  Assert.AreEqual('1250', Event.Extra[0].Value);
  Assert.IsTrue(Event.Extra[0].Kind = TDFValueKind.Integer, 'Kind');
end;

procedure TSanitizerTests.ScrubEvent_RedactedNumber_BecomesText;
var
  Event: TDFTraceEvent;
begin
  Event := TDFTraceEvent.Create(TDFLogLevel.Info, 'test');
  Event.Extra := [TDFKeyValuePair.Create('SessionToken', 123456)];

  TDFPIISanitizer.ScrubEvent(Event);

  Assert.AreEqual('[REDACTED]', Event.Extra[0].Value);
  Assert.IsTrue(Event.Extra[0].Kind = TDFValueKind.Text, 'A redacted number must be sent as text');
end;

function TSanitizerTests.CreateWorker(const AInput, AExpected: string): TThread;
begin
  // Parameters instead of loop variables: an anonymous method captures variables, not values
  Result := TThread.CreateAnonymousThread(
    procedure
    var
      I: Integer;
    begin
      for I := 1 to ParallelIterations do
        if TDFPIISanitizer.ScrubText(AInput) <> AExpected then
          TInterlocked.Increment(FFailures);
    end);
  Result.FreeOnTerminate := False;
end;

procedure TSanitizerTests.ScrubText_ParallelCalls_GiveSameResultAsSingleThread;
var
  Threads: array[0..ParallelThreads - 1] of TThread;
  Input: string;
  I: Integer;
begin
  FFailures := 0;
  for I := 0 to ParallelThreads - 1 do
  begin
    Input := Format('User user%d@example.com from 10.0.0.%d in C:\Users\person%d\file.txt', [I, I, I]);
    Threads[I] := CreateWorker(Input, TDFPIISanitizer.ScrubText(Input));
  end;

  for I := 0 to ParallelThreads - 1 do
    Threads[I].Start;
  for I := 0 to ParallelThreads - 1 do
  begin
    Threads[I].WaitFor;
    Threads[I].Free;
  end;

  Assert.AreEqual(0, FFailures);
end;

procedure TSanitizerTests.ScrubText_LongRepetitiveText_IsRedactedInTime;
const
  Sizes: array[0..3] of Integer = (10000, 30000, 100000, 200000);
  // Repeated up to the size: one long word, digits, dots, encoded and plain @ signs,
  // addresses without a gap, the start of an IP address, of a user path and a secret key
  Parts: array[0..8] of string = ('a', '1', 'a.', '%40', 'a@', 'a@b.cd-', '1.', 'c:\Users', 'token ');
  Address = ' someone@example.com';
  LimitMS = 1000;
var
  Part, Input, Scrubbed, Outcome, Problems: string;
  Size: Integer;
  Watch: TStopwatch;
  ElapsedMS: Int64;
begin
  Problems := '';
  System.Writeln;
  for Part in Parts do
    for Size in Sizes do
    begin
      Input := DupeString(Part, Size div Length(Part)) + Address;

      Watch := TStopwatch.StartNew;
      Scrubbed := TDFPIISanitizer.ScrubText(Input);
      ElapsedMS := Watch.ElapsedMilliseconds;

      if Scrubbed.EndsWith(' [EMAIL_REDACTED]') then
        Outcome := 'redacted'
      else if Scrubbed.EndsWith(Address) then
        Outcome := 'NOT redacted'
      else if Scrubbed = '[REDACTED]' then
        Outcome := 'whole text replaced'
      else
        Outcome := 'unexpected result';

      // Printed for every size: how the time grows shows more than the first failure
      System.Writeln(Format('  %-9s %7d chars: %6d ms, %s', [Part, Size, ElapsedMS, Outcome]));

      if (Outcome <> 'redacted') or (ElapsedMS > LimitMS) then
        Problems := Problems + Format('"%s" %d chars: %d ms, %s; ', [Part, Size, ElapsedMS, Outcome]);

      // The time may grow with the square of the length, so the next size could take minutes
      if ElapsedMS > LimitMS then
        Break;
    end;

  Assert.IsTrue(Problems.IsEmpty, Problems);
end;

procedure TSanitizerTests.AddSecretKey_RedactsValueInTextAndExtra;
var
  Event: TDFTraceEvent;
begin
  TDFPIISanitizer.AddSecretKey('pin');

  Assert.AreEqual('Login with pin=[REDACTED] failed', TDFPIISanitizer.ScrubText('Login with pin=4711 failed'));

  Event := TDFTraceEvent.Create(TDFLogLevel.Info, 'test');
  Event.Extra := [TDFKeyValuePair.Create('PIN', '4711')];
  TDFPIISanitizer.ScrubEvent(Event);
  Assert.AreEqual('[REDACTED]', Event.Extra[0].Value);
end;

procedure TSanitizerTests.AddScrubRule_ReplacesMatches;
begin
  TDFPIISanitizer.AddScrubRule('\bDE\d{20}\b', '[IBAN_REDACTED]');

  Assert.AreEqual('Transfer to [IBAN_REDACTED] done',
    TDFPIISanitizer.ScrubText('Transfer to DE89370400440532013000 done'));
end;

procedure TSanitizerTests.AddScrubRule_InvalidPattern_Raises;
begin
  Assert.WillRaiseAny(
    procedure
    begin
      TDFPIISanitizer.AddScrubRule('(unclosed', 'x');
    end);
end;

initialization
  TDUnitX.RegisterTestFixture(TSanitizerTests);

end.
