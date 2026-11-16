// DevFormel Trace, https://devformel.com/trace/
// Copyright (c) 2026 Dennis Powering.
// SPDX-License-Identifier: MPL-2.0
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

unit DevFormel.Trace.Types;

interface

uses
  DevFormel.Trace.StackWalker,
  System.SysUtils, System.Classes,
  System.Generics.Collections,
  System.JSON;

{$SCOPEDENUMS ON}

type
  /// <summary>
  /// Level of an event or breadcrumb. Each sink ignores events below its MinLevel.
  /// </summary>
  TDFLogLevel = (
    /// <summary>Details for finding a fault, usually only written during development.</summary>
    Debug,
    /// <summary>Normal operation, such as a started job or a saved document.</summary>
    Info,
    /// <summary>Something unexpected that the application could handle, such as a retry.</summary>
    Warning,
    /// <summary>An operation failed, for example with a handled exception. From this level on,
    /// events carry the breadcrumbs.</summary>
    Error,
    /// <summary>The application cannot continue. Unhandled exceptions that end the program
    /// are sent as Fatal.</summary>
    Fatal
  );

  /// <summary>
  /// Kind of step recorded with TDFTraceHub.AddBreadcrumb.
  /// </summary>
  /// <remarks>Only the Sentry sink uses it; Sentry shows navigation, HTTP and user steps with
  /// their own icon.</remarks>
  TDFBreadcrumbType = (
    /// <summary>Any other step.</summary>
    Default,
    /// <summary>Change of window, page or tab.</summary>
    Navigation,
    /// <summary>HTTP request or response.</summary>
    Http,
    /// <summary>Action of the user, such as a button click.</summary>
    User,
    /// <summary>Event of the operating system or of the application lifecycle, such as start
    /// or resume. Sentry has no type for it and shows it like Default.</summary>
    System
  );

  /// <summary>
  /// Type of the value in a TDFKeyValuePair.
  /// </summary>
  TDFValueKind = (
    /// <summary>Text. Redacted values are always text.</summary>
    Text,
    /// <summary>Whole number (Int64).</summary>
    Integer,
    /// <summary>Floating-point number (Double).</summary>
    Float,
    /// <summary>True or false.</summary>
    Boolean
  );

  /// <summary>
  /// What the user has agreed to: which sinks receive events.
  /// </summary>
  TDFConsent = (
    /// <summary>Nothing is recorded, and no breadcrumbs are collected.</summary>
    None,
    /// <summary>Only sinks that implement IDFLocalSink receive events.</summary>
    LocalOnly,
    /// <summary>All sinks receive events.</summary>
    Full
  );

  /// <summary>
  /// A named value attached to an event as a tag or extra entry.
  /// </summary>
  /// <remarks>
  /// Value always holds the text form, which text sinks such as the log file write as is.
  /// Numbers use a period as decimal separator, booleans are written as true or false.
  /// Kind tells sinks that write JSON to write numbers and booleans as JSON numbers and
  /// booleans, so that a backend such as Seq can compare and sort them.
  /// A TDateTime matches the Double overload and becomes a number; pass dates as text,
  /// for example with DateToISO8601.
  /// </remarks>
  TDFKeyValuePair = record
    /// <summary>Name of the value.</summary>
    Key: string;
    /// <summary>Text form of the value.</summary>
    Value: string;
    /// <summary>Type of the value. Text for pairs created from a string.</summary>
    Kind: TDFValueKind;
    /// <summary>Creates a text value.</summary>
    /// <param name="AKey">Name of the value.</param>
    /// <param name="AValue">The text.</param>
    constructor Create(const AKey, AValue: string); overload;
    /// <summary>Creates a whole-number value.</summary>
    /// <param name="AKey">Name of the value.</param>
    /// <param name="AValue">The number.</param>
    constructor Create(const AKey: string; AValue: Int64); overload;
    /// <summary>Creates a floating-point value.</summary>
    /// <param name="AKey">Name of the value.</param>
    /// <param name="AValue">The number.</param>
    /// <remarks>NaN and infinity have no JSON form and are stored as text.</remarks>
    constructor Create(const AKey: string; AValue: Double); overload;
    /// <summary>Creates a boolean value.</summary>
    /// <param name="AKey">Name of the value.</param>
    /// <param name="AValue">The value.</param>
    constructor Create(const AKey: string; AValue: Boolean); overload;
    /// <summary>Returns the value as a JSON value of the matching type.</summary>
    /// <returns>A new JSON value that the caller frees or hands to a JSON object.
    /// A JSON string if Kind is Text or if Value no longer matches Kind, for example
    /// after Value was changed directly.</returns>
    function ToJSONValue: TJSONValue;
  end;

  /// <summary>
  /// A step recorded with TDFTraceHub.AddBreadcrumb.
  /// </summary>
  TDFBreadcrumb = record
    /// <summary>Time in UTC at which the breadcrumb was recorded.</summary>
    TimestampUtc: TDateTime;
    /// <summary>What happened.</summary>
    Message: string;
    /// <summary>Free text for grouping, for example 'ui' or 'db'.</summary>
    Category: string;
    /// <summary>Kind of step. Only the Sentry sink uses it.</summary>
    CrumbType: TDFBreadcrumbType;
    /// <summary>Level of the step.</summary>
    Level: TDFLogLevel;
    /// <summary>
    /// Creates a breadcrumb with the current time.
    /// </summary>
    /// <param name="AMessage">What happened.</param>
    /// <param name="ACategory">Free text for grouping.</param>
    /// <param name="ALevel">Level of the step.</param>
    /// <param name="ACrumbType">Kind of step.</param>
    /// <returns>The new breadcrumb.</returns>
    class function Create(const AMessage, ACategory: string;
      ALevel: TDFLogLevel = TDFLogLevel.Info;
      ACrumbType: TDFBreadcrumbType = TDFBreadcrumbType.Default): TDFBreadcrumb; static;
  end;

  /// <summary>
  /// An event as the sinks receive it.
  /// </summary>
  /// <remarks>The Track methods of TDFTraceHub create it; own sinks read it in
  /// IDFTraceSink.Emit.</remarks>
  TDFTraceEvent = record
    /// <summary>Unique ID of the event.</summary>
    EventID: TGUID;
    /// <summary>Time in UTC at which the event was created.</summary>
    /// <remarks>Sinks that show the time to people convert it to local time.</remarks>
    TimestampUtc: TDateTime;
    /// <summary>Level of the event.</summary>
    Level: TDFLogLevel;
    /// <summary>Text of the event; for exceptions the message of the exception.</summary>
    Message: string;
    /// <summary>Always 'DevFormel.Trace'. Sentry shows it as logger.</summary>
    LoggerName: string;
    /// <summary>Value of TDFTraceHub.AppName.</summary>
    AppName: string;
    /// <summary>Value of TDFTraceHub.Environment.</summary>
    Environment: string;
    /// <summary>Value of TDFTraceHub.AppVersion, or the file version of the executable if
    /// that is empty.</summary>
    AppVersion: string;
    /// <summary>Class name of the exception, such as EAccessViolation. Empty for events
    /// without exception.</summary>
    ExceptionClassName: string;
    /// <summary>Message of the exception.</summary>
    ExceptionMessage: string;
    /// <summary>Stack trace of the exception, one line per frame, in the format of
    /// TDFStackWalker. Empty if none could be recorded.</summary>
    StackTrace: string;
    /// <summary>ID of the thread that called the Track method.</summary>
    ThreadID: TThreadID;
    /// <summary>Breadcrumbs recorded before the event. TDFTraceHub attaches them only to events
    /// of level Error or Fatal.</summary>
    Breadcrumbs: TArray<TDFBreadcrumb>;
    /// <summary>Short values for filtering and grouping in remote backends.</summary>
    /// <remarks>Sentry indexes tags and only accepts text, so tag values are sent to
    /// Sentry as text whatever their Kind.</remarks>
    Tags: TArray<TDFKeyValuePair>;
    /// <summary>Additional values attached to the event.</summary>
    Extra: TArray<TDFKeyValuePair>;
    /// <summary>
    /// Creates an event with a new ID, the current time and the ID of the calling thread.
    /// </summary>
    /// <param name="ALevel">Level of the event.</param>
    /// <param name="AMessage">Text of the event.</param>
    /// <returns>The new event. TDFTraceHub fills in the application fields, tags and
    /// breadcrumbs when the event is submitted.</returns>
    class function Create(ALevel: TDFLogLevel; const AMessage: string): TDFTraceEvent; static;
    /// <summary>
    /// Creates an event with class name, message and stack trace of an exception.
    /// </summary>
    /// <param name="AException">The exception. nil gives an event without exception data.</param>
    /// <param name="ALevel">Level of the event.</param>
    /// <returns>The new event. If no stack trace was recorded when the exception was raised,
    /// the stack trace of the calling code is used.</returns>
    class function CreateException(const AException: Exception; ALevel: TDFLogLevel = TDFLogLevel.Error): TDFTraceEvent; static;
  end;

  /// <summary>
  /// Interface of a sink: receives events from TDFTraceHub and writes or sends them.
  /// </summary>
  /// <remarks>
  /// The hub calls Emit from a single background thread, one event at a time, in the order
  /// the events were submitted. Emit may block, for example for an HTTP request, but while
  /// it does, no other sink receives events and the queue fills up.
  /// Emit must not wait for the main thread (TThread.Synchronize): freeing a sink waits for
  /// Emit to return, so if the main thread frees it, both wait for each other.
  /// Exceptions raised in Emit are discarded; count failures in the sink if they matter.
  /// The event has already passed the sanitizer when EnablePIIScrubbing is True.
  /// Call TDFTraceHub.UnregisterSink before the sink is freed.
  /// </remarks>
  IDFTraceSink = interface
    ['{8F4E2A10-1704-4C23-9118-2B7A81E9802A}']
    /// <summary>Read method of Enabled.</summary>
    /// <returns>True if the sink receives events.</returns>
    function GetEnabled: Boolean;
    /// <summary>Read method of MinLevel.</summary>
    /// <returns>The lowest level the sink receives.</returns>
    function GetMinLevel: TDFLogLevel;
    /// <summary>
    /// Writes or sends one event.
    /// </summary>
    /// <param name="Event">The event. The hub calls Emit only if Enabled is True, the level of
    /// the event is at least MinLevel and TDFTraceHub.Consent allows it.</param>
    procedure Emit(const Event: TDFTraceEvent);
    /// <summary>False: the hub passes no events to the sink.</summary>
    property Enabled: Boolean read GetEnabled;
    /// <summary>Lowest level the hub passes to the sink.</summary>
    property MinLevel: TDFLogLevel read GetMinLevel;
  end;

  /// <summary>
  /// Marks a sink that keeps events where the application runs instead of sending them to a
  /// service.
  /// </summary>
  /// <remarks>
  /// With TDFTraceHub.Consent set to LocalOnly, only sinks that implement this interface
  /// receive events. The log file, memo and Windows event log sinks implement it.
  /// It has no methods. List it next to IDFTraceSink, for example
  /// <c>class(TComponent, IDFTraceSink, IDFLocalSink)</c>.
  /// </remarks>
  IDFLocalSink = interface
    ['{3B393B10-678D-4A60-82C1-534D4687F1F2}']
  end;

  /// <summary>
  /// Measures the time until Stop is called or the last reference is released, then sends
  /// one event with the extra values DurationMS and Operation.
  /// </summary>
  /// <remarks>
  /// Returned by TDFTraceHub.TrackScope. A scope that is not assigned to a variable lives
  /// until the end of the calling method. Release the scope before the hub is freed.
  /// </remarks>
  IDFTraceScope = interface
    ['{A72480CE-2531-47EF-B652-2B8BEBCBA29A}']
    /// <summary>Ends the measurement and sends the event. Further calls do nothing.</summary>
    procedure Stop;
  end;

implementation

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ELSE}
  System.DateUtils,
  {$ENDIF}
  System.Math;

// Reads UTC from the system clock instead of converting Now: the local hour that
// repeats when daylight saving time ends cannot be converted unambiguously.
function UtcNow: TDateTime;
{$IFDEF MSWINDOWS}
var
  SystemTime: TSystemTime;
begin
  GetSystemTime(SystemTime);
  Result := SystemTimeToDateTime(SystemTime);
end;
{$ELSE}
begin
  Result := TTimeZone.Local.ToUniversalTime(Now);
end;
{$ENDIF}

{ TDFKeyValuePair }

constructor TDFKeyValuePair.Create(const AKey, AValue: string);
begin
  Key := AKey;
  Value := AValue;
  Kind := TDFValueKind.Text;
end;

constructor TDFKeyValuePair.Create(const AKey: string; AValue: Int64);
begin
  Key := AKey;
  Value := IntToStr(AValue);
  Kind := TDFValueKind.Integer;
end;

constructor TDFKeyValuePair.Create(const AKey: string; AValue: Double);
begin
  Key := AKey;
  // Invariant format, so the text form does not depend on the user's locale
  Value := FloatToStr(AValue, TFormatSettings.Invariant);
  if IsNan(AValue) or IsInfinite(AValue) then
    Kind := TDFValueKind.Text
  else
    Kind := TDFValueKind.Float;
end;

constructor TDFKeyValuePair.Create(const AKey: string; AValue: Boolean);
begin
  Key := AKey;
  if AValue then
    Value := 'true'
  else
    Value := 'false';
  Kind := TDFValueKind.Boolean;
end;

function TDFKeyValuePair.ToJSONValue: TJSONValue;
var
  IntValue: Int64;
  FloatValue: Double;
begin
  // The typed value is read back from the text, so Value stays the only source and the
  // sanitizer only has to look at one field.
  case Kind of
    TDFValueKind.Integer:
      if TryStrToInt64(Value, IntValue) then
        Exit(TJSONNumber.Create(IntValue));
    TDFValueKind.Float:
      if TryStrToFloat(Value, FloatValue, TFormatSettings.Invariant) then
        Exit(TJSONNumber.Create(FloatValue));
    TDFValueKind.Boolean:
      if (Value = 'true') or (Value = 'false') then
        Exit(TJSONBool.Create(Value = 'true'));
  end;
  Result := TJSONString.Create(Value);
end;

{ TDFBreadcrumb }

class function TDFBreadcrumb.Create(const AMessage, ACategory: string;
  ALevel: TDFLogLevel; ACrumbType: TDFBreadcrumbType): TDFBreadcrumb;
begin
  Result.TimestampUtc := UtcNow;
  Result.Message := AMessage;
  Result.Category := ACategory;
  Result.Level := ALevel;
  Result.CrumbType := ACrumbType;
end;

{ TDFTraceEvent }

class function TDFTraceEvent.Create(ALevel: TDFLogLevel; const AMessage: string): TDFTraceEvent;
begin
  CreateGUID(Result.EventID);
  Result.TimestampUtc := UtcNow;
  Result.Level := ALevel;
  Result.Message := AMessage;
  Result.LoggerName := 'DevFormel.Trace';

  // AppName, Environment and AppVersion are set by the hub when the event is submitted
  Result.Environment := '';
  Result.AppVersion := '';
  Result.ExceptionClassName := '';
  Result.ExceptionMessage := '';
  Result.StackTrace := '';
  Result.ThreadID := TThread.CurrentThread.ThreadID;
  Result.Breadcrumbs := nil;
  Result.Tags := nil;
  Result.Extra := nil;
end;

class function TDFTraceEvent.CreateException(const AException: Exception;
  ALevel: TDFLogLevel): TDFTraceEvent;
begin
  if Assigned(AException) then
  begin
    Result := TDFTraceEvent.Create(ALevel, AException.Message);
    Result.ExceptionClassName := AException.ClassName;
    Result.ExceptionMessage := AException.Message;

    try
      // Recorded where the exception was raised, by TDFStackWalker or another provider
      Result.StackTrace := AException.StackTrace;

      // Without a provider, at least show where the exception is being reported
      if Result.StackTrace.IsEmpty then
        Result.StackTrace := TDFStackWalker.GetStackTrace(3);
    except
      // A failing stack trace must not cost the event itself
      Result.StackTrace := '';
    end;
  end
  else
    Result := TDFTraceEvent.Create(ALevel, '');
end;

end.
